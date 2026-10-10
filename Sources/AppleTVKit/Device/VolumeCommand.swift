import Foundation

/// Commands that change the television's volume.
///
/// Some televisions give the Apple TV no volume route of its own. The Apple TV then falls
/// back to infrared, which leaves from the physical remote, and no network client can reach
/// it. This hook lets the app run a command of yours instead, so any television with a
/// network control tool works. The app reads it from `volume-command.json` in its
/// Application Support folder.
///
/// Each field holds one shell command. Every field is optional:
/// - `up` and `down` run for one step of the volume keys.
/// - `set` runs when you drag the slider. `{level}` becomes a whole number, 0 to 100.
/// - `get` prints the level as a whole number, 0 to 100. The slider needs it.
public struct VolumeCommand: Codable, Sendable, Equatable {
    public var up: String?
    public var down: String?
    public var set: String?
    public var get: String?

    public init(up: String? = nil, down: String? = nil, set: String? = nil, get: String? = nil) {
        self.up = up
        self.down = down
        self.set = set
        self.get = get
    }

    /// True when no command is present.
    public var isEmpty: Bool {
        up == nil && down == nil && set == nil && get == nil
    }

    /// The placeholder `set` replaces with the wanted level.
    public static let levelPlaceholder = "{level}"
}

public enum VolumeCommandError: Error, Sendable {
    case notConfigured
    case failed(status: Int32, output: String)
    case badOutput(String)
}

/// Loads the volume hook and runs it.
///
/// The file is yours and the app runs it with your own account, the same trust as a shell
/// alias. The app never writes the file.
public actor VolumeCommandRunner {
    public static let fileName = "volume-command.json"
    /// A command that runs longer than this is stopped. Volume must feel instant.
    private static let timeout: Double = 5
    /// The file is checked for changes no more than once per this many seconds.
    private static let recheckInterval: TimeInterval = 1

    private let fileURL: URL
    private var cached = VolumeCommand()
    private var modified: Date?
    private var checked = Date.distantPast

    public init(directory: URL? = nil) {
        let base = directory ?? CredentialStore.defaultDirectory()
        fileURL = base.appendingPathComponent(Self.fileName)
    }

    /// The current commands. The file is re-read after it changes on disk.
    public func command() -> VolumeCommand {
        let now = Date()
        if now.timeIntervalSince(checked) < Self.recheckInterval { return cached }
        checked = now
        let stamp = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard stamp != modified else { return cached }
        modified = stamp
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(VolumeCommand.self, from: data)
        else {
            cached = VolumeCommand()
            return cached
        }
        ATVLog.input.info("volume hook loaded")
        cached = decoded
        return cached
    }

    public func isConfigured() -> Bool { !command().isEmpty }

    /// True when the hook can report a level, so a slider makes sense.
    public func reportsLevel() -> Bool { command().get != nil }

    /// Runs one step. Returns false when no command is set for that direction.
    @discardableResult
    public func step(up: Bool) async -> Bool {
        guard let line = up ? command().up : command().down else { return false }
        do {
            _ = try await Self.run(line)
            return true
        } catch {
            ATVLog.input.error("volume hook failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Sets the level as 0...1. Returns false when no `set` command is present.
    @discardableResult
    public func setLevel(_ level: Double) async -> Bool {
        guard let template = command().set else { return false }
        let percent = Int((min(1, max(0, level)) * 100).rounded())
        let line = template.replacingOccurrences(of: VolumeCommand.levelPlaceholder, with: String(percent))
        do {
            _ = try await Self.run(line)
            return true
        } catch {
            ATVLog.input.error("volume hook failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Reads the level as 0...1, or nil when no `get` command is present or it fails.
    public func level() async -> Double? {
        guard let line = command().get else { return nil }
        do {
            let output = try await Self.run(line)
            let digits = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let percent = Double(digits) else { throw VolumeCommandError.badOutput(digits) }
            return min(1, max(0, percent / 100))
        } catch {
            ATVLog.input.error("volume hook failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Carries the process to the watchdog. `terminate()` is safe from another thread.
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    /// Runs one shell command and returns what it printed.
    private static func run(_ shellCommand: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) { () throws -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", shellCommand]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            try process.run()

            // Stop a command that hangs. The pipe then closes and the read below returns.
            let box = ProcessBox(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) {
                if box.process.isRunning { box.process.terminate() }
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let problem = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let text = String(decoding: problem, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw VolumeCommandError.failed(status: process.terminationStatus, output: text)
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
