import Foundation
import Darwin

struct UploadFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}

struct FolderUploadItem: Identifiable, Sendable {
    let id = UUID()
    let file: URL
    let key: String
    let root: URL
    let components: [String]
    let rootIdentity: UploadFileIdentity?
    let fileIdentity: UploadFileIdentity

    func snapshot() async throws -> URL {
        let worker = Task.detached(priority: .utility) { try snapshotSynchronously() }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private func snapshotSynchronously() throws -> URL {
        try Task.checkCancellation()
        let opened = try openUploadSource(root: root, components: components, expectedRoot: rootIdentity, expectedFile: fileIdentity)
        let input = FileHandle(fileDescriptor: opened.fd, closeOnDealloc: true)
        defer { try? input.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let target = directory.appendingPathComponent("data")
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw FolderUploadError.message("Could not create a private upload snapshot.") }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: bytes)
            }
            return target
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

private func openUploadSource(root: URL, components: [String], expectedRoot: UploadFileIdentity? = nil,
                              expectedFile: UploadFileIdentity? = nil) throws -> (fd: Int32, rootIdentity: UploadFileIdentity?, fileIdentity: UploadFileIdentity) {
    func identity(_ fd: Int32, directory: Bool) throws -> UploadFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else {
            throw FolderUploadError.message("Upload source is no longer the expected regular file or directory.")
        }
        return UploadFileIdentity(device: info.st_dev, inode: info.st_ino)
    }
    var fd = root.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (components.isEmpty ? 0 : O_DIRECTORY)) }
    guard fd >= 0 else { throw FolderUploadError.message("Cannot securely open upload source: \(root.path)") }
    do {
        var rootIdentity: UploadFileIdentity?
        if !components.isEmpty {
            rootIdentity = try identity(fd, directory: true)
            if let expectedRoot, rootIdentity != expectedRoot { throw FolderUploadError.message("The selected folder changed after review; upload skipped.") }
            for (index, component) in components.enumerated() {
                let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (index == components.count - 1 ? 0 : O_DIRECTORY)
                let next = component.withCString { Darwin.openat(fd, $0, flags) }
                guard next >= 0 else { throw FolderUploadError.message("A queued path changed or contains a symbolic link; upload skipped.") }
                Darwin.close(fd); fd = next
            }
        }
        let fileIdentity = try identity(fd, directory: false)
        if let expectedFile, fileIdentity != expectedFile { throw FolderUploadError.message("The selected file changed after review; upload skipped.") }
        return (fd, rootIdentity, fileIdentity)
    } catch { Darwin.close(fd); throw error }
}

struct FolderUploadPlan: Sendable {
    let bucket: String
    let prefix: String
    let profile: String
    let storageClass: String
    let settings: UploadSettings
    let roots: [URL]
    let items: [FolderUploadItem]

    static func build(roots: [URL], bucket: String, prefix: String, profile: String,
                      storageClass: String, settings: UploadSettings) throws -> FolderUploadPlan {
        try settings.validate()
        var items: [FolderUploadItem] = []
        var keys = Set<String>()
        for supplied in roots {
            let rootValues = try supplied.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard rootValues.isSymbolicLink != true else { throw FolderUploadError.message("Symbolic links cannot be uploaded: \(supplied.path)") }
            let root = supplied.standardizedFileURL
            func append(_ file: URL, relative: String, components: [String]) throws {
                let key = prefix + relative
                guard keys.insert(key).inserted else { throw FolderUploadError.message("Two selected files map to the same S3 key: \(key)") }
                let opened = try openUploadSource(root: root, components: components)
                Darwin.close(opened.fd)
                items.append(FolderUploadItem(file: file, key: key, root: root, components: components, rootIdentity: opened.rootIdentity, fileIdentity: opened.fileIdentity))
            }
            if rootValues.isRegularFile == true { try append(root, relative: root.lastPathComponent, components: []); continue }
            guard rootValues.isDirectory == true else { throw FolderUploadError.message("Not a regular file or folder: \(root.path)") }
            var traversalError: Error?
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in traversalError = error; return false }) else {
                throw FolderUploadError.message("Cannot read folder: \(root.path)")
            }
            while let file = enumerator.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                guard values.isRegularFile == true else { continue }
                let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
                let normalizedPath = file.standardizedFileURL.path
                guard normalizedPath.hasPrefix(base) else { throw FolderUploadError.message("File is outside the selected folder.") }
                let relative = String(normalizedPath.dropFirst(base.count))
                try append(file, relative: root.lastPathComponent + "/" + relative, components: relative.split(separator: "/").map(String.init))
            }
            if let traversalError { throw traversalError }
        }
        guard !items.isEmpty else { throw FolderUploadError.message("No regular files found. Empty folders and symbolic links are not uploaded.") }
        items.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return FolderUploadPlan(bucket: bucket, prefix: prefix, profile: profile, storageClass: storageClass, settings: settings, roots: roots, items: items)
    }
}

enum FolderUploadError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct QueuedUpload: Identifiable {
    let item: FolderUploadItem
    var state = "Queued"
    var id: UUID { item.id }
}
