import Foundation

/// A replacement import waits for the cancelled import's rollback and UI cleanup.
/// Otherwise the old task can clear the new progress state or roll back its models.
@MainActor
final class ImportTaskController {
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    var isRunning: Bool { task != nil }

    func start(
        _ operation: @escaping @MainActor () async -> Void,
        onFinished: @escaping @MainActor () -> Void = {}
    ) {
        let previous = task
        previous?.cancel()
        let id = UUID()
        requestID = id
        task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if self.requestID == id {
                    self.task = nil
                    self.requestID = nil
                    onFinished()
                }
            }
            guard !Task.isCancelled, self.requestID == id else { return }
            await operation()
        }
    }

    func cancel() {
        task?.cancel()
    }
}
