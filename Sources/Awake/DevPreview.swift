import AppKit
import AwakeCore
import IOKit.pwr_mgt
import SwiftUI

/// `Awake --render-preview <folder>` writes the panel (two samples) and each Settings tab as PNGs and exits. It draws a made-up sample
/// (`PreviewSample`) in a model of its own: it never reads or changes the user's settings, never runs a command and
/// never starts the app. For reviewing the design, edge cases included.
enum DevPreview {
    @MainActor
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--render-preview") else { return }
        guard arguments.indices.contains(flag + 1) else { fail("usage: Awake --render-preview <folder>") }
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail("Awake: can't create \(directory.path): \(error.localizedDescription)")
        }
        _ = NSApplication.shared
        Theme.registerFonts()
        let model = AppModel.preview()
        let calm = AppModel.preview(.calm)
        do {
            try save(panel(model), to: directory, name: "panel.png")
            try save(panel(calm), to: directory, name: "panel-calm.png")
            for tab in SettingsTab.allCases {
                try save(SettingsContent(model: model, tab: tab, scrolls: false).environment(\.liveControls, false)
                            .frame(width: 520).background(Theme.void), to: directory, name: "settings-\(tab.title.lowercased()).png")
            }
            try save(GlyphSheet(), to: directory, name: "glyphs.png")
            let firstLaunch = AppModel.preview(.firstLaunch)
            for step in OnboardingStep.allCases {
                try save(OnboardingView(model: firstLaunch, step: step).environment(\.liveControls, false), to: directory,
                         name: "welcome-\(step.rawValue + 1).png")
            }
            // The calm sample has no admin permission yet: the Setup tab's dot and its Set Up button.
            try save(SettingsContent(model: calm, tab: .setup, scrolls: false).environment(\.liveControls, false)
                        .frame(width: 520).background(Theme.void), to: directory, name: "settings-setup-needed.png")
        } catch {
            fail("Awake: can't write the preview to \(directory.path): \(error.localizedDescription)")
        }
        print("Wrote panel.png, panel-calm.png, glyphs.png, welcome-<n>.png and settings-<tab>.png to \(directory.path)")
        exit(0)
    }

    private static func panel(_ model: AppModel) -> some View {
        PanelView(model: model, openSettings: {}).environment(\.frostedGlass, false)
            .padding(28).background(Color(hex: 0x33405e))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    private struct RenderFailed: LocalizedError {
        var errorDescription: String? { "the view didn't render" }
    }

    @MainActor
    private static func save<V: View>(_ view: V, to directory: URL, name: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw RenderFailed()
        }
        try png.write(to: directory.appendingPathComponent(name))
    }
}

/// The made-up state the preview draws. The default shows edge cases: the longest Wi-Fi name (32 characters) on a
/// sign-in page, five alerts at once (a weak charger and a nearly full disk among them) and Overnight on. `calm` is
/// an ordinary moment: home Wi-Fi, keep-awake on, nothing to warn about, the admin permission not set up yet. No real
/// names, paths or settings.
struct PreviewSample {
    static let appPath = "/Applications/Awake.app"
    static let userName = "alex"

