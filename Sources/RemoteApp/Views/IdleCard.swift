import SwiftUI

/// Stands in for the now-playing card while nothing plays.
///
/// The menu bar panel takes its height from what it holds, so the card keeps its place
/// there. Without this the panel would grow and shrink every time playback starts or stops.
struct IdleCard: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Tokens.surfaceHover)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "play.tv")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Tokens.inkTertiary)
                )
            Text("Nothing Playing")
                .font(Tokens.body)
                .foregroundStyle(Tokens.inkTertiary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(height: Tokens.compactCardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Tokens.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Tokens.edge, lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nothing playing")
    }
}
