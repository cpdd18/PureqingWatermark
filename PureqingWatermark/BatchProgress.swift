import Foundation
import Combine

/// UI progress and the lifetime of one batch worker. Cancellation is cooperative:
/// a file already encoded successfully remains available to save.
@MainActor
final class PWMBatchProgress: ObservableObject {
    @Published private(set) var processed = 0
    @Published private(set) var total = 0
    @Published private(set) var succeeded = 0
    @Published private(set) var title = ""
    @Published private(set) var cancellationRequested = false
    @Published private(set) var isRunning = false
    private var worker: Task<[URL], Never>?

    func begin(title: String, total: Int) {
        self.title = title
        self.total = total
        processed = 0
        succeeded = 0
        cancellationRequested = false
        isRunning = true
    }

    func attach(_ task: Task<[URL], Never>) {
        worker = task
        if cancellationRequested { task.cancel() }
    }

    func advance(processed: Int, succeeded: Int) {
        self.processed = min(processed, total)
        self.succeeded = succeeded
    }

    func cancel() {
        guard isRunning else { return }
        cancellationRequested = true
        worker?.cancel()
    }

    func finish() {
        worker = nil
        isRunning = false
    }
}
