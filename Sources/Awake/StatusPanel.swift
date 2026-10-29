import AppKit
import AwakeCore
import Combine
import SwiftUI

/// The menu bar item and its panel. A custom panel (not an NSMenu) so the Dimension style can apply.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = FloatingPanel()
    private let hosting: NSHostingController<PanelView>
    private let model: AppModel
    private var outsideClickMonitor: Any?
    private var changes: AnyCancellable?
    // The menu bar glyph: the pose on screen, the animation in flight, the timer driving it, the frame shown.
    private var glyphPose = GlyphPose.asleep
    private var glyphAnimation: GlyphAnimation?
    private var glyphTimer: Timer?
    private var glyphFrame: GlyphFrame?
    /// The state the menu bar button last told VoiceOver and its tooltip.
    private var statusShown: String?

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        hosting = NSHostingController(rootView: PanelView(model: model, openSettings: openSettings))
        super.init()
        hosting.rootView = PanelView(model: model) { [weak self] in
            self?.close()
            openSettings()
        }

        panel.contentViewController = hosting
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        statusItem.autosaveName = "Awake"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.setAccessibilityLabel("Awake")
        }
        glyphPose = GlyphAnimation(from: .asleep, open: eyesOpen, accent: accent, start: 0, reduceMotion: true).target
        showGlyph(glyphPose)
        describeStatus()
        changes = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcon()
                if self?.panel.isVisible == true {
                    self?.layout()
                }
            }
    }

    @objc private func toggle() {
        panel.isVisible ? close() : show()
    }

    /// Opens the panel, or brings it forward if it's already open (a notification tap): never a second click monitor.
    func show() {
        guard !panel.isVisible else {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        model.panelWillOpen()
        layout()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
    }

    func close() {
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Sizes the panel to its content and hangs it under the menu bar icon, keeping it on screen: content taller than
    /// the room below the menu bar scrolls inside the panel.
    private func layout() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
        let maxHeight = visible.map { max(240, anchor.minY - 6 - $0.minY - 8) }
        if hosting.rootView.maxHeight != maxHeight {
            var root = hosting.rootView
            root.maxHeight = maxHeight
            hosting.rootView = root
        }
        let size = hosting.view.fittingSize
        var x = anchor.midX - size.width / 2
        if let visible {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
    }

    /// Open while anything keeps the Mac awake (On the Move included), closed otherwise.
    private var eyesOpen: Bool {
        model.onTheMove || model.isKeepingAwake
    }

    /// The mode's detail on the open eyes: a moon for Overnight, speed lines for On the Move, none for Keep awake.
    private var accent: GlyphAccent {
        switch model.mode {
        case .overnight: .moon
        case .onTheMove: .speedLines
        case .off, .keepAwake: .none
        }
    }

    /// Tells VoiceOver (the button's value) and the tooltip what Awake is doing, whenever that changes.
    private func describeStatus() {
        let status = model.menuBarStatus
        guard status != statusShown, let button = statusItem.button else { return }
        statusShown = status
        button.setAccessibilityValue(status)
        button.toolTip = status == "Off" ? "Awake is off" : "Awake: \(status)"
    }

    /// Animates the glyph toward the current state, continuing from wherever it is; Reduce Motion jumps. Each
    /// change plays once (the eyes, then the mode's detail) and then holds still.
    private func updateIcon() {
        describeStatus()
        let now = ProcessInfo.processInfo.systemUptime
        let current = glyphAnimation?.pose(at: now) ?? glyphPose
        let animation = GlyphAnimation(from: current, open: eyesOpen, accent: accent, start: now,
                                       reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard animation.target != (glyphAnimation?.target ?? glyphPose) else { return }
        glyphPose = current
        glyphAnimation = animation
        stepGlyph()
        if glyphAnimation != nil, glyphTimer == nil {
            let timer = Timer(timeInterval: EyeTransition.frameInterval, target: self, selector: #selector(stepGlyph),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            glyphTimer = timer
        }
    }

    @objc private func stepGlyph() {
        guard let animation = glyphAnimation else { return stopGlyph() }
        let now = ProcessInfo.processInfo.systemUptime
        glyphPose = animation.pose(at: now)
        showGlyph(glyphPose)
        if animation.isFinished(at: now) {
            stopGlyph()
        }
    }

    private func stopGlyph() {
        glyphAnimation = nil
        glyphTimer?.invalidate()
        glyphTimer = nil
    }

    /// Sets the cached frame for this pose, only when it differs from the one shown.
    private func showGlyph(_ pose: GlyphPose) {
        let frame = pose.frame
        guard frame != glyphFrame else { return }
        glyphFrame = frame
        statusItem.button?.image = MenuBarIcon.image(frame)
    }
}

/// Borderless, transparent panel that can take keyboard focus without activating the app.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The welcome window: on first launch and from Settings. Closing it counts as done, like Start Using Awake.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let view = OnboardingView(model: model) { [weak self] in self?.window?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Awake"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.finishOnboarding()
        // A fresh window next time starts on the first step.
        window = nil
    }
}

/// The Settings window, styled like the panel.
@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        model.settingsWillOpen()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Awake Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
