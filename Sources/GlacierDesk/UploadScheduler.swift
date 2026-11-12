import Foundation

/// State machine for one queue run. Stopping drains active work without scheduling more.
struct UploadScheduler {
    private(set) var next = 0
    private(set) var active = 0
    private(set) var stopping = false
    let total: Int
    let limit: Int

    init(total: Int, limit: Int) {
        self.total = max(0, total); self.limit = max(1, limit)
    }
    mutating func takeNext() -> Int? {
        guard !stopping, active < limit, next < total else { return nil }
        let index = next; next += 1; active += 1
        return index
    }
    mutating func finishOne() { precondition(active > 0); active -= 1 }
    mutating func stop() { stopping = true }
}
