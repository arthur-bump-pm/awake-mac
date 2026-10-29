import AppKit
import AwakeCore
import CoreLocation
import UserNotifications

@main
@MainActor
enum AwakeMain {
    static func main() {
        DevPreview.runIfRequested()
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var panel: StatusPanelController?
    private var settings: SettingsWindowController?
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        NSApp.mainMenu = Self.mainMenu()
        UNUserNotificationCenter.current().delegate = self
        let model = AppModel.shared
        let settings = SettingsWindowController(model: model)
        self.settings = settings
        panel = StatusPanelController(model: model) { settings.show() }
        let onboarding = OnboardingWindowController(model: model)
        self.onboarding = onboarding
        model.openWelcome = { onboarding.show() }
        model.start()
        if !model.didOnboard {
            onboarding.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    /// Never shown (Awake has no menu bar of its own), but it routes ⌘C/⌘V/⌘A, ⌘W and ⌘Q in Settings.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        submenu("Awake", [NSMenuItem(title: "Quit Awake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"), redo,
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        submenu("Window", [NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        return main
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            let model = AppModel.shared
            switch Notifier.Action(rawValue: action) {
            case .signIn:
                NSWorkspace.shared.open(model.portalURL ?? URL(string: "http://captive.apple.com")!)
            case .turnOnMove:
                await model.setModeFromMenu(.onTheMove)
            case .backAtDesk:
                await model.endMoveFromMenu()
            case .switchWiFi:
                if let ssid = response.notification.request.content.userInfo["ssid"] as? String {
                    await model.switchToTrusted(ssid)
                }
            case nil:
                panel?.show()
            }
            completionHandler()
        }
    }
}

/// The menu bar eyes, one template image per openness step (`EyeTransition.steps` + 1 frames), each drawn
/// on first use and reused for every later animation.
enum MenuBarIcon {
    private static var cache: [GlyphFrame: NSImage] = [:]

    /// The 18 pt menu bar image for a frame, drawn once and cached.
    static func image(_ frame: GlyphFrame) -> NSImage {
        if let image = cache[frame] { return image }
        let image = image(frame, size: 18)
        image.accessibilityDescription = "Awake"
        cache[frame] = image
        return image
    }

    /// The glyph drawn at `size` points (not scaled up from 18), as a template image: for onboarding and previews.
    static func image(_ frame: GlyphFrame, size: CGFloat) -> NSImage {
        let detail: AwakeMark.Detail = switch frame.accent {
        case .none: .none
        case .moon: .moon
        case .speedLines: .speedLines
        }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(.black)
            ctx.setStrokeColor(.black)
            AwakeMark.drawGlyph(in: ctx, rect: rect, openness: CGFloat(frame.openness), detail: detail,
                                amount: CGFloat(frame.amount))
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum Notifier {
    enum Category: String {
        case signIn, leftDesk, backAtDesk, trustedNearby
    }

    enum Action: String {
        case signIn = "SIGN_IN"
        case turnOnMove = "TURN_ON_MOVE"
        case backAtDesk = "BACK_AT_DESK"
        case switchWiFi = "SWITCH_WIFI"
    }

    /// Registers the actions; `askPermission` false waits for the welcome to close (see `askPermission()`).
    static func setUp(askPermission: Bool = true) {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            category(.signIn, .signIn, "Sign In"),
            category(.leftDesk, .turnOnMove, "Turn On the Move"),
            category(.backAtDesk, .backAtDesk, "Turn Off On the Move"),
            category(.trustedNearby, .switchWiFi, "Switch"),
        ])
        if askPermission {
            Self.askPermission()
        }
    }

    static func askPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, category: Category? = nil, userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        if let category {
            content.categoryIdentifier = category.rawValue
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func category(_ category: Category, _ action: Action, _ title: String) -> UNNotificationCategory {
        UNNotificationCategory(identifier: category.rawValue,
                               actions: [UNNotificationAction(identifier: action.rawValue, title: title, options: [.foreground])],
                               intentIdentifiers: [])
    }
}

/// macOS hides Wi-Fi network names from apps without Location access.
@MainActor
final class LocationAccess: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    /// Nil with a fixed status (`--render-preview`), which never asks macOS.
    private var manager: CLLocationManager?

    /// `fixed` pins the status without reading or asking for the real permission.
    init(fixed: CLAuthorizationStatus? = nil) {
        super.init()
        if let fixed {
            status = fixed
            return
        }
        let manager = CLLocationManager()
        manager.delegate = self
        self.manager = manager
        status = manager.authorizationStatus
    }

    var isAuthorized: Bool { status == .authorizedAlways }
    var isDenied: Bool { status == .denied || status == .restricted }

    func request() {
        guard let manager else { return }
        if isDenied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}
