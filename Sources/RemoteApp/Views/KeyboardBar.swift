import AppleTVKit
import SwiftUI

/// Types into the text field that is open on the Apple TV.
/// Return presses Select on the TV. Escape presses Back and closes the bar.
struct KeyboardBar: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundStyle(Tokens.inkSecondary)
            TextField("Type on Apple TV", text: $text)
                .textFieldStyle(.plain)
                .font(Tokens.body)
                .focused($focused)
                .onSubmit {
                    // A newline in the text session acts as the keyboard's return key.
                    // Select would press the highlighted on-screen key instead.
                    store.typeText("\n")
                }
                .onKeyPress(.escape) {
                    close(pressBack: true)
                    return .handled
                }
                .onChange(of: text) { old, new in
                    send(old: old, new: new)
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Tokens.inkTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            Button {
                close(pressBack: false)
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .foregroundStyle(Tokens.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("Hide the keyboard bar (Escape)")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tokens.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.edge, lineWidth: 0.5))
        )
        .onAppear {
            // Seed once from the TV. Later TV reports are echoes of our own typing.
            if case .active(let current) = store.textInput { text = current }
            focused = true
        }
    }

    /// Sends only the new suffix when the user appends. Replaces the field otherwise.
    private func send(old: String, new: String) {
        if new.hasPrefix(old) {
            let suffix = String(new.dropFirst(old.count))
            if !suffix.isEmpty { store.typeText(suffix) }
        } else {
            store.clearText()
            if !new.isEmpty { store.typeText(new) }
        }
    }

    private func close(pressBack: Bool) {
        focused = false
        withAnimation(reduceMotion ? Motion.reduced : Motion.panelClose) {
            store.keyboardVisible = false
        }
        if pressBack { store.click(.menu) }
    }
}
