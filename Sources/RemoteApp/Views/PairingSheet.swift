import AppleTVKit
import SwiftUI

/// Asks for the four-digit PIN the Apple TV shows.
struct PairingSheet: View {
    @Environment(DeviceStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Tokens.inkSecondary)
            VStack(spacing: 6) {
                Text(store.pairingTitle.isEmpty ? "Pair with \(store.selectedName)" : store.pairingTitle)
                    .font(Tokens.deviceName)
                Text("Enter the code shown on your TV.")
                    .font(Tokens.body)
                    .foregroundStyle(Tokens.inkSecondary)
            }
            PINField(code: Binding(get: { store.pinEntry }, set: { store.pinEntry = $0 }))
                .focused($focused)
            HStack {
                Button("Cancel") { coordinator.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Pair") { coordinator.submitPIN() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.pinEntry.count != 4)
            }
        }
        .padding(28)
        .frame(width: 320)
        .onAppear { focused = true }
    }
}

/// Four digit boxes bound to one string.
struct PINField: View {
    @Binding var code: String

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { index in
                    let digit = index < code.count ? String(code[code.index(code.startIndex, offsetBy: index)]) : ""
                    Text(digit)
                        .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                        .frame(width: 48, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Tokens.surfaceRaised)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(index == code.count ? Tokens.accent : Tokens.edge, lineWidth: index == code.count ? 1.5 : 0.5)
                                )
                        )
                        .animation(Motion.hover, value: code.count)
                }
            }
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .font(.system(size: 1))
                .opacity(0.02)
                .onChange(of: code) { _, new in
                    let digits = new.filter(\.isNumber)
                    if digits != new || digits.count > 4 { code = String(digits.prefix(4)) }
                }
        }
        .frame(height: 56)
    }
}
