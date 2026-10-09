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
    var selectedName: String = "Apple TV"
    var selectedModel: String = ""

    // MARK: Link

    var connection: ConnectionState = .idle
    var power: PowerState = .unknown
    var nowPlaying: NowPlaying?
    var textInput: TextInputState = .inactive
    var apps: [LaunchableApp] = []
    var volume: Double?
    var lastError: String?

    // MARK: Pairing

    var pinEntry: String = ""
    var pairingTitle: String = ""

    // MARK: UI state

    var pressedButtons: Set<RemoteButton> = []
    var paletteVisible = false
    var keyboardVisible = false
    var surfacePointer: CGPoint? = nil
    var surfaceActive = false
    var hotKeyPanelRequested = false

    // MARK: Controller

    private(set) var controller: (any RemoteController)?
    private var eventTask: Task<Void, Never>?

    /// Connects the UI to a controller. Any previous controller disconnects first.
    func attach(_ controller: any RemoteController, name: String, model: String) {
        eventTask?.cancel()
        if let old = self.controller {
            Task { await old.disconnect() }
        }
        self.controller = controller
        self.selectedDeviceID = controller.id
        self.selectedName = name
        self.selectedModel = model
        self.nowPlaying = nil
        self.apps = []
        self.textInput = .inactive
        self.connection = .idle

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
            // A negative level means the output has no volume control.
            if !volumeDragging { volume = level >= 0 ? level : nil }
        }
    }

    // MARK: Volume

    /// True while the user drags the slider. TV reports are ignored then.
    var volumeDragging = false
    private var volumeSendTask: Task<Void, Never>?
    private var pendingVolume: Double?

    /// Sets the level from the slider. Sends at most one request each 60 ms.
    func setVolume(_ level: Double) {
        volume = level
        pendingVolume = level
        guard volumeSendTask == nil else { return }
        volumeSendTask = Task { [weak self] in
            while let self, let next = self.pendingVolume {
                self.pendingVolume = nil
                if let controller = self.controller {
                    try? await controller.setVolume(next)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            self?.volumeSendTask = nil
        }
    }

    func refreshVolume() {
        guard let controller else { return }
        Task {
            if let level = try? await controller.volumeLevel() {
                if !volumeDragging { volume = level }
            }
        }
    }

    // MARK: Power

    /// Wakes a sleeping TV, or puts an awake TV to sleep.
    func togglePower() {
        guard let controller else { return }
        let wasAsleep = power == .asleep
        Task {
            if wasAsleep { await controller.wake() } else { await controller.sleep() }
            try? await Task.sleep(for: .seconds(2))
            refreshPower()
            try? await Task.sleep(for: .seconds(4))
            refreshPower()
        }
    }

    func refreshPower() {
        guard let controller, connection.isConnected else { return }
        Task {
            if let state = try? await controller.powerState() { power = state }
        }
    }

    private var pollTask: Task<Void, Never>?

    /// Polls power and volume while connected. The TV does not push power changes.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard self.connection.isConnected else { continue }
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
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            pressedButtons.remove(button)
        }
    }

    func touch(_ event: TouchEvent) {
        controller?.touch(event)
    }

    func media(_ command: MediaCommand) {
        guard let controller else { return }
        Task {
            do { try await controller.media(command) } catch { lastError = error.localizedDescription }
        }
    }

    func typeText(_ text: String) {
        guard let controller else { return }
        Task {
            do { try await controller.typeText(text) } catch { lastError = error.localizedDescription }
        }
    }

    func clearText() {
        guard let controller else { return }
        Task {
            do { try await controller.clearText() } catch { lastError = error.localizedDescription }
        }
    }

    func loadApps() {
        guard let controller else { return }
        Task {
            do { apps = try await controller.launchableApps() } catch { lastError = error.localizedDescription }
        }
    }

    func launch(_ app: LaunchableApp) {
        guard let controller else { return }
        Task {
            do { try await controller.launch(bundleID: app.bundleID) } catch { lastError = error.localizedDescription }
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
