import AppleTVKit
import SwiftUI

/// The card at the top of the remote. It is never empty.
///
/// The menu bar panel takes its height from what it holds. A slot that empties leaves the
/// panel taller than its content, and the desktop shows through the gap. So this card keeps
/// one height and always says something: what plays, what the app is doing, or what is
/// wrong and what to do about it.
struct StatusCard: View {
    @Environment(DeviceStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Tokens.body)
                    .foregroundStyle(isProblem ? Tokens.danger : Tokens.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.inkTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if case .needsPairing = store.status {
                Button("Pair") { coordinator.pairSelected() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        // A short message sits in the middle of the fixed height, not at the top.
        .frame(height: Tokens.compactCardHeight, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Tokens.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Tokens.edge, lineWidth: 0.5)
                )
        )
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    @ViewBuilder
    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Tokens.surfaceHover)
            if case .busy = store.status {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isProblem ? Tokens.danger : Tokens.inkTertiary)
            }
        }
        .frame(width: 40, height: 40)
    }

    private var isProblem: Bool {
        if case .problem = store.status { return true }
        if case .needsPairing = store.status { return true }
        return false
    }

    private var symbol: String {
        switch store.status {
        case .idle: "wifi.slash"
        case .busy: "arrow.triangle.2.circlepath"
        case .needsPairing: "lock.open"
        case .asleep: "moon.zzz"
        case .nothingPlaying: "play.tv"
        case .problem: "exclamationmark.triangle"
        }
    }

    /// Short enough for the card. The card never grows, so the words must fit.
    private var title: String {
        switch store.status {
        case .idle: "Not Connected"
        case .busy(let label): label
        case .needsPairing: "Needs Pairing"
        case .asleep: "Apple TV Asleep"
        case .nothingPlaying: "Nothing Playing"
        case .problem: "Connection Failed"
        }
    }

    private var detail: String {
        switch store.status {
        case .idle:
            store.devices.isEmpty ? "Looking for an Apple TV." : "Choose an Apple TV in the list."
        case .busy:
            "This takes a moment."
        case .needsPairing:
            "Your Apple TV will show a code."
        case .asleep:
            "Press power to wake it."
        case .nothingPlaying:
            "Open something on your Apple TV."
        case .problem(let message):
            message
        }
    }
}
