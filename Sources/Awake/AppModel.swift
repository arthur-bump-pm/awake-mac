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

    /// The panel's choices under Keep awake; Off is a mode of its own.
    static let chips: [KeepAwakeOption] = [.minutes(60), .minutes(240), .indefinitely, .whileClaudeWorks]

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .indefinitely: "Always"
        case .minutes(let m): AppModel.format(TimeInterval(m) * 60)
        case .whileClaudeWorks: "While Claude works"
        }
    }

    /// For VoiceOver: "4 hours", not "4 hr".
    var spokenTitle: String {
        if case .minutes(let m) = self { return TimeText.spoken(minutes: m) }
        return title
    }

    /// For the settings store: minutes, or a negative code.
    var stored: Int {
        switch self {
        case .off: 0
        case .indefinitely: -1
        case .whileClaudeWorks: -2
        case .minutes(let m): m
        }
    }

    init(stored: Int) {
        switch stored {
        case -2: self = .whileClaudeWorks
        case 1...: self = .minutes(stored)
        default: self = .indefinitely
        }
    }
}

/// What the panel offers: one way of staying awake at a time.
enum AwakeMode: CaseIterable, Identifiable {
    case off, keepAwake, overnight, onTheMove

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .keepAwake: "Keep awake"
        case .overnight: "Overnight"
        case .onTheMove: "On the Move"
        }
    }
}

extension OvernightEnd {
    /// Mid-sentence form, e.g. "until Claude finishes"; the morning hour is the session's own time.
    var phrase: String {
        switch self {
        case .morning: "in the morning"
        case .whenClaudeFinishes: "when Claude finishes"
        case .manually: "when you turn it off"
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
        /// Lid-closed mode is on with no mode using it: set elsewhere, or a turn-off that failed.
        case lidModeLeftOn
        case leftDesk
        case backAtDesk
        case sharing
        case locationAccess
        /// The last lid-closed mode, permission, Overnight or On the Move action from the panel failed.
        case actionFailed
        case weakCharger
        case joinHotspot
        case health(HealthWarning.Kind)
        /// A trusted network is in range: switch to it, or "Not now".
        case trustedNearby(String)
    }

    let kind: Kind
    let message: String
    /// The button's title; nil for a warning with nothing to press.
    let action: String?
    /// Shows a "Not now" button that hides it (see `AppModel.dismiss`).
    var dismissible = false
    /// What VoiceOver says for the button when its title alone is vague.
    var spokenAction: String?
    var id: String { message }
}

/// Owns the features and the panel/settings state. One instance for the app's lifetime.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// How long every Claude session must stay idle before "Claude finished" counts.
    static let claudeIdleGrace: TimeInterval = 5 * 60
    static let moveTimeLimit: TimeInterval = 4 * 3600
    let keepAwake: KeepAwakeController
    let lidMode: LidModeController
    let location: LocationAccess
    /// Made by `--render-preview` from a fixed sample: it never reads or changes the user's settings or the system.
    let isPreview: Bool
    /// The app bundle, for the Claude Code command in Settings.
    let appPath: String
    private let userName: String

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
    /// A trusted network in range to offer switching to (see `TrustedReturn`), or nil.
    @Published private(set) var trustedOffer: String?
    /// The user's shortcuts, for Settings to pick from; read when Settings opens.
    @Published private(set) var installedShortcuts: [String] = []
    @Published private(set) var otherAwakeApps: [String] = []
    @Published private(set) var claudeWorking = 0
    @Published private(set) var keepAwakeWhileClaudeWorks = false
    @Published private(set) var atDesk = false
    @Published private(set) var deskNudge: DeskEvent?
    /// The hotspot password as last read from or saved to the keychain; nil until a read succeeds. Automatic work
    /// (failover) uses only this: the app is ad-hoc signed, so its signature changes with every install and a keychain
    /// read can wait on an "allow" prompt nobody answers (lid closed). The keychain is read off the main actor, at
    /// launch and when Settings opens.
    @Published private(set) var savedHotspotPassword: String?
    /// Why the last lid-closed mode, permission or On the Move action from the panel didn't fully work, until it's
    /// dismissed or a later one works. Shown in the panel too, since notifications may be off.
    @Published private(set) var lastFailure: String?
    /// Health warnings now (empty while they're turned off in Settings), and the busiest process once the CPU warning
    /// starts.
    @Published private(set) var healthWarnings: [HealthWarning] = []
    /// Mode changes queued or running (see `modeStep`).
    @Published private(set) var pendingModeSteps = 0
    @Published private(set) var busyProcess: String?

