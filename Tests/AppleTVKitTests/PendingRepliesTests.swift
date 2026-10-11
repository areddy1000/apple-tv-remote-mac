import Foundation
import Testing
@testable import AppleTVKit

/// A request that gets its reply must not leave a sleeping timer behind.
@Suite("PendingRepliesTests")
struct PendingRepliesTests {
    private static func longTimer() -> Task<Void, Never> {
        Task { try? await Task.sleep(for: .seconds(60)) }
    }

    @Test func aReplyStopsTheTimer() async throws {
        let timer = Self.longTimer()
        var replies = PendingReplies<Int, String>()
        let value = try await withCheckedThrowingContinuation { continuation in
            replies.add(1, continuation: continuation, timer: timer)
            let found = replies.resolve(1, with: .success("ok"))
            #expect(found)
        }
        #expect(value == "ok")
        #expect(timer.isCancelled)
        #expect(replies.isEmpty)
    }

    @Test func anUnknownKeyChangesNothing() async throws {
        let timer = Self.longTimer()
        var replies = PendingReplies<Int, String>()
        let value = try await withCheckedThrowingContinuation { continuation in
            replies.add(1, continuation: continuation, timer: timer)
            let found = replies.resolve(2, with: .success("wrong"))
            #expect(!found)
            #expect(!timer.isCancelled)
            replies.resolve(1, with: .success("right"))
        }
        #expect(value == "right")
    }

    /// Holds the table, so two requests can wait at the same time.
    private actor Table {
        var replies = PendingReplies<Int, String>()

        func wait(_ key: Int, timer: Task<Void, Never>) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                replies.add(key, continuation: continuation, timer: timer)
            }
        }

        func count() -> Int { replies.count }

        func answerOldest(_ value: String) {
            guard let key = replies.oldestKey else { return }
            replies.resolve(key, with: .success(value))
        }
    }

    @Test func theOldestRequestGetsTheFirstReply() async throws {
        let table = Table()
        let first = Task { try await table.wait(1, timer: Self.longTimer()) }
        while await table.count() < 1 { await Task.yield() }
        let second = Task { try await table.wait(2, timer: Self.longTimer()) }
        while await table.count() < 2 { await Task.yield() }
        await table.answerOldest("one")
        await table.answerOldest("two")
        #expect(try await first.value == "one")
        #expect(try await second.value == "two")
    }

    @Test func failAllStopsEveryTimer() async {
        let timer = Self.longTimer()
        var replies = PendingReplies<Int, String>()
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                replies.add(1, continuation: continuation, timer: timer)
                replies.failAll(CompanionError.notConnected)
            }
            Issue.record("the request must fail")
        } catch {
            #expect(error as? CompanionError == .notConnected)
        }
        #expect(timer.isCancelled)
        #expect(replies.isEmpty)
    }
}