    var wifiName = "Harbourside Coworking Guest WiFi"
    var connectivity = Connectivity.captivePortal(nil)
    var hotspot = "Travel Phone"
    var trustedNetworks = ["Home Network", "Studio 5G"]
    var publicShortcut = "Public Wi-Fi"
    var installedShortcuts = ["Focus: Work", "Public Wi-Fi", "Studio Lights Off"]
    var nearbyNetworks = ["Harbourside Coworking Guest WiFi", "Studio 5G", "Travel Phone"]
    /// On for Overnight.
    var lidClosedMode = true
    var adminPermission = true
    var locationAllowed = true
    var keepAwake = KeepAwakeOption.off
    var claudeSessions = 2
    var otherAwakeApps = ["Music"]
    var sharingOn: [SharingService] = [.screenSharing, .remoteLogin]
    var tailscale: TailscaleStatus? = TailscaleStatus(online: true, dnsName: "example-mac.example-tailnet.ts.net",
                                                      ips: ["100.64.0.10"])
    var lastFailure: String? = "Couldn't turn off lid-closed mode. sudo: a password is required"
    /// Plugged into a 30 W charger that can't keep up.
    var power = PowerReading(percent: 64, onBattery: false, externalConnected: true, isCharging: false, minutesLeft: nil,
                             drawWatts: 6, adapterWatts: 30)
    /// Ends at 9:00 tomorrow, wherever and whenever the preview runs.
    var overnight: OvernightSession? = OvernightSession(
        end: .morning, until: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now.addingTimeInterval(86_400)),
        started: .now)
    var healthWarnings: [HealthWarning] = [.diskAlmostFull(freeBytes: 7_400_000_000)]
    /// The firewall shield is up (public Wi-Fi).
    var shielded = true
    var busyProcess: String?
    /// A trusted network in range, offered from the public Wi-Fi.
    var trustedOffer: String? = "Studio 5G"

    static var calm: PreviewSample {
        var sample = PreviewSample()
        sample.wifiName = "Home Network"
        sample.connectivity = .online
        sample.lidClosedMode = false
        sample.overnight = nil
        sample.keepAwake = .whileClaudeWorks
        sample.claudeSessions = 1
        sample.otherAwakeApps = []
        sample.sharingOn = []
        sample.lastFailure = nil
        sample.healthWarnings = []
        sample.trustedOffer = nil
        sample.shielded = false
        sample.adminPermission = false
        sample.power = PowerReading(percent: 82, onBattery: true, externalConnected: false, isCharging: false,
                                    minutesLeft: 190, drawWatts: 7, adapterWatts: nil)
        return sample
    }

    /// A Mac that just installed Awake: no admin permission, nothing trusted, no hotspot chosen.
    static var firstLaunch: PreviewSample {
        var sample = PreviewSample.calm
        sample.trustedNetworks = []
        sample.hotspot = ""
        sample.keepAwake = .off
        sample.claudeSessions = 0
        sample.publicShortcut = ""
        return sample
    }
}

/// The menu bar glyph in each mode, as the app draws it, on light and dark menu bars at 1x and 4x.
private struct GlyphSheet: View {
    private let states: [(String, GlyphFrame)] = [
        ("Off", GlyphPose.asleep.frame),
        ("Keep awake", GlyphPose(openness: 1, accent: .none, amount: 0).frame),
        ("Overnight", GlyphPose(openness: 1, accent: .moon, amount: 1).frame),
        ("On the Move", GlyphPose(openness: 1, accent: .speedLines, amount: 1).frame),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 18) {
                    ForEach(states, id: \.0) { name, frame in
                        VStack(spacing: 8) {
                            glyph(frame, size: 18, dark: dark)
                            glyph(frame, size: 72, dark: dark)
                            Text(name)
                                .font(Theme.body(11))
                                .foregroundStyle(dark ? Theme.ash : Color(hex: 0x3a3a3c))
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(dark ? Color(hex: 0x2b2b2e) : Color(hex: 0xe9e9eb)))
            }
        }
        .padding(20)
        .background(Theme.void)
    }

    private func glyph(_ frame: GlyphFrame, size: CGFloat, dark: Bool) -> some View {
        Image(nsImage: MenuBarIcon.image(frame, size: size))
            .renderingMode(.template)
            .foregroundStyle(dark ? Color(hex: 0xf5f5f7) : Color(hex: 0x1d1d1f))
    }
}


/// UserDefaults kept in memory only. Every read and write is overridden, so nothing reaches the user's settings
/// (a suite's search list would otherwise fall through to the app's own domain).
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    init() {
        super.init(suiteName: "io.github.arthur-bump-pm.Awake.preview")!
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        registered.merge(registrationDictionary) { _, new in new }
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] ?? registered[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Float, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ url: URL?, forKey defaultName: String) { values[defaultName] = url }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }

    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func url(forKey defaultName: String) -> URL? { object(forKey: defaultName) as? URL }
    override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey defaultName: String) -> Double {
        (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0
    }
    override func float(forKey defaultName: String) -> Float { (object(forKey: defaultName) as? NSNumber)?.floatValue ?? 0 }
    override func dictionaryRepresentation() -> [String: Any] { registered.merging(values) { _, new in new } }
}

/// Answers `pmset -g` with the sample's lid-closed mode; runs nothing.
struct PreviewCommands: CommandRunning {
    var lidClosedMode: Bool

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        CommandResult(status: 0, output: " SleepDisabled\t\t\(lidClosedMode ? 1 : 0)\n")
    }
}

/// Keep-awake without a real power assertion.
struct PreviewAssertions: PowerAssertionManaging {
    func create(type: CFString, name: CFString, id: inout IOPMAssertionID) -> IOReturn {
        id = 1
        return kIOReturnSuccess
    }

    func release(id: IOPMAssertionID) {}
}
