import AppKit
import Combine
import Network
import OutpostCore
import ServiceManagement

enum KeepAwakeOption: Hashable, Identifiable {
    case off
    case indefinitely
    case minutes(Int)
    case whileClaudeWorks

    static let chips: [KeepAwakeOption] = [.off, .minutes(60), .minutes(240), .indefinitely, .whileClaudeWorks]

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .indefinitely: "Always"
        case .minutes(let m): AppModel.format(TimeInterval(m) * 60)
        case .whileClaudeWorks: "While Claude works"
        }
    }
}

/// When On the Move switches itself off.
enum MoveEnd: String, CaseIterable, Identifiable {
    case whenClaudeFinishes
    case afterFourHours
    case manually

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whenClaudeFinishes: "When Claude finishes"
        case .afterFourHours: "After 4 hours"
        case .manually: "When I turn it off"
        }
    }

    /// Mid-sentence form, e.g. "ends when Claude finishes".
    var phrase: String {
        switch self {
        case .whenClaudeFinishes: "when Claude finishes"
        case .afterFourHours: "after 4 hours"
        case .manually: "when you turn it off"
        }
    }
}

/// Something in the panel that wants the user's attention, with one action.
struct PanelAlert: Identifiable, Equatable {
    enum Kind: Equatable {
        case signIn(URL)
        case foreignLidMode
        case leftDesk
        case backAtDesk
    }

    let kind: Kind
    let message: String
    let action: String
    var id: String { message }
}

