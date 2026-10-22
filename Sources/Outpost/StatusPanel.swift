import AppKit
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

        statusItem.autosaveName = "Outpost"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.setAccessibilityLabel("Outpost")
        }
        updateIcon()
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

    func show() {
        model.panelWillOpen()
        layout()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
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

    /// Sizes the panel to its content and hangs it under the menu bar icon, keeping it on screen.
    private func layout() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let size = hosting.view.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = anchor.midX - size.width / 2
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
    }

    private func updateIcon() {
        let state: OutpostMark.GlyphState = model.onTheMove ? .moving : model.isKeepingAwake ? .awake : .asleep
        statusItem.button?.image = MenuBarIcon.image(for: state)
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

/// The Settings window, styled like the panel.
@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Outpost Settings"
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
