import SwiftUI

/// A dot and a short state word.
struct StatusBadge: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.statusColor)
                .frame(width: 7, height: 7)
                .animation(Motion.hover, value: store.connection)
            Text(store.statusText)
                .font(Tokens.caption)
                .foregroundStyle(Tokens.inkSecondary)
                .contentTransition(.opacity)
                .animation(Motion.crossfade, value: store.statusText)
        }
        .accessibilityElement(children: .combine)
    }
}
