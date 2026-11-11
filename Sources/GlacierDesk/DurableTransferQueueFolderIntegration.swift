import Foundation
import Darwin

extension DurableTransferSession {
    /// Captures the reviewed S3 plan, including upload settings and both file and root
    /// security bookmarks. Bookmarks contain access metadata, never AWS credentials.
    static func s3Upload(from plan: FolderUploadPlan, accountID: String,
                         storageClass: String) throws -> DurableTransferSession {
        let records = try plan.items.map { item -> DurableTransferItem in
            let fileBookmark = try durableBookmark(for: item.file)
            let rootBookmark = try durableBookmark(for: item.root)
            return DurableTransferItem(sourcePath: item.file.path, sourceBookmark: fileBookmark,
                sourceDevice: UInt64(item.fileIdentity.device), sourceInode: UInt64(item.fileIdentity.inode),
                target: item.key, rootPath: item.root.path, rootBookmark: rootBookmark,
                rootDevice: UInt64((item.rootIdentity ?? item.fileIdentity).device),
                rootInode: UInt64((item.rootIdentity ?? item.fileIdentity).inode), relativeComponents: item.components)
        }
        return DurableTransferSession(kind: .s3Upload, accountID: accountID, profile: plan.profile,
            destination: "s3://\(plan.bucket)/\(plan.prefix)", thresholdMiB: plan.settings.thresholdMiB,
            partSizeMiB: plan.settings.partSizeMiB, connections: plan.settings.connections,
            bucket: plan.bucket, prefix: plan.prefix, storageClass: storageClass, items: records)
    }
}

extension DurableTransferSession {
    /// Legacy upload factory accepts already-bookmarked items so the vault UI can prepare
    /// files without coupling the queue layer to a particular picker or upload view.
    static func legacyArchiveUpload(accountID: String, profile: String, vault: String,
                                    region: String, settings: UploadSettings,
                                    items: [DurableTransferItem]) -> DurableTransferSession {
        DurableTransferSession(kind: .legacyArchiveUpload, accountID: accountID, profile: profile,
            destination: "glacier://\(region)/\(vault)", thresholdMiB: settings.thresholdMiB,
            partSizeMiB: settings.partSizeMiB, connections: settings.connections,
            vault: vault, region: region, items: items)
    }
}

extension DurableTransferQueue {
    /// Reconstructs only caller-selected retryable items after a fresh account identity check.
    /// Use `retryableItems` first so the UI can request explicit consent for interrupted S3 PUTs.
    /// Security-scope access still must be started/stopped by the caller for the transfer lifetime.
    func reconstructFolderItems(_ records: [DurableTransferItem]) throws -> [FolderUploadItem] {
        try records.map { record in
            guard let rootPath = record.rootPath, let rootBookmark = record.rootBookmark,
                  let rootDevice = record.rootDevice, let rootInode = record.rootInode else {
                throw DurableTransferQueueError.invalidSource("The saved source is missing its selected-folder bookmark or identity. Select the source again.")
            }
            var rootStale = false
            let root = try resolveDurableBookmark(rootBookmark, stale: &rootStale)
            guard !rootStale, root.standardizedFileURL.path == URL(fileURLWithPath: rootPath).standardizedFileURL.path else {
                throw DurableTransferQueueError.invalidSource("The saved folder bookmark is stale or no longer points to the reviewed source. Prepare the upload again.")
            }
            var fileStale = false
            let fileFromBookmark = try resolveDurableBookmark(record.sourceBookmark, stale: &fileStale)
            guard !fileStale, fileFromBookmark.standardizedFileURL.path == URL(fileURLWithPath: record.sourcePath).standardizedFileURL.path else {
                throw DurableTransferQueueError.invalidSource("The saved file bookmark is stale or no longer points to the reviewed file. Prepare the upload again.")
            }
            guard !record.relativeComponents.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("/") || $0.contains("\\") }) else {
                throw DurableTransferQueueError.invalidSource("The saved relative path is invalid. Prepare the upload again.")
            }
            guard let fileDevice = record.sourceDevice, let fileInode = record.sourceInode else {
                throw DurableTransferQueueError.invalidSource("The saved file identity is missing. Prepare the upload again.")
            }
            let rootIdentity = UploadFileIdentity(device: dev_t(rootDevice), inode: ino_t(rootInode))
            let fileIdentity = UploadFileIdentity(device: dev_t(fileDevice), inode: ino_t(fileInode))
            let components = record.relativeComponents
            try verifyNoFollow(root: root, components: components, expectedRoot: rootIdentity, expectedFile: fileIdentity)
            let file = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
            return FolderUploadItem(file: file, key: record.target, root: root, components: components,
                                    rootIdentity: components.isEmpty ? nil : rootIdentity, fileIdentity: fileIdentity)
        }
    }
}

private func durableBookmark(for url: URL) throws -> Data {
    do { return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
    catch { return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
}

private func resolveDurableBookmark(_ bookmark: Data, stale: inout Bool) throws -> URL {
    do { return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) }
    catch { return try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) }
}

private func verifyNoFollow(root: URL, components: [String], expectedRoot: UploadFileIdentity,
                            expectedFile: UploadFileIdentity) throws {
    func identity(_ descriptor: Int32, directory: Bool) throws -> UploadFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else {
            throw DurableTransferQueueError.invalidSource("The saved source is no longer the expected regular file or folder.")
        }
        return UploadFileIdentity(device: info.st_dev, inode: info.st_ino)
    }
    var descriptor = root.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (components.isEmpty ? 0 : O_DIRECTORY)) }
    guard descriptor >= 0 else { throw DurableTransferQueueError.invalidSource("The saved source cannot be opened safely. Reauthorize or select it again.") }
    defer { Darwin.close(descriptor) }
    if !components.isEmpty {
        guard try identity(descriptor, directory: true) == expectedRoot else {
            throw DurableTransferQueueError.invalidSource("The selected folder changed since the transfer was prepared.")
        }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = component.withCString { Darwin.openat(descriptor, $0, flags) }
            guard next >= 0 else { throw DurableTransferQueueError.invalidSource("The queued path changed or contains a symbolic link.") }
            Darwin.close(descriptor); descriptor = next
        }
    }
    guard try identity(descriptor, directory: false) == expectedFile else {
        throw DurableTransferQueueError.invalidSource("The selected file changed since the transfer was prepared.")
    }
}
