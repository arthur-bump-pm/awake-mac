import AwakeCore
import SwiftUI

/// The welcome window's steps, in order.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, permissions, wifi, finish

    var id: Self { self }
}

/// First launch (and Settings → Setup → Show Welcome): what Awake does, the two permissions, your networks and Claude
/// Code. Every step can be skipped; all of it is in Settings later.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    /// The step it opens on. Only the first value counts (it's state): for previews.
    @State var step: OnboardingStep = .welcome
    var finish: () -> Void = {}
    @Environment(\.liveControls) private var liveControls
    @State private var password = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .wifi: wifi
                case .finish: finishStep
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: 560, height: 620)
        .background(Theme.void)
        .toggleStyle(AwakeSwitchStyle())
        .foregroundStyle(Theme.bone)
        .environment(\.colorScheme, .dark)
        .onAppear { password = model.savedHotspotPassword ?? "" }
        .onChange(of: password) { model.setHotspotPassword(password) }
        .onChange(of: model.savedHotspotPassword) {
            if let saved = model.savedHotspotPassword, saved != password { password = saved }
        }
    }

    // MARK: - Steps

    @ViewBuilder private var welcome: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
        heading("Welcome to Awake",
                "Keeps your Mac running and online while you work away from your desk. Click the eyes in the menu bar to pick a mode.")
        VStack(alignment: .leading, spacing: 0) {
            ModeIntro(frame: GlyphPose.asleep.frame, title: "Off", detail: "Your Mac sleeps as usual.")
            ModeIntro(frame: GlyphPose(openness: 1, accent: .none, amount: 0).frame, title: "Keep awake",
                      detail: "Stays awake with the lid open: for an hour, four, always, or while your coding agents work.")
            ModeIntro(frame: GlyphPose(openness: 1, accent: .moon, amount: 1).frame, title: "Overnight",
                      detail: "Keeps running with the lid closed until morning, for long jobs.")
            ModeIntro(frame: GlyphPose(openness: 1, accent: .speedLines, amount: 1).frame, title: "On the Move",
                      detail: "Lid closed, your iPhone hotspot if the internet drops, Low Power Mode. All back when you return.")
        }
        .padding(.top, -1)
        .background(Theme.glass)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
    }

    @ViewBuilder private var permissions: some View {
        heading("Two permissions",
                "Both are optional, and both are in Settings → Setup later. macOS asks about notifications when you finish.")
        VStack(alignment: .leading, spacing: 18) {
            PermissionRow(title: "Admin permission",
                          detail: "For Overnight and On the Move. macOS asks for your password once. Awake can then switch lid-closed mode, Low Power Mode, sleep and the firewall, and nothing else.",
                          granted: model.lidMode.isSetUp, grantedText: "Ready", action: "Set Up…") {
                Task { await model.setUpLidMode() }
            }
            PermissionRow(title: "Location access",
                          detail: "macOS hides Wi-Fi names without it: the public Wi-Fi shield, auto-hotspot and trusted networks need them. Awake never reads your location.",
                          granted: model.location.isAuthorized, grantedText: "Allowed",
                          action: model.location.isDenied ? "Open Settings…" : "Allow…") {
                model.location.request()
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
    }

    @ViewBuilder private var wifi: some View {
        heading("Your networks",
                "Trusted Wi-Fi skips the public Wi-Fi shield, and Awake offers to switch back to it when you're in range again. Your hotspot takes over when the internet drops.")
        ListSection(title: "This network") {
            if !model.location.isAuthorized {
                ListRow(icon: "wifi.exclamationmark", title: "Allow Location access to see its name", dimmed: true) {
                    Button("Back") { step = .permissions }
                        .buttonStyle(GhostButtonStyle())
                }
            } else if let ssid = model.wifi.ssid {
                ListRow(icon: "wifi", title: ssid) {
                    if model.profile == .home {
                        StatusBadge(text: "Trusted", color: Theme.online)
                    } else {
                        Button("Trust") { model.trustCurrentNetwork() }
                            .buttonStyle(PillButtonStyle())
                            .accessibilityLabel("Trust \(ssid)")
                    }
                }
            } else {
                ListRow(icon: "wifi.slash", title: "Not on Wi-Fi", dimmed: true) {}
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Your iPhone hotspot")
                .font(Theme.body(12, weight: .medium))
                .foregroundStyle(Theme.slate)
            LabeledRow(label: "Hotspot") {
                Field(title: "Hotspot name", text: $model.hotspotSSID, prompt: "iPhone name")
                nearbyMenu
            }
            LabeledRow(label: "Password") {
                if liveControls {
                    SecureField("Hotspot password", text: $password,
                                prompt: Text("Optional").foregroundStyle(Theme.slate))
                        .labelsHidden()
                        .modifier(FieldStyle())
                } else {
                    FieldStandIn(text: "", prompt: "Optional")
                }
                Image(systemName: "chevron.up.chevron.down").hidden()  // lines up with the field above, which has a menu
            }
            SettingToggle(title: "Switch to it when the internet drops",
                          detail: "On your iPhone, keep Personal Hotspot → Allow Others to Join on.", isOn: $model.autoHotspot)
        }
    }

    @ViewBuilder private var finishStep: some View {
        heading("You're set",
                "Two last things, and you can change both in Settings.")
        VStack(alignment: .leading, spacing: 18) {
            SettingToggle(title: "Launch at login", detail: "Starts Awake when you log in.",
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect Claude Code")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.bone)
                Text("Run this once in Terminal. Then tell Claude \"I got to move\" or \"going to bed, keep it running\".")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.mcpCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.ash)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).fill(Theme.graphite))
                    .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).strokeBorder(Theme.hairline))
                Button(copied ? "Copied" : "Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.mcpCommand, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
    }

    // MARK: - Parts

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.title(28, weight: .semibold))
                .foregroundStyle(Theme.bone)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(Theme.body(14))
                .foregroundStyle(Theme.ash)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var nearbyMenu: some View {
        let chevron = Image(systemName: "chevron.up.chevron.down").foregroundStyle(Theme.ash)
        if liveControls {
            Menu {
                if !model.location.isAuthorized {
                    Button("Allow Location access to list networks") { model.location.request() }
                } else if model.nearbyNetworks.isEmpty {
                    Text("No networks found")
                }
                ForEach(model.nearbyNetworks, id: \.self) { name in
                    Button(name) { model.hotspotSSID = name }
                }
            } label: {
                chevron
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a nearby network")
            .accessibilityLabel("Choose a nearby network")
            .onAppear { model.refreshNearbyNetworks() }
        } else {
            chevron
        }
    }

    /// Step dots, Back, and Continue (Start Using Awake on the last step).
    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases) { item in
                    Capsule()
                        .fill(item == step ? Theme.white : Theme.gunmetal)
                        .frame(width: item == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
            Spacer()
            if let previous = OnboardingStep(rawValue: step.rawValue - 1) {
                Button("Back") { step = previous }
                    .buttonStyle(GhostButtonStyle())
            }
            if let next = OnboardingStep(rawValue: step.rawValue + 1) {
                Button("Continue") { step = next }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Start Using Awake", action: finish)
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 18)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// One mode on the welcome step: its menu bar glyph, name and what it does.
private struct ModeIntro: View {
    let frame: GlyphFrame
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: MenuBarIcon.image(frame, size: 26))
                .renderingMode(.template)
                .foregroundStyle(Theme.bone)
                .frame(width: 30, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.bone)
                Text(detail)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .modifier(RowDivider())
        .accessibilityElement(children: .combine)
    }
}
