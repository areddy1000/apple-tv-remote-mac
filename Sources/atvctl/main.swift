import AppleTVKit
import Foundation

// Command line companion for the Apple TV remote.
// It shares the credential store with the app, so a paired TV needs no new PIN.

let usage = """
usage: atvctl <command> [options]

  discover                    List Apple TVs on the network.
  press <button> [--hold ms]  Press a button: up down left right select menu home
                              volume-up volume-down siri screensaver sleep wake
                              play-pause channel-up channel-down guide page-up page-down
  swipe <up|down|left|right>  Swipe on the touch surface.
  type <text>                 Type into the open text field.
  apps                        List installed apps.
  launch <bundle-id>          Launch an app.
  state                       Print the power state.
  media <play|pause|next|previous|skip-forward|skip-backward>
  forget                      Remove the stored pairing.

options:
  --device <name>             Pick the Apple TV by name. Default: the first one found.
  --wait <seconds>            Discovery time. Default 2.
"""

struct Options {
    var device: String?
    var wait: Double = 2
    var hold: Int = 0
    var pinFile: String?
    var watch: Double = 30
    var positional: [String] = []
}

func parse(_ args: [String]) -> Options {
    var options = Options()
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--device": options.device = iterator.next()
        case "--wait": options.wait = Double(iterator.next() ?? "") ?? 2
        case "--hold": options.hold = Int(iterator.next() ?? "") ?? 0
        case "--pin-file": options.pinFile = iterator.next()
        case "--watch": options.watch = Double(iterator.next() ?? "") ?? 30
        default: options.positional.append(arg)
        }
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
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
    if let name = options.device {
        guard let match = devices.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            fail("No Apple TV named \(name). Found: \(devices.map(\.name).joined(separator: ", "))")
        }
        return match
    }
    return devices[0]
}

