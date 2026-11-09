import Foundation

/// Small AWS CLI adapter for the first GlacierDesk browsing and transfer flows.
/// Every AWS command is pinned to an explicitly selected shared AWS profile.
public struct AWSService: Sendable {
    public let profile: String
    private let executableURL: URL

    public init(profile: String) {
        self.profile = profile
        self.executableURL = Self.findAWSCLI()
    }

    public init(profile: String, executableURL: URL) {
        self.profile = profile
        self.executableURL = executableURL
    }

    private static func findAWSCLI() -> URL {
        let candidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent("aws").path
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // Keep a useful launch error if the CLI is installed somewhere nonstandard.
        return URL(fileURLWithPath: "/opt/homebrew/bin/aws")
    }

    public func listProfiles() async throws -> [String] {
        let result = try await run(["configure", "list-profiles"])
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    public func identity() async throws -> AWSIdentity {
        let data = try await json(["sts", "get-caller-identity"])
        return try Self.decoder().decode(AWSIdentity.self, from: data)
    }

    public func listBuckets() async throws -> [AWSBucket] {
        let data = try await json(["s3api", "list-buckets"])
        return try Self.decoder().decode(BucketResponse.self, from: data).buckets ?? []
    }

    /// Fetches one S3 page. Pass `nextContinuationToken` from the prior result to continue.
    public func listObjects(bucket: String, prefix: String? = nil,
                            continuationToken: String? = nil, maxKeys: Int = 1000) async throws -> AWSObjectPage {
        var args = ["s3api", "list-objects-v2", "--bucket", bucket, "--delimiter", "/",
                    "--max-keys", String(max(1, min(maxKeys, 1000))), "--no-paginate"]
        if let prefix { args += ["--prefix", prefix] }
        if let continuationToken { args += ["--continuation-token", continuationToken] }
        let data = try await json(args)
        return try Self.decoder().decode(AWSObjectPage.self, from: data)
    }

    public func headObject(bucket: String, key: String) async throws -> AWSObjectMetadata {
        let data = try await json(["s3api", "head-object", "--bucket", bucket, "--key", key])
        return try Self.decoder().decode(AWSObjectMetadata.self, from: data)
    }

    public func upload(fileURL: URL, bucket: String, key: String,
                       storageClass: String = "STANDARD", settings: UploadSettings = .init(), progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try settings.validate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        let original = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/config")
        if FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.copyItem(at: original, to: config)
        } else {
            try Data().write(to: config, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let overrides = ["AWS_CONFIG_FILE": config.path]
        for (name, value) in [("multipart_threshold", settings.thresholdMiB), ("multipart_chunksize", settings.partSizeMiB), ("max_concurrent_requests", settings.connections)] {
            let configured = name == "max_concurrent_requests" ? "\(value)" : "\(value * 1_048_576)"
            _ = try await run(["configure", "set", "s3.\(name)", configured, "--profile", profile], environmentOverrides: overrides)
        }
        // The CRT transfer client can ignore these settings; force the classic client.
        _ = try await run(["configure", "set", "s3.preferred_transfer_client", "classic", "--profile", profile], environmentOverrides: overrides)
        _ = try await run(["s3", "cp", fileURL.path, "s3://\(bucket)/\(key)",
                           "--storage-class", storageClass, "--progress-frequency", "1"], environmentOverrides: overrides, progress: progress)
    }

    public func download(bucket: String, key: String, to fileURL: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".glacierdesk-\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await run(["s3", "cp", "s3://\(bucket)/\(key)", temporary.path, "--progress-frequency", "1"], progress: progress)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: fileURL) }
    }

    /// Requests a restore. `days` is bounded to S3's supported request range.
    public func restore(bucket: String, key: String, days: Int = 3,
                        tier: RestoreTier = .standard) async throws {
        let request = RestoreRequest(days: max(1, min(days, 365)),
                                     glacierJobParameters: .init(tier: tier.rawValue))
        let body = try JSONEncoder().encode(request)
        guard let bodyString = String(data: body, encoding: .utf8) else {
            throw AWSServiceError.invalidResponse
        }
        _ = try await run(["s3api", "restore-object", "--bucket", bucket, "--key", key,
                           "--restore-request", bodyString])
    }

    private func json(_ arguments: [String]) async throws -> Data {
        Data(try await run(arguments).stdout.utf8)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid AWS date.")
        }
        return decoder
    }

    private func run(_ arguments: [String], environmentOverrides: [String: String] = [:], progress: (@Sendable (Double) -> Void)? = nil) async throws -> CommandResult {
        var command = ["--profile", profile, "--no-cli-pager", "--output", "json"] + arguments
        // `configure list-profiles` does not accept output formatting options.
        if arguments.first == "configure" { command = arguments }
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .utility) { [executableURL, profile] in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = command
            var environment = ProcessInfo.processInfo.environment
            // Prevent environment credentials, custom endpoints, or CA overrides from changing
            // the identity or destination behind the explicitly selected shared profile.
            for name in environment.keys where name.hasPrefix("AWS_") { environment.removeValue(forKey: name) }
            environment["AWS_PROFILE"] = profile
            environment["AWS_CLI_AUTO_PROMPT"] = "off"
            environment["AWS_PAGER"] = ""
            environment.merge(environmentOverrides) { _, new in new }
            process.environment = environment
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do { try process.run() }
            catch { throw AWSServiceError.launchFailed(error.localizedDescription) }
            control.started(process)
            let outputTask = Task.detached {
                var output = Data()
                var progressBuffer = ""
                while true {
                    let data = stdout.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    if let progress {
                        progressBuffer += String(decoding: data, as: UTF8.self)
                        if let value = Self.progressFraction(progressBuffer) { progress(value) }
                        if progressBuffer.count > 4096 { progressBuffer = String(progressBuffer.suffix(512)) }
                    } else { output.append(data) }
                }
                return output
            }
            let errorTask = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
            process.waitUntilExit()
            control.finished()
            let out = await outputTask.value
            let err = await errorTask.value
            guard process.terminationStatus == 0 else {
                let message = String(data: err, encoding: .utf8) ?? "AWS CLI command failed."
                throw AWSServiceError.commandFailed(Self.redact(message).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return CommandResult(stdout: String(data: out, encoding: .utf8) ?? "")
        }.value
        try Task.checkCancellation()
        return result
        }, onCancel: { control.cancel() })
    }

