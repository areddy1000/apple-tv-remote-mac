import AppleTVKit
import Foundation

// Command line companion for the Apple TV remote.
// It shares the credential store with the app, so a paired TV needs no new PIN.
// Exit codes: 0 success, 1 failure, 64 usage error.

let usage = """
usage: atvctl <command> [options]

commands:
  discover                    List the Apple TVs on the network.
  press <button> [--hold ms]  Press a button. Names: up down left right select menu home
                              volume-up volume-down siri screensaver sleep wake play-pause
                              channel-up channel-down guide page-up page-down
  swipe <up|down|left|right>  Swipe on the touch surface.
  type <text>                 Type into the open text field.
  apps                        List the installed apps.
  launch <bundle-id>          Launch an app.
  media <command>             play pause toggle next previous skip-forward skip-backward
  state                       Print the power state.
  volume [0-100]              Print the volume. With a number, set it first.
  now-playing [--watch s]     Open the now-playing link and print updates.
  resolve                     Print the resolved addresses of the TV. A diagnostic.
  forget                      Remove the stored pairing for the TV.

options:
  --device <name>             Pick the Apple TV by name. Default: the first one found.
  --wait <seconds>            Discovery time before a command runs. Default 2.
  --hold <ms>                 Hold time for press. Default 0.
  --watch <seconds>           How long now-playing listens. Default 30.
  --seek <seconds>            With now-playing: move playback to this position first.
  --pin-file <path>           Read the PIN from this file instead of the terminal.
"""

struct Options {
    var device: String?
    var wait: Double = 2
    var hold: Int = 0
    var watch: Double = 30
    var pinFile: String?
    var seek: Double?
    var positional: [String] = []

    static func parse(_ args: [String]) -> Options {
        var options = Options()
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--device": options.device = iterator.next()
            case "--wait": options.wait = Double(iterator.next() ?? "") ?? options.wait
            case "--hold": options.hold = Int(iterator.next() ?? "") ?? options.hold
            case "--watch": options.watch = Double(iterator.next() ?? "") ?? options.watch
            case "--pin-file": options.pinFile = iterator.next()
            case "--seek": options.seek = Double(iterator.next() ?? "")
            default: options.positional.append(arg)
            }
        }
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func usageError() -> Never {
    print(usage)
    exit(64)
}

func discover(wait: Double) async -> [DiscoveredDevice] {
    let browser = DeviceBrowser()
    await browser.start()
    try? await Task.sleep(for: .seconds(wait))
    let devices = await browser.current
    await browser.stop()
    return devices
}

func pickDevice(_ options: Options) async -> DiscoveredDevice {
    let devices = await discover(wait: options.wait)
    guard !devices.isEmpty else { fail("No Apple TV found.") }
    guard let name = options.device else { return devices[0] }
    guard let match = devices.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
        fail("No Apple TV named \(name). Found: \(devices.map(\.name).joined(separator: ", "))")
    }
    return match
}

