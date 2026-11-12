import XCTest
@testable import GlacierDesk

final class UploadSchedulerTests: XCTestCase {
    func testStopDrainsActiveWorkAndResumeStartsOnlyRemaining() {
        var run = UploadScheduler(total: 5, limit: 2)
        XCTAssertEqual(run.takeNext(), 0); XCTAssertEqual(run.takeNext(), 1)
        XCTAssertNil(run.takeNext())
        run.finishOne(); XCTAssertEqual(run.takeNext(), 2)
        run.stop()
        run.finishOne(); XCTAssertNil(run.takeNext())
        run.finishOne(); XCTAssertEqual(run.active, 0)
        XCTAssertEqual(run.next, 3)
        var resumed = UploadScheduler(total: 2, limit: 2)
        XCTAssertEqual(resumed.takeNext(), 0); XCTAssertEqual(resumed.takeNext(), 1)
        XCTAssertNil(resumed.takeNext())
    }
    func testFailedRunCanStopBeforeSchedulingFurtherItems() {
        var run = UploadScheduler(total: 10, limit: 3)
        XCTAssertEqual([run.takeNext(), run.takeNext(), run.takeNext()], [0, 1, 2])
        run.finishOne(); run.stop()
        XCTAssertNil(run.takeNext())
        run.finishOne(); run.finishOne()
        XCTAssertEqual(run.active, 0); XCTAssertEqual(run.next, 3)
    }
}

private actor SimulatedUploads {
    private var started: [Int] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var ready: CheckedContinuation<Void, Never>?
    private var stopped = false
    func upload(_ index: Int) async {
        started.append(index)
        if started.count == 2 { ready?.resume(); ready = nil }
        await withCheckedContinuation { pending.append($0) }
    }
    func waitForTwo() async {
        if started.count >= 2 { return }
        await withCheckedContinuation { ready = $0 }
    }
    func stopAndRelease() {
        stopped = true
        let continuations = pending; pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
    func shouldStop() -> Bool { stopped }
    func startedItems() -> [Int] { started.sorted() }
}

extension UploadSchedulerTests {
    func testConcurrentStopDrainsActiveAndPreservesPendingForResume() async {
        let probe = SimulatedUploads()
        let run = Task { () -> Int in
            var scheduler = UploadScheduler(total: 6, limit: 2)
            await withTaskGroup(of: Void.self) { group in
                while let index = scheduler.takeNext() { group.addTask { await probe.upload(index) } }
                while await group.next() != nil {
                    scheduler.finishOne()
                    if await probe.shouldStop() { scheduler.stop() }
                    if let index = scheduler.takeNext() { group.addTask { await probe.upload(index) } }
                }
            }
            return scheduler.next
        }
        await probe.waitForTwo()
        await probe.stopAndRelease()
        let next = await run.value
        let started = await probe.startedItems()
        XCTAssertEqual(started, [0, 1]); XCTAssertEqual(next, 2)
        var resume = UploadScheduler(total: 6 - next, limit: 2)
        XCTAssertEqual(resume.takeNext(), 0); XCTAssertEqual(resume.takeNext(), 1)
    }
    func testConcurrentStopKeepsDurablePendingForRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.sqlite")
        let queue = try DurableTransferQueue(fileURL: url)
        let items = (0..<6).map { DurableTransferItem(sourcePath: "file\($0)", sourceBookmark: Data(), target: "file\($0)") }
        let session = DurableTransferSession(kind: .legacyArchiveUpload, accountID: "a", profile: "p", destination: "v", vault: "v", region: "r", items: items)
        try await queue.add(session)
        let probe = SimulatedUploads()
        let run = Task {
            var scheduler = UploadScheduler(total: items.count, limit: 2)
            await withTaskGroup(of: Void.self) { group in
                func schedule(_ index: Int) {
                    group.addTask {
                        guard (try? await queue.claimLegacyItem(sessionID: session.id, itemID: items[index].id)) == true else { return }
                        await probe.upload(index)
                        try? await queue.updateItem(sessionID: session.id, itemID: items[index].id, state: .completed)
                    }
                }
                while let index = scheduler.takeNext() { schedule(index) }
                while await group.next() != nil {
                    scheduler.finishOne()
                    if await probe.shouldStop() { scheduler.stop() }
                    if let index = scheduler.takeNext() { schedule(index) }
                }
            }
        }
        await probe.waitForTwo(); await probe.stopAndRelease(); await run.value
        let reopened = try DurableTransferQueue(fileURL: url)
        let sessions = try await reopened.allSessions()
        XCTAssertEqual(sessions[0].items.filter { $0.state == .completed }.count, 2)
        let resume = try await reopened.retryableItems(sessionID: session.id, selectedProfile: "p", currentAccountID: "a")
        XCTAssertEqual(resume.count, 4)
        XCTAssertTrue(resume.allSatisfy { $0.state == .queued })
    }
}