/// Connects and waits for the connected state. Reads a PIN from the terminal when needed.
func connect(_ device: DiscoveredDevice) async -> AppleTVDevice {
    let store = CredentialStore()
    try? await store.load()
    let identity = CompanionIdentity.thisMac(clientID: CredentialStore.clientID())
    let controller = AppleTVDevice(device: device, identity: identity, store: store) { title in
        print("\(title). Enter the PIN shown on the TV: ", terminator: "")
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
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

// Line-buffered output so a redirected log shows progress at once.
setvbuf(stdout, nil, _IOLBF, 0)

let options = parse(Array(CommandLine.arguments.dropFirst()))
guard let command = options.positional.first else {
    print(usage)
    exit(64)
}
let arguments = Array(options.positional.dropFirst())

let task = Task {
    do { try await run() } catch { fail("Failed: \(error)") }
    exit(0)
}

func run() async throws {
    switch command {
    case "discover":
        let devices = await discover(wait: options.wait)
        if devices.isEmpty { print("No Apple TV found.") }
        for device in devices {
            print("\(device.name)\t\(device.modelDisplayName)\t\(device.host ?? "?")\ttvOS \(device.osVersion ?? "?")\t\(device.id)")
        }

    case "press":
        guard let name = arguments.first, let button = RemoteButton(commandName: name) else { fail("Unknown button.") }
        let device = await pickDevice(options)
        let controller = await connect(device)
        controller.button(button, down: true)
        if options.hold > 0 { try? await Task.sleep(for: .milliseconds(options.hold)) }
        controller.button(button, down: false)
        try? await Task.sleep(for: .milliseconds(150))
        await controller.disconnect()
        print("pressed \(button.title)")

    case "swipe":
        guard let direction = arguments.first else { fail("Direction missing.") }
        let device = await pickDevice(options)
        let controller = await connect(device)
        let (dx, dy): (Double, Double) = switch direction {
        case "up": (0, -300)
        case "down": (0, 300)
        case "left": (-300, 0)
        case "right": (300, 0)
        default: fail("Unknown direction.")
        }
        controller.touch(TouchEvent(x: 500, y: 500, phase: .press))
        for step in 1...8 {
            let t = Double(step) / 8
            controller.touch(TouchEvent(x: 500 + dx * t, y: 500 + dy * t, phase: .hold))
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.touch(TouchEvent(x: 500 + dx, y: 500 + dy, phase: .release))
        try? await Task.sleep(for: .milliseconds(200))
        await controller.disconnect()
        print("swiped \(direction)")

    case "type":
        let text = arguments.joined(separator: " ")
        let device = await pickDevice(options)
        let controller = await connect(device)
        do {
            try await controller.typeText(text)
            print("typed")
        } catch {
            fail("Type failed: \(error)")
        }
        await controller.disconnect()

    case "apps":
        let device = await pickDevice(options)
        let controller = await connect(device)
        do {
            for app in try await controller.launchableApps() {
                print("\(app.bundleID)\t\(app.name)")
            }
        } catch {
            fail("Apps failed: \(error)")
        }
        await controller.disconnect()

    case "launch":
        guard let bundle = arguments.first else { fail("Bundle id missing.") }
        let device = await pickDevice(options)
        let controller = await connect(device)
        do {
            try await controller.launch(bundleID: bundle)
            print("launched \(bundle)")
        } catch {
            fail("Launch failed: \(error)")
        }
        await controller.disconnect()

    case "state":
        let device = await pickDevice(options)
        let controller = await connect(device)
        for await event in controller.events {
            if case .power(let power) = event {
                print("power: \(power)")
                break
            }
        }
        await controller.disconnect()

    case "media":
        guard let name = arguments.first else { fail("Media command missing.") }
        let mapping: [String: MediaCommand] = [
            "play": .play, "pause": .pause, "toggle": .togglePlayPause, "next": .nextTrack,
            "previous": .previousTrack, "skip-forward": .skipForward, "skip-backward": .skipBackward,
        ]
        guard let mediaCommand = mapping[name] else { fail("Unknown media command.") }
        let device = await pickDevice(options)
        let controller = await connect(device)
        do {
            try await controller.media(mediaCommand)
            print("sent \(name)")
        } catch {
            fail("Media failed: \(error)")
        }
        await controller.disconnect()

    case "volume":
        // Prints the level. With a number 0...100 it sets the level first.
        let device = await pickDevice(options)
        let controller = await connect(device)
        try? await Task.sleep(for: .seconds(1))
        if let text = arguments.first, let percent = Double(text) {
            try await controller.setVolume(percent / 100)
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let level = try await controller.volumeLevel() {
            print("volume: \(Int((level * 100).rounded()))%")
        } else {
            print("volume: not available on this output")
        }
        await controller.disconnect()

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
        // Opens the AirPlay tunnel and prints now-playing updates for 30 seconds.
        // --pin-file <path>: the PIN is read from that file when it appears.
        let device = await pickDevice(options)
        guard let endpoint = device.airplayEndpoint else { fail("No AirPlay service.") }
        let (host, port) = try await DeviceBrowser.resolve(endpoint)
        print("airplay \(host):\(port)")
        let store = CredentialStore()
        try? await store.load()
        let stored = try? await store.device(for: device.id)
        let pinFile = options.pinFile
        let tunnel = AirPlayNowPlaying(host: host, port: port, clientID: CredentialStore.clientID(role: "airplay"), name: (Host.current().localizedName ?? "Mac") + " Now Playing") { title in
            if let pinFile {
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
            print("\(title). Enter the PIN shown on the TV: ", terminator: "")
            return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            let credentials = try await tunnel.connect(credentials: stored?.airplay)
            if stored?.airplay == nil {
                var record = stored ?? StoredDevice(name: device.name)
                record.airplay = credentials
                try? await store.save(record, for: device.id)
                print("airplay paired")
            }
            print("tunnel open")
        } catch {
            fail("AirPlay failed: \(error)")
        }
        let watcher = Task {
            for await info in tunnel.nowPlaying {
                if let info {
                    print("now playing: \(info.title) · \(info.subtitle) · \(info.appName) · \(Int(info.elapsed))/\(Int(info.duration ?? 0)) rate \(info.rate) artwork \(info.artwork?.count ?? 0) bytes")
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
        print(usage)
        exit(64)
    }
}

RunLoop.main.run()
_ = task
