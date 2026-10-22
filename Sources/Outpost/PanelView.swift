import OutpostCore
import SwiftUI

/// The menu bar panel: status, On the Move, keep awake, the two switches, and a footer.
struct PanelView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void
    @Environment(\.frostedGlass) private var frostedGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
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
            .toggleStyle(OutpostSwitchStyle())
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
            VStack(alignment: .leading, spacing: 1) {
                Text(model.networkStatus)
                    .font(Theme.body(13, weight: .medium))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.awakeStatus)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                if model.claudeWorking > 0 {
                    Text(model.claudeWorking == 1 ? "1 Claude session working" : "\(model.claudeWorking) Claude sessions working")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let battery = PowerSource.batteryLevel() {
                Text("\(battery)%")
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.ash)
                    .monospacedDigit()
                    .accessibilityLabel("Battery \(battery) percent")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
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
        .toggleStyle(OutpostSwitchStyle(onLight: true))
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
            Button("Quit Outpost") { model.quit() }
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
