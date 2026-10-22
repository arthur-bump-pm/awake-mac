import AwakeCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            SettingsContent(model: model)
        }
        .frame(width: 520, height: 680)
        .background(Theme.void)
        .environment(\.colorScheme, .dark)
    }
}

struct SettingsContent: View {
    @ObservedObject var model: AppModel
    @State private var password = ""
    @State private var copied = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var mcpCommand: String {
        "claude mcp add --scope user awake -- \(Bundle.main.bundlePath)/Contents/MacOS/awakectl mcp"
    }

    var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Awake")
                            .font(Theme.title(24, weight: .semibold))
                            .foregroundStyle(Theme.bone)
                        Text("Your laptop, always on. Wherever you work.")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.ash)
                    }
                }

                Card("General") {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    Toggle("Let the display sleep while keeping awake", isOn: $model.allowDisplaySleep)
                    Toggle("Turn everything off when the battery is low or the Mac is hot", isOn: $model.safetyEnabled)
                }

                Card("On the Move", footer: "Low Power Mode applies on battery. The shield turns on the macOS firewall with stealth mode for public Wi-Fi. Both go back to how they were when you're back.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ends")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.bone)
                        FlowLayout(spacing: 6) {
                            ForEach(MoveEnd.allCases) { option in
                                Chip(title: option.title, selected: model.moveEnd == option) { model.moveEnd = option }
                            }
                        }
                    }
                    Toggle("Turn on Low Power Mode", isOn: $model.moveLowPower)
                    Toggle("Shield me on public Wi-Fi", isOn: $model.moveShield)
                    Toggle("Suggest it when I leave my desk", isOn: $model.deskSuggestions)
                }

                Card("Permission", footer: "Lets Awake switch lid-closed mode, Low Power Mode, sleep and the firewall without asking each time. Nothing else.") {
                    HStack {
                        Text("Admin permission")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.bone)
                        Spacer()
                        if model.lidMode.isSetUp {
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .font(Theme.body(12, weight: .medium))
                                .foregroundStyle(Theme.ash)
                        } else {
                            Button("Set Up…") { Task { await model.setUpLidMode() } }
                                .buttonStyle(PillButtonStyle())
                        }
                    }
                }

                Card("Auto-hotspot", footer: "On your iPhone, keep Settings → Personal Hotspot → Allow Others to Join turned on.") {
                    Toggle("Switch to my hotspot when the internet drops", isOn: $model.autoHotspot)
                    HStack(spacing: 6) {
                        Field(title: "Hotspot", text: $model.hotspotSSID, prompt: "iPhone name")
                        Menu {
                            if model.nearbyNetworks.isEmpty {
                                Text("No networks found")
                            }
                            ForEach(model.nearbyNetworks, id: \.self) { name in
                                Button(name) { model.hotspotSSID = name }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(Theme.ash)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Choose a nearby network")
                        .accessibilityLabel("Choose a nearby network")
                    }
                    SecureField("Hotspot password", text: $password, prompt: Text("Hotspot password").foregroundStyle(Theme.slate))
                        .labelsHidden()
                        .modifier(FieldStyle())
                    Toggle("Go back to Wi-Fi when it returns", isOn: $model.returnToWiFi)
                    if !model.location.isAuthorized {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Location access")
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.bone)
                                Text("macOS requires it for apps to see Wi-Fi network names.")
                                    .font(Theme.body(11))
                                    .foregroundStyle(Theme.slate)
                            }
                            Spacer()
                            Button(model.location.isDenied ? "Open Settings…" : "Allow…") { model.location.request() }
                                .buttonStyle(PillButtonStyle())
                        }
                    }
                }

                Card("Claude Code", footer: "Then any new Claude session can switch On the Move when you say \"I got to move\", and off when you're back.") {
                    Text(mcpCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ash)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(copied ? "Copied" : "Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpCommand, forType: .string)
                        copied = true
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                Text("Awake \(version) · Built on Insomnia by Karan Sangha · Fonts: DM Sans, Geist (OFL)")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity)
            }
            .toggleStyle(AwakeSwitchStyle())
            .font(Theme.body(13))
            .foregroundStyle(Theme.bone)
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 24)
            .onAppear {
            password = model.hotspotPassword()
            model.refreshNearbyNetworks()
        }
        .onChange(of: password) {
            model.setHotspotPassword(password)
        }
        .onChange(of: model.location.isAuthorized) {
            model.refreshNearbyNetworks()
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.ash)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.glass))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
            if let footer {
                Text(footer)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct Field: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt).foregroundStyle(Theme.slate))
            .labelsHidden()
            .modifier(FieldStyle())
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.body(13))
            .foregroundStyle(Theme.bone)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).fill(Theme.graphite))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).strokeBorder(Theme.hairline))
    }
}
