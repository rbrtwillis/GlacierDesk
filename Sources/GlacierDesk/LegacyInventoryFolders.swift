import Foundation

/// Reconstructs a virtual hierarchy from archive descriptions; Glacier itself has no folders.
struct LegacyInventoryFolders: Sendable {
    private(set) var folders: [String: Set<String>] = [:]
    private(set) var files: [String: [IndexedGlacierArchive]] = [:]

    static func path(for description: String?) -> String? {
        guard let description, !description.isEmpty else { return nil }
        if description.hasPrefix("<m>") {
            guard description.contains("<v>4</v>"),
                  let start = description.range(of: "<p>"),
                  let end = description.range(of: "</p>", range: start.upperBound..<description.endIndex),
                  let data = Data(base64Encoded: String(description[start.upperBound..<end.lowerBound])),
                  let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty else { return nil }
            return decoded
        }
        // Other structured metadata is not a filename.
        guard !description.hasPrefix("<") else { return nil }
        return description
    }

    mutating func add(_ archive: IndexedGlacierArchive) {
        guard let path = Self.path(for: archive.description) else {
            files["", default: []].append(archive); return
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
            files["", default: []].append(archive); return
        }
        var parent = ""
        for component in components.dropLast() {
            folders[parent, default: []].insert(component)
            parent = parent.isEmpty ? component : parent + "/" + component
        }
        files[parent, default: []].append(archive)
    }

    static func filename(_ archive: IndexedGlacierArchive) -> String {
        guard let path = path(for: archive.description),
              let name = path.split(separator: "/").last, name != ".", name != ".." else { return "Unnamed archive" }
        return String(name)
    }

    func listing(folder: String, search: String, offset: Int, pageSize: Int, sort: GlacierArchiveSort, ascending: Bool) -> (folders: [String], page: GlacierArchivePage) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingFolders = (folders[folder] ?? []).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var matchingFiles = (files[folder] ?? []).filter { query.isEmpty || Self.filename($0).localizedCaseInsensitiveContains(query) || $0.archiveID.localizedCaseInsensitiveContains(query) }
        matchingFiles.sort { a, b in
            let comparison: ComparisonResult
            switch sort {
            case .description: comparison = Self.filename(a).localizedStandardCompare(Self.filename(b))
            case .archiveID: comparison = a.archiveID.compare(b.archiveID)
            case .creationDate: comparison = (a.creationDate ?? "").compare(b.creationDate ?? "")
            case .size: comparison = (a.size ?? -1) == (b.size ?? -1) ? .orderedSame : ((a.size ?? -1) < (b.size ?? -1) ? .orderedAscending : .orderedDescending)
            }
            if comparison == .orderedSame { return a.archiveID < b.archiveID }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        let start = min(max(offset, 0), matchingFiles.count), end = min(start + pageSize, matchingFiles.count)
        return (matchingFolders, GlacierArchivePage(archives: Array(matchingFiles[start..<end]), totalCount: matchingFiles.count, offset: start, pageSize: pageSize))
    }
}
