import AwakeCore
import SwiftUI

/// The menu bar panel: status, anything that needs attention, one mode at a time, and a footer. Everything else
/// lives in Settings.
struct PanelView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void
    /// The room on screen below the menu bar; taller content scrolls inside it. Nil: no limit (previews).
    var maxHeight: CGFloat?
    @Environment(\.frostedGlass) private var frostedGlass

    var body: some View {
        // The panel sizes to its content; once that's taller than the screen allows, the same content scrolls.
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }
        }
        .frame(width: 320)
        .frame(maxHeight: maxHeight)
        .background(
            ZStack {
                if frostedGlass {
                    FrostedBackground()
                }
                Theme.graphite.opacity(frostedGlass ? 0.82 : 1)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).strokeBorder(Theme.hairline))
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(model.alerts) { alert in
                AlertRow(alert: alert, action: { Task { await model.perform(alert) } }, dismiss: { model.dismiss(alert) })
            }
            modes
            footer
        }
        .padding(Theme.panelPadding)
    }

    /// Two lines: the network and battery, then the network's profile, the coding sessions working and battery time.
    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.networkStatus)
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(Theme.bone)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                let detail = model.panelDetail
                // A weak charger is an alert of its own, so the line doesn't repeat it.
                let battery = model.power.percent != nil && !model.power.chargerTooWeak ? model.power.detail : nil
                if detail != nil || battery != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(detail ?? "")
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.slate)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if let battery {
                            Text(battery)
                                .font(Theme.body(11))
                                .foregroundStyle(powerNeedsAttention ? Theme.attention : Theme.slate)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    /// One grouped control: the mode that's on is the white row (white = on); Keep awake shows its lengths under it.
    private var modes: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AwakeMode.allCases) { mode in
                ModeRow(title: mode.title, detail: model.modeDetail(mode), selected: model.mode == mode) {
                    Task { await model.setModeFromMenu(mode) }
                }
                if mode == .keepAwake, model.mode == .keepAwake {
                    FlowLayout(spacing: 6) {
                        ForEach(KeepAwakeOption.chips) { option in
                            Chip(title: option.title, spokenTitle: option.spokenTitle,
                                 selected: model.keepAwakeOption == option) { Task { await model.chooseKeepAwake(option) } }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Keep awake for")
                }
            }
        }
        .padding(Self.modeInset)
        .background(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }

    /// Rows sit this far inside the group, so their corners are concentric with it.
    static let modeInset: CGFloat = 4

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

    /// Battery running low (under the warning threshold).
    private var powerNeedsAttention: Bool {
        let power = model.power
        return power.onBattery && (power.minutesLeft.map { $0 < model.outletWarningMinutes } ?? false)
    }

    private var statusColor: Color {
        switch model.connectivity {
        case .online?: Theme.online
        case .captivePortal?: Theme.attention
        case .offline?: Theme.offline
        case nil: Theme.slate
        }
    }
}

/// A mode: title and one line of detail. The selected one is white with graphite text and a check mark, so it doesn't
/// rely on the fill alone.
private struct ModeRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.body(13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.graphite : Theme.bone)
                    Text(detail)
                        .font(Theme.body(11))
                        .foregroundStyle(selected ? Color(hex: 0x5c5c5c) : Theme.slate)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.graphite)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.innerRadius - PanelView.modeInset, style: .continuous)
                    .fill(selected ? Theme.white : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct AlertRow: View {
    let alert: PanelAlert
    let action: () -> Void
    let dismiss: () -> Void

    var body: some View {
        Group {
            if let title = alert.action, alert.dismissible {
                // Two buttons: the message gets the whole row, the buttons go under it.
                VStack(alignment: .leading, spacing: 8) {
                    message
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Not now", action: dismiss)
                            .buttonStyle(GhostButtonStyle())
                        Button(title, action: action)
                            .buttonStyle(PillButtonStyle())
                            .accessibilityLabel(alert.spokenAction ?? title)
                    }
                }
            } else if let title = alert.action {
                HStack(spacing: 10) {
                    message
                    Spacer(minLength: 6)
                    Button(title, action: action)
                        .buttonStyle(PillButtonStyle())
                }
            } else {
                // Nothing to press: the message takes the whole row.
                message
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous).strokeBorder(Theme.hairline))
    }
    private var message: some View {
        Text(alert.message)
            .font(Theme.body(12))
            .foregroundStyle(Theme.bone)
            .fixedSize(horizontal: false, vertical: true)
    }
}
