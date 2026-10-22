import AppKit
import Combine
import Network
import AwakeCore
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
        case sharing
        case locationAccess
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

    @Published private(set) var wifi = WiFiState(isPoweredOn: true, ssid: nil) {
        didSet { updateProfile() }
    }
    /// nil until the first check finishes.
    @Published private(set) var connectivity: Connectivity?
    /// From the current Wi-Fi name; see `heldProfile` for the one the shield and shortcuts follow.
    @Published private(set) var profile: NetworkProfile = .unknown
    /// The one owner of the firewall shield, persisted so a crash can still be undone.
    @Published private(set) var shield: FirewallShield {
        didSet { defaults.set(try? JSONEncoder().encode(shield), forKey: Keys.firewallShield) }
    }
    /// The firewall as last read (unprivileged, off the main actor): after each shield step, while the shield is up,
    /// and when the panel opens. Nil before the first read or when it can't be read.
    @Published private(set) var firewallNow: FirewallState?
    /// Sharing services listening on this Mac, from the last check.
    @Published private(set) var sharingOn: [SharingService] = []
    /// nil when Tailscale isn't installed (or before the first check, see `reachChecked`).
    @Published private(set) var tailscale: TailscaleStatus?
    @Published private(set) var reachChecked = false
    @Published private(set) var power: PowerReading
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
        didSet {
            defaults.set(moveShield, forKey: Keys.moveShield)
            shieldSoon()
        }
    }
    @Published var deskSuggestions: Bool {
        didSet { defaults.set(deskSuggestions, forKey: Keys.deskSuggestions) }
    }
    /// Wi-Fi names that count as home. The hotspot always does too.
    @Published private(set) var trustedNetworks: [String] {
        didSet {
            defaults.set(trustedNetworks, forKey: Keys.trustedNetworks)
            updateProfile()
        }
    }
    @Published var publicShield: Bool {
        didSet {
            defaults.set(publicShield, forKey: Keys.publicShield)
            shieldSoon()
        }
    }
    /// Shortcuts to run when switching to public or home Wi-Fi; empty = none.
    @Published var publicShortcut: String {
        didSet { defaults.set(publicShortcut, forKey: Keys.publicShortcut) }
    }
    @Published var homeShortcut: String {
        didSet { defaults.set(homeShortcut, forKey: Keys.homeShortcut) }
    }
    @Published var outletWarningMinutes: Int {
        didSet { defaults.set(outletWarningMinutes, forKey: Keys.outletWarningMinutes) }
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
        static let lidModeSetByAwake = "lidModeSetByAwake"
        static let lowPowerSetByGuard = "lowPowerSetByGuard"
        static let didRegisterLoginItem = "didRegisterLoginItem"
        static let trustedNetworks = "trustedNetworks"
        static let publicShield = "publicShield"
        static let publicShortcut = "publicShortcut"
        static let homeShortcut = "homeShortcut"
        static let outletWarningMinutes = "outletWarningMinutes"
        static let firewallShield = "firewallShield"
        static let lastProfile = "lastProfile"
    }

    /// What On the Move changed, so "back at desk" can put it back. Optional fields are only
    /// set for settings Awake actually changed. The firewall isn't here: the shield owns it.
    private struct MoveSnapshot: Codable {
        enum KeepAwake: Codable, Equatable {
            case off, indefinitely, whileClaudeWorks
            case until(Date)
        }

        var keepAwake: KeepAwake
        var lidMode: Bool
        var autoHotspot: Bool
        var lowPowerOnBattery: Bool?
        /// Legacy, read only: builds before the shield kept the firewall's previous state here. `start()` hands it
        /// to the shield, and `saveSnapshot` never writes it.
        var firewall: FirewallState?
    }

    static let sharingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!

    private let defaults: UserDefaults
    private let wifiControl: WiFiControlling = CoreWLANWiFi()
    private let probe: ConnectivityProbing = CaptiveAwareProbe()
    private let lowPower = LowPowerModeController()
    private let firewall = FirewallController()
    /// Every firewall command (shield steps and the status read) runs here, one at a time, so quitting can wait for
    /// the one in flight before putting the firewall back, and nothing starts after that.
    private let firewallQueue = SerialCommandQueue(label: "Awake.firewall")
    private var isReadingFirewall = false
    private var isQuitting = false
    private let shortcuts = ShortcutRunner()
    private let tailscaleCLI = TailscaleCLI()
    private let sharingCheck = SharingCheck()
    private var powerAlerts = PowerAlerts()
    /// The last definite profile, held through short moments without a Wi-Fi name (waking, roaming) so the shield
    /// doesn't drop and come back; lapses after 10 minutes of unknown or when Wi-Fi is off. Starts unknown at launch.
    private var profileHold = ProfileHold()
    private var heldProfile: NetworkProfile { profileHold.profile }
    private var didFirstNetworkCheck = false
    private var isRefreshingReach = false
    private var reachCheckIncludesSharing = false
    /// The sharing check was asked for while a Tailscale-only check was running; it runs once that one ends.
    private var reachRecheck = false
    private var lastReachCheck = Date.distantPast
    /// Tailscale is re-checked at most this often unless the panel opens or the profile changes.
    private static let reachInterval: TimeInterval = 5 * 60
    /// Shield steps run one at a time, like On the Move's transitions; shortcuts queue the same way.
    private var shieldTransition: Task<[String], Never>?
    private var shortcutRun: Task<Void, Never>?
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
                                     Keys.moveShield: true, Keys.deskSuggestions: true, Keys.publicShield: true,
                                     Keys.outletWarningMinutes: PowerAlerts.defaultWarning])
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
        trustedNetworks = defaults.stringArray(forKey: Keys.trustedNetworks) ?? []
        publicShield = defaults.bool(forKey: Keys.publicShield)
        publicShortcut = defaults.string(forKey: Keys.publicShortcut) ?? ""
        homeShortcut = defaults.string(forKey: Keys.homeShortcut) ?? ""
        let warning = defaults.integer(forKey: Keys.outletWarningMinutes)
        outletWarningMinutes = PowerAlerts.warningChoices.contains(warning) ? warning : PowerAlerts.defaultWarning
        shield = defaults.data(forKey: Keys.firewallShield)
            .flatMap { try? JSONDecoder().decode(FirewallShield.self, from: $0) } ?? FirewallShield()
        power = PowerMonitor.read()
        keepAwake = KeepAwakeController(allowDisplaySleep: defaults.bool(forKey: Keys.allowDisplaySleep))

        Publishers.Merge3(keepAwake.objectWillChange, lidMode.objectWillChange, location.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func start() {
        Notifier.setUp()
        adoptLegacyFirewallSnapshot()
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
            NSLog("Awake: control socket unavailable: \(error.localizedDescription)")
        }

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.checkSoon() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Awake.path"))

        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkNetwork()
                try? await Task.sleep(for: .seconds(self.checkInterval))
            }
        }

        refreshAwakeWatch()
        refreshPower()
        refreshReach(sharing: true)
        refreshFirewall()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.runGuard() }
        }
    }

    /// Puts back what Awake changed. Runs synchronously: the app is about to exit.
    func shutdown() {
        controlServer?.stop()
        if onTheMove {
            let snapshot = loadSnapshot()
            Self.restorePrivileged(snapshot, lowPower: lowPower)
            defaults.removeObject(forKey: Keys.moveSnapshot)
            onTheMove = false
            autoHotspot = snapshot?.autoHotspot ?? autoHotspot
        }
        // Waits for a shield command in flight (a raise could otherwise finish after the restore and leave the
        // firewall on with no snapshot), restores, and stops any shield step still queued.
        isQuitting = true
        let shield = self.shield, firewall = self.firewall
        if firewallQueue.close(then: { shield.isUp && Self.restoreFirewall(shield, firewall: firewall) }) {
            self.shield.didLower()
        }
        if defaults.bool(forKey: Keys.lowPowerSetByGuard) {
            try? lowPower.setForBattery(false)
            defaults.set(false, forKey: Keys.lowPowerSetByGuard)
        }
        keepAwake.deactivate()
        if lidMode.isEnabled, defaults.bool(forKey: Keys.lidModeSetByAwake) {
            try? lidMode.setEnabled(false)
            defaults.set(false, forKey: Keys.lidModeSetByAwake)
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
        refreshPower()
        refreshReach(sharing: true)
        refreshFirewall()
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

    /// The shield is up and the firewall, as last read, really is shielded (the user can switch it off behind it).
    var isShielded: Bool { shield.isOn(firewall: firewallNow) }

    /// The public Wi-Fi shield is on, but without Location access every network reads as unknown, so it never engages.
    var shieldNeedsLocation: Bool { publicShield && !location.isAuthorized }

    /// The panel's network line: "Public network · shielded", "Home network", or nil when there's nothing to say.
    var profileStatus: String? {
        switch profile {
        case .home:
            return isShielded ? "Home network · shielded" : "Home network"
        case .public:
            if isShielded { return "Public network · shielded" }
            return publicShield ? "Public network · not shielded" : "Public network"
        case .unknown:
            return isShielded ? "Firewall shield on" : nil
        }
    }

    private var profileSentence: String? {
        switch profile {
        case .home: isShielded ? "Home network, firewall shield on." : "Home network."
        case .public: isShielded ? "Public network, firewall shield on." : "Public network, firewall shield off."
        case .unknown: isShielded ? "Firewall shield on." : nil
        }
    }

    /// Whether the owner's phone can reach this Mac; nil until the first check. Only lid-closed mode counts as
    /// staying on: keep-awake ends when the lid closes.
    var reach: RemoteReach? {
        guard reachChecked else { return nil }
        return RemoteReach.evaluate(tailscale: tailscale, remoteLogin: sharingOn.contains(.remoteLogin),
                                    lidClosedMode: lidMode.isEnabled, user: NSUserName())
    }

    var alerts: [PanelAlert] {
        var alerts: [PanelAlert] = []
        if let url = portalURL {
            alerts.append(PanelAlert(kind: .signIn(url), message: "This Wi-Fi wants you to sign in.", action: "Sign In"))
        }
        if profile == .public, !sharingOn.isEmpty {
            alerts.append(PanelAlert(kind: .sharing,
                                     message: "Sharing on this network: \(sharingOn.map(\.title).joined(separator: ", "))",
                                     action: "Open Settings"))
        }
        if shieldNeedsLocation {
            alerts.append(PanelAlert(kind: .locationAccess, message: "The public Wi-Fi shield needs Location access.",
                                     action: "Allow"))
        }
        if lidMode.isEnabled, !defaults.bool(forKey: Keys.lidModeSetByAwake) {
            alerts.append(PanelAlert(kind: .foreignLidMode, message: "Lid-closed mode was turned on outside Awake.", action: "Turn Off"))
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
        case .sharing:
            NSWorkspace.shared.open(Self.sharingSettingsURL)
        case .locationAccess:
            location.request()
        }
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        TimeText.format(seconds)
    }

    func status() -> AwakeStatus {
        let power = PowerMonitor.read()
        let reach = self.reach
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
        if let profileSentence {
            sentences.append(profileSentence)
        }
        if shieldNeedsLocation {
            sentences.append("The public Wi-Fi shield can't tell public from trusted Wi-Fi without Location access: allow it in Awake Settings.")
        }
        if profile == .public, !sharingOn.isEmpty {
            sentences.append("Sharing is on: \(sharingOn.map(\.title).joined(separator: ", ")).")
        }
        if !otherAwakeApps.isEmpty {
            sentences.append("Also keeping it awake: \(otherAwakeApps.joined(separator: ", ")).")
        }
        if let battery = power.sentence {
            sentences.append(battery)
        }
        if let reach {
            sentences.append(reach.sentence)
        }
        let hasBattery = power.percent != nil
        return AwakeStatus(
            onTheMove: onTheMove, keepAwake: keepAwake.isActive,
            keepAwakeMinutesLeft: keepAwake.remainingTime.map { Int(($0 / 60).rounded(.up)) },
            lidClosedMode: lidMode.isEnabled, lidClosedModeSetUp: lidMode.isSetUp,
            autoHotspot: autoHotspot, hotspot: hotspotSSID.isEmpty ? nil : hotspotSSID,
            hotspotReady: hotspotIsConfigured, online: online, wifi: wifi.ssid, onHotspot: isOnHotspot,
            batteryPercent: power.percent, onBattery: power.onBattery, keepAwakeWhileClaudeWorks: keepAwakeWhileClaudeWorks,
            claudeWorking: claudeWorking, otherAwakeApps: otherAwakeApps, captivePortal: portalURL != nil,
            atDesk: atDesk, networkProfile: profile, firewallShield: isShielded,
            batteryMinutesLeft: power.minutesLeft, chargerWatts: power.adapterWatts,
            chargerTooWeak: hasBattery && power.externalConnected ? power.chargerTooWeak : nil,
            reachable: reach?.isReachable, reach: reach?.text, summary: sentences.joined(separator: " "))
    }

    // MARK: - Control (awakectl / MCP)

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
            failure = hotspotSSID.isEmpty ? "No hotspot is chosen yet (Awake Settings)." : await joinHotspotNow()
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

        if lidMode.isSetUp, moveLowPower {
            let lowPower = self.lowPower
            let changes = await Task.detached { () -> (Bool?, [String]) in
                guard let current = lowPower.isOnForBattery(), !current else { return (nil, []) }
                do {
                    try lowPower.setForBattery(true)
                    return (current, [])
                } catch {
                    return (nil, ["Low Power Mode didn't switch on."])
                }
            }.value
            if snapshot.lowPowerOnBattery == nil { snapshot.lowPowerOnBattery = changes.0 }
            notes += changes.1
            saveSnapshot(snapshot)
        }
        return notes + (await updateShield())
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
        let lowPower = self.lowPower
        let undoGuardLowPower = defaults.bool(forKey: Keys.lowPowerSetByGuard) && snapshot?.lowPowerOnBattery == nil
        defaults.set(false, forKey: Keys.lowPowerSetByGuard)
        await Task.detached {
            Self.restorePrivileged(snapshot, lowPower: lowPower)
            if undoGuardLowPower {
                try? lowPower.setForBattery(false)
            }
        }.value
        return notes + (await updateShield())
    }

    nonisolated private static func restorePrivileged(_ snapshot: MoveSnapshot?, lowPower: LowPowerModeController) {
        if let previous = snapshot?.lowPowerOnBattery {
            try? lowPower.setForBattery(previous)
        }
    }

    private func loadSnapshot() -> MoveSnapshot? {
        defaults.data(forKey: Keys.moveSnapshot).flatMap { try? JSONDecoder().decode(MoveSnapshot.self, from: $0) }
    }

    private func saveSnapshot(_ snapshot: MoveSnapshot) {
        var snapshot = snapshot
        snapshot.firewall = nil
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: Keys.moveSnapshot)
    }

    /// A crash during On the Move under a build before the shield owned the firewall left the firewall shielded,
    /// with its previous state only in On the Move's snapshot. The shield takes that over, so it gets put back
    /// instead of being snapshotted as the "previous" state and kept on.
    private func adoptLegacyFirewallSnapshot() {
        guard let snapshot = loadSnapshot(), let legacy = snapshot.firewall else { return }
        shield.adoptLegacy(legacy)
        saveSnapshot(snapshot)
    }

    // MARK: - Firewall shield

    /// The shield's reasons: On the Move with its shield setting, or public Wi-Fi with that setting.
    private var shieldWanted: Bool {
        FirewallShield.isWanted(onTheMove: onTheMove, moveShield: moveShield, profile: heldProfile,
                                publicShield: publicShield)
    }

    /// Brings the firewall shield in line with its reasons. Steps run one at a time, so a raise and a lower can't
    /// interleave; each reads the reasons when it runs, so queued steps collapse. Returns notes about failures.
    @discardableResult
    func updateShield() async -> [String] {
        let previous = shieldTransition
        let transition = Task { @MainActor in
            _ = await previous?.value
            return await self.stepShield()
        }
        shieldTransition = transition
        return await transition.value
    }

    private func shieldSoon() {
        Task { await updateShield() }
    }

    /// One shield step. Its commands run on `firewallQueue`; after a quit has started, it does nothing more.
    private func stepShield() async -> [String] {
        guard !isQuitting else { return [] }
        let firewall = self.firewall
        let step = shield.step(wanted: shieldWanted)
        switch step {
        case .none:
            return []
        case .raise, .reapply:
            // Needs the admin permission; without it the panel says "not shielded".
            guard lidMode.isSetUp else { return [] }
            if step == .raise {
                guard let read = await firewallQueue.run({ firewall.read() }), !isQuitting else { return [] }
                guard let current = read else { return ["The firewall shield didn't switch on."] }
                shield.willRaise(from: current)
            }
            // Read the firewall back: a raise can fail partway, so the snapshot alone proves nothing. Nothing applied
            // drops the snapshot; a partial raise keeps it, and the next tick tries again.
            guard let observed = await firewallQueue.run({ () -> FirewallState? in
                try? firewall.apply(FirewallShield.shielded)
                return firewall.read()
            }) else { return [] }
            firewallNow = observed
            shield.didApply(observed: observed)
            return isShielded ? [] : ["The firewall shield didn't switch on."]
        case .lower:
            return await lowerShield() ? [] : ["Couldn't turn the firewall shield off."]
        }
    }

    /// Returns false (and keeps the snapshot for another try) if the firewall couldn't be put back.
    private func lowerShield() async -> Bool {
        let shield = self.shield, firewall = self.firewall
        guard let restored = await firewallQueue.run({ Self.restoreFirewall(shield, firewall: firewall) }) else {
            return false  // quitting: shutdown restores instead
        }
        if restored {
            self.shield.didLower()
        }
        return restored
    }

    /// Re-reads the firewall without privileges, behind any shield step, so "shielded" follows the real firewall.
    private func refreshFirewall() {
        guard !isReadingFirewall else { return }
        isReadingFirewall = true
        let firewall = self.firewall
        Task {
            let read = await firewallQueue.run { firewall.read() }
            isReadingFirewall = false
            if let read, read != firewallNow {
                firewallNow = read
            }
        }
    }

    nonisolated private static func restoreFirewall(_ shield: FirewallShield, firewall: FirewallController) -> Bool {
        guard let current = firewall.read() else { return false }
        return (try? firewall.apply(shield.restoreTarget(current: current))) != nil
    }

    // MARK: - Home vs public

    func trustCurrentNetwork() {
        guard let ssid = wifi.ssid, !trustedNetworks.contains(ssid) else { return }
        trustedNetworks.append(ssid)
    }

    func untrust(_ ssid: String) {
        trustedNetworks.removeAll { $0 == ssid }
    }

    /// Re-decides the profile. A change of the held profile moves the shield and re-checks reach and sharing; a
    /// change to home or public also runs that profile's shortcut (once per change, also across relaunches).
    private func updateProfile() {
        let decided = NetworkProfile.decide(ssid: wifi.ssid, trusted: trustedNetworks, hotspot: hotspotSSID)
        if profile != decided {
            profile = decided
        }
        let previous = heldProfile
        let held = profileHold.observe(decided, wifiOn: wifi.isPoweredOn, now: .now)
        guard held != previous else { return }
        shieldSoon()
        refreshReach(sharing: true)
        guard held != .unknown, defaults.string(forKey: Keys.lastProfile) != held.rawValue else { return }
        defaults.set(held.rawValue, forKey: Keys.lastProfile)
        runShortcut(held == .public ? publicShortcut : homeShortcut)
    }

    /// Queues a shortcut behind any still running, off the main actor. Empty names are skipped.
    private func runShortcut(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let previous = shortcutRun, shortcuts = self.shortcuts
        shortcutRun = Task { @MainActor in
            _ = await previous?.value
            let ran = await Task.detached { shortcuts.run(name) }.value
            if !ran {
                Notifier.post(title: "Couldn't run \"\(name)\"", body: "Check the shortcut's name in Awake Settings.")
            }
        }
    }

    // MARK: - Power

    private func refreshPower() {
        let reading = PowerMonitor.read()
        if reading != power {
            power = reading
        }
        for alert in powerAlerts.observe(reading, warnUnderMinutes: outletWarningMinutes, now: .now) {
            switch alert {
            case .findOutlet(let minutes):
                Notifier.post(title: "Find an outlet", body: "About \(TimeText.format(minutes: minutes)) left.")
            case .weakCharger(let watts):
                let charger = watts.map { "This \($0) W charger" } ?? "This charger"
                Notifier.post(title: "Charger too weak", body: "\(charger) can't keep up, so the battery is still draining.")
            }
        }
    }

    // MARK: - Remote reach

    /// Re-checks Tailscale off the main actor, and with `sharing` the sharing ports too. Each port-22 connect starts
    /// an sshd session (and a log line), so that runs only at launch, when the panel opens and when the profile
    /// changes. A request the running check already covers joins it; a sharing request during a Tailscale-only
    /// check runs once that one ends.
    private func refreshReach(sharing: Bool) {
        guard !isRefreshingReach else {
            if sharing, !reachCheckIncludesSharing { reachRecheck = true }
            return
        }
        isRefreshingReach = true
        reachCheckIncludesSharing = sharing
        let cli = tailscaleCLI, check = sharingCheck
        Task {
            let (status, services) = await Task.detached { (cli.status(), sharing ? check.servicesOn() : nil) }.value
            applyReach(status, services)
            lastReachCheck = .now
            isRefreshingReach = false
            if reachRecheck {
                reachRecheck = false
                refreshReach(sharing: true)
            }
        }
    }

    /// For `--render-preview` only, which draws once and exits.
    func refreshReachNow() {
        applyReach(tailscaleCLI.status(), sharingCheck.servicesOn())
    }

    /// `services` is nil when the sharing ports weren't checked this time; reach shows once they have been.
    private func applyReach(_ status: TailscaleStatus?, _ services: [SharingService]?) {
        if tailscale != status { tailscale = status }
        guard let services else { return }
        if sharingOn != services { sharingOn = services }
        if !reachChecked { reachChecked = true }
    }

    func performReachAction() {
        switch reach {
        case .reachable(let ssh)?, .untilSleep(let ssh)?:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ssh, forType: .string)
        case .remoteLoginOff?:
            NSWorkspace.shared.open(Self.sharingSettingsURL)
        case .tailscaleOff?:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Tailscale.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        case .tailscaleMissing?, nil:
            break
        }
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
                shieldSoon()
            }
            try lidMode.setEnabled(enabled)
            defaults.set(enabled, forKey: Keys.lidModeSetByAwake)
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
            shieldSoon()
        } catch LidModeError.setUpCancelled {
        } catch {
            Self.showAlert("Couldn't set up Awake's permission", error.localizedDescription)
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
                NSLog("Awake: launch at login change failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    // MARK: - Auto-hotspot

    var hotspotIsConfigured: Bool { hotspotSetupProblem == nil }

    var hotspotSetupProblem: String? {
        if hotspotSSID.isEmpty { return "Auto-hotspot has no hotspot chosen yet: pick one in Awake Settings." }
        if !location.isAuthorized { return "Awake needs Location access to see Wi-Fi names: allow it in Awake Settings." }
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
        if !didFirstNetworkCheck {
            // A shield left up by a crash comes down now if nothing wants it any more.
            didFirstNetworkCheck = true
            shieldSoon()
        }
        switch result {
        case .online:
            joinFailureNotified = false
            portalNotified = false
        case .captivePortal:
            if !portalNotified {
                portalNotified = true
                Notifier.post(title: "This Wi-Fi wants you to sign in",
                              body: "Awake will wait before switching to your hotspot.", category: .signIn)
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
                "Check the hotspot password in Awake Settings."
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
            Notifier.post(title: "Back on \(home)", body: "Awake left the hotspot to save your phone's data.")
        }
        wifi = await Task.detached { wifiControl.state() }.value
    }

    // MARK: - Housekeeping: desk, awake watch, guard, end conditions

    private func tick() {
        tickCount += 1
        updateDesk()
        refreshPower()
        guard tickCount % 6 == 0 else { return }
        lidMode.refresh()
        refreshAwakeWatch()
        if Date.now.timeIntervalSince(lastReachCheck) >= Self.reachInterval {
            refreshReach(sharing: false)
        }
        if shield.isUp {
            refreshFirewall()
        }
        if shield.step(wanted: shieldWanted) != .none {
            shieldSoon()  // retries a raise or lower that didn't finish
        }
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
            Notifier.post(title: "Claude finished", body: "Awake stopped keeping your Mac awake.")
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
                Notifier.post(title: "Your Mac is getting warm", body: "Awake turned on Low Power Mode to cool it down.")
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
                Notifier.post(title: "Your Mac got hot", body: "Awake turned everything off so it can sleep and cool down.")
            case .lowBattery(let percent):
                Notifier.post(title: "Battery at \(percent)%", body: "Awake turned everything off so your Mac can sleep.")
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
