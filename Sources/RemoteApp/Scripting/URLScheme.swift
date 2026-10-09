import AppleTVKit
import Foundation

/// Commands the app accepts as `atvremote://` URLs.
///
/// - `atvremote://press/<button>` with a button name such as `select` or `volume-up`.
/// - `atvremote://launch/<bundle-id>`.
/// - `atvremote://device/<name>` picks an Apple TV by name.
/// - `atvremote://media/<play|pause|toggle|next|previous|skip-forward|skip-backward>`.
/// - `atvremote://wake` and `atvremote://sleep`.
enum URLCommand: Equatable {
    case press(RemoteButton)
    case launch(String)
    case device(String)
    case media(MediaCommand)
    case wake
    case sleep

    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "atvremote" else { return nil }
        let verb = url.host?.lowercased() ?? ""
        let argument = url.path.split(separator: "/").first.map(String.init)?.removingPercentEncoding ?? ""
        switch verb {
        case "press":
            guard let button = RemoteButton(commandName: argument) else { return nil }
            return .press(button)
        case "launch":
            return argument.isEmpty ? nil : .launch(argument)
        case "device":
            return argument.isEmpty ? nil : .device(argument)
        case "media":
            let mapping: [String: MediaCommand] = [
                "play": .play, "pause": .pause, "toggle": .togglePlayPause, "next": .nextTrack,
                "previous": .previousTrack, "skip-forward": .skipForward, "skip-backward": .skipBackward,
            ]
            guard let command = mapping[argument] else { return nil }
            return .media(command)
        case "wake": return .wake
        case "sleep": return .sleep
        default: return nil
        }
    }
}

extension AppCoordinator {
    /// Runs one URL command against the current device.
    @MainActor
    func handle(_ url: URL) {
        guard let command = URLCommand.parse(url) else {
            ATVLog.input.error("unknown url \(url.absoluteString, privacy: .public)")
            return
        }
        switch command {
        case .press(let button): store.click(button)
        case .launch(let bundle): store.launch(LaunchableApp(bundleID: bundle, name: bundle))
        case .device(let name):
            if let device = store.devices.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                select(device)
            }
        case .media(let media): store.media(media)
        case .wake: wakeSelected()
        case .sleep: store.click(.sleep)
        }
    }
}
