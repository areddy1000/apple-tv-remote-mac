import AppleTVKit
import SwiftUI

/// Command-K palette. Type to filter, Return to launch, Escape to close.
struct AppLauncherPalette: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True in the menu bar panel. The palette fits the panel width and shows fewer rows.
    var compact = false

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [LaunchableApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = store.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if q.isEmpty { return sorted }
        let prefix = sorted.filter { $0.name.lowercased().hasPrefix(q) }
        let contains = sorted.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return prefix + contains
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Tokens.inkSecondary)
                TextField("Open app on Apple TV", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit(launchSelected)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider().opacity(0.5)

            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                            row(app, selected: index == selection)
                                .id(app.id)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
                                .animation(Motion.rows.delay(Double(index) * Motion.stagger), value: store.apps)
                        }
                        if results.isEmpty {
                            Text(store.apps.isEmpty ? "Loading apps…" : "No apps match")
                                .font(Tokens.body)
                                .foregroundStyle(Tokens.inkTertiary)
                                .padding(.vertical, 18)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: compact ? 220 : 280)
                .onChange(of: selection) { _, index in
                    if results.indices.contains(index) {
                        reader.scrollTo(results[index].id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: (compact ? Tokens.compactWidth : Tokens.windowWidth) - 2 * Tokens.inset)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.edge, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .task {
            if store.apps.isEmpty { store.loadApps() }
            // The field joins the responder chain only after the first layout pass,
            // so asking for focus during appear is too early and is dropped.
            try? await Task.sleep(for: .milliseconds(40))
            focused = true
        }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func row(_ app: LaunchableApp, selected: Bool) -> some View {
        HStack(spacing: 10) {
            AppIconView(app: app)
            Text(app.name)
                .font(Tokens.body)
                .foregroundStyle(Tokens.ink)
            Spacer()
            if selected {
                Text("↩")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.inkTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Tokens.surfacePressed : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.launch(app)
            close()
        }
        .onHover { inside in
            if inside, let index = results.firstIndex(of: app) { selection = index }
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func launchSelected() {
        guard results.indices.contains(selection) else { return }
        store.launch(results[selection])
        close()
    }

    private func close() {
        withAnimation(reduceMotion ? Motion.reduced : Motion.panelClose) {
            store.paletteVisible = false
        }
    }
}
