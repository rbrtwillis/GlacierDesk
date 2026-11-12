import Foundation

/// Runs only after explicit user action. This test contacts the macOS-configured Internet endpoint.
enum NetworkCapacityTest {
    static func parse(_ data: Data) throws -> (bitsPerSecond: Double, interface: String) {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let bps = (object?["ul_throughput"] as? NSNumber)?.doubleValue, bps.isFinite, bps > 0 else { throw AWSServiceError.invalidResponse }
        return (bps, object?["interface_name"] as? String ?? "default interface")
    }
    static func run() async throws -> Data {
        let control = NetworkProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let task = Task.detached(priority: .utility) { () throws -> Data in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
                process.arguments = ["-d", "-c", "-M", "30"]
                let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                try process.run(); control.started(process)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw AWSServiceError.commandFailed("The macOS network test did not complete successfully.") }
                return data
            }
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }, onCancel: { control.cancel() })
    }
}
private final class NetworkProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func started(_ process: Process) {
        lock.lock(); self.process = process; let shouldStop = cancelled; lock.unlock()
        if shouldStop, process.isRunning { process.terminate() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let process = self.process; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
}
