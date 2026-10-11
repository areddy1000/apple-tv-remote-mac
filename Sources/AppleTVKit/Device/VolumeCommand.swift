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

    /// A helper that stays running, for televisions that are slow to connect.
    ///
    /// The app starts it once and keeps it. It reads one request per line on its standard
    /// input and answers with exactly one line on its standard output. The requests are
    /// `up`, `down`, `set <0-100>` and `get`. An answer is `ok`, a whole number for `get`,
    /// or `err <reason>`. The helper exits when its input closes.
    ///
    /// This field wins over the four above, which stay for simple one-line commands.
    public var daemon: String?

    public init(
        up: String? = nil,
        down: String? = nil,
        set: String? = nil,
        get: String? = nil,
        daemon: String? = nil
    ) {
        self.up = up
        self.down = down
        self.set = set
        self.get = get
        self.daemon = daemon
    }

    /// True when no command is present.
    public var isEmpty: Bool {
        up == nil && down == nil && set == nil && get == nil && daemon == nil
    }

    /// The placeholder `set` replaces with the wanted level.
    public static let levelPlaceholder = "{level}"
}

public enum VolumeCommandError: Error, Sendable {
    case notConfigured
    case failed(status: Int32, output: String)
    case badOutput(String)
    case helperStopped
    case helperRefused(String)
}

/// Carries the watchdog across threads. Cancelling it is safe from any of them.
private final class WatchdogBox: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
}

/// A helper that stays running between requests.
///
/// Opening a connection to a television costs far more than the command itself, so the
/// helper holds one open. `VolumeCommandRunner` owns this and serializes every use.
private final class VolumeHelper: @unchecked Sendable {
    let queue = DispatchQueue(label: "atv.volume.helper", qos: .userInitiated)
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private var buffer = Data()

    init(command: String) throws {
        let toHelper = Pipe()
        let fromHelper = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = FileHandle.nullDevice
        input = toHelper.fileHandleForWriting
        output = fromHelper.fileHandleForReading
        // A helper can exit just before a request. A write to its closed pipe then sends
        // SIGPIPE, which stops the whole app. With this flag the write throws instead.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        try? input.close()
        if process.isRunning { process.terminate() }
    }

    /// Sends one request and returns the one line of answer.
    func ask(_ request: String) throws -> String {
        guard process.isRunning else { throw VolumeCommandError.helperStopped }
        try input.write(contentsOf: Data((request + "\n").utf8))
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let chunk = output.availableData
            if chunk.isEmpty { throw VolumeCommandError.helperStopped }
            buffer.append(chunk)
        }
    }
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

    /// After this many failed requests in a row, the helper pauses before it starts again.
    static let helperFailureLimit = 3
    /// The first pause after the limit. Each later pause doubles, up to `helperMaxPause`.
    private static let helperFirstPause: TimeInterval = 30
    private static let helperMaxPause: TimeInterval = 600

    private let fileURL: URL
    private var cached = VolumeCommand()
    private var modified: Date?
    private var checked = Date.distantPast
    private var helper: VolumeHelper?
    /// Failed helper requests in a row.
    private var helperFailures = 0
    /// The helper does not start again before this time.
    private var helperPausedUntil: Date?
    private var helperPause = VolumeCommandRunner.helperFirstPause

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
        // A changed file may name a different helper, so drop the running one.
        helper?.stop()
        helper = nil
        resetHelperPause()
        cached = decoded
        return cached
    }

    /// Stops the helper. The app calls this when it drops the device.
    public func stop() {
        helper?.stop()
        helper = nil
    }

    /// Sends one request to the long-running helper. Nil when there is none, or it failed.
    /// A helper that died is started again once. A helper that keeps dying pauses.
    private func ask(_ request: String) async -> String? {
        guard let line = command().daemon else { return nil }
        if let until = helperPausedUntil, Date() < until { return nil }
        for attempt in 0..<2 {
            if helper?.isRunning != true {
                helper?.stop()
                helper = try? VolumeHelper(command: line)
            }
            guard let helper else { return nil }
            do {
                let reply = try await Self.send(request, to: helper)
                // The helper answered, so it works, also when it refuses this request.
                resetHelperPause()
                if reply.hasPrefix("err") {
                    ATVLog.input.error("volume helper refused: \(reply, privacy: .public)")
                    return nil
                }
                return reply
            } catch {
                self.helper?.stop()
                self.helper = nil
                if attempt == 1 {
                    ATVLog.input.error("volume helper failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        noteHelperFailure()
        return nil
    }

    /// Counts a failed request. At the limit the helper pauses, and each pause doubles.
    /// A broken helper then costs no new process for each poll and each event.
    private func noteHelperFailure() {
        helperFailures += 1
        guard helperFailures >= Self.helperFailureLimit else { return }
        ATVLog.input.error("volume helper keeps failing, pausing for \(Int(self.helperPause)) s")
        helperPausedUntil = Date().addingTimeInterval(helperPause)
        helperPause = min(helperPause * 2, Self.helperMaxPause)
        helperFailures = 0
    }

    private func resetHelperPause() {
        helperFailures = 0
        helperPausedUntil = nil
        helperPause = Self.helperFirstPause
    }

    /// Runs one exchange on the helper's own thread, and stops a helper that hangs.
    private static func send(_ request: String, to helper: VolumeHelper) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = ResumeOnce(continuation)
            // Stopping the helper closes the pipe, so the blocking read returns.
            let watchdog = WatchdogBox(DispatchWorkItem { helper.stop() })
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog.item)
            helper.queue.async {
                defer { watchdog.item.cancel() }
                do {
                    once.resume(.success(try helper.ask(request)))
                } catch {
                    once.resume(.failure(error))
                }
            }
        }
    }

    public func isConfigured() -> Bool { !command().isEmpty }

    /// True when the hook can report a level, so a slider makes sense.
    public func reportsLevel() -> Bool { command().get != nil || command().daemon != nil }

    /// Runs one step. Returns false when no command is set for that direction.
    @discardableResult
    public func step(up: Bool) async -> Bool {
        if command().daemon != nil { return await ask(up ? "up" : "down") != nil }
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
        let percent = Int((min(1, max(0, level)) * 100).rounded())
        if command().daemon != nil { return await ask("set \(percent)") != nil }
        guard let template = command().set else { return false }
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
        if command().daemon != nil {
            guard let reply = await ask("get"), let percent = Double(reply) else { return nil }
            return min(1, max(0, percent / 100))
        }
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
    ///
    /// The reads and the wait block a thread. They run on a dispatch queue, because a
    /// blocked thread in the shared task pool stalls other tasks.
    private static func run(_ shellCommand: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(shellCommand) })
            }
        }
    }

    private static func runBlocking(_ shellCommand: String) throws -> String {
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
    }
}
