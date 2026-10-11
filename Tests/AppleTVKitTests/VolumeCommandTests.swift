import Foundation
import Testing
@testable import AppleTVKit

@Suite("VolumeCommandTests")
struct VolumeCommandTests {
    /// Makes a folder with a hook file in it, and removes the folder afterwards.
    private func withHook(_ json: String?, _ body: (VolumeCommandRunner, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atv-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if let json {
            try json.write(
                to: directory.appendingPathComponent(VolumeCommandRunner.fileName),
                atomically: true,
                encoding: .utf8
            )
        }
        try await body(VolumeCommandRunner(directory: directory), directory)
    }

    @Test func decodesEveryField() throws {
        let json = #"{"up":"a","down":"b","set":"c {level}","get":"d"}"#
        let command = try JSONDecoder().decode(VolumeCommand.self, from: Data(json.utf8))
        #expect(command.up == "a")
        #expect(command.down == "b")
        #expect(command.set == "c {level}")
        #expect(command.get == "d")
        #expect(!command.isEmpty)
    }

    @Test func decodesAPartialFile() throws {
        let command = try JSONDecoder().decode(VolumeCommand.self, from: Data(#"{"up":"a"}"#.utf8))
        #expect(command.up == "a")
        #expect(command.down == nil)
        #expect(!command.isEmpty)
    }

    @Test func reportsNothingWithoutAFile() async throws {
        try await withHook(nil) { runner, _ in
            #expect(await !runner.isConfigured())
            #expect(await !runner.reportsLevel())
            #expect(await runner.level() == nil)
            #expect(await !runner.step(up: true))
            #expect(await !runner.setLevel(0.5))
        }
    }

    @Test func ignoresABrokenFile() async throws {
        try await withHook("this is not json") { runner, _ in
            #expect(await !runner.isConfigured())
        }
    }

    @Test func readsTheLevelFromTheCommandOutput() async throws {
        try await withHook(#"{"get":"echo 42"}"#) { runner, _ in
            #expect(await runner.reportsLevel())
            let level = try #require(await runner.level())
            #expect(abs(level - 0.42) < 0.0001)
        }
    }

    @Test func clampsAndRejectsBadOutput() async throws {
        try await withHook(#"{"get":"echo 140"}"#) { runner, _ in
            #expect(await runner.level() == 1)
        }
        try await withHook(#"{"get":"echo hello"}"#) { runner, _ in
            #expect(await runner.level() == nil)
        }
    }

    @Test func runsTheStepCommand() async throws {
        try await withHook(nil) { _, directory in
            let marker = directory.appendingPathComponent("step.txt")
            let json = #"{"up":"echo up > '\#(marker.path)'","down":"echo down > '\#(marker.path)'"}"#
            try json.write(
                to: directory.appendingPathComponent(VolumeCommandRunner.fileName),
                atomically: true,
                encoding: .utf8
            )
            let runner = VolumeCommandRunner(directory: directory)
            #expect(await runner.step(up: true))
            #expect(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "up")
            #expect(await runner.step(up: false))
            #expect(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "down")
        }
    }

    @Test func putsTheLevelIntoTheSetCommand() async throws {
        try await withHook(nil) { _, directory in
            let marker = directory.appendingPathComponent("set.txt")
            let json = #"{"set":"echo {level} > '\#(marker.path)'"}"#
            try json.write(
                to: directory.appendingPathComponent(VolumeCommandRunner.fileName),
                atomically: true,
                encoding: .utf8
            )
            let runner = VolumeCommandRunner(directory: directory)
            #expect(await runner.setLevel(0.37))
            #expect(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "37")
        }
    }

    /// A shell loop stands in for a real helper. It answers one line per request.
    private static let shellHelper =
        "while read request; do case \\\"$request\\\" in "
        + "get) echo 55;; set*) echo ok;; up|down) echo ok;; *) echo 'err what';; esac; done"

    @Test func usesALongRunningHelper() async throws {
        try await withHook(#"{"daemon":"\#(Self.shellHelper)"}"#) { runner, _ in
            #expect(await runner.isConfigured())
            #expect(await runner.reportsLevel())
            let level = try #require(await runner.level())
            #expect(abs(level - 0.55) < 0.0001)
            #expect(await runner.step(up: true))
            #expect(await runner.step(up: false))
            #expect(await runner.setLevel(0.2))
            // The same helper serves every request, so it still answers.
            #expect(await runner.level() != nil)
            await runner.stop()
        }
    }

    @Test func treatsAnErrorAnswerAsAFailure() async throws {
        let helper = "while read request; do echo 'err nope'; done"
        try await withHook(#"{"daemon":"\#(helper)"}"#) { runner, _ in
            #expect(await !runner.step(up: true))
            #expect(await runner.level() == nil)
            await runner.stop()
        }
    }

    @Test func startsTheHelperAgainAfterItExits() async throws {
        // This helper answers one request and then leaves.
        let helper = "read request; echo 55"
        try await withHook(#"{"daemon":"\#(helper)"}"#) { runner, _ in
            #expect(await runner.level() != nil)
            #expect(await runner.level() != nil)
            await runner.stop()
        }
    }

    @Test func reportsAFailedCommandWithoutThrowing() async throws {
        try await withHook(#"{"up":"exit 3","get":"exit 3"}"#) { runner, _ in
            #expect(await !runner.step(up: true))
            #expect(await runner.level() == nil)
        }
    }

    /// A helper that dies at every request must not start again for each request.
    @Test func pausesAHelperThatKeepsDying() async throws {
        try await withHook(nil) { _, directory in
            let marker = directory.appendingPathComponent("starts.txt")
            // The helper notes each start, reads the request, and leaves with no answer.
            let helper = "echo start >> '\(marker.path)'; read request; exit 1"
            let json = #"{"daemon":"\#(helper)"}"#
            try json.write(
                to: directory.appendingPathComponent(VolumeCommandRunner.fileName),
                atomically: true,
                encoding: .utf8
            )
            let runner = VolumeCommandRunner(directory: directory)
            for _ in 0..<6 {
                #expect(await runner.level() == nil)
            }
            let starts = try String(contentsOf: marker, encoding: .utf8)
                .split(separator: "\n").count
            // Each request starts the helper at most twice, and the runner stops after
            // three failed requests in a row.
            #expect(starts == 2 * VolumeCommandRunner.helperFailureLimit)
            await runner.stop()
        }
    }
}