/// Owns the features and the panel/settings state. One instance for the app's lifetime.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// How long every Claude session must stay idle before "Claude finished" counts.
    static let claudeIdleGrace: TimeInterval = 5 * 60
    static let moveTimeLimit: TimeInterval = 4 * 3600
    /// Longest timed keep-awake accepted from the CLI or MCP: one week.
    static let maxKeepAwakeMinutes = 10_080

    let keepAwake: KeepAwakeController
    let lidMode = LidModeController()
    let location = LocationAccess()

    @Published private(set) var wifi = WiFiState(isPoweredOn: true, ssid: nil)
    /// nil until the first check finishes.
    @Published private(set) var connectivity: Connectivity?
    @Published private(set) var nearbyNetworks: [String] = []
    @Published private(set) var otherAwakeApps: [String] = []
    @Published private(set) var claudeWorking = 0
    @Published private(set) var keepAwakeWhileClaudeWorks = false
    @Published private(set) var atDesk = false
    @Published private(set) var deskNudge: DeskEvent?

    @Published private(set) var onTheMove: Bool {
        didSet { defaults.set(onTheMove, forKey: Keys.onTheMove) }
    }
    @Published var autoHotspot: Bool {
        didSet {
            defaults.set(autoHotspot, forKey: Keys.autoHotspot)
            engine.reset()
            checkSoon()
        }
    }
    @Published var hotspotSSID: String {
        didSet {
            defaults.set(hotspotSSID, forKey: Keys.hotspotSSID)
            engine.reset()
        }
    }
    @Published var returnToWiFi: Bool {
        didSet { defaults.set(returnToWiFi, forKey: Keys.returnToWiFi) }
    }
    @Published var safetyEnabled: Bool {
        didSet { defaults.set(safetyEnabled, forKey: Keys.safety) }
    }
    @Published var allowDisplaySleep: Bool {
        didSet {
            defaults.set(allowDisplaySleep, forKey: Keys.allowDisplaySleep)
            keepAwake.allowDisplaySleep = allowDisplaySleep
        }
    }
    @Published var moveEnd: MoveEnd {
        didSet { defaults.set(moveEnd.rawValue, forKey: Keys.moveEnd) }
    }
    @Published var moveLowPower: Bool {
        didSet { defaults.set(moveLowPower, forKey: Keys.moveLowPower) }
    }
    @Published var moveShield: Bool {
        didSet { defaults.set(moveShield, forKey: Keys.moveShield) }
    }
    @Published var deskSuggestions: Bool {
        didSet { defaults.set(deskSuggestions, forKey: Keys.deskSuggestions) }
    }

    private enum Keys {
        static let onTheMove = "onTheMove"
        static let moveSnapshot = "moveSnapshot"
        static let moveStartedAt = "moveStartedAt"
        static let autoHotspot = "autoHotspot"
        static let hotspotSSID = "hotspotSSID"
        static let returnToWiFi = "returnToWiFi"
        static let safety = "safetyEnabled"
        static let allowDisplaySleep = "allowDisplaySleep"
        static let moveEnd = "moveEnd"
        static let moveLowPower = "moveLowPower"
        static let moveShield = "moveShield"
        static let deskSuggestions = "deskSuggestions"
        static let lidModeSetByOutpost = "lidModeSetByOutpost"
        static let lowPowerSetByGuard = "lowPowerSetByGuard"
        static let didRegisterLoginItem = "didRegisterLoginItem"
    }

    /// What On the Move changed, so "back at desk" can put it back. Optional fields are only
    /// set for settings Outpost actually changed.
    private struct MoveSnapshot: Codable {
        enum KeepAwake: Codable, Equatable {
            case off, indefinitely, whileClaudeWorks
            case until(Date)
        }

        var keepAwake: KeepAwake
        var lidMode: Bool
        var autoHotspot: Bool
        var lowPowerOnBattery: Bool?
        var firewall: FirewallState?
    }

    private let defaults: UserDefaults
    private let wifiControl: WiFiControlling = CoreWLANWiFi()
    private let probe: ConnectivityProbing = CaptiveAwareProbe()
    private let lowPower = LowPowerModeController()
    private let firewall = FirewallController()
    private var engine = FailoverEngine()
    private var desk = DeskDetector()
    private let pathMonitor = NWPathMonitor()
    private var controlServer: ControlServer?
    private var loopTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var tickCount = 0
    private var isChecking = false
    private var joinFailureNotified = false
    private var portalNotified = false
    private var cachedPassword: String?
    private var claudeWasWorking = false
    private var claudeIdleSince: Date?
    private var lowPowerOnBattery: Bool?
    /// On the Move switches one transition at a time, so a start and an end can't interleave across awaits.
    private var moveTransition: Task<[String], Never>?
    private var cancellables = Set<AnyCancellable>()

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.returnToWiFi: true, Keys.safety: true, Keys.moveLowPower: true,
                                     Keys.moveShield: true, Keys.deskSuggestions: true])
        onTheMove = defaults.bool(forKey: Keys.onTheMove)
        autoHotspot = defaults.bool(forKey: Keys.autoHotspot)
        hotspotSSID = defaults.string(forKey: Keys.hotspotSSID) ?? ""
        returnToWiFi = defaults.bool(forKey: Keys.returnToWiFi)
        safetyEnabled = defaults.bool(forKey: Keys.safety)
        allowDisplaySleep = defaults.bool(forKey: Keys.allowDisplaySleep)
        moveEnd = MoveEnd(rawValue: defaults.string(forKey: Keys.moveEnd) ?? "") ?? .whenClaudeFinishes
        moveLowPower = defaults.bool(forKey: Keys.moveLowPower)
        moveShield = defaults.bool(forKey: Keys.moveShield)
        deskSuggestions = defaults.bool(forKey: Keys.deskSuggestions)
        keepAwake = KeepAwakeController(allowDisplaySleep: defaults.bool(forKey: Keys.allowDisplaySleep))

        Publishers.Merge3(keepAwake.objectWillChange, lidMode.objectWillChange, location.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func start() {
        Notifier.setUp()
        if !defaults.bool(forKey: Keys.didRegisterLoginItem) {
            defaults.set(true, forKey: Keys.didRegisterLoginItem)
            launchAtLogin = true
        }
        if onTheMove {
            // Keep-awake assertions end with the process; bring it back after a relaunch.
            keepAwake.activate()
        }

        let server = ControlServer { request in await AppModel.shared.handle(request) }
        do {
            try server.start()
            controlServer = server
        } catch {
            NSLog("Outpost: control socket unavailable: \(error.localizedDescription)")
        }

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.checkSoon() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Outpost.path"))

        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkNetwork()
                try? await Task.sleep(for: .seconds(self.checkInterval))
            }
        }

        refreshAwakeWatch()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.runGuard() }
        }
    }

    /// Puts back what Outpost changed. Runs synchronously: the app is about to exit.
    func shutdown() {
        controlServer?.stop()
        if onTheMove {
            let snapshot = loadSnapshot()
            Self.restorePrivileged(snapshot, lowPower: lowPower, firewall: firewall)
            defaults.removeObject(forKey: Keys.moveSnapshot)
            onTheMove = false
            autoHotspot = snapshot?.autoHotspot ?? autoHotspot
        }
        if defaults.bool(forKey: Keys.lowPowerSetByGuard) {
            try? lowPower.setForBattery(false)
            defaults.set(false, forKey: Keys.lowPowerSetByGuard)
        }
        keepAwake.deactivate()
        if lidMode.isEnabled, defaults.bool(forKey: Keys.lidModeSetByOutpost) {
            try? lidMode.setEnabled(false)
            defaults.set(false, forKey: Keys.lidModeSetByOutpost)
        }
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    /// Called when the panel opens, so it shows fresh state.
    func panelWillOpen() {
        lidMode.refresh()
        refreshAwakeWatch()
        checkSoon()
    }

    // MARK: - Status

    var online: Bool? { connectivity.map { $0 == .online } }

    var isKeepingAwake: Bool { keepAwake.isActive || lidMode.isEnabled }

    var isOnHotspot: Bool { !hotspotSSID.isEmpty && wifi.ssid == hotspotSSID }

    var portalURL: URL? {
        guard case .captivePortal(let url) = connectivity else { return nil }
        if let url, ["http", "https"].contains(url.scheme?.lowercased()) { return url }
        return URL(string: "http://captive.apple.com")
    }

    var networkStatus: String {
        guard let connectivity else { return "Checking connection…" }
        guard wifi.isPoweredOn else { return connectivity == .online ? "Online" : "Wi-Fi is off" }
        switch (wifi.ssid, connectivity) {
        case (let ssid?, .online) where isOnHotspot: return "Online via hotspot — \(ssid)"
        case (let ssid?, .online): return "Online — \(ssid)"
        case (let ssid?, .captivePortal): return "Sign-in needed — \(ssid)"
        case (let ssid?, .offline): return "No internet — \(ssid)"
        case (nil, .online): return "Online"
        case (nil, .captivePortal): return "Sign-in needed"
        case (nil, .offline): return "Not connected"
        }
    }

    var awakeStatus: String {
        if lidMode.isEnabled { return "Stays on with the lid closed" }
        if keepAwakeWhileClaudeWorks { return "Awake while Claude works" }
        if keepAwake.isActive {
            return keepAwake.remainingTime.map { "Awake for \(Self.format($0))" } ?? "Keeping your Mac awake"
        }
        return "Sleeps normally"
    }

    var alerts: [PanelAlert] {
        var alerts: [PanelAlert] = []
        if let url = portalURL {
            alerts.append(PanelAlert(kind: .signIn(url), message: "This Wi-Fi wants you to sign in.", action: "Sign In"))
        }
        if lidMode.isEnabled, !defaults.bool(forKey: Keys.lidModeSetByOutpost) {
            alerts.append(PanelAlert(kind: .foreignLidMode, message: "Lid-closed mode was turned on outside Outpost.", action: "Turn Off"))
        }
        switch deskNudge {
        case .left? where !onTheMove:
            alerts.append(PanelAlert(kind: .leftDesk, message: "Leaving your desk? Keep Claude running with the lid closed.", action: "On the Move"))
        case .arrived? where onTheMove:
            alerts.append(PanelAlert(kind: .backAtDesk, message: "Back at your desk? Turn off On the Move.", action: "I'm Back"))
        default:
            break
        }
        return alerts
    }

    func perform(_ alert: PanelAlert) async {
        switch alert.kind {
        case .signIn(let url):
            NSWorkspace.shared.open(url)
        case .foreignLidMode:
            await setLidModeFromMenu(false)
        case .leftDesk:
            deskNudge = nil
            await setOnTheMoveFromMenu(true)
        case .backAtDesk:
            deskNudge = nil
            await setOnTheMoveFromMenu(false)
        }
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    func status() -> OutpostStatus {
        let battery = PowerSource.batteryLevel()
        let onBattery = PowerSource.isOnBattery()
        var sentences: [String] = []
        if onTheMove {
            sentences.append("On the Move is on and ends \(moveEnd.phrase).")
        }
        if lidMode.isEnabled {
            sentences.append("The Mac keeps running with the lid closed.")
        } else if keepAwakeWhileClaudeWorks {
            sentences.append("The Mac stays awake while Claude works (lid open).")
        } else if keepAwake.isActive {
            sentences.append(keepAwake.remainingTime.map { "The Mac stays awake for \(Self.format($0)) (lid open)." }
                             ?? "The Mac stays awake while the lid is open.")
        } else {
            sentences.append("The Mac sleeps normally.")
        }
        if claudeWorking > 0 {
            sentences.append(claudeWorking == 1 ? "1 Claude session is working." : "\(claudeWorking) Claude sessions are working.")
        }
        if autoHotspot {
            sentences.append(hotspotSetupProblem.map { "Auto-hotspot is on, but it can't work yet. \($0)" }
                             ?? "Auto-hotspot is on (\(hotspotSSID)).")
        }
        sentences.append(networkStatus + ".")
        if !otherAwakeApps.isEmpty {
            sentences.append("Also keeping it awake: \(otherAwakeApps.joined(separator: ", ")).")
        }
        if let battery {
            sentences.append("Battery \(battery)%\(onBattery ? "" : ", on power").")
        }
        return OutpostStatus(
            onTheMove: onTheMove, keepAwake: keepAwake.isActive,
            keepAwakeMinutesLeft: keepAwake.remainingTime.map { Int(($0 / 60).rounded(.up)) },
            lidClosedMode: lidMode.isEnabled, lidClosedModeSetUp: lidMode.isSetUp,
            autoHotspot: autoHotspot, hotspot: hotspotSSID.isEmpty ? nil : hotspotSSID,
            hotspotReady: hotspotIsConfigured, online: online, wifi: wifi.ssid, onHotspot: isOnHotspot,
            batteryPercent: battery, onBattery: onBattery, keepAwakeWhileClaudeWorks: keepAwakeWhileClaudeWorks,
            claudeWorking: claudeWorking, otherAwakeApps: otherAwakeApps, captivePortal: portalURL != nil,
            atDesk: atDesk, summary: sentences.joined(separator: " "))
    }

    // MARK: - Control (outpostctl / MCP)

    func handle(_ request: ControlRequest) async -> ControlResponse {
        var notes: [String] = []
        var failure: String?
        switch request.command {
        case .status:
            break
        case .move:
            notes = await setOnTheMove(request.on ?? true)
        case .keepAwake:
            if request.on == false {
                keepAwakeOption = .off
            } else if request.whileClaudeWorks == true {
                keepAwakeOption = .whileClaudeWorks
            } else if let minutes = request.minutes {
                guard (1...Self.maxKeepAwakeMinutes).contains(minutes) else {
                    failure = "Minutes must be between 1 and \(Self.maxKeepAwakeMinutes)."
                    break
                }
                keepAwakeOption = .minutes(minutes)
            } else {
                keepAwakeOption = .indefinitely
            }
        case .lidMode:
            failure = await lidModeProblem(request.on ?? true)
        case .autoHotspot:
            autoHotspot = request.on ?? true
            if autoHotspot, let problem = hotspotSetupProblem {
                notes.append(problem)
            }
        case .joinHotspot:
            failure = hotspotSSID.isEmpty ? "No hotspot is chosen yet (Outpost Settings)." : await joinHotspotNow()
        }
        return ControlResponse(ok: failure == nil, error: failure, notes: notes.isEmpty ? nil : notes, status: status())
    }

    // MARK: - On the Move

    /// Switches On the Move on (lid-closed mode, keep-awake, auto-hotspot, and on battery Low Power Mode and
    /// the firewall shield) or restores what was there before. Returns notes about anything that couldn't switch.
    @discardableResult
    func setOnTheMove(_ on: Bool) async -> [String] {
        let previous = moveTransition
        let transition = Task { @MainActor in
            _ = await previous?.value
            return on ? await self.startMove() : await self.endMove()
        }
        moveTransition = transition
        return await transition.value
    }

    func setOnTheMoveFromMenu(_ on: Bool) async {
        let notes = await setOnTheMove(on)
        if !notes.isEmpty {
            Notifier.post(title: on ? "On the Move is on" : "Back at your desk", body: notes.joined(separator: " "))
        }
    }

    private func startMove() async -> [String] {
        var notes: [String] = []
        let starting = !onTheMove
        // Snapshot before changing anything, so an interruption can always be undone.
        var snapshot = (starting ? nil : loadSnapshot())
            ?? MoveSnapshot(keepAwake: currentKeepAwake, lidMode: lidMode.isEnabled, autoHotspot: autoHotspot)
        saveSnapshot(snapshot)
        if starting {
            onTheMove = true
            defaults.set(Date.now, forKey: Keys.moveStartedAt)
            claudeWasWorking = claudeWorking > 0
            claudeIdleSince = nil
            deskNudge = nil
        }
        keepAwakeWhileClaudeWorks = false
        keepAwake.activate()
        if !autoHotspot {
            autoHotspot = true
        }
        if let problem = hotspotSetupProblem {
            notes.append(problem)
        }
        if !lidMode.isEnabled, let problem = await lidModeProblem(true) {
            notes.append("Lid-closed mode is off (\(problem)), so closing the lid will still put the Mac to sleep.")
        }

        if lidMode.isSetUp {
            let lowPower = self.lowPower, firewall = self.firewall
            let wantLowPower = moveLowPower, wantShield = moveShield
            let changes = await Task.detached { () -> (Bool?, FirewallState?, [String]) in
                var problems: [String] = []
                var previousLowPower: Bool?
                var previousFirewall: FirewallState?
                if wantLowPower, let current = lowPower.isOnForBattery(), !current {
                    do {
                        try lowPower.setForBattery(true)
                        previousLowPower = current
                    } catch {
                        problems.append("Low Power Mode didn't switch on.")
                    }
                }
                let shielded = FirewallState(enabled: true, stealth: true)
                if wantShield, let current = firewall.read(), current != shielded {
                    do {
                        try firewall.apply(shielded)
                        previousFirewall = current
                    } catch {
                        problems.append("The firewall shield didn't switch on.")
                    }
                }
                return (previousLowPower, previousFirewall, problems)
            }.value
            if snapshot.lowPowerOnBattery == nil { snapshot.lowPowerOnBattery = changes.0 }
            if snapshot.firewall == nil { snapshot.firewall = changes.1 }
            notes += changes.2
            saveSnapshot(snapshot)
        }
        return notes
    }

    private var currentKeepAwake: MoveSnapshot.KeepAwake {
        guard keepAwake.isActive else { return .off }
        if keepAwakeWhileClaudeWorks { return .whileClaudeWorks }
        guard let left = keepAwake.remainingTime else { return .indefinitely }
        return .until(Date.now.addingTimeInterval(left))
    }

    private func restoreKeepAwake(_ previous: MoveSnapshot.KeepAwake?) {
        switch previous {
        case .indefinitely?:
            keepAwakeOption = .indefinitely
        case .whileClaudeWorks?:
            keepAwakeOption = .whileClaudeWorks
        case .until(let end)? where end > .now:
            keepAwakeWhileClaudeWorks = false
            keepAwake.activate(for: end.timeIntervalSinceNow)
        default:
            keepAwakeOption = .off
        }
    }

    private func endMove() async -> [String] {
        guard onTheMove else { return [] }
        var notes: [String] = []
        let snapshot = loadSnapshot()
        onTheMove = false
        defaults.removeObject(forKey: Keys.moveSnapshot)
        defaults.removeObject(forKey: Keys.moveStartedAt)
        restoreKeepAwake(snapshot?.keepAwake)
        autoHotspot = snapshot?.autoHotspot ?? false
        if snapshot?.lidMode != true, lidMode.isEnabled, let problem = await lidModeProblem(false) {
            notes.append("Couldn't turn lid-closed mode off: \(problem)")
        }
        let lowPower = self.lowPower, firewall = self.firewall
        let undoGuardLowPower = defaults.bool(forKey: Keys.lowPowerSetByGuard) && snapshot?.lowPowerOnBattery == nil
        defaults.set(false, forKey: Keys.lowPowerSetByGuard)
        await Task.detached {
            Self.restorePrivileged(snapshot, lowPower: lowPower, firewall: firewall)
            if undoGuardLowPower {
                try? lowPower.setForBattery(false)
            }
        }.value
        return notes
    }

    nonisolated private static func restorePrivileged(_ snapshot: MoveSnapshot?, lowPower: LowPowerModeController,
                                                      firewall: FirewallController) {
        if let previous = snapshot?.lowPowerOnBattery {
            try? lowPower.setForBattery(previous)
        }
        if let previous = snapshot?.firewall {
            try? firewall.apply(previous)
        }
    }

    private func loadSnapshot() -> MoveSnapshot? {
        defaults.data(forKey: Keys.moveSnapshot).flatMap { try? JSONDecoder().decode(MoveSnapshot.self, from: $0) }
    }

    private func saveSnapshot(_ snapshot: MoveSnapshot) {
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: Keys.moveSnapshot)
    }

    // MARK: - Keep awake

    var keepAwakeOption: KeepAwakeOption {
        get {
            guard keepAwake.isActive else { return .off }
            if keepAwakeWhileClaudeWorks { return .whileClaudeWorks }
            guard let duration = keepAwake.activatedDuration else { return .indefinitely }
            return .minutes(Int(duration / 60))
        }
        set {
            keepAwakeWhileClaudeWorks = newValue == .whileClaudeWorks
            claudeWasWorking = claudeWorking > 0
            claudeIdleSince = nil
            switch newValue {
            case .off: keepAwake.deactivate()
            case .indefinitely, .whileClaudeWorks: keepAwake.activate()
            case .minutes(let m): keepAwake.activate(for: TimeInterval(m) * 60)
            }
        }
    }

    // MARK: - Lid-closed mode

    /// Switches lid-closed mode (running setup first if needed). Returns a problem description, or nil.
    func lidModeProblem(_ enabled: Bool) async -> String? {
        do {
            if enabled, !lidMode.isSetUp {
                try await lidMode.setUp()
            }
            try lidMode.setEnabled(enabled)
            defaults.set(enabled, forKey: Keys.lidModeSetByOutpost)
            return nil
        } catch LidModeError.setUpCancelled {
            return "the password prompt was cancelled"
        } catch {
            return error.localizedDescription
        }
    }

    func setLidModeFromMenu(_ enabled: Bool) async {
        if let problem = await lidModeProblem(enabled), problem != "the password prompt was cancelled" {
            Self.showAlert("Couldn't change lid-closed mode", problem)
        }
    }

    func setUpLidMode() async {
        do {
            try await lidMode.setUp()
        } catch LidModeError.setUpCancelled {
        } catch {
            Self.showAlert("Couldn't set up Outpost's permission", error.localizedDescription)
        }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Outpost: launch at login change failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    // MARK: - Auto-hotspot

    var hotspotIsConfigured: Bool { hotspotSetupProblem == nil }

    var hotspotSetupProblem: String? {
        if hotspotSSID.isEmpty { return "Auto-hotspot has no hotspot chosen yet: pick one in Outpost Settings." }
        if !location.isAuthorized { return "Outpost needs Location access to see Wi-Fi names: allow it in Outpost Settings." }
        return nil
    }

    var canJoinHotspotNow: Bool { !hotspotSSID.isEmpty && wifi.isPoweredOn && !isOnHotspot }

    func hotspotPassword() -> String {
        if let cachedPassword { return cachedPassword }
        let password = HotspotPasswordStore.read()
        cachedPassword = password
        return password
    }

    func setHotspotPassword(_ password: String) {
        guard password != cachedPassword else { return }
        cachedPassword = password
        HotspotPasswordStore.save(password)
    }

    func refreshNearbyNetworks() {
        let wifiControl = self.wifiControl
        Task {
            nearbyNetworks = await Task.detached { wifiControl.nearbyNetworkNames() }.value
        }
    }

    /// Returns a problem description, or nil once joined.
    @discardableResult
    func joinHotspotNow() async -> String? {
        await joinHotspot(leaving: wifi.ssid, automatic: false)
    }

    private var checkInterval: TimeInterval {
        guard autoHotspot else { return 30 }
        switch connectivity {
        case .offline?: return 2
        case .captivePortal?: return 10
        default: return isOnHotspot ? 15 : 5
        }
    }

    private func checkSoon() {
        Task { await checkNetwork() }
    }

    private func checkNetwork() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let wifiControl = self.wifiControl
        let state = await Task.detached { wifiControl.state() }.value
        let result = await probe.check()
        wifi = state
        connectivity = result
        switch result {
        case .online:
            joinFailureNotified = false
            portalNotified = false
        case .captivePortal:
            if !portalNotified {
                portalNotified = true
                Notifier.post(title: "This Wi-Fi wants you to sign in",
                              body: "Outpost will wait before switching to your hotspot.", category: .signIn)
            }
        case .offline:
            portalNotified = false
        }

        guard autoHotspot else { return }
        let decision = engine.observe(wifi: state, connectivity: result, hotspot: hotspotSSID,
                                      returnEnabled: returnToWiFi, now: .now)
        switch decision {
        case .none:
            break
        case .joinHotspot(let leaving):
            await joinHotspot(leaving: leaving, automatic: true)
        case .returnToWiFi(let home):
            await goBack(to: home)
        }
    }

    @discardableResult
    private func joinHotspot(leaving: String?, automatic: Bool) async -> String? {
        let ssid = hotspotSSID
        let password = hotspotPassword()
        let wifiControl = self.wifiControl
        let failure: Error? = await Task.detached {
            do {
                try wifiControl.join(ssid: ssid, password: password.isEmpty ? nil : password)
                return nil
            } catch {
                return error
            }
        }.value

        if let failure {
            engine.hotspotJoinFailed(now: .now)
            let hint = if case WiFiError.notFound = failure {
                "It isn't nearby. On your iPhone, turn on Personal Hotspot → Allow Others to Join."
            } else {
                "Check the hotspot password in Outpost Settings."
            }
            if automatic, !joinFailureNotified {
                joinFailureNotified = true
                Notifier.post(title: "Couldn't join \(ssid)", body: hint)
            }
            return "Couldn't join \(ssid). \(hint)"
        }

        if automatic {
            engine.joinedHotspot(leaving: leaving, now: .now)
            Notifier.post(title: "Switched to \(ssid)",
                          body: leaving.map { "The internet dropped on \($0)." } ?? "The internet dropped.")
        } else {
            engine.joinedHotspotManually()
        }
        wifi = await Task.detached { wifiControl.state() }.value
        return nil
    }

    private func goBack(to home: String) async {
        let wifiControl = self.wifiControl
        let success = await Task.detached { () -> Bool in
            do {
                try wifiControl.join(ssid: home, password: nil)
                return true
            } catch WiFiError.notFound {
                return false
            } catch {
                // Joining needs the saved password, which only macOS holds: step off the
                // hotspot and let macOS auto-join its preferred network.
                wifiControl.disconnect()
                for _ in 0..<10 {
                    try? await Task.sleep(for: .seconds(1))
                    if wifiControl.state().ssid == home { return true }
                }
                return false
            }
        }.value
        engine.returnAttempted(success: success, now: .now)
        if success {
            Notifier.post(title: "Back on \(home)", body: "Outpost left the hotspot to save your phone's data.")
        }
        wifi = await Task.detached { wifiControl.state() }.value
    }

    // MARK: - Housekeeping: desk, awake watch, guard, end conditions

    private func tick() {
        tickCount += 1
        updateDesk()
        guard tickCount % 6 == 0 else { return }
        lidMode.refresh()
        refreshAwakeWatch()
        checkEndConditions()
        Task { await runGuard() }
    }

    private func updateDesk() {
        let state = DeskState.current()
        atDesk = state.atDesk
        switch desk.update(state, now: .now) {
        case .left? where deskSuggestions && !onTheMove && !PowerSource.isLidClosed():
            deskNudge = .left
            Notifier.post(title: "Leaving your desk?", body: "Turn on On the Move to keep Claude running with the lid closed.",
                          category: .leftDesk)
        case .arrived? where deskSuggestions && onTheMove:
            deskNudge = .arrived
            Notifier.post(title: "Back at your desk?", body: "Turn off On the Move to put your settings back.",
                          category: .backAtDesk)
        case .arrived?, .left?:
            deskNudge = nil
        case nil:
            break
        }
    }

    private func refreshAwakeWatch() {
        let holders = AwakeWatch.holders()
        let isClaude: (AwakeHolder) -> Bool = { holder in
            holder.processName == "caffeinate"
                && AwakeWatch.processParent(holder.pid).flatMap(AwakeWatch.processName) == "claude"
        }
        claudeWorking = holders.filter(isClaude).count
        otherAwakeApps = AwakeWatch.appNames(for: holders.filter { !isClaude($0) })
    }

    private func checkEndConditions() {
        let claudeFinished = updateClaudeIdle()
        if onTheMove {
            let started = defaults.object(forKey: Keys.moveStartedAt) as? Date ?? .now
            let timeUp = moveEnd == .afterFourHours && Date.now.timeIntervalSince(started) >= Self.moveTimeLimit
            if timeUp || (moveEnd == .whenClaudeFinishes && claudeFinished) {
                Task {
                    await setOnTheMove(false)
                    Notifier.post(title: timeUp ? "On the Move ended after 4 hours" : "Claude finished",
                                  body: "On the Move is off, so your Mac can sleep.")
                    sleepIfLidClosed()
                }
            }
        } else if keepAwakeWhileClaudeWorks, claudeFinished {
            keepAwakeOption = .off
            Notifier.post(title: "Claude finished", body: "Outpost stopped keeping your Mac awake.")
        }
    }

    /// Tracks whether every Claude session has been idle long enough. Only counts once Claude has worked.
    private func updateClaudeIdle() -> Bool {
        if claudeWorking > 0 {
            claudeWasWorking = true
            claudeIdleSince = nil
            return false
        }
        guard claudeWasWorking else { return false }
        let since = claudeIdleSince ?? .now
        claudeIdleSince = since
        return Date.now.timeIntervalSince(since) >= Self.claudeIdleGrace
    }

    private func runGuard() async {
        let lowPower = self.lowPower
        lowPowerOnBattery = await Task.detached { lowPower.isOnForBattery() }.value
        let input = GuardInput(thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
                               lidClosed: PowerSource.isLidClosed(), onBattery: PowerSource.isOnBattery(),
                               batteryPercent: PowerSource.batteryLevel(), keepingAwake: keepAwake.isActive,
                               lidModeOn: lidMode.isEnabled, lowPowerOn: lowPowerOnBattery ?? true,
                               enabled: safetyEnabled)
        switch HotBagGuard.decide(input) {
        case .none:
            break
        case .enableLowPower:
            guard lidMode.isSetUp else { return }
            let ok = await Task.detached { (try? lowPower.setForBattery(true)) != nil }.value
            if ok {
                defaults.set(true, forKey: Keys.lowPowerSetByGuard)
                lowPowerOnBattery = true
                Notifier.post(title: "Your Mac is getting warm", body: "Outpost turned on Low Power Mode to cool it down.")
            }
        case .stopAndSleep(let reason):
            if onTheMove {
                await setOnTheMove(false)
            }
            keepAwakeOption = .off
            if lidMode.isEnabled {
                _ = await lidModeProblem(false)
            }
            switch reason {
            case .hot:
                Notifier.post(title: "Your Mac got hot", body: "Outpost turned everything off so it can sleep and cool down.")
            case .lowBattery(let percent):
                Notifier.post(title: "Battery at \(percent)%", body: "Outpost turned everything off so your Mac can sleep.")
            }
            sleepIfLidClosed()
        }
    }

    private func sleepIfLidClosed() {
        guard PowerSource.isLidClosed() else { return }
        Task.detached { SystemSleep.sleepNow() }
    }

    static func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