    @Published private(set) var onTheMove: Bool {
        didSet { defaults.set(onTheMove, forKey: Keys.onTheMove) }
    }
    /// The Overnight session, persisted so a crash or relaunch picks it up again.
    @Published private(set) var overnight: OvernightSession? {
        didSet { defaults.set(overnight.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.overnight) }
    }
    @Published var overnightEnd: OvernightEnd {
        didSet { defaults.set(overnightEnd.rawValue, forKey: Keys.overnightEnd) }
    }
    @Published var overnightHour: Int {
        didSet { defaults.set(overnightHour, forKey: Keys.overnightHour) }
    }
    @Published var offerTrustedNetworks: Bool {
        didSet {
            defaults.set(offerTrustedNetworks, forKey: Keys.offerTrusted)
            showTrustedOffer()
        }
    }
    @Published var healthWarningsOn: Bool {
        didSet {
            defaults.set(healthWarningsOn, forKey: Keys.healthWarnings)
            // Turned on: start over, so what's wrong now gets its notification.
            if healthWarningsOn, !oldValue {
                healthWatch = HealthWatch(cores: ProcessInfo.processInfo.activeProcessorCount)
            }
            showHealthWarnings()
        }
    }
    @Published var autoHotspot: Bool {
        didSet {
            // Assigning the same value (ending a move, a repeated request) must not reset the engine and lose the
            // Wi-Fi to return to.
            guard autoHotspot != oldValue else { return }
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
        static let overnight = "overnight"
        static let overnightEnd = "overnightEnd"
        static let overnightHour = "overnightHour"
        static let healthWarnings = "healthWarnings"
        static let lastKeepAwake = "lastKeepAwake"
        static let offerTrusted = "offerTrustedNetworks"
        static let onboarded = "onboarded"
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
    private var healthWatch = HealthWatch(cores: ProcessInfo.processInfo.activeProcessorCount)
    private var trustedReturn = TrustedReturn()
    private var isScanningForTrusted = false
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
    /// Keychain reads and writes run here, in order, never on the main actor.
    private let keychainQueue = DispatchQueue(label: "Awake.keychain")
    /// Counts password saves, so a read that started before one doesn't overwrite what the user just typed.
    private var passwordSaves = 0
    /// The guard runs one at a time (tick and thermal changes both start it) and acts once per episode.
    private var isGuarding = false
    private var guardEpisode = GuardEpisode()
    private var claudeWasWorking = false
    private var claudeIdleSince: Date?
    private var lowPowerOnBattery: Bool?
    /// On the Move switches one transition at a time, so a start and an end can't interleave across awaits.
    private var moveTransition: Task<[String], Never>?
    private var modeTransition: Task<Void, Never>?
    private var previewLaunchAtLogin = false
    private var cancellables = Set<AnyCancellable>()

    /// The live app, or with `preview` the sample `--render-preview` draws: then `defaults` is in memory, and lid-closed
    /// mode, Location, keep-awake and power come from the sample instead of the system.
    private init(defaults: UserDefaults = .standard, preview: PreviewSample? = nil) {
        self.defaults = defaults
        isPreview = preview != nil
        if let preview {
            lidMode = LidModeController(runner: PreviewCommands(lidClosedMode: preview.lidClosedMode),
                                        fileExists: { _ in preview.adminPermission }, defaults: defaults)
            location = LocationAccess(fixed: preview.locationAllowed ? .authorizedAlways : .notDetermined)
            keepAwake = KeepAwakeController(assertionManager: PreviewAssertions())
            power = preview.power
            appPath = PreviewSample.appPath
            userName = PreviewSample.userName
        } else {
            lidMode = LidModeController()
            location = LocationAccess()
            keepAwake = KeepAwakeController(allowDisplaySleep: defaults.bool(forKey: Keys.allowDisplaySleep))
            power = PowerMonitor.read()
            appPath = Bundle.main.bundlePath
            userName = NSUserName()
        }
        defaults.register(defaults: [Keys.returnToWiFi: true, Keys.safety: true, Keys.moveLowPower: true,
                                     Keys.moveShield: true, Keys.deskSuggestions: true, Keys.publicShield: true,
                                     Keys.outletWarningMinutes: PowerAlerts.defaultWarning, Keys.healthWarnings: true,
                                     Keys.offerTrusted: true,
                                     Keys.overnightHour: OvernightSession.defaultMorningHour,
                                     Keys.lastKeepAwake: KeepAwakeOption.indefinitely.stored])
        onTheMove = defaults.bool(forKey: Keys.onTheMove)
        overnight = defaults.data(forKey: Keys.overnight)
            .flatMap { try? JSONDecoder().decode(OvernightSession.self, from: $0) }
        overnightEnd = OvernightEnd(rawValue: defaults.string(forKey: Keys.overnightEnd) ?? "") ?? .morning
        let hour = defaults.integer(forKey: Keys.overnightHour)
        overnightHour = OvernightSession.morningChoices.contains(hour) ? hour : OvernightSession.defaultMorningHour
        healthWarningsOn = defaults.bool(forKey: Keys.healthWarnings)
        offerTrustedNetworks = defaults.bool(forKey: Keys.offerTrusted)
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

        Publishers.Merge3(keepAwake.objectWillChange, lidMode.objectWillChange, location.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Wi-Fi names appear as soon as Location access is allowed (the welcome's Wi-Fi step shows the network).
        location.$status.dropFirst().removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.checkSoon() } }
            .store(in: &cancellables)
    }

    func start() {
        precondition(!isPreview, "a preview model never starts")
        // First, before changing anything: a second copy must neither take the socket over nor touch any setting.
        let server = ControlServer { request in await AppModel.shared.handle(request) }
        do {
            try server.start()
            controlServer = server
        } catch ControlSocketError.alreadyRunning {
            NSLog("Awake: another copy is already running; quitting this one.")
            exit(0)
        } catch {
            NSLog("Awake: control socket unavailable: \(error.localizedDescription)")
        }

        Notifier.setUp(askPermission: didOnboard)
        adoptLegacyFirewallSnapshot()
        if !defaults.bool(forKey: Keys.didRegisterLoginItem) {
            defaults.set(true, forKey: Keys.didRegisterLoginItem)
            launchAtLogin = true
        }
        if onTheMove {
            // Keep-awake assertions end with the process; bring it back after a relaunch, then finish starting On the
            // Move in case a crash cut the start short.
            keepAwake.activate()
            resumeMove()
        } else if loadSnapshot() != nil {
            // A snapshot without On the Move: a crash cut an end short before it put everything back.
            finishInterruptedMoveEnd()
        }
        resumeOvernight()
        Task { await loadHotspotPassword() }

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
        refreshHealth(disk: true)
        refreshReach(sharing: true)
        refreshFirewall()
        // Common modes, so the tick keeps running while a menu or a control is tracking the mouse.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.runGuard() }
        }
    }

    /// Puts back what Awake changed. Runs synchronously: the app is about to exit. Lid-closed mode and Low Power Mode
    /// go first, so a slow firewall command can't hold them up. A "set by Awake" flag is cleared only once its setting
    /// is really off, so a failure can still be undone later.
    func shutdown() {
        controlServer?.stop()
        isQuitting = true
        lidMode.refreshNow()
        // Quitting ends Overnight like any other mode; lid-closed mode goes off below if Awake turned it on.
        overnight = nil
        if onTheMove {
            let snapshot = loadSnapshot()
            Self.restorePrivileged(snapshot, lowPower: lowPower)
            defaults.removeObject(forKey: Keys.moveSnapshot)
            onTheMove = false
            autoHotspot = snapshot?.autoHotspot ?? autoHotspot
        }
        if defaults.bool(forKey: Keys.lowPowerSetByGuard), (try? lowPower.setForBattery(false)) != nil {
            defaults.set(false, forKey: Keys.lowPowerSetByGuard)
        }
        keepAwake.deactivate()
        if defaults.bool(forKey: Keys.lidModeSetByAwake), !lidMode.isEnabled || (try? lidMode.setEnabledNow(false)) != nil {
            defaults.set(false, forKey: Keys.lidModeSetByAwake)
        }
        // Waits for a shield command in flight (a raise could otherwise finish after the restore and leave the
        // firewall on with no snapshot), restores, and stops any shield step still queued.
        let shield = self.shield, firewall = self.firewall
        if firewallQueue.close(then: { shield.isUp && Self.restoreFirewall(shield, firewall: firewall) }) {
            self.shield.didLower()
        }
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    /// Called when the panel opens, so it shows fresh state.
    func panelWillOpen() {
        Task { await lidMode.refresh() }
        refreshAwakeWatch()
        refreshPower()
        refreshHealth(disk: true)
        refreshReach(sharing: true)
        refreshFirewall()
        checkSoon()
        scanForTrustedIfDue()
    }

    // MARK: - Status

    var online: Bool? { connectivity.map { $0 == .online } }

    var isKeepingAwake: Bool { keepAwake.isActive || lidMode.isEnabled }

    /// Awake itself keeps the Mac awake (On the Move, Overnight, keep-awake or lid-closed mode); the menu bar eyes
    /// are open.
    var isAwakeOn: Bool { onTheMove || overnight != nil || isKeepingAwake }

    /// The panel's mode. Lid-closed mode left on by something else isn't a mode: the panel warns about it instead.
    var mode: AwakeMode {
        if onTheMove { return .onTheMove }
        if overnight != nil { return .overnight }
        if keepAwake.isActive { return .keepAwake }
        return .off
    }

    /// The menu bar item's state, for VoiceOver and its tooltip.
    var menuBarStatus: String {
        if onTheMove { return "On the Move" }
        if let overnight { return "Overnight: running with the lid closed too, \(overnightPhrase(overnight))" }
        if lidMode.isEnabled { return "Keeping your Mac awake, lid closed too" }
        if keepAwake.isActive {
            return keepAwakeWhileClaudeWorks ? "Keeping your Mac awake while Claude works" : "Keeping your Mac awake"
        }
        return "Off"
    }

    /// Other apps holding the Mac awake: "Also …" while Awake keeps it awake too, plain otherwise.
    var otherAwakeAppsLine: String? {
        guard !otherAwakeApps.isEmpty else { return nil }
        let names = otherAwakeApps.joined(separator: ", ")
        return isAwakeOn ? "Also keeping it awake: \(names)" : "Keeping it awake: \(names)"
    }

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

    /// "until 9:00 AM", "until Claude finishes" or "until you turn it off".
    func overnightPhrase(_ session: OvernightSession) -> String {
        switch session.end {
        case .morning: session.until.map { "until \($0.formatted(date: .omitted, time: .shortened))" } ?? "until morning"
        case .whenClaudeFinishes: "until Claude finishes"
        case .manually: "until you turn it off"
        }
    }

    /// For the status: "at 9:00 AM", "when Claude finishes" or "when turned off".
    private func overnightEndsText(_ session: OvernightSession) -> String {
        switch session.end {
        case .morning: session.until.map { "at \($0.formatted(date: .omitted, time: .shortened))" } ?? "in the morning"
        case .whenClaudeFinishes: "when Claude finishes"
        case .manually: "when turned off"
        }
    }

    /// The second line of a mode in the panel: what it does, or for the mode that's on, how it's going.
    func modeDetail(_ mode: AwakeMode) -> String {
        let on = self.mode == mode
        switch mode {
        case .off:
            guard on, !otherAwakeApps.isEmpty else { return "Sleeps as usual" }
            return "\(otherAwakeApps.joined(separator: ", ")) \(otherAwakeApps.count == 1 ? "keeps" : "keep") it awake anyway"
        case .keepAwake:
            guard on else { return "Lid open" }
            if keepAwakeWhileClaudeWorks { return "Lid open · while Claude works" }
            return "Lid open · " + (keepAwake.remainingTime.map { "\(Self.format($0)) left" } ?? "until you turn it off")
        case .overnight:
            if on, let overnight { return "Lid closed is fine · \(overnightPhrase(overnight))" }
            return lidMode.isSetUp ? "Lid closed is fine · for long jobs" : "Lid closed is fine · asks for your password once"
        case .onTheMove:
            return on ? "Lid closed, hotspot · ends \(moveEnd.phrase)" : "Lid closed, hotspot, Low Power Mode"
        }
    }

    /// The panel's second header line: the network's profile and Claude's sessions, or nil.
    var panelDetail: String? {
        var parts: [String] = []
        switch profile {
        case .public: parts.append(isShielded ? "Public Wi-Fi · shielded" : publicShield ? "Public Wi-Fi · not shielded" : "Public Wi-Fi")
        case .home: if isShielded { parts.append("Firewall shield on") }
        case .unknown: if isShielded { parts.append("Firewall shield on") }
        }
        if claudeWorking > 0 {
            parts.append(claudeWorking == 1 ? "1 Claude session working" : "\(claudeWorking) Claude sessions working")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The shield is up and the firewall, as last read, really is shielded (the user can switch it off behind it).
    var isShielded: Bool { shield.isOn(firewall: firewallNow) }

    /// Features that are on but can't work without Location access: macOS hides Wi-Fi names, so the shield can't tell
    /// public from trusted Wi-Fi and auto-hotspot can't find the hotspot.
    var featuresNeedingLocation: [String] {
        guard !location.isAuthorized else { return [] }
        return (publicShield ? ["the public Wi-Fi shield"] : []) + (autoHotspot ? ["auto-hotspot"] : [])
    }

    /// "The public Wi-Fi shield and auto-hotspot need Location access", or nil when nothing does.
    private var locationProblem: String? {
        let features = featuresNeedingLocation
        guard let first = features.first else { return nil }
        let subject = features.count == 1 ? first : features.joined(separator: " and ")
        let capitalized = subject.prefix(1).uppercased() + subject.dropFirst()
        return "\(capitalized) \(features.count == 1 ? "needs" : "need") Location access"
    }

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
                                    lidClosedMode: lidMode.isEnabled, user: userName)
    }

    /// Tailscale's app is there to open (a Homebrew install has only the CLI).
    var canOpenTailscale: Bool {
        isPreview || FileManager.default.fileExists(atPath: TailscaleCLI.appPath)
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
        if let locationProblem {
            alerts.append(PanelAlert(kind: .locationAccess, message: locationProblem + ".",
                                     action: location.isDenied ? "Open Settings" : "Allow"))
        }
        if let ssid = trustedOffer {
            let question = isOnHotspot ? "Switch from your hotspot?" : wifi.ssid == nil ? "Join it?" : "Switch from this public Wi-Fi?"
            alerts.append(PanelAlert(kind: .trustedNearby(ssid), message: "\(ssid) is in range. \(question)", action: "Switch",
                                     dismissible: true, spokenAction: "Switch to \(ssid)"))
        }
        if connectivity == .offline, hotspotIsConfigured, canJoinHotspotNow {
            alerts.append(PanelAlert(kind: .joinHotspot, message: "No internet. Your hotspot, \(hotspotSSID), can take over.",
                                     action: "Join"))
        }
        if let lastFailure {
            alerts.append(PanelAlert(kind: .actionFailed, message: lastFailure, action: "OK"))
        }
        // While Overnight or On the Move keeps the Mac running anyway, a stray lid-closed mode changes nothing; while a
        // mode is switching, lid-closed mode can be on a moment before its mode is.
        if lidMode.isEnabled, !onTheMove, overnight == nil, pendingModeSteps == 0 {
            let message = defaults.bool(forKey: Keys.lidModeSetByAwake) ? "Lid-closed mode is still on, so your Mac won't sleep."
                                                                          : "Lid-closed mode was turned on outside Awake."
            alerts.append(PanelAlert(kind: .lidModeLeftOn, message: message, action: "Turn Off"))
        }
        if power.percent != nil, power.chargerTooWeak {
            let charger = power.adapterWatts.map { "Charger too weak (\($0) W)" } ?? "Charger too weak"
            alerts.append(PanelAlert(kind: .weakCharger, message: "\(charger): the battery is still draining.", action: nil))
        }
        alerts += healthWarnings.map(healthAlert)
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
        case .lidModeLeftOn:
            // Queued like the modes, and only while still stray: a mode that took it over meanwhile keeps it.
            await modeStep {
                guard self.lidMode.isEnabled, !self.onTheMove, self.overnight == nil else { return }
                await self.setLidModeFromMenu(false)
            }
        case .leftDesk:
            deskNudge = nil
            await setModeFromMenu(.onTheMove)
        case .backAtDesk:
            deskNudge = nil
            await endMoveFromMenu()
        case .sharing:
            NSWorkspace.shared.open(Self.sharingSettingsURL)
        case .locationAccess:
            location.request()
        case .actionFailed:
            lastFailure = nil
        case .joinHotspot:
            await joinHotspotNow()
        case .weakCharger:
            break
        case .health(.disk):
            NSWorkspace.shared.open(Self.storageSettingsURL)
        case .health(.memory), .health(.cpu):
            NSWorkspace.shared.open(Self.activityMonitorURL)
        case .trustedNearby(let ssid):
            await switchToTrusted(ssid)
        }
    }

    /// "Not now" on a dismissible alert.
    func dismiss(_ alert: PanelAlert) {
        guard case .trustedNearby(let ssid) = alert.kind else { return }
        trustedReturn.decline(ssid)
        showTrustedOffer()
    }

    static let storageSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
    static let activityMonitorURL = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")

    private func healthAlert(_ warning: HealthWarning) -> PanelAlert {
        switch warning {
        case .diskAlmostFull(let free):
            return PanelAlert(kind: .health(.disk), message: "Disk almost full: \(Self.bytes(free)) free. Builds and downloads can fail.",
                              action: "Open Storage")
        case .lowMemory(let critical):
            return PanelAlert(kind: .health(.memory),
                              message: critical ? "Memory is very low: macOS may quit apps." : "Memory is low, so apps and Claude slow down.",
                              action: "Activity Monitor")
        case .busyCPU:
            let who = busyProcess.map { ", mostly \($0)" } ?? ""
            return PanelAlert(kind: .health(.cpu), message: "The CPU has been busy on battery for 10 min\(who), so it drains faster.",
                              action: "Activity Monitor")
        }
    }

    /// "8.2 GB", as Finder counts.
    nonisolated static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
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
        if let overnight {
            sentences.append("Overnight is on: the Mac keeps running with the lid closed \(overnightPhrase(overnight)).")
        } else if lidMode.isEnabled {
            sentences.append("The Mac keeps running with the lid closed.")
        } else if keepAwakeWhileClaudeWorks {
            sentences.append("The Mac stays awake while Claude works (lid open).")
        } else if keepAwake.isActive {
            sentences.append(keepAwake.remainingTime.map { "The Mac stays awake for \(Self.format($0)) (lid open)." }
                             ?? "The Mac stays awake while the lid is open.")
        } else {
            sentences.append("Awake is off.")
        }
        if claudeWorking > 0 {
            sentences.append(claudeWorking == 1 ? "1 Claude session is working." : "\(claudeWorking) Claude sessions are working.")
        }
        if autoHotspot {
            // Location is one sentence below, for every feature that needs it.
            sentences.append(hotspotSSID.isEmpty ? "Auto-hotspot is on, but no hotspot is chosen yet: pick one in Awake Settings."
                                                 : "Auto-hotspot is on (\(hotspotSSID)).")
        }
        sentences.append(networkStatus + ".")
        if let profileSentence {
            sentences.append(profileSentence)
        }
        if let locationProblem {
            sentences.append("\(locationProblem) to see Wi-Fi names: allow it in Awake Settings.")
        }
        if profile == .public, !sharingOn.isEmpty {
            sentences.append("Sharing is on: \(sharingOn.map(\.title).joined(separator: ", ")).")
        }
        if let trustedOffer {
            sentences.append("\(trustedOffer), a trusted network, is in range; the user can switch to it from Awake's menu.")
        }
        if !otherAwakeApps.isEmpty {
            let names = otherAwakeApps.joined(separator: ", ")
            sentences.append(isAwakeOn ? "Also keeping the Mac awake: \(names)." : "Keeping the Mac awake: \(names).")
        }
        if let battery = power.sentence {
            sentences.append(battery)
        }
        if let reach {
            sentences.append(reach.sentence)
        }
        let warnings = healthWarnings.map { healthAlert($0).message }
        sentences += warnings
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
            reachable: reach?.isReachable, reach: reach?.text, overnight: overnight != nil,
            overnightEnds: overnight.map(overnightEndsText),
            diskFreeGB: healthWatch.diskFreeBytes.map { (Double($0) / 1e8).rounded() / 10 },
            memoryPressure: healthWatch.memory?.name,
            cpuPercent: healthWatch.recentBusyCores.map { Int(($0 / Double(healthWatch.cores) * 100).rounded()) },
            warnings: warnings.isEmpty ? nil : warnings, summary: sentences.joined(separator: " "))
    }

    // MARK: - Control (awakectl / MCP)

    /// A malformed request (a switch without "on") is refused, never read as "on". A move or keep-awake started here
    /// came from Claude (MCP, or awakectl in its shell), so it counts as Claude having worked for the end conditions.
    func handle(_ request: ControlRequest) async -> ControlResponse {
        if let problem = request.problem {
            return ControlResponse(ok: false, error: problem, status: status())
        }
        var notes: [String] = []
        var failure: String?
        switch request.command {
        case .status:
            break
        // One mode at a time, as in the panel: On the Move and keep-awake take over from Overnight, and the other way
        // round (see `startOvernight`). Keep-awake off leaves Overnight on: it wasn't asked to stop.
        case .move:
            let on = request.on == true
            notes = await modeStep {
                let ended = on ? await self.endOvernight() : nil
                return (ended.map { [$0] } ?? []) + (await self.setOnTheMove(on))
            }
            if on { claudeHasWorked() }
        case .keepAwake:
            let option: KeepAwakeOption = if request.on == false {
                .off
            } else if request.whileClaudeWorks == true {
                .whileClaudeWorks
            } else if let minutes = request.minutes {
                .minutes(minutes)
            } else {
                .indefinitely
            }
            failure = await modeStep {
                let problem = option == .off ? nil : await self.endOvernight()
                self.keepAwakeOption = option
                return problem
            }
            if request.on == true { claudeHasWorked() }
        case .lidMode:
            // Lid-closed mode on its own is Overnight that ends only when turned off. Off also turns off lid-closed mode
            // that something else turned on: it was asked for.
            let on = request.on == true
            failure = await modeStep {
                if on {
                    return self.onTheMove ? await self.lidModeProblem(true) : await self.startOvernight(end: .manually)
                }
                self.overnight = nil
                return await self.lidModeProblem(false)
            }
        case .overnight:
            let on = request.on == true
            failure = await modeStep { await self.setOvernight(on, end: request.end) }
            if on, failure == nil { claudeHasWorked() }
        case .autoHotspot:
            autoHotspot = request.on == true
            if autoHotspot, let problem = hotspotSetupProblem {
                notes.append(problem)
            }
        case .joinHotspot:
            failure = hotspotSSID.isEmpty ? "No hotspot is chosen yet: pick one in Awake Settings." : await joinHotspotNow()
        }
        return ControlResponse(ok: failure == nil, error: failure, notes: notes.isEmpty ? nil : notes, status: status())
    }

    // MARK: - Modes

    /// The panel's mode list: one mode at a time. Leaving On the Move first puts back what it changed; a failure shows
    /// in the panel (and a notification), like the other actions from the menu.
    func setModeFromMenu(_ mode: AwakeMode) async {
        await modeStep { await self.switchMode(to: mode) }
    }

    /// "Back at your desk" (an alert or a notification): ends On the Move and puts back what was there before, unlike
    /// picking Off.
    func endMoveFromMenu() async {
        await modeStep { await self.setOnTheMoveFromMenu(false) }
    }

    /// Mode changes (the panel, awakectl, MCP, the timed ends) run one at a time, each deciding from the state when it
    /// runs: a tap made while an earlier one waits on the password prompt applies after it, not halfway through.
    private func modeStep<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = modeTransition
        pendingModeSteps += 1
        let step = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        modeTransition = Task { _ = await step.value }
        let result = await step.value
        pendingModeSteps -= 1
        return result
    }

    private func switchMode(to mode: AwakeMode) async {
        guard mode != self.mode else { return }
        switch mode {
        case .onTheMove:
            if let problem = await endOvernight() {
                return reportFailure(problem, title: "Couldn't end Overnight")
            }
            await setOnTheMoveFromMenu(true)
        case .overnight:
            await setOvernightFromMenu(true)
        case .off, .keepAwake:
            if onTheMove {
                await setOnTheMoveFromMenu(false)
            }
            if let problem = await endOvernight() {
                return reportFailure(problem, title: "Couldn't end Overnight")
            }
            keepAwakeOption = mode == .off ? .off : lastKeepAwake
        }
    }

    /// The Keep awake choice last made in the panel; picking Keep awake again starts with it.
    var lastKeepAwake: KeepAwakeOption {
        KeepAwakeOption(stored: defaults.integer(forKey: Keys.lastKeepAwake))
    }

    /// A chip under Keep awake. Queued like the modes: tapped while another mode is still switching on, it wins.
    func chooseKeepAwake(_ option: KeepAwakeOption) async {
        await modeStep {
            self.defaults.set(option.stored, forKey: Keys.lastKeepAwake)
            if self.mode == .keepAwake {
                self.keepAwakeOption = option
            } else {
                await self.switchMode(to: .keepAwake)
            }
        }
    }

    private func reportFailure(_ problem: String, title: String) {
        guard problem != Self.setUpCancelled else { return }
        lastFailure = "\(title). \(problem)"
        Notifier.post(title: title, body: problem)
    }

    // MARK: - Overnight

    /// Starts Overnight (ending On the Move or keep-awake first) or ends it. Returns a problem, as a sentence, or nil.
    func setOvernight(_ on: Bool, end: OvernightEnd? = nil) async -> String? {
        on ? await startOvernight(end: end ?? overnightEnd) : await endOvernight()
    }

    func setOvernightFromMenu(_ on: Bool) async {
        if let problem = await setOvernight(on) {
            reportFailure(problem, title: on ? "Couldn't start Overnight" : "Couldn't end Overnight")
        } else {
            lastFailure = nil
        }
    }

    /// The one-time password prompt comes first, so cancelling it changes nothing (On the Move stays on). Lid-closed
    /// mode then goes on before keep-awake goes off. Starting again while on only sets the new end.
    private func startOvernight(end: OvernightEnd) async -> String? {
        if !lidMode.isSetUp {
            do {
                try await lidMode.setUp()
                shieldSoon()
            } catch LidModeError.setUpCancelled {
                return Self.setUpCancelled
            } catch {
                return error.localizedDescription
            }
        }
        if onTheMove {
            let notes = await setOnTheMove(false)
            if !notes.isEmpty {
                Notifier.post(title: "Back at your desk", body: notes.joined(separator: " "))
            }
        }
        if let problem = await lidModeProblem(true) {
            return problem
        }
        if keepAwake.isActive {
            keepAwakeOption = .off
        }
        refreshAwakeWatch()
        claudeWasWorking = claudeWorking > 0
        claudeIdleSince = nil
        overnight = OvernightSession.start(end: end, morningHour: overnightHour, now: .now)
        return nil
    }

    /// Turns lid-closed mode off if Awake turned it on (On the Move may own it now, then it stays). If that fails, the
    /// session still ends and the panel's "still on" alert offers to turn lid-closed mode off again.
    @discardableResult
    private func endOvernight() async -> String? {
        guard overnight != nil else { return nil }
        overnight = nil
        guard !onTheMove, defaults.bool(forKey: Keys.lidModeSetByAwake), let problem = await lidModeProblem(false) else {
            return nil
        }
        return "Couldn't turn off lid-closed mode. \(problem)"
    }

    /// At launch. Overnight left on by a crash or restart goes on, its lid-closed mode back on without a password
    /// prompt (nobody may be there), or ends if its time has passed. Lid-closed mode that an older build's switch left
    /// on becomes Overnight that ends only when turned off.
    private func resumeOvernight() {
        if overnight == nil, !onTheMove, loadSnapshot() == nil, lidMode.isEnabled,
           defaults.bool(forKey: Keys.lidModeSetByAwake) {
            overnight = OvernightSession(end: .manually, until: nil, started: .now)
        }
        guard let session = overnight, !onTheMove else {
            overnight = nil
            return
        }
        if session.isOver(now: .now, claudeFinished: false) {
            Task { await endOvernight() }
        } else if !lidMode.isEnabled, !lidMode.isSetUp {
            overnight = nil
        } else if !lidMode.isEnabled {
            Task {
                if let problem = await lidModeProblem(true) {
                    overnight = nil
                    reportFailure(problem, title: "Couldn't resume Overnight")
                }
            }
        }
    }

    // MARK: - On the Move

    /// Switches On the Move on (lid-closed mode, keep-awake, auto-hotspot, and on battery Low Power Mode and
    /// the firewall shield) or restores what was there before. Returns notes about anything that couldn't switch.
    @discardableResult
    func setOnTheMove(_ on: Bool) async -> [String] {
        await moveStep { on ? await self.startMove() : await self.endMove() }
    }

    /// Runs one On the Move transition after the ones before it.
    private func moveStep(_ work: @escaping @MainActor () async -> [String]) async -> [String] {
        let previous = moveTransition
        let transition = Task { @MainActor in
            _ = await previous?.value
            return await work()
        }
        moveTransition = transition
        return await transition.value
    }

    /// After a relaunch with On the Move on (a crash or force quit can come partway through starting it), finishes
    /// starting it; starting is idempotent. Never asks for the admin password here: nobody may be there to answer.
    private func resumeMove() {
        Task { await moveStep { await self.startMove(allowSetUp: false) } }
    }

    /// Ending keeps the snapshot until lid-closed mode and Low Power Mode are back, so a crash in between leaves it
    /// for the next launch to finish.
    private func finishInterruptedMoveEnd() {
        Task {
            await moveStep {
                guard !self.onTheMove, let snapshot = self.loadSnapshot() else { return [] }
                return await self.putBackAfterMove(snapshot)
            }
        }
    }

    func setOnTheMoveFromMenu(_ on: Bool) async {
        let notes = await setOnTheMove(on)
        // Hotspot setup already shows in the panel (the auto-hotspot row, the Location alert), so it isn't a failure.
        let failures = notes.filter { $0 != hotspotSetupProblem }
        lastFailure = failures.isEmpty ? nil : failures.joined(separator: " ")
        if !notes.isEmpty {
            Notifier.post(title: on ? "On the Move is on" : "Back at your desk", body: notes.joined(separator: " "))
        }
    }

    private func startMove(allowSetUp: Bool = true) async -> [String] {
        var notes: [String] = []
        let starting = !onTheMove
        // Lid-closed mode as it is now (another tool or a person may have changed it), for the snapshot and the switch.
        await lidMode.refresh()
        // Snapshot before changing anything, so an interruption can always be undone.
        var snapshot = (starting ? nil : loadSnapshot())
            ?? MoveSnapshot(keepAwake: currentKeepAwake, lidMode: lidMode.isEnabled, autoHotspot: autoHotspot)
        saveSnapshot(snapshot)
        if starting {
            onTheMove = true
            defaults.set(Date.now, forKey: Keys.moveStartedAt)
            refreshAwakeWatch()
            claudeWasWorking = claudeWorking > 0
            claudeIdleSince = nil
            deskNudge = nil
        }
        if keepAwakeWhileClaudeWorks { keepAwakeWhileClaudeWorks = false }
        keepAwake.activate()
        if !autoHotspot {
            autoHotspot = true
        }
        if let problem = hotspotSetupProblem {
            notes.append(problem)
        }
        if !lidMode.isEnabled, allowSetUp || lidMode.isSetUp, let problem = await lidModeProblem(true) {
            notes.append("Lid-closed mode stayed off, so closing the lid will still put the Mac to sleep. \(problem)")
        }

        if moveLowPower {
            if lidMode.isSetUp {
                notes += await switchOnLowPower(recordingIn: &snapshot)
            } else {
                notes.append("Low Power Mode stayed off: set up Awake's permission in Awake Settings first.")
            }
        }
        return notes + (await updateShield())
    }

    /// Turns Low Power Mode on for battery if it's off. What it was is saved in the snapshot before `pmset` runs, so a
    /// crash right after the change can still be undone.
    private func switchOnLowPower(recordingIn snapshot: inout MoveSnapshot) async -> [String] {
        let lowPower = self.lowPower
        guard let current = await Task.detached(operation: { lowPower.isOnForBattery() }).value, !current else {
            return []
        }
        let recorded = snapshot.lowPowerOnBattery == nil
        if recorded {
            snapshot.lowPowerOnBattery = current
            saveSnapshot(snapshot)
        }
        let switched = await Task.detached { (try? lowPower.setForBattery(true)) != nil }.value
        guard !switched else { return [] }
        if recorded {
            snapshot.lowPowerOnBattery = nil
            saveSnapshot(snapshot)
        }
        return ["Couldn't turn on Low Power Mode."]
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
        let snapshot = loadSnapshot()
        onTheMove = false
        defaults.removeObject(forKey: Keys.moveStartedAt)
        restoreKeepAwake(snapshot?.keepAwake)
        autoHotspot = snapshot?.autoHotspot ?? false
        return await putBackAfterMove(snapshot)
    }

    /// The part of ending On the Move that outlives the process: lid-closed mode, Low Power Mode and the shield. The
    /// snapshot is dropped only after these, so a crash midway leaves it for the next launch (`start()`).
    private func putBackAfterMove(_ snapshot: MoveSnapshot?) async -> [String] {
        var notes: [String] = []
        await lidMode.refresh()
        if snapshot?.lidMode != true, lidMode.isEnabled, defaults.bool(forKey: Keys.lidModeSetByAwake),
           let problem = await lidModeProblem(false) {
            notes.append("Couldn't turn off lid-closed mode. \(problem)")
        }
        let lowPower = self.lowPower
        // The move's own restore decides Low Power Mode when it changed it; otherwise the guard's change is undone.
        let undoGuardLowPower = defaults.bool(forKey: Keys.lowPowerSetByGuard) && snapshot?.lowPowerOnBattery == nil
        let guardUndone = await Task.detached { () -> Bool in
            Self.restorePrivileged(snapshot, lowPower: lowPower)
            return undoGuardLowPower && (try? lowPower.setForBattery(false)) != nil
        }.value
        if snapshot?.lowPowerOnBattery != nil || guardUndone {
            defaults.set(false, forKey: Keys.lowPowerSetByGuard)
        }
        defaults.removeObject(forKey: Keys.moveSnapshot)
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
        guard !isPreview else { return }
        Task { await updateShield() }
    }

    /// One shield step. Its commands run on `firewallQueue`; after a quit has started, it does nothing more.
    private func stepShield() async -> [String] {
        guard !isQuitting, !isPreview else { return [] }
        let firewall = self.firewall
        let step = shield.step(wanted: shieldWanted)
        switch step {
        case .none:
            return []
        case .raise, .reapply:
            // Needs the admin permission; without it the panel says "not shielded", and the note tells Claude.
            guard lidMode.isSetUp else {
                return ["The firewall shield stayed off: set up Awake's permission in Awake Settings first."]
            }
            if step == .raise {
                guard let read = await firewallQueue.run({ firewall.read() }), !isQuitting else { return [] }
                guard let current = read else { return ["Couldn't turn on the firewall shield."] }
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
            return isShielded ? [] : ["Couldn't turn on the firewall shield."]
        case .lower:
            return await lowerShield() ? [] : ["Couldn't turn off the firewall shield."]
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
        guard let ssid = wifi.ssid else { return }
        trust(ssid)
    }

    func trust(_ ssid: String) {
        guard !ssid.isEmpty, !trustedNetworks.contains(ssid) else { return }
        trustedNetworks.append(ssid)
    }

    func untrust(_ ssid: String) {
        trustedNetworks.removeAll { $0 == ssid }
    }

    /// Re-decides the profile. A change of the held profile moves the shield and re-checks reach and sharing; a
    /// change to home or public also runs that profile's shortcut (once per change, also across relaunches).
    private func updateProfile() {
        updateTrustedOffer()
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
        guard !name.isEmpty, !isPreview else { return }
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

    // MARK: - Health

    /// Every tick: CPU and memory (both cheap). With `disk`, the free space too, off the main actor.
    private func refreshHealth(disk: Bool) {
        guard !isPreview else { return }
        let discharging = power.onBattery || power.chargerTooWeak
        observeHealth(HealthSample(cpu: HealthMonitor.cpuTicks(), memory: HealthMonitor.memoryPressure(),
                                   diskFreeBytes: nil, discharging: discharging))
        guard disk else { return }
        Task {
            let free = await Task.detached { HealthMonitor.diskFreeBytes() }.value
            observeHealth(HealthSample(cpu: nil, memory: nil, diskFreeBytes: free, discharging: discharging))
        }
    }

    private func observeHealth(_ sample: HealthSample) {
        let started = healthWatch.observe(sample, now: .now)
        if !healthWatch.warnings.contains(.busyCPU), busyProcess != nil {
            busyProcess = nil
        }
        showHealthWarnings()
        guard healthWarningsOn else { return }
        for warning in started {
            switch warning {
            case .diskAlmostFull(let free):
                Notifier.post(title: "Disk almost full", body: "\(Self.bytes(free)) free. Builds and downloads can fail.")
            case .lowMemory(let critical):
                Notifier.post(title: critical ? "Memory is very low" : "Memory is low",
                              body: "Quit apps you don't need, or Claude's work slows down.")
            case .busyCPU:
                // Named once, when the warning starts: `ps` isn't worth running every few seconds.
                Task {
                    let name = await Task.detached { HealthMonitor.busiestProcess() }.value
                    // Notified even if it calmed down meanwhile: the watch notifies once per discharge.
                    if healthWatch.warnings.contains(.busyCPU) { busyProcess = name }
                    Notifier.post(title: "Busy CPU on battery",
                                  body: "\(name ?? "Something") has kept the CPU busy for 10 minutes, so the battery drains faster.")
                }
            }
        }
    }

    private func showHealthWarnings() {
        let shown = healthWarningsOn ? healthWatch.warnings : []
        if healthWarnings != shown { healthWarnings = shown }
    }

    // MARK: - Remote reach

    /// Re-checks Tailscale off the main actor, and with `sharing` the sharing ports too. Each port-22 connect starts
    /// an sshd session (and a log line), so that runs only at launch, when the panel opens and when the profile
    /// changes. A request the running check already covers joins it; a sharing request during a Tailscale-only
    /// check runs once that one ends.
    private func refreshReach(sharing: Bool) {
        guard !isPreview else { return }
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
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: TailscaleCLI.appPath),
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
            // Only "while Claude works" starts its own watch: other choices would otherwise forget that Claude worked,
            // and an On the Move or Overnight that ends when Claude finishes would never end.
            if newValue == .whileClaudeWorks {
                // Fresh, not up to 30 s old: the session asking for this is likely working right now.
                refreshAwakeWatch()
                claudeWasWorking = claudeWorking > 0
                claudeIdleSince = nil
            }
            switch newValue {
            case .off: keepAwake.deactivate()
            case .indefinitely, .whileClaudeWorks: keepAwake.activate()
            case .minutes(let m): keepAwake.activate(for: TimeInterval(m) * 60)
            }
        }
    }

    // MARK: - Lid-closed mode

    static let setUpCancelled = "The password prompt was cancelled."

    /// Switches lid-closed mode (running setup first if needed). Returns a problem, as a sentence, or nil. Turning on
    /// lid-closed mode that was already on (set by another tool or by hand) doesn't make it Awake's to turn off.
    func lidModeProblem(_ enabled: Bool) async -> String? {
        do {
            if enabled, !lidMode.isSetUp {
                try await lidMode.setUp()
                shieldSoon()
            }
            if enabled { await lidMode.refresh() }
            let wasOn = enabled && lidMode.isEnabled
            try await lidMode.setEnabled(enabled)
            if !wasOn {
                defaults.set(enabled, forKey: Keys.lidModeSetByAwake)
            }
            return nil
        } catch LidModeError.setUpCancelled {
            return Self.setUpCancelled
        } catch {
            return error.localizedDescription
        }
    }

    /// Errors go to a notification and a panel alert, not a modal alert: a modal would stall the main actor (tick,
    /// guard, control socket). Cancelling the password prompt isn't an error.
    func setLidModeFromMenu(_ enabled: Bool) async {
        guard let problem = await lidModeProblem(enabled) else {
            lastFailure = nil
            return
        }
        guard problem != Self.setUpCancelled else { return }
        let title = enabled ? "Couldn't turn on lid-closed mode" : "Couldn't turn off lid-closed mode"
        lastFailure = "\(title). \(problem)"
        Notifier.post(title: title, body: problem)
    }

    func setUpLidMode() async {
        do {
            try await lidMode.setUp()
            lastFailure = nil
            shieldSoon()
        } catch LidModeError.setUpCancelled {
        } catch {
            lastFailure = "Couldn't set up Awake's permission. \(error.localizedDescription)"
            Notifier.post(title: "Couldn't set up Awake's permission", body: error.localizedDescription)
        }
    }

    // MARK: - Onboarding

    /// Opens the welcome window; the app delegate sets it.
    var openWelcome: () -> Void = {}

    /// The welcome window has been through once (finished or closed).
    var didOnboard: Bool { defaults.bool(forKey: Keys.onboarded) }

    /// Closing the welcome: macOS's notification prompt comes now, not on top of the welcome.
    func finishOnboarding() {
        let first = !didOnboard
        defaults.set(true, forKey: Keys.onboarded)
        if first, !isPreview {
            Notifier.askPermission()
        }
    }

    /// Adds Awake's MCP server to Claude Code. The app's path is quoted, so it works from a folder with a space.
    var mcpCommand: String {
        "claude mcp add --scope user awake -- \"\(appPath)/Contents/MacOS/awakectl\" mcp"
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { isPreview ? previewLaunchAtLogin : SMAppService.mainApp.status == .enabled }
        set {
            guard !isPreview else {
                previewLaunchAtLogin = newValue
                return objectWillChange.send()
            }
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

    /// Re-reads the hotspot password from the keychain off the main actor, for when someone is there to answer an
    /// "allow" prompt: at launch and when Settings opens. A failed read keeps the cached value.
    @discardableResult
    func loadHotspotPassword() async -> String? {
        guard !isPreview else { return savedHotspotPassword }
        let saves = passwordSaves, queue = keychainQueue
        let read = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: HotspotPasswordStore.read()) }
        }
        if let read, saves == passwordSaves, read != savedHotspotPassword {
            savedHotspotPassword = read
        }
        return savedHotspotPassword
    }

    /// Caches the password and saves it to the keychain off the main actor (saves stay in order).
    func setHotspotPassword(_ password: String) {
        guard password != savedHotspotPassword, !isPreview else { return }
        savedHotspotPassword = password
        passwordSaves += 1
        keychainQueue.async { HotspotPasswordStore.save(password) }
    }

    /// Called when Settings opens: the user is there to answer a keychain prompt.
    func settingsWillOpen() {
        Task { await loadHotspotPassword() }
        refreshShortcuts()
    }

    private func refreshShortcuts() {
        guard !isPreview else { return }
        let shortcuts = self.shortcuts
        Task {
            let names = await Task.detached { shortcuts.list() }.value
            if names != installedShortcuts { installedShortcuts = names }
        }
    }

    func refreshNearbyNetworks() {
        guard !isPreview else { return }
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
        guard !isPreview else { return }
        Task { await checkNetwork() }
    }

    private func checkNetwork() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let wifiControl = self.wifiControl
        let state = await Task.detached { wifiControl.state() }.value
        let result = await probe.check()
        if wifi != state {
            wifi = state
        } else {
            updateProfile()  // unchanged Wi-Fi still lets a held profile lapse
        }
        if connectivity != result { connectivity = result }
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
        // Failover uses the cache only (see `savedHotspotPassword`); a join someone asked for may read the keychain,
        // off the main actor, if the launch read didn't get it.
        let cached = automatic ? savedHotspotPassword ?? "" : savedHotspotPassword
        let password: String
        if let cached {
            password = cached
        } else {
            password = await loadHotspotPassword() ?? ""
        }
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
        let success = await joinKnownNetwork(home)
        engine.returnAttempted(success: success, now: .now)
        if success {
            Notifier.post(title: "Back on \(home)", body: "Awake left the hotspot to save your phone's data.")
        }
        wifi = await Task.detached { wifiControl.state() }.value
    }

    /// Joins a network macOS knows. Joining needs its saved password, which only macOS holds: when a plain join can't,
    /// it steps off the current network and waits up to 10 s for macOS to auto-join its preferred one, but only for a
    /// network macOS has saved; otherwise it would just drop the current one.
    private func joinKnownNetwork(_ ssid: String) async -> Bool {
        let wifiControl = self.wifiControl
        return await Task.detached { () -> Bool in
            do {
                try wifiControl.join(ssid: ssid, password: nil)
                return true
            } catch WiFiError.notFound {
                return false
            } catch {
                guard wifiControl.isSaved(ssid) else { return false }
                wifiControl.disconnect()
                for _ in 0..<10 {
                    try? await Task.sleep(for: .seconds(1))
                    if wifiControl.state().ssid == ssid { return true }
                }
                return false
            }
        }.value
    }

    // MARK: - Trusted Wi-Fi nearby

    /// Ends the offer's episode once there's nothing to switch from or to; every network check.
    private func updateTrustedOffer() {
        trustedReturn.observe(current: wifi.ssid, wifiOn: wifi.isPoweredOn, trusted: trustedNetworks, hotspot: hotspotSSID)
        showTrustedOffer()
    }

    private func showTrustedOffer() {
        let shown = offerTrustedNetworks ? trustedReturn.offer : nil
        if trustedOffer != shown { trustedOffer = shown }
    }

    /// Looks for a trusted network in range when one is worth offering (`TrustedReturn` paces the scans), off the
    /// main actor. Needs Location access: without it macOS hides the names.
    private func scanForTrustedIfDue() {
        guard !isPreview, offerTrustedNetworks, location.isAuthorized, !isScanningForTrusted,
              trustedReturn.shouldScan(current: wifi.ssid, wifiOn: wifi.isPoweredOn, trusted: trustedNetworks,
                                       hotspot: hotspotSSID, now: .now) else { return }
        isScanningForTrusted = true
        let wifiControl = self.wifiControl
        Task {
            let nearby = await Task.detached { wifiControl.nearbyNetworkNames() }.value
            isScanningForTrusted = false
            if nearbyNetworks != nearby { nearbyNetworks = nearby }
            let ask = trustedReturn.scanned(nearby: nearby, current: wifi.ssid, trusted: trustedNetworks,
                                            hotspot: hotspotSSID, now: .now)
            showTrustedOffer()
            guard let ssid = ask, offerTrustedNetworks else { return }
            Notifier.post(title: "\(ssid) is in range", body: trustedOfferQuestion, category: .trustedNearby,
                          userInfo: ["ssid": ssid])
        }
    }

    /// What switching would leave: the hotspot, public Wi-Fi, or nothing.
    private var trustedOfferQuestion: String {
        if isOnHotspot { return "Switch from your hotspot to save its data?" }
        return wifi.ssid == nil ? "Join it?" : "Switch from this public Wi-Fi?"
    }

    /// From the panel or the notification's Switch button. Only while that offer stands: a notification can be tapped
    /// hours later, after macOS joined the network itself or somewhere it isn't in range.
    func switchToTrusted(_ ssid: String) async {
        guard trustedOffer == ssid, trustedNetworks.contains(ssid), wifi.ssid != ssid else { return }
        let joined = await joinKnownNetwork(ssid)
        let wifiControl = self.wifiControl
        wifi = await Task.detached { wifiControl.state() }.value
        if joined {
            lastFailure = nil
        } else {
            lastFailure = "Couldn't switch to \(ssid). Join it once from the Wi-Fi menu in the menu bar, so macOS saves it."
        }
        checkSoon()
    }

    // MARK: - Housekeeping: desk, awake watch, guard, end conditions

    private func tick() {
        tickCount += 1
        updateDesk()
        refreshPower()
        refreshHealth(disk: tickCount % 6 == 0)
        guard tickCount % 6 == 0 else { return }
        refreshAwakeWatch()
        if Date.now.timeIntervalSince(lastReachCheck) >= Self.reachInterval {
            refreshReach(sharing: false)
        }
        if shield.isUp {
            refreshFirewall()
        }
        scanForTrustedIfDue()
        if shield.step(wanted: shieldWanted) != .none {
            shieldSoon()  // retries a raise or lower that didn't finish
        }
        checkEndConditions()
        Task {
            await lidMode.refresh()  // pmset, off the main actor
            await runGuard()
        }
    }

    private func updateDesk() {
        let state = DeskState.current()
        if atDesk != state.atDesk { atDesk = state.atDesk }
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
        guard !isPreview else { return }
        let holders = AwakeWatch.holders()
        let isClaude: (AwakeHolder) -> Bool = { holder in
            holder.processName == "caffeinate"
                && AwakeWatch.processParent(holder.pid).flatMap(AwakeWatch.processName) == "claude"
        }
        let working = holders.filter(isClaude).count
        let others = AwakeWatch.appNames(for: holders.filter { !isClaude($0) })
        if claudeWorking != working { claudeWorking = working }
        if otherAwakeApps != others { otherAwakeApps = others }
    }

    /// A move or keep-awake that Claude started (through the control socket) counts as Claude having worked, even
    /// if its own keep-awake was never seen.
    private func claudeHasWorked() {
        claudeWasWorking = true
        claudeIdleSince = nil
    }

    private func checkEndConditions() {
        let claudeFinished = updateClaudeIdle()
        if onTheMove {
            let started = defaults.object(forKey: Keys.moveStartedAt) as? Date ?? .now
            let timeUp = moveEnd == .afterFourHours && Date.now.timeIntervalSince(started) >= Self.moveTimeLimit
            if timeUp || (moveEnd == .whenClaudeFinishes && claudeFinished) {
                Task {
                    let ended = await modeStep { () -> Bool in
                        guard self.onTheMove else { return false }
                        _ = await self.setOnTheMove(false)
                        return true
                    }
                    guard ended else { return }
                    Notifier.post(title: timeUp ? "On the Move ended after 4 hours" : "Claude finished",
                                  body: "On the Move is off, so your Mac can sleep.")
                    sleepIfLidClosed()
                }
            }
        } else if let session = overnight, session.isOver(now: .now, claudeFinished: claudeFinished) {
            Task {
                // Queued with the other mode changes; one that ran first may have ended or replaced the session.
                let (ended, problem) = await modeStep { () -> (Bool, String?) in
                    guard self.overnight == session else { return (false, nil) }
                    return (true, await self.endOvernight())
                }
                guard ended else { return }
                Notifier.post(title: session.end == .morning ? "Good morning" : "Claude finished",
                              body: problem ?? "Overnight is off, so your Mac can sleep.")
                sleepIfLidClosed()
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

    /// One run at a time; a stop happens once per episode (`GuardEpisode`), so lid-closed mode that won't turn off
    /// doesn't bring another notification and sleep-now every 30 s and on every thermal change.
    private func runGuard() async {
        guard !isGuarding else { return }
        isGuarding = true
        defer { isGuarding = false }
        let lowPower = self.lowPower
        lowPowerOnBattery = await Task.detached { lowPower.isOnForBattery() }.value
        let input = GuardInput(thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
                               lidClosed: PowerSource.isLidClosed(), externalDisplay: DeskState.current().externalDisplay,
                               onBattery: PowerSource.isOnBattery(), chargerTooWeak: power.chargerTooWeak,
                               batteryPercent: PowerSource.batteryLevel(), keepingAwake: keepAwake.isActive,
                               lidModeOn: lidMode.isEnabled, lowPowerOn: lowPowerOnBattery ?? true,
                               enabled: safetyEnabled, overnight: overnight != nil && !onTheMove)
        switch guardEpisode.filter(HotBagGuard.decide(input)) {
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
            overnight = nil
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

    /// Sleeps the Mac if its lid is closed, but not in clamshell mode at a desk (an external display on).
    private func sleepIfLidClosed() {
        guard HotBagGuard.shouldSleepNow(lidClosed: PowerSource.isLidClosed(),
                                         externalDisplay: DeskState.current().externalDisplay) else { return }
        Task.detached { SystemSleep.sleepNow() }
    }

    // MARK: - Preview

    /// The sample `--render-preview` draws, in a model of its own (never `shared`) that reads and changes nothing.
    static func preview(_ sample: PreviewSample = PreviewSample()) -> AppModel {
        let defaults = MemoryDefaults()
        defaults.set(LidModeController.ruleVersion, forKey: LidModeController.ruleVersionKey)
        let model = AppModel(defaults: defaults, preview: sample)
        model.showPreview(sample)
        return model
    }

    private func showPreview(_ sample: PreviewSample) {
        launchAtLogin = true
        hotspotSSID = sample.hotspot
        autoHotspot = !sample.hotspot.isEmpty
        trustedNetworks = sample.trustedNetworks
        publicShortcut = sample.publicShortcut
        wifi = WiFiState(isPoweredOn: true, ssid: sample.wifiName)
        connectivity = sample.connectivity
        if sample.shielded {
            shield.willRaise(from: FirewallState(enabled: false, stealth: false))
            shield.didApply(observed: FirewallShield.shielded)
            firewallNow = FirewallShield.shielded
        }
        sharingOn = sample.sharingOn
        tailscale = sample.tailscale
        reachChecked = true
        claudeWorking = sample.claudeSessions
        otherAwakeApps = sample.otherAwakeApps
        nearbyNetworks = sample.nearbyNetworks
        installedShortcuts = sample.installedShortcuts
        lastFailure = sample.lastFailure
        keepAwakeOption = sample.keepAwake
        overnight = sample.overnight
        healthWarnings = sample.healthWarnings
        busyProcess = sample.busyProcess
        trustedOffer = sample.trustedOffer
    }
}
