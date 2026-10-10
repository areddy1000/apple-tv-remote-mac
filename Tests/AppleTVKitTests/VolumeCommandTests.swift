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

    @Test func reportsAFailedCommandWithoutThrowing() async throws {
        try await withHook(#"{"up":"exit 3","get":"exit 3"}"#) { runner, _ in
            #expect(await !runner.step(up: true))
            #expect(await runner.level() == nil)
        }
    }
}