    private static func progressFraction(_ text: String) -> Double? {
        let pattern = #"Completed\s+([0-9.]+)\s+(Bytes|KiB|MiB|GiB|TiB)/([0-9.]+)\s+(Bytes|KiB|MiB|GiB|TiB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last else { return nil }
        func value(_ index: Int) -> String { Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
        let units: [String: Double] = ["Bytes": 1, "KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776]
        guard let done = Double(value(1)), let total = Double(value(3)), total > 0, let a = units[value(2)], let b = units[value(4)] else { return nil }
        return min(1, max(0, done * a / (total * b)))
    }

    private static func redact(_ message: String) -> String {
        // Avoid forwarding credential-shaped values if an underlying diagnostic includes them.
        let patterns = [
            #"(?i)(aws_access_key_id|aws_secret_access_key|aws_session_token|accesskeyid|secretaccesskey|sessiontoken)\s*[:=]\s*[^\s,;]+"#,
            #"\bAKIA[0-9A-Z]{16}\b"#,
            #"(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*"#
        ]
        return patterns.reduce(message) { value, pattern in
            value.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func started(_ process: Process) { lock.lock(); self.process = process; let stop = cancelled; lock.unlock(); if stop { process.interrupt() } }
    func finished() { lock.lock(); process = nil; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; let running = process; lock.unlock(); if let running, running.isRunning { running.interrupt() } }
}

public struct UploadSettings: Sendable {
    public init() {}
    public var thresholdMiB = 64
    public var partSizeMiB = 16
    public var connections = 4

    public func validate() throws {
        guard (1...5120).contains(thresholdMiB), (5...5120).contains(partSizeMiB), (1...32).contains(connections) else {
            throw AWSServiceError.commandFailed("Upload settings are outside their allowed range.")
        }
    }
}

public struct AWSIdentity: Decodable, Sendable {
    public let userId: String
    public let account: String
    public let arn: String
    enum CodingKeys: String, CodingKey { case userId = "UserId", account = "Account", arn = "Arn" }
}

public struct AWSBucket: Decodable, Sendable, Identifiable {
    public let name: String
    public let creationDate: Date?
    public var id: String { name }
    enum CodingKeys: String, CodingKey { case name = "Name", creationDate = "CreationDate" }
}

public struct AWSObjectPage: Decodable, Sendable {
    public let contents: [AWSObject]?
    public let commonPrefixes: [AWSCommonPrefix]?
    public let isTruncated: Bool?
    public let nextContinuationToken: String?
    enum CodingKeys: String, CodingKey {
        case contents = "Contents", commonPrefixes = "CommonPrefixes", isTruncated = "IsTruncated"
        case nextContinuationToken = "NextContinuationToken"
    }
}

public struct AWSObject: Decodable, Sendable, Identifiable {
    public let key: String
    public let size: Int64?
    public let lastModified: Date?
    public let eTag: String?
    public let storageClass: String?
    public var id: String { key }
    enum CodingKeys: String, CodingKey {
        case key = "Key", size = "Size", lastModified = "LastModified", eTag = "ETag", storageClass = "StorageClass"
    }
}

public struct AWSCommonPrefix: Decodable, Sendable, Identifiable {
    public let prefix: String
    public var id: String { prefix }
    enum CodingKeys: String, CodingKey { case prefix = "Prefix" }
}

public struct AWSObjectMetadata: Decodable, Sendable {
    public let contentLength: Int64?
    public let lastModified: Date?
    public let eTag: String?
    public let storageClass: String?
    /// S3 returns `ongoing-request="false", expiry-date="..."` when restored.
    public let restore: String?
    enum CodingKeys: String, CodingKey {
        case contentLength = "ContentLength", lastModified = "LastModified", eTag = "ETag"
        case storageClass = "StorageClass", restore = "Restore"
    }
}

public enum RestoreTier: String, Sendable, CaseIterable {
    case expedited = "Expedited"
    case standard = "Standard"
    case bulk = "Bulk"
}

public enum AWSServiceError: LocalizedError, Sendable {
    case launchFailed(String)
    case commandFailed(String)
    case invalidResponse
    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): "Could not start AWS CLI: \(detail)"
        case .commandFailed(let detail): detail.isEmpty ? "AWS CLI command failed." : detail
        case .invalidResponse: "AWS CLI returned an invalid response."
        }
    }
}

private struct BucketResponse: Decodable {
    let buckets: [AWSBucket]?
    enum CodingKeys: String, CodingKey { case buckets = "Buckets" }
}
private struct RestoreRequest: Encodable {
    let days: Int
    let glacierJobParameters: JobParameters
    enum CodingKeys: String, CodingKey { case days = "Days", glacierJobParameters = "GlacierJobParameters" }
    struct JobParameters: Encodable {
        let tier: String
        enum CodingKeys: String, CodingKey { case tier = "Tier" }
    }
}
private struct CommandResult { let stdout: String }
