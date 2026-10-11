import AppleTVKit
import Foundation
import Observation
import SwiftUI

/// What the status card says when nothing plays.
///
/// Every case is a complete rest state. The menu bar panel shows one of them at all times,
/// so it never leaves a hole where the user expects to read something.
enum PanelStatus: Equatable {
    case idle
    case busy(String)
    case needsPairing
    case asleep
    case nothingPlaying
    case problem(String)
}

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
    /// True after the app has asked this Apple TV for a level one time.
    /// It keeps the no-volume notice away until the first answer arrives.
    private(set) var volumeChecked = false
    /// The last failure, shown under the remote. It clears by itself after a few seconds,
    /// and a click clears it at once.
    var lastError: String? {
        didSet { scheduleErrorClear() }
    }
    private var errorClearTask: Task<Void, Never>?
    private static let errorDisplayTime: Duration = .seconds(8)

    private func scheduleErrorClear() {
        errorClearTask?.cancel()
        guard lastError != nil else { return }
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.errorDisplayTime)
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    // MARK: Pairing

    var pinEntry = ""
    var pairingTitle = ""

    // MARK: UI state

    var pressedButtons: Set<RemoteButton> = []
    var paletteVisible = false
    var keyboardVisible = false
    /// True while the user drags the volume slider. TV reports are ignored then.
    var volumeDragging = false
    /// True after the user asks for something while no link is up. Until then the panel
    /// stays calm and shows no pairing prompt or error. Closing the panel clears it.
    var connectionRequested = false

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
        volumeChecked = false
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
                connectionRequested = false
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
            volumeChecked = true
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
            let level = try? await controller.volumeLevel()
            guard let self, !self.volumeDragging else { return }
            self.volumeChecked = true
            // A read that failed keeps the last level. Only a real answer moves the slider.
            if let level { self.volume = level }
        }
    }

    /// True when this Apple TV gives the app no way to change the volume.
    ///
    /// The app asked and got no level. A sleeping Apple TV answers nothing either, so it
    /// does not count.
    var volumeUnavailable: Bool {
        connection.isConnected && power != .asleep && volumeChecked && volume == nil
    }

    /// The rest state the status card shows. Highest trouble first.
    var status: PanelStatus {
        // Without a link, the panel stays calm until the user asks for something.
        if !connection.isConnected, !connection.isBusy, !connectionRequested { return .idle }
        if connection == .needsPairing { return .needsPairing }
        if case .failed(let message) = connection { return .problem(message) }
        if let error = lastError, !connection.isConnected { return .problem(error) }
        if connection.isBusy { return .busy(connection.label) }
        if connection == .idle { return .idle }
        if power == .asleep { return .asleep }
        if let error = lastError { return .problem(error) }
        return .nothingPlaying
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

    /// Called by each user action. Without a link, it shows what is wrong and tries to connect.
    /// A missing pairing only shows the Pair button, because a PIN turns the television on.
    func requestConnection() {
        guard !connection.isConnected else { return }
        connectionRequested = true
        guard connection != .needsPairing, !connection.isBusy, let controller else { return }
        Task { await controller.connect() }
    }

    /// Sends a button down and marks it pressed. The socket write happens on the controller.
    func buttonDown(_ button: RemoteButton) {
        requestConnection()
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
        requestConnection()
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
        requestConnection()
        controller?.touch(event)
    }

    func media(_ command: MediaCommand) {
        perform { try await $0.media(command) }
    }

    /// Seeks to `seconds`. The bar moves at once; the TV confirms a moment later.
    func seek(to seconds: Double) {
        if var info = nowPlaying {
            info.elapsed = seconds
            info.elapsedAt = .now
            nowPlaying = info
        }
        perform { try await $0.seek(to: seconds) }
    }

    func typeText(_ text: String) {
        perform { try await $0.typeText(text) }
    }

    func clearText() {
        perform { try await $0.clearText() }
    }

    func loadApps() {
        requestConnection()
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
        requestConnection()
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
        case .needsPairing: connectionRequested ? .orange : Tokens.inkTertiary
        case .connecting, .reconnecting, .pairing, .awaitingPIN: .orange
        case .failed: connectionRequested ? Tokens.danger : Tokens.inkTertiary
        case .idle: Tokens.inkTertiary
        }
    }
}
