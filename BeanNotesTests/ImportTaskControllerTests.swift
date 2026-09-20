import Foundation
import Testing
@testable import BeanNotes

@MainActor
struct ImportTaskControllerTests {
    @Test func completionCanStartTheNextImport() async {
        let controller = ImportTaskController()
        var events: [Int] = []
        controller.start({ events.append(1) }, onFinished: {
            #expect(!controller.isRunning)
            controller.start { events.append(2) }
        })
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.isRunning, ContinuousClock.now < deadline { await Task.yield() }
        #expect(events == [1, 2])
        #expect(!controller.isRunning)
    }

    @Test func replacementWaitsForRollbackAndRemainsCancellable() async throws {
        let controller = ImportTaskController()
        var events: [String] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        controller.start {
            events.append("first started")
            // Model rollback can outlive cancellation of a file-provider request.
            await withCheckedContinuation { releaseFirst = $0 }
            events.append("first rolled back")
        }
        while releaseFirst == nil { await Task.yield() }

        controller.start {
            events.append("second started")
            do { try await Task.sleep(for: .seconds(30)) }
            catch { events.append("second cancelled") }
        }
        await Task.yield()
        #expect(events == ["first started"])
        releaseFirst?.resume()
        let deadline = ContinuousClock.now + .seconds(2)
        while !events.contains("second started"), ContinuousClock.now < deadline { await Task.yield() }
        #expect(events == ["first started", "first rolled back", "second started"])
        #expect(controller.isRunning)
        controller.cancel()
        while controller.isRunning, ContinuousClock.now < deadline { await Task.yield() }
        #expect(events.last == "second cancelled")
        #expect(!controller.isRunning)
    }

    @Test func cancelledQueuedImportDoesNotStart() async {
        let controller = ImportTaskController()
        var releaseFirst: CheckedContinuation<Void, Never>?
        var secondStarted = false
        controller.start { await withCheckedContinuation { releaseFirst = $0 } }
        while releaseFirst == nil { await Task.yield() }
        controller.start { secondStarted = true }
        controller.cancel()
        releaseFirst?.resume()
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.isRunning, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!secondStarted)
        #expect(!controller.isRunning)
    }
}
