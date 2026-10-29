import AwakeCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsContent(model: model)
            .frame(width: 520, height: 680)
        .background(Theme.void)
        .environment(\.colorScheme, .dark)
    }
}

/// Settings come in four short tabs instead of one long page.
enum SettingsTab: CaseIterable, Identifiable {
    case general, modes, network, setup

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .modes: "Modes"
        case .network: "Network"
        case .setup: "Setup"
        }
    }
}

struct SettingsContent: View {
    @ObservedObject var model: AppModel
    /// The tab it opens on. Only the first value counts (it's state): for previews.
    @State var tab: SettingsTab = .general
    /// The header and tabs stay put while the tab scrolls under them; previews draw the whole tab instead.
    var scrolls = true
    @Environment(\.liveControls) private var liveControls
    @State private var password = ""
    @State private var copied = false
    @State private var copiedSSH = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var mcpCommand: String { model.mcpCommand }

    /// Setup gets a dot while a permission is missing: the admin permission (Overnight, On the Move) or Location for
    /// a feature that's on.
    private var setupNeedsAttention: Bool {
        !model.lidMode.isSetUp || !model.featuresNeedingLocation.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                header
                TabBar(selection: $tab, attention: setupNeedsAttention ? [.setup] : [])
            }
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 14)
            if scrolls {
                ScrollView { tabContent }
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            } else {
                tabContent
            }
        }
        .toggleStyle(AwakeSwitchStyle())
        .font(Theme.body(13))
        .foregroundStyle(Theme.bone)
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

    private var header: some View {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Awake")
                        .font(Theme.title(24, weight: .semibold))
                        .foregroundStyle(Theme.bone)
                    Text("Your laptop, always on. Wherever you work.")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.ash)
                }
            }
    }

    private var tabContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch tab {
            case .general: general
            case .modes: modes
            case .network: network
            case .setup: setup
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }

    // MARK: - Tabs

    @ViewBuilder private var general: some View {
        Card("Startup") {
            SettingToggle(title: "Launch at login", detail: "Starts Awake when you log in.",
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
        }

        Card("Safety") {
            SettingToggle(title: "Stop when it's hot or the battery is low",
                          detail: "Turns everything off and lets the Mac sleep: hot with the lid closed, or at 20% battery.",
                          isOn: $model.safetyEnabled)
        }

        Card("Warnings") {
            ChoiceRow(title: "Find an outlet", detail: "A heads-up when the battery has this much left.",
                      spokenTitle: "Find an outlet warning") {
                ForEach(PowerAlerts.warningChoices, id: \.self) { minutes in
                    Chip(title: TimeText.format(minutes: minutes), spokenTitle: "\(TimeText.spoken(minutes: minutes)) left",
                         selected: model.outletWarningMinutes == minutes) { model.outletWarningMinutes = minutes }
                }
            }
            SettingToggle(title: "Disk, memory and CPU", detail: "Under 10 GB free, low memory, or a busy CPU for 10 minutes on battery.",
                          isOn: $model.healthWarningsOn)
        }
    }

    @ViewBuilder private var modes: some View {
        Card("Keep awake") {
            SettingToggle(title: "Let the display sleep", detail: "The Mac stays awake; only the screen turns off.",
                          isOn: $model.allowDisplaySleep)
        }

        Card("Overnight", footer: "Changes nothing else: Wi-Fi, the firewall and Low Power Mode stay as they are. On a charger only critical heat stops it.") {
            ChoiceRow(title: "Ends", detail: nil, spokenTitle: "Overnight ends") {
                ForEach(OvernightSession.morningChoices, id: \.self) { hour in
                    let title = Self.hourTitle(hour)
                    Chip(title: title, spokenTitle: "At \(title)",
                         selected: model.overnightEnd == .morning && model.overnightHour == hour) {
                        model.overnightHour = hour
                        model.overnightEnd = .morning
                    }
                }
                Chip(title: "When Claude finishes", selected: model.overnightEnd == .whenClaudeFinishes) {
                    model.overnightEnd = .whenClaudeFinishes
                }
                Chip(title: "When I turn it off", selected: model.overnightEnd == .manually) {
                    model.overnightEnd = .manually
                }
            }
        }

        Card("On the Move", footer: "It also turns on auto-hotspot (Network tab). When you're back, everything goes back to how it was.") {
            ChoiceRow(title: "Ends", detail: nil, spokenTitle: "On the Move ends") {
                ForEach(MoveEnd.allCases) { option in
                    Chip(title: option.title, selected: model.moveEnd == option) { model.moveEnd = option }
                }
            }
            SettingToggle(title: "Low Power Mode", detail: "On battery.", isOn: $model.moveLowPower)
            SettingToggle(title: "Firewall shield", detail: "The macOS firewall with stealth mode.", isOn: $model.moveShield)
            SettingToggle(title: "Suggest it when I leave my desk", detail: "When you unplug from your display or charger.",
                          isOn: $model.deskSuggestions)
        }
    }

    @ViewBuilder private var network: some View {
        Card("Wi-Fi", footer: "Your hotspot always counts as trusted. On any other Wi-Fi the shield turns on; back on a trusted network, the firewall goes back to how it was.") {
            SettingToggle(title: "Shield me on public Wi-Fi",
                          detail: "The macOS firewall with stealth mode, and a heads-up about sharing that's on.",
                          isOn: $model.publicShield)
            SettingToggle(title: "Offer to switch to a trusted network",
                          detail: "When one is in range while you're on your hotspot or public Wi-Fi.",
                          isOn: $model.offerTrustedNetworks)
            ListSection(title: "Connected") {
                connectedRow
            }
            ListSection(title: "Trusted networks") {
                trustedRows
            }
        }

        Card("Run a shortcut", footer: "Runs when you switch between public and trusted Wi-Fi. Leave one empty to skip it.") {
            LabeledRow(label: "On public Wi-Fi") {
                Field(title: "On public Wi-Fi shortcut", text: $model.publicShortcut, prompt: "None")
                shortcutMenu("On public Wi-Fi", text: $model.publicShortcut)
            }
            LabeledRow(label: "On trusted Wi-Fi") {
                Field(title: "On trusted Wi-Fi shortcut", text: $model.homeShortcut, prompt: "None")
                shortcutMenu("On trusted Wi-Fi", text: $model.homeShortcut)
            }
        }

        Card("Auto-hotspot", footer: "On your iPhone, keep Settings → Personal Hotspot → Allow Others to Join turned on.") {
            SettingToggle(title: "Switch to my hotspot when the internet drops", detail: nil, isOn: $model.autoHotspot)
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
                chevron.hidden()  // lines up with the fields above, which have a menu
            }
            if model.hotspotIsConfigured, model.canJoinHotspotNow {
                Button("Join \(model.hotspotSSID) now") { Task { await model.joinHotspotNow() } }
                    .buttonStyle(GhostButtonStyle())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            SettingToggle(title: "Go back to Wi-Fi when it returns", detail: "Saves your phone's data.", isOn: $model.returnToWiFi)
        }

        Card("Reach from your phone", footer: "Over Tailscale and SSH. It stays reachable with the lid closed only in Overnight or On the Move.") {
            reachRow
        }
    }

    @ViewBuilder private var setup: some View {
        Card("Permissions", footer: "The admin permission lets Awake switch lid-closed mode, Low Power Mode, sleep and the firewall without asking each time, and nothing else. Awake never reads your location: macOS just hides Wi-Fi names without it.") {
            PermissionRow(title: "Admin permission", detail: "For Overnight and On the Move. Asks for your password once.",
                          granted: model.lidMode.isSetUp, grantedText: "Ready", action: "Set Up…") {
                Task { await model.setUpLidMode() }
            }
            PermissionRow(title: "Location access", detail: "To see Wi-Fi names, for the shield and auto-hotspot.",
                          granted: model.location.isAuthorized, grantedText: "Allowed",
                          action: model.location.isDenied ? "Open Settings…" : "Allow…") {
                model.location.request()
            }
        }

        Card("Claude Code", footer: "Then a new Claude session can switch On the Move or Overnight when you tell it you're leaving or going to bed, and check the Mac's health.") {
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

        Button("Show the welcome again") { model.openWelcome() }
            .buttonStyle(GhostButtonStyle())
            .frame(maxWidth: .infinity)

        Text("Awake \(version) · Built on Insomnia by Karan Sangha · Fonts: DM Sans, Geist (OFL)")
            .font(Theme.body(11))
            .foregroundStyle(Theme.slate)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Parts

    /// "9 AM" in the user's locale.
    static func hourTitle(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }

    @ViewBuilder private var reachRow: some View {
        HStack {
            Text(model.reach.map { $0 == .tailscaleMissing ? "Tailscale isn't installed" : $0.text } ?? "Checking…")
                .font(Theme.body(13))
                .foregroundStyle(Theme.bone)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let reach = model.reach, let action = reachAction(reach) {
                Button(action) {
                    model.performReachAction()
                    if reach.isReachable { showCopiedSSH() }
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }

    private func reachAction(_ reach: RemoteReach) -> String? {
        switch reach {
        case .reachable, .untilSleep: copiedSSH ? "Copied" : "Copy SSH"
        case .remoteLoginOff: "Open Settings"
        case .tailscaleOff: model.canOpenTailscale ? "Open Tailscale" : nil
        case .tailscaleMissing: nil
        }
    }

    private func showCopiedSSH() {
        copiedSSH = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedSSH = false
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down").foregroundStyle(Theme.ash)
    }

    /// Nearby networks to pick the hotspot from; asks for Location access first, without which macOS lists none.
    @ViewBuilder private var networkMenu: some View {
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

    /// The user's shortcuts to pick from, so a name can't be mistyped; the field still takes any name.
    @ViewBuilder private func shortcutMenu(_ when: String, text: Binding<String>) -> some View {
        if liveControls {
            Menu {
                Button("None") { text.wrappedValue = "" }
                if model.installedShortcuts.isEmpty {
                    Text("No shortcuts found")
                } else {
                    Divider()
                }
                ForEach(model.installedShortcuts, id: \.self) { name in
                    Button(name) { text.wrappedValue = name }
                }
            } label: {
                chevron
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a shortcut")
            .accessibilityLabel("Choose a shortcut to run \(when.lowercased())")
        } else {
            chevron
        }
    }

    /// The Wi-Fi this Mac is on, whether it's trusted, and Trust for a public one.
    @ViewBuilder private var connectedRow: some View {
        if !model.location.isAuthorized {
            ListRow(icon: "wifi.exclamationmark", title: "Needs Location access to see its name") {
                Button("Setup") { tab = .setup }
                    .buttonStyle(GhostButtonStyle())
            }
        } else if let ssid = model.wifi.ssid {
            ListRow(icon: ssid == model.hotspotSSID ? "personalhotspot" : "wifi", title: ssid) {
                if ssid == model.hotspotSSID {
                    StatusBadge(text: "Your hotspot", color: Theme.online)
                } else if model.profile == .home {
                    StatusBadge(text: "Trusted", color: Theme.online)
                } else {
                    StatusBadge(text: "Public", color: Theme.attention)
                    Button("Trust") { model.trustCurrentNetwork() }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityLabel("Trust \(ssid)")
                }
            }
        } else {
            ListRow(icon: "wifi.slash", title: model.wifi.isPoweredOn ? "Not on Wi-Fi" : "Wi-Fi is off", dimmed: true) {}
        }
    }

    /// Trusted networks, your hotspot, and a menu to add one in range.
    @ViewBuilder private var trustedRows: some View {
        let trusted = model.trustedNetworks.filter { $0 != model.hotspotSSID }
        if trusted.isEmpty, model.hotspotSSID.isEmpty {
            ListRow(icon: "wifi", title: "None yet", dimmed: true) {}
        }
        ForEach(trusted, id: \.self) { name in
            ListRow(icon: "wifi", title: name) {
                if name == model.wifi.ssid {
                    StatusBadge(text: "Connected", color: Theme.online)
                }
                Button { model.untrust(name) } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ash)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel("Remove \(name)")
            }
        }
        if !model.hotspotSSID.isEmpty {
            ListRow(icon: "personalhotspot", title: model.hotspotSSID) {
                StatusBadge(text: "Your hotspot", color: Theme.slate)
            }
        }
        addNetworkRow
    }

    /// Networks in range that aren't trusted yet, to add without joining them first.
    @ViewBuilder private var addNetworkRow: some View {
        let label = Label("Add a network in range", systemImage: "plus.circle")
            .font(Theme.body(13))
            .foregroundStyle(Theme.ash)
        if liveControls {
            let candidates = model.nearbyNetworks.filter { !model.trustedNetworks.contains($0) && $0 != model.hotspotSSID }
            Menu {
                if !model.location.isAuthorized {
                    Button("Allow Location access to list networks") { model.location.request() }
                } else if candidates.isEmpty {
                    Text("No other networks in range")
                }
                ForEach(candidates, id: \.self) { name in
                    Button(name) { model.trust(name) }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .modifier(RowDivider())
            .onAppear { model.refreshNearbyNetworks() }
        } else {
            label
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .modifier(RowDivider())
        }
    }
}

/// A labelled group of rows in one rounded box, with hairlines between the rows.
struct ListSection<Rows: View>: View {
    let title: String
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.body(12, weight: .medium))
                .foregroundStyle(Theme.slate)
                .accessibilityAddTraits(.isHeader)
            // Each row draws a hairline on top; the first one sits under the box's own edge.
            VStack(alignment: .leading, spacing: 0) {
                rows
            }
            .padding(.top, -1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.void.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

/// The hairline over each row of a `ListSection`, starting after the icon column.
struct RowDivider: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 40)
        }
    }
}

/// One row: an icon, a name, and whatever goes on the right (a badge, a button).
struct ListRow<Trailing: View>: View {
    let icon: String
    let title: String
    var dimmed = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ash)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.body(13))
                .foregroundStyle(dimmed ? Theme.slate : Theme.bone)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .modifier(RowDivider())
        .accessibilityElement(children: .contain)
    }
}

/// A small status pill: a coloured dot and a word.
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(Theme.body(11, weight: .medium))
                .foregroundStyle(Theme.ash)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .fixedSize()
    }
}

