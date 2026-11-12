import SwiftUI
import Security

struct UploadSpeedTestView: View {
    let profile: String
    let account: String
    let bucket: String
    let settings: UploadSettings
    @Environment(\.dismiss) private var dismiss
    @State private var sizeMiB = 16
    @State private var confirm = false
    @State private var running = false
    @State private var result: String?
    @State private var progress = 0.0
    @State private var worker: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("S3 upload speed test").font(.title2.weight(.semibold))
            Text("Destination: s3://\(bucket)/glacierdesk-throughput-tests/").textSelection(.enabled)
            Stepper("Test size: \(sizeMiB) MiB", value: $sizeMiB, in: 1...1024).disabled(running)
            Text("The test uploads a new STANDARD object with a unique name. AWS request, storage and transfer charges may apply. GlacierDesk attempts to delete the test object and its version when done. Cleanup requires read and delete permissions; incomplete multipart uploads may still need cleanup. A temporary file of the selected size is created on this Mac.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("This measures the AWS upload operation, including CLI setup; it is not a measurement of your network's maximum capacity.").font(.caption).foregroundStyle(.secondary)
            if running { ProgressView(value: progress) }
            if let result { Text(result).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if running { Button("Cancel test") { worker?.cancel() } }
                Spacer()
                Button("Close") { dismiss() }.disabled(running)
                Button("Review test…") { confirm = true }.disabled(running)
            }
        }.padding(20).frame(width: 580)
        .confirmationDialog("Upload test data to AWS?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Upload \(sizeMiB) MiB test object") { start() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The test creates a billable S3 object in \(bucket), then attempts to delete it. Check the result and inspect incomplete uploads if necessary.") }
    }

    @MainActor private func start() {
        guard !running else { return }
        running = true; progress = 0; result = "Preparing test data…"
        let bytes = sizeMiB * 1_048_576
        let key = "glacierdesk-throughput-tests/\(UUID().uuidString).bin"
        worker = Task {
            defer { running = false; worker = nil }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = AWSService(profile: profile)
            var uploadStarted = false
            do {
                let identity = try await service.identity()
                guard identity.account == account else { throw AWSServiceError.commandFailed("The selected profile now points to a different account.") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("data")
                let generator = Task.detached(priority: .utility) {
                    var block = Data(count: 1_048_576)
                    guard block.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else { throw AWSServiceError.commandFailed("Could not generate test data.") }
                    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AWSServiceError.commandFailed("Could not create test file.") }
                    let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                    for _ in 0..<(bytes / 1_048_576) { try Task.checkCancellation(); try handle.write(contentsOf: block) }
                }
                try await withTaskCancellationHandler(operation: { try await generator.value }, onCancel: { generator.cancel() })
                try Task.checkCancellation()
                result = "Uploading test object…"
                let start = Date()
                uploadStarted = true
                try await service.upload(fileURL: file, bucket: bucket, key: key, settings: settings, progress: { value in Task { @MainActor in progress = value } })
                let seconds = max(0.001, Date().timeIntervalSince(start))
                let rate = ByteCountFormatter.string(fromByteCount: Int64(Double(bytes) / seconds), countStyle: .binary)
                result = "Uploaded in \(String(format: "%.1f", seconds)) s · average \(rate)/s. Cleaning up…"
                do {
                    let metadata = try await service.headObject(bucket: bucket, key: key)
                    try await service.deleteTestObject(bucket: bucket, key: key, versionID: metadata.versionID)
                    result = "Uploaded in \(String(format: "%.1f", seconds)) s · average \(rate)/s. Test object deleted."
                } catch { result = "Uploaded in \(String(format: "%.1f", seconds)) s · average \(rate)/s. Cleanup was not confirmed: \(error.localizedDescription). Inspect s3://\(bucket)/\(key), including object versions." }
            } catch {
                let message = error.localizedDescription
                if uploadStarted {
                    let cleanup = await Task.detached { () -> String in
                        do {
                            let metadata = try await service.headObject(bucket: bucket, key: key)
                            try await service.deleteTestObject(bucket: bucket, key: key, versionID: metadata.versionID)
                            return "The test object was deleted."
                        } catch { return "Object cleanup was not confirmed. Inspect s3://\(bucket)/\(key), including versions." }
                    }.value
                    result = "Test failed or was cancelled: \(message). \(cleanup) Inspect incomplete multipart uploads."
                } else { result = "Test failed before upload: \(message)" }
            }
        }
    }
}
