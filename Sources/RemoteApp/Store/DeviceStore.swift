import AppleTVKit
import Foundation
import Observation
import SwiftUI

/// The one source of truth for the UI. Runs on the main actor.
@MainActor
@Observable
final class DeviceStore {
    // MARK: Devices

    var devices: [DiscoveredDevice] = []
    var selectedDeviceID: String?
    var selectedName = "Apple TV"

    // MARK: Link

    var connection: ConnectionState = .idle
    var power: PowerState = .unknown
    var nowPlaying: NowPlaying?
    var textInput: TextInputState = .inactive
    var apps: [LaunchableApp] = []
    /// The volume as 0...1. Nil when the current output reports no level.
    var volume: Double?
    var lastError: String?

    // MARK: Pairing

    var pinEntry = ""
    var pairingTitle = ""

    // MARK: UI state

    var pressedButtons: Set<RemoteButton> = []
    var paletteVisible = false
    var keyboardVisible = false
    /// True while the user drags the volume slider. TV reports are ignored then.
    var volumeDragging = false

    // MARK: Controller

    private(set) var controller: (any RemoteController)?
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var volumeSendTask: Task<Void, Never>?
    private var pendingVolume: Double?

    /// How often the store asks the TV for its power and volume state.
    private static let pollInterval: Duration = .seconds(15)
    /// The shortest gap between two volume requests while the slider moves.
    private static let volumeSendInterval: Duration = .milliseconds(60)

    /// Connects the UI to a controller. Any previous controller disconnects first.
    func attach(_ controller: any RemoteController, name: String) {
        eventTask?.cancel()
        pollTask?.cancel()
        volumeSendTask?.cancel()
        volumeSendTask = nil
        pendingVolume = nil
        if let old = self.controller {
            Task { await old.disconnect() }
        }
        self.controller = controller
        selectedDeviceID = controller.id
        selectedName = name
        nowPlaying = nil
        apps = []
        textInput = .inactive
        volume = nil
        connection = .idle

        eventTask = Task { [weak self] in
            for await event in controller.events {
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
        }
        Task { await controller.connect() }
    }

    private func apply(_ event: DeviceEvent) {
        switch event {
        case .connection(let state):
            connection = state
            if case .failed(let message) = state { lastError = message }
            if state == .connected {
                lastError = nil
                refreshVolume()
                startPolling()
            }
        case .power(let state):
            power = state
        case .nowPlaying(let info):
            withAnimation(Motion.crossfade) { nowPlaying = info }
        case .textInput(let state):
            textInput = state
            switch state {
            case .active: keyboardVisible = true
            case .inactive: keyboardVisible = false
            }
        case .apps(let list):
            apps = list
        case .volume(let level):
            if !volumeDragging { volume = level == DeviceEvent.noVolumeLevel ? nil : level }
        }
    }

    // MARK: Volume

    /// Sets the level from the slider. Sends at most one request each 60 ms.
    func setVolume(_ level: Double) {
        volume = level
        pendingVolume = level
        guard volumeSendTask == nil else { return }
        volumeSendTask = Task { [weak self] in
            while let self, !Task.isCancelled, let next = self.pendingVolume {
                self.pendingVolume = nil
                if let controller = self.controller {
                    try? await controller.setVolume(next)
                }
                try? await Task.sleep(for: Self.volumeSendInterval)
            }
            self?.volumeSendTask = nil
        }
    }

    func refreshVolume() {
        guard let controller else { return }
        Task { [weak self] in
            guard let level = try? await controller.volumeLevel(), let self, !self.volumeDragging else { return }
            self.volume = level
        }
    }

    // MARK: Power

    /// Wakes a sleeping TV, or puts an awake TV to sleep.
    func togglePower() {
        guard let controller else { return }
        let wasAsleep = power == .asleep
        Task { [weak self] in
            if wasAsleep { await controller.wake() } else { await controller.sleep() }
            try? await Task.sleep(for: .seconds(2))
            self?.refreshPower()
            try? await Task.sleep(for: .seconds(4))
            self?.refreshPower()
        }
    }

    func refreshPower() {
        guard let controller, connection.isConnected else { return }
        Task { [weak self] in
            guard let state = try? await controller.powerState() else { return }
            self?.power = state
        }
    }

    /// Polls power and volume while connected. The TV does not push power changes.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, self.connection.isConnected else { continue }
                self.refreshPower()
                self.refreshVolume()
            }
        }
    }

    // MARK: Input

    /// Sends a button down and marks it pressed. The socket write happens on the controller.
    func buttonDown(_ button: RemoteButton) {
        guard !pressedButtons.contains(button) else { return }
        pressedButtons.insert(button)
        controller?.button(button, down: true)
    }

    /// Sends a button up and clears the pressed mark.
    func buttonUp(_ button: RemoteButton) {
        guard pressedButtons.contains(button) else { return }
        pressedButtons.remove(button)
        controller?.button(button, down: false)
    }

    /// Releases every button that is down. Used when focus leaves the window.
    func releaseAll() {
        for button in pressedButtons { buttonUp(button) }
    }

    /// A full click for menus, scripting and the palette.
    func click(_ button: RemoteButton) {
        controller?.press(button)
        flash(button)
    }

    /// Shows the pressed state for a moment after a click that had no mouse down.
    private func flash(_ button: RemoteButton) {
        pressedButtons.insert(button)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            self?.pressedButtons.remove(button)
        }
    }

    func touch(_ event: TouchEvent) {
        controller?.touch(event)
    }

    func media(_ command: MediaCommand) {
        perform { try await $0.media(command) }
    }

    func typeText(_ text: String) {
        perform { try await $0.typeText(text) }
    }

    func clearText() {
        perform { try await $0.clearText() }
    }

    func loadApps() {
        guard let controller else { return }
        Task { [weak self] in
            do {
                let list = try await controller.launchableApps()
                self?.apps = list
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func launch(_ app: LaunchableApp) {
        perform { try await $0.launch(bundleID: app.bundleID) }
    }

    /// Runs one controller call and shows its error, if any.
    private func perform(_ action: @escaping @Sendable (any RemoteController) async throws -> Void) {
        guard let controller else { return }
        Task { [weak self] in
            do {
                try await action(controller)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    // MARK: Derived

    var statusText: String {
        switch connection {
        case .connected:
            switch power {
            case .asleep: "Asleep"
            case .screensaver: "Screensaver"
            default: "Connected"
            }
        default: connection.label
        }
    }

    var statusColor: Color {
        switch connection {
        case .connected: power == .asleep ? Tokens.inkTertiary : .green
        case .connecting, .reconnecting, .pairing, .awaitingPIN: .orange
        case .failed: Tokens.danger
        case .idle: Tokens.inkTertiary
        }
    }
}
