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
    @Environment(\.liveControls) private var liveControls
    @State private var password = ""
    @State private var copied = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// The app's path is quoted, so it still works from a folder with a space in its name.
    private var mcpCommand: String {
        "claude mcp add --scope user awake -- \"\(model.appPath)/Contents/MacOS/awakectl\" mcp"
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tell me to find an outlet when the battery has")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.bone)
                        FlowLayout(spacing: 6) {
                            ForEach(PowerAlerts.warningChoices, id: \.self) { minutes in
                                Chip(title: "\(TimeText.format(minutes: minutes)) left",
                                     spokenTitle: "\(TimeText.spoken(minutes: minutes)) left",
                                     selected: model.outletWarningMinutes == minutes) { model.outletWarningMinutes = minutes }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Find an outlet warning")
                    }
                }

                Card("On the Move", footer: "Low Power Mode applies on battery. The shield turns on the macOS firewall with stealth mode. Both go back to how they were when you're back.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ends")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.bone)
                        FlowLayout(spacing: 6) {
                            ForEach(MoveEnd.allCases) { option in
                                Chip(title: option.title, selected: model.moveEnd == option) { model.moveEnd = option }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("On the Move ends")
                    }
                    Toggle("Turn on Low Power Mode", isOn: $model.moveLowPower)
                    Toggle("Turn on the firewall shield", isOn: $model.moveShield)
                    Toggle("Suggest it when I leave my desk", isOn: $model.deskSuggestions)
                }

                Card("Networks", footer: "Your hotspot always counts as trusted; any other Wi-Fi is public. There the shield turns on the macOS firewall with stealth mode, and Awake flags sharing that's on. Back on a trusted network, the firewall goes back to how it was. Shortcuts run when you switch; leave one empty to skip it.") {
                    Toggle("Shield me on public Wi-Fi", isOn: $model.publicShield)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Trusted Wi-Fi")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.bone)
                        let trusted = model.trustedNetworks.filter { $0 != model.hotspotSSID }
                        if trusted.isEmpty, model.hotspotSSID.isEmpty {
                            Text("None yet")
                                .font(Theme.body(12))
                                .foregroundStyle(Theme.slate)
                        }
                        ForEach(trusted, id: \.self) { name in
                            HStack {
                                Text(name)
                                    .font(Theme.body(12))
                                    .foregroundStyle(Theme.ash)
                                    .lineLimit(1)
                                Spacer()
                                Button("Remove") { model.untrust(name) }
                                    .buttonStyle(GhostButtonStyle())
                                    .accessibilityLabel("Remove \(name)")
                            }
                        }
                        if !model.hotspotSSID.isEmpty {
                            HStack {
                                Text(model.hotspotSSID)
                                    .font(Theme.body(12))
                                    .foregroundStyle(Theme.ash)
                                    .lineLimit(1)
                                Spacer()
                                Text("Your hotspot")
                                    .font(Theme.body(11))
                                    .foregroundStyle(Theme.slate)
                            }
                        }
                    }
                    currentNetwork
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run a shortcut")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.bone)
                        LabeledRow(label: "On public Wi-Fi") {
                            Field(title: "On public Wi-Fi shortcut", text: $model.publicShortcut, prompt: "Shortcut name")
                        }
                        LabeledRow(label: "At home") {
                            Field(title: "At home shortcut", text: $model.homeShortcut, prompt: "Shortcut name")
                        }
                    }
                }

                Card("Permissions", footer: "Admin permission lets Awake switch lid-closed mode, Low Power Mode, sleep and the firewall without asking each time, and nothing else. Location access lets it see Wi-Fi names, for the public Wi-Fi shield and auto-hotspot; Awake never reads your location.") {
                    PermissionRow(title: "Admin permission", detail: "Asks for your password once",
                                  granted: model.lidMode.isSetUp, grantedText: "Ready", action: "Set Up…") {
                        Task { await model.setUpLidMode() }
                    }
                    PermissionRow(title: "Location access", detail: "To see Wi-Fi names",
                                  granted: model.location.isAuthorized, grantedText: "Allowed",
                                  action: model.location.isDenied ? "Open Settings…" : "Allow…") {
                        model.location.request()
                    }
                }

                Card("Auto-hotspot", footer: "On your iPhone, keep Settings → Personal Hotspot → Allow Others to Join turned on.") {
                    Toggle("Switch to my hotspot when the internet drops", isOn: $model.autoHotspot)
                    LabeledRow(label: "Hotspot") {
                        Field(title: "Hotspot name", text: $model.hotspotSSID, prompt: "iPhone name")
                        networkMenu
                    }
                    LabeledRow(label: "Password") {
                        if liveControls {
                            SecureField("Hotspot password", text: $password,
                                        prompt: Text("Hotspot password").foregroundStyle(Theme.slate))
                                .labelsHidden()
                                .modifier(FieldStyle())
                        } else {
                            FieldStandIn(text: "", prompt: "Hotspot password")
                        }
                    }
                    Toggle("Go back to Wi-Fi when it returns", isOn: $model.returnToWiFi)
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
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
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
            password = model.savedHotspotPassword ?? ""
            model.refreshNearbyNetworks()
        }
        .onChange(of: password) {
            model.setHotspotPassword(password)
        }
        .onChange(of: model.savedHotspotPassword) {
            // The keychain read (off the main actor) finished after the field appeared.
            if let saved = model.savedHotspotPassword, saved != password { password = saved }
        }
        .onChange(of: model.location.isAuthorized) {
            model.refreshNearbyNetworks()
        }
    }

    /// Nearby networks to pick the hotspot from; asks for Location access first, without which macOS lists none.
    @ViewBuilder private var networkMenu: some View {
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
        } else {
            chevron
        }
    }

    private var currentNetwork: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("This network")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.bone)
                Text(currentNetworkDetail)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.location.isAuthorized, model.profile == .public {
                Button("Trust current network") { model.trustCurrentNetwork() }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }

    /// The status first, so "Public" or "Trusted" stays visible next to a long name.
    private var currentNetworkDetail: String {
        guard model.location.isAuthorized else { return "Needs Location access (Permissions)" }
        guard let ssid = model.wifi.ssid else { return "Not on Wi-Fi" }
        return model.profile == .home ? "Trusted · \(ssid)" : "Public · \(ssid)"
    }
}

/// A field (or fields) with a visible label on the left, 110 pt wide so the fields line up.
private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.body(12))
                .foregroundStyle(Theme.ash)
                .frame(width: 110, alignment: .leading)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                content
            }
        }
    }
}

/// A permission's state: a check mark once granted, otherwise the button that asks for it.
private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let grantedText: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.bone)
                Text(detail)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.slate)
            }
            Spacer()
            if granted {
                Label(grantedText, systemImage: "checkmark.circle.fill")
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.ash)
            } else {
                Button(action, action: perform)
                    .buttonStyle(PillButtonStyle())
            }
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
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.glass))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
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
    @Environment(\.liveControls) private var liveControls

    var body: some View {
        if liveControls {
            TextField(title, text: $text, prompt: Text(prompt).foregroundStyle(Theme.slate))
                .labelsHidden()
                .modifier(FieldStyle())
        } else {
            FieldStandIn(text: text, prompt: prompt)
        }
    }
}

/// A field drawn as plain text, for off-screen previews (see `liveControls`).
private struct FieldStandIn: View {
    let text: String
    let prompt: String

    var body: some View {
        Text(text.isEmpty ? prompt : text)
            .foregroundStyle(text.isEmpty ? Theme.slate : Theme.bone)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
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
