import AppKit
import CoreText
import SwiftUI

/// Awake's design tokens, adapted from the Dimension style on Refero: a void-black canvas,
/// graphite surfaces, 1px hairlines, white as the only "on" color, DM Sans for UI text and Geist for titles.
enum Theme {
    static let void = Color(hex: 0x0a0a0a)
    static let graphite = Color(hex: 0x161616)
    static let gunmetal = Color(hex: 0x282828)
    /// Off-state switch tracks, at least 3:1 against their surface so the track is always visible: `trackOff` on
    /// the panel's graphite (3.3:1) and a Settings card (3.1:1), `trackOffOnLight` on the white card (3.4:1).
    static let trackOff = Color(hex: 0x68686c)
    static let trackOffOnLight = Color(hex: 0x8a8a92)
    static let bone = Color(hex: 0xededed)
    static let ash = Color(hex: 0xc2c2c2)
    static let smoke = Color(hex: 0xb2b2b2)
    static let slate = Color(hex: 0x8a8a8a)
    static let white = Color.white
    static let hairline = Color(hex: 0xe5e5e5).opacity(0.14)
    static let glass = Color(hex: 0xd4d4d4).opacity(0.08)
    static let violet = Color(hex: 0x6b62f2)
    // Status colors are semantic, not brand accents.
    static let online = Color(hex: 0x5fd39a)
    static let attention = Color(hex: 0xf2b45f)
    static let offline = Color(hex: 0xf26b6b)

    static let panelRadius: CGFloat = 24
    static let panelPadding: CGFloat = 12
    /// Corner radius for anything inset by `panelPadding`, so corners stay concentric with the panel.
    static var innerRadius: CGFloat { panelRadius - panelPadding }
    /// Settings cards. They sit on the window, not inset in the panel, so they aren't tied to `innerRadius`.
    static let cardRadius: CGFloat = 18
    static let fieldRadius: CGFloat = 10

    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .custom("DM Sans", size: size).weight(weight)
    }

    /// Geist, for titles of 24 pt and up only (Dimension: DM Sans carries everything smaller).
    static func title(_ size: CGFloat = 24, weight: Font.Weight = .medium) -> Font {
        .custom("Geist", size: size).weight(weight)
    }

    /// Registers the bundled DM Sans and Geist for this process.
    static func registerFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") else { return }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

/// A switch with a visible track: white when on (graphite knob), dark gray when off.
/// `onLight` inverts it for use on the white On the Move card.
struct AwakeSwitchStyle: ToggleStyle {
    var onLight = false

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        let track = on ? (onLight ? Theme.graphite : Theme.white) : (onLight ? Theme.trackOffOnLight : Theme.trackOff)
        let knob = on ? (onLight ? Theme.white : Theme.graphite) : (onLight ? Theme.white : Theme.ash)
        // A Button, so it takes keyboard focus (Space toggles) like a native switch.
        return Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(track)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(on || onLight ? 0 : 0.18)))
                    Circle().fill(knob).frame(width: 16, height: 16).padding(3)
                }
                .frame(width: 38, height: 22)
                .animation(.easeOut(duration: 0.15), value: on)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// Pill chip used for single-choice rows like Keep awake. The selected one is white = on (graphite text).
/// `spokenTitle` is what VoiceOver reads when the title is abbreviated ("4 hr" → "4 hours").
struct Chip: View {
    let title: String
    var spokenTitle: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(12, weight: .medium))
                .foregroundStyle(selected ? Theme.graphite : Theme.smoke)
                .padding(.vertical, 5)
                .padding(.horizontal, 11)
                .background(Capsule().fill(selected ? Theme.white : Color.clear))
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenTitle ?? title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Transparent text button with a hairline, for secondary actions.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(12, weight: .medium))
            .foregroundStyle(Theme.ash)
            .padding(.vertical, 5)
            .padding(.horizontal, 11)
            .background(Capsule().fill(configuration.isPressed ? Theme.gunmetal : Color.clear))
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .contentShape(Capsule())
    }
}

/// White filled pill: the one primary action in a view.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(12, weight: .medium))
            .foregroundStyle(Theme.graphite)
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Theme.white.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

/// Lays children out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(width: bounds.width, subviews: subviews).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + rowHeight))
    }
}

private struct FrostedGlassKey: EnvironmentKey {
    static let defaultValue = true
}

private struct LiveControlsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Off when rendering previews off-screen, where the live blur can't draw.
    var frostedGlass: Bool {
        get { self[FrostedGlassKey.self] }
        set { self[FrostedGlassKey.self] = newValue }
    }

    /// Off when rendering previews off-screen, where AppKit-backed controls (text fields, menus) can't draw: they
    /// show as static stand-ins instead.
    var liveControls: Bool {
        get { self[LiveControlsKey.self] }
        set { self[LiveControlsKey.self] = newValue }
    }
}

/// Behind-window blur for the panel's frosted glass.
struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
