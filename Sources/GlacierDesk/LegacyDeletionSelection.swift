import Foundation

/// Folder paths are reconstructed from descriptions; they are not AWS folders.
struct LegacyDeletionSelection: Sendable {
    var archiveIDs: Set<String> = []
    var folders: Set<String> = []

    func includes(_ archive: IndexedGlacierArchive) -> Bool {
        if archiveIDs.contains(archive.archiveID) { return true }
        guard let path = LegacyInventoryFolders.path(for: archive.description) else { return false }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !pieces.isEmpty, !pieces.contains("."), !pieces.contains("..") else { return false }
        let normalized = pieces.joined(separator: "/")
        return folders.contains { normalized.hasPrefix($0 + "/") }
    }
}
