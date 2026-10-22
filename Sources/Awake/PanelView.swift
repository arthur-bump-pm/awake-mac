import AwakeCore
import SwiftUI

/// The menu bar panel: status, On the Move, keep awake, the two switches, and a footer.
struct PanelView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void
    @Environment(\.frostedGlass) private var frostedGlass
    @State private var copiedSSH = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusLines
            ForEach(model.alerts) { alert in
                AlertRow(alert: alert) { Task { await model.perform(alert) } }
            }
            moveCard
            keepAwake
            VStack(spacing: 6) {
                Toggle(isOn: Binding(get: { model.lidMode.isEnabled },
                                     set: { on in Task { await model.setLidModeFromMenu(on) } })) {
                    RowLabel(title: "Lid-closed mode", detail: model.lidMode.isSetUp ? nil : "Asks for your password once")
                }
                Toggle(isOn: $model.autoHotspot) {
                    RowLabel(title: "Auto-hotspot", detail: hotspotDetail)
                }
            }
            .toggleStyle(AwakeSwitchStyle())
            .padding(.horizontal, 6)
            if model.autoHotspot, model.hotspotIsConfigured, model.canJoinHotspotNow {
                Button("Join \(model.hotspotSSID) now") { Task { await model.joinHotspotNow() } }
                    .buttonStyle(GhostButtonStyle())
                    .padding(.horizontal, 6)
            }
            if !model.otherAwakeApps.isEmpty {
                Text("Also keeping it awake: \(model.otherAwakeApps.joined(separator: ", "))")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
            footer
        }
        .padding(Theme.panelPadding)
        .frame(width: 320)
        .background(
            ZStack {
                if frostedGlass {
                    FrostedBackground()
                }
                Theme.graphite.opacity(frostedGlass ? 0.82 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).strokeBorder(Theme.hairline))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 5)
            // Each line carries its own battery text on the right, so a long charger note doesn't squeeze the
            // network name above it.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.networkStatus)
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(Theme.bone)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let percent = model.power.percent {
                        Text("\(percent)%")
                            .font(Theme.body(12, weight: .medium))
                            .foregroundStyle(Theme.ash)
                            .monospacedDigit()
                            .fixedSize()
                            .accessibilityLabel("Battery \(percent) percent")
                    }
                }
                HStack(spacing: 6) {
                    Text(model.awakeStatus)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if model.power.percent != nil, let detail = model.power.detail {
                        Text(detail)
                            .font(Theme.body(11))
                            .foregroundStyle(powerNeedsAttention ? Theme.attention : Theme.slate)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                if model.claudeWorking > 0 {
                    Text(model.claudeWorking == 1 ? "1 Claude session working" : "\(model.claudeWorking) Claude sessions working")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    /// The network line (home or public) and whether the owner's phone can reach this Mac.
    @ViewBuilder private var statusLines: some View {
        let profile = model.profileStatus
        let reach = model.reach
        if profile != nil || reach != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let profile {
                    StatusLine(text: profile) {
                        if model.profile == .public, model.wifi.ssid != nil {
                            Button("Trust") { model.trustCurrentNetwork() }
                                .buttonStyle(GhostButtonStyle())
                                .help("Trust this network")
                                .accessibilityLabel("Trust this network")
                        }
                    }
                }
                if let reach {
                    StatusLine(text: reach.text) {
                        if let action = reachAction(reach) {
                            Button(action) {
                                model.performReachAction()
                                if reach.isReachable { showCopied() }
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func reachAction(_ reach: RemoteReach) -> String? {
        switch reach {
        case .reachable, .untilSleep: copiedSSH ? "Copied" : "Copy SSH"
        case .remoteLoginOff: "Open Settings"
        case .tailscaleOff: "Open Tailscale"
        case .tailscaleMissing: nil
        }
    }

    private func showCopied() {
        copiedSSH = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedSSH = false
        }
    }

    /// Battery running low (under the warning threshold) or a charger that can't keep up.
    private var powerNeedsAttention: Bool {
        let power = model.power
        if power.chargerTooWeak { return true }
        return power.onBattery && (power.minutesLeft.map { $0 < model.outletWarningMinutes } ?? false)
    }

    private var moveCard: some View {
        Toggle(isOn: Binding(get: { model.onTheMove },
                             set: { on in Task { await model.setOnTheMoveFromMenu(on) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("On the Move")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.graphite)
                Text(model.onTheMove ? "Lid closed is fine · ends \(model.moveEnd.phrase)"
                                     : "Keeps Claude running while you travel")
                    .font(Theme.body(11))
                    .foregroundStyle(Color(hex: 0x686868))
            }
        }
        .toggleStyle(AwakeSwitchStyle(onLight: true))
        .padding(.vertical, 12)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .background(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous).fill(Theme.white))
    }

    private var keepAwake: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Keep awake")
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.ash)
                Spacer()
                if let left = model.keepAwake.remainingTime {
                    Text("\(AppModel.format(left)) left")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.slate)
                        .monospacedDigit()
                }
            }
            FlowLayout(spacing: 6) {
                ForEach(KeepAwakeOption.chips) { option in
                    Chip(title: option.title, selected: model.keepAwakeOption == option) {
                        model.keepAwakeOption = option
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var footer: some View {
        HStack {
            Button("Settings", action: openSettings)
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut(",")
            Spacer()
            Button("Quit Awake") { model.quit() }
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut("q")
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var statusColor: Color {
        switch model.connectivity {
        case .online?: Theme.online
        case .captivePortal?: Theme.attention
        case .offline?: Theme.offline
        case nil: Theme.slate
        }
    }

    private var hotspotDetail: String? {
        guard model.autoHotspot else { return model.hotspotSSID.isEmpty ? nil : model.hotspotSSID }
        if model.hotspotSSID.isEmpty { return "Choose a hotspot in Settings" }
        if !model.location.isAuthorized { return "Needs Location access (Settings)" }
        return model.isOnHotspot ? "Using \(model.hotspotSSID)" : "Ready · \(model.hotspotSSID)"
    }
}

private struct RowLabel: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Theme.body(13))
                .foregroundStyle(Theme.bone)
            if let detail {
                Text(detail)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.slate)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One compact line of status with an optional ghost action on the right.
private struct StatusLine<Action: View>: View {
    let text: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(Theme.body(12))
                .foregroundStyle(Theme.ash)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            action
        }
        .frame(minHeight: 24)
    }
}

private struct AlertRow: View {
    let alert: PanelAlert
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(alert.message)
                .font(Theme.body(12))
                .foregroundStyle(Theme.bone)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(alert.action, action: action)
                .buttonStyle(PillButtonStyle())
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous).strokeBorder(Theme.hairline))
    }
}