/// Asks for the PIN on the terminal, or waits for a file to hold it.
func readPIN(title: String, pinFile: String?) async -> String? {
    guard let pinFile else {
        print("\(title). Enter the PIN shown on the TV: ", terminator: "")
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    print("\(title). Waiting for the PIN in \(pinFile)")
    for _ in 0..<120 {
        if let text = try? String(contentsOfFile: pinFile, encoding: .utf8) {
            let pin = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if pin.count == 4 { return pin }
        }
        try? await Task.sleep(for: .seconds(1))
    }
    return nil
}

/// Connects over Companion Link and returns when the TV accepts the session.
func connect(_ device: DiscoveredDevice, options: Options) async -> AppleTVDevice {
    let store = CredentialStore()
    try? await store.load()
    let identity = CompanionIdentity.thisMac(clientID: CredentialStore.clientID())
    let controller = AppleTVDevice(device: device, identity: identity, store: store) { title in
        await readPIN(title: title, pinFile: options.pinFile)
    }
    await controller.connect()
    let deadline = ContinuousClock.now + .seconds(60)
    for await event in controller.events {
        if case .connection(let state) = event {
            switch state {
            case .connected: return controller
            case .failed(let message): fail("Connection failed: \(message)")
            case .idle: fail("Pairing cancelled.")
            default: break
            }
        }
        if ContinuousClock.now > deadline { fail("Timed out.") }
    }
    fail("Connection closed.")
}

/// Runs one action on a connected TV, then disconnects.
func withTV(_ options: Options, _ action: (AppleTVDevice) async throws -> Void) async throws {
    let device = await pickDevice(options)
    let controller = await connect(device, options: options)
    defer { Task { await controller.disconnect() } }
    try await action(controller)
    // Give the last frame time to leave the socket.
    try? await Task.sleep(for: .milliseconds(150))
}

func run(_ command: String, _ arguments: [String], _ options: Options) async throws {
    switch command {
    case "discover":
        let devices = await discover(wait: options.wait)
        if devices.isEmpty { print("No Apple TV found.") }
        for device in devices {
            print("\(device.name)\t\(device.modelDisplayName)\ttvOS \(device.osVersion ?? "?")\t\(device.id)")
        }

    case "press":
        guard let name = arguments.first, let button = RemoteButton(commandName: name) else { usageError() }
        try await withTV(options) { controller in
            controller.button(button, down: true)
            if options.hold > 0 { try? await Task.sleep(for: .milliseconds(options.hold)) }
            controller.button(button, down: false)
            print("pressed \(button.title)")
        }

    case "swipe":
        let travel: (Double, Double)
        switch arguments.first {
        case "up": travel = (0, -300)
        case "down": travel = (0, 300)
        case "left": travel = (-300, 0)
        case "right": travel = (300, 0)
        default: usageError()
        }
        try await withTV(options) { controller in
            controller.touch(TouchEvent(x: 500, y: 500, phase: .press))
            for step in 1...8 {
                let t = Double(step) / 8
                controller.touch(TouchEvent(x: 500 + travel.0 * t, y: 500 + travel.1 * t, phase: .hold))
                try? await Task.sleep(for: .milliseconds(20))
            }
            controller.touch(TouchEvent(x: 500 + travel.0, y: 500 + travel.1, phase: .release))
            print("swiped \(arguments[0])")
        }

    case "type":
        guard !arguments.isEmpty else { usageError() }
        let text = arguments.joined(separator: " ")
        try await withTV(options) { controller in
            try await controller.typeText(text)
            print("typed")
        }

    case "apps":
        try await withTV(options) { controller in
            for app in try await controller.launchableApps() {
                print("\(app.bundleID)\t\(app.name)")
            }
        }

    case "launch":
        guard let bundle = arguments.first else { usageError() }
        try await withTV(options) { controller in
            try await controller.launch(bundleID: bundle)
            print("launched \(bundle)")
        }

    case "media":
        guard let name = arguments.first, let mediaCommand = MediaCommand(commandName: name) else { usageError() }
        try await withTV(options) { controller in
            try await controller.media(mediaCommand)
            print("sent \(name)")
        }

    case "state":
        try await withTV(options) { controller in
            print("power: \(try await controller.powerState())")
        }

    case "volume":
        try await withTV(options) { controller in
            if let text = arguments.first {
                guard let percent = Double(text), (0...100).contains(percent) else { usageError() }
                try await controller.setVolume(percent / 100)
                try? await Task.sleep(for: .milliseconds(300))
            }
            if let level = try await controller.volumeLevel() {
                print("volume: \(Int((level * 100).rounded()))%")
            } else {
                print("volume: not available on this output")
            }
        }

    case "resolve":
        let device = await pickDevice(options)
        for (label, endpoint) in [("companion", device.companionEndpoint), ("airplay", device.airplayEndpoint)] {
            guard let endpoint else { print("\(label): none"); continue }
            do {
                let (host, port) = try await DeviceBrowser.resolve(endpoint)
                print("\(label): \(host):\(port)")
            } catch {
                print("\(label): failed \(error)")
            }
        }

    case "now-playing":
        let device = await pickDevice(options)
        guard let endpoint = device.airplayEndpoint else { fail("No AirPlay service.") }
        let (host, port) = try await DeviceBrowser.resolve(endpoint)
        let store = CredentialStore()
        try? await store.load()
        let stored = try? await store.device(for: device.id)
        guard let record = stored?.companion else { fail("Not paired yet. Run `atvctl press menu` first.") }
        let identity = CompanionIdentity.thisMac(clientID: CredentialStore.clientID())
        let tunnel = AirPlayNowPlaying(
            host: host,
            port: port,
            clientID: identity.clientID,
            name: identity.name,
            deviceAddress: identity.deviceAddress
        )
        try await tunnel.connect(credentials: record)
        if let seek = options.seek {
            try await tunnel.seek(to: seek)
            print("seek to \(Int(seek)) s sent")
        }
        print("listening for \(Int(options.watch)) s")
        let watcher = Task {
            for await info in tunnel.nowPlaying {
                if let info {
                    let position = "\(Int(info.elapsed))/\(Int(info.duration ?? 0)) s"
                    print("now playing: \(info.title) · \(info.subtitle) · \(info.appName) · \(position) · rate \(info.rate) · artwork \(info.artwork?.count ?? 0) bytes")
                } else {
                    print("nothing playing")
                }
            }
        }
        try? await Task.sleep(for: .seconds(options.watch))
        watcher.cancel()
        await tunnel.close()

    case "forget":
        let device = await pickDevice(options)
        let store = CredentialStore()
        try? await store.load()
        try? await store.remove(for: device.id)
        print("forgot \(device.name)")

    default:
        usageError()
    }
}

// Line-buffered output so a redirected log shows progress at once.
setvbuf(stdout, nil, _IOLBF, 0)

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
guard let command = options.positional.first else { usageError() }
let arguments = Array(options.positional.dropFirst())

Task {
    do {
        try await run(command, arguments, options)
    } catch {
        fail("Failed: \(error)")
    }
    exit(0)
}

RunLoop.main.run()
