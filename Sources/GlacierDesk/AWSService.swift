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
                       storageClass: String = "STANDARD") async throws {
        _ = try await run(["s3", "cp", fileURL.path, "s3://\(bucket)/\(key)",
                           "--storage-class", storageClass, "--only-show-errors"])
    }

    public func download(bucket: String, key: String, to fileURL: URL) async throws {
        _ = try await run(["s3", "cp", "s3://\(bucket)/\(key)", fileURL.path, "--only-show-errors"])
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

    private func run(_ arguments: [String]) async throws -> CommandResult {
        var command = ["--profile", profile, "--no-cli-pager", "--output", "json"] + arguments
        // `configure list-profiles` does not accept output formatting options.
        if arguments.first == "configure" { command = arguments }
        return try await Task.detached(priority: .utility) { [executableURL, profile] in
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
            process.environment = environment
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do { try process.run() }
            catch { throw AWSServiceError.launchFailed(error.localizedDescription) }
            let outputTask = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
            let errorTask = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
            process.waitUntilExit()
            let out = await outputTask.value
            let err = await errorTask.value
            guard process.terminationStatus == 0 else {
                let message = String(data: err, encoding: .utf8) ?? "AWS CLI command failed."
                throw AWSServiceError.commandFailed(Self.redact(message).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return CommandResult(stdout: String(data: out, encoding: .utf8) ?? "")
        }.value
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