/// The four tabs as one segmented control: the selected one is white (white = on). ⌘1–⌘4 switch between them.
private struct TabBar: View {
    @Binding var selection: SettingsTab
    let attention: Set<SettingsTab>

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element) { index, tab in
                let selected = selection == tab
                Button { selection = tab } label: {
                    // The dot hangs off the title, so the title stays centred.
                    Text(tab.title)
                        .font(Theme.body(12, weight: .medium))
                        .overlay(alignment: .trailing) {
                            if attention.contains(tab) {
                                Circle()
                                    .fill(Theme.attention)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 11)
                            }
                        }
                    .foregroundStyle(selected ? Theme.graphite : Theme.smoke)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(selected ? Theme.white : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityLabel(attention.contains(tab) ? "\(tab.title), needs attention" : tab.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.glass))
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }
}

/// A switch with a short title and, under it, one line on what it does.
struct SettingToggle: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.bone)
                if let detail {
                    Text(detail)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A title (and an optional detail) over a row of chips for a single choice.
private struct ChoiceRow<Chips: View>: View {
    let title: String
    let detail: String?
    /// What VoiceOver calls the group, when the title alone is ambiguous ("Ends" in two cards).
    var spokenTitle: String?
    @ViewBuilder let chips: Chips

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.bone)
                if let detail {
                    Text(detail)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.slate)
                }
            }
            .accessibilityHidden(true)
            FlowLayout(spacing: 6) {
                chips
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(spokenTitle ?? title)
            .accessibilityHint(detail ?? "")
        }
    }
}

/// A field (or fields) with a visible label on the left, 110 pt wide so the fields line up.
struct LabeledRow<Content: View>: View {
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
struct PermissionRow: View {
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
                    .fixedSize(horizontal: false, vertical: true)
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

struct Field: View {
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
struct FieldStandIn: View {
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

struct FieldStyle: ViewModifier {
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
