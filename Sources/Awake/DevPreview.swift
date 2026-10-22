import AppKit
import SwiftUI

/// `Awake --render-preview <dir>` writes the panel and Settings as PNGs and exits, without
/// starting the app or touching any setting. For reviewing the design.
enum DevPreview {
    @MainActor
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--render-preview"), arguments.indices.contains(flag + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[flag + 1])
        _ = NSApplication.shared
        Theme.registerFonts()
        let model = AppModel.shared
        save(PanelView(model: model, openSettings: {}).environment(\.frostedGlass, false)
                .padding(28).background(Color(hex: 0x33405e)), to: directory, name: "panel.png")
        save(SettingsContent(model: model).frame(width: 520).background(Theme.void), to: directory, name: "settings.png")
        exit(0)
    }

    @MainActor
    private static func save<V: View>(_ view: V, to directory: URL, name: String) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent(name))
    }
}
