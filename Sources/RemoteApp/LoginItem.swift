import OSLog
import ServiceManagement
import SwiftUI

/// Opens the app at login. The first launch turns it on one time. After that the user's
/// choice in the menu stays, also when the user turns it off.
@MainActor
enum LoginItem {
    private static let configuredKey = "loginItemConfigured"

    static func configureOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: configuredKey) else { return }
        UserDefaults.standard.set(true, forKey: configuredKey)
        try? SMAppService.mainApp.register()
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger(subsystem: "com.appletvremote.mac", category: "login").error(
                "login item change failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The "Open at Login" menu item. It reads the system state each time the menu opens.
struct OpenAtLoginToggle: View {
    @State private var enabled = LoginItem.isEnabled

    var body: some View {
        Toggle("Open at Login", isOn: Binding(
            get: { enabled },
            set: { newValue in
                LoginItem.setEnabled(newValue)
                enabled = LoginItem.isEnabled
            }
        ))
        .onAppear { enabled = LoginItem.isEnabled }
    }
}
