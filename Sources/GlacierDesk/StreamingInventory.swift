import Foundation

public extension GlacierInventoryIndex {
    /// Imports a Glacier inventory JSON file without materializing `ArchiveList`.
    /// Only one archive JSON object and a small input buffer are held at a time.
    /// The existing snapshot is retained if reading, decoding, or SQLite insertion fails.
    @discardableResult
    func importInventoryJSON(at url: URL, scope: GlacierInventoryScope) throws -> String? {
        try replaceInventoryStreaming(scope: scope) { emit in
            var parser = try GlacierInventoryJSONStream(url: url)
            return try parser.readInventory(emit: emit)
        }
    }
}

private struct GlacierInventoryJSONStream {
    private var file: FileHandle
    private var buffer = [UInt8]()
    private var cursor = 0
    private var ended = false

    init(url: URL) throws { file = try FileHandle(forReadingFrom: url) }

    mutating func readInventory(emit: (IndexedGlacierArchive) throws -> Void) throws -> String? {
        defer { try? file.close() }
        try expectNonWhitespace(123) // {
        var inventoryDate: String?
        var foundArchiveList = false
        while try peekNonWhitespace() != 125 {
            let key = try readString()
            try expectNonWhitespace(58) // :
            if key == "ArchiveList" {
                guard !foundArchiveList else { throw malformed("duplicate ArchiveList") }
                foundArchiveList = true
                try readArchiveList(emit: emit)
            } else if key == "InventoryDate" {
                if try peekNonWhitespace() == 34 { inventoryDate = try readString() }
                else { try skipValue() }
            } else {
                try skipValue()
            }
            let next = try peekNonWhitespace()
            if next == 44 {
                _ = try takeNonWhitespace()
                if try peekNonWhitespace() == 125 { throw malformed("trailing comma in object") }
            } else if next != 125 { throw malformed("expected comma or end of object") }
        }
        _ = try takeNonWhitespace()
        guard foundArchiveList else { throw malformed("missing ArchiveList") }
        guard try peekNonWhitespace() == nil else { throw malformed("trailing data") }
        return inventoryDate
    }

    private mutating func readArchiveList(emit: (IndexedGlacierArchive) throws -> Void) throws {
        try expectNonWhitespace(91) // [
        if try peekNonWhitespace() == 93 { _ = try takeNonWhitespace(); return }
        while true {
            let raw = try readRawObject()
            let decoded: InventoryArchiveJSON
            do { decoded = try JSONDecoder().decode(InventoryArchiveJSON.self, from: raw) }
            catch { throw malformed("invalid archive object: \(error.localizedDescription)") }
            guard let id = decoded.archiveID, !id.isEmpty else { throw malformed("archive object has no ArchiveId") }
            try emit(IndexedGlacierArchive(archiveID: id, description: decoded.archiveDescription,
                                           size: decoded.size, creationDate: decoded.creationDate))
            let next = try peekNonWhitespace()
            if next == 44 {
                _ = try takeNonWhitespace()
                if try peekNonWhitespace() == 93 { throw malformed("trailing comma in ArchiveList") }
                continue
            }
            if next == 93 { _ = try takeNonWhitespace(); return }
            throw malformed("expected comma or end of ArchiveList")
        }
    }

    /// Reads one balanced object. Its size is proportional to a single archive record.
    private mutating func readRawObject() throws -> Data {
        try expectNonWhitespace(123)
        var bytes: [UInt8] = [123]
        var depth = 1, inString = false, escaped = false
        while let byte = try take() {
            bytes.append(byte)
            if bytes.count > 16 * 1024 * 1024 { throw malformed("archive record exceeds 16 MiB") }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 { depth += 1 }
            else if byte == 125 || byte == 93 {
                depth -= 1
                if depth == 0 { return Data(bytes) }
                if depth < 0 { throw malformed("unbalanced archive object") }
            }
        }
        throw malformed("truncated archive object")
    }

    private mutating func readString() throws -> String {
        try expectNonWhitespace(34)
        var bytes: [UInt8] = [34], escaped = false
        while let byte = try take() {
            bytes.append(byte)
            if bytes.count > 16 * 1024 * 1024 { throw malformed("JSON string exceeds 16 MiB") }
            if escaped { escaped = false }
            else if byte == 92 { escaped = true }
            else if byte == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes)) }
                catch { throw malformed("invalid JSON string") }
            }
        }
        throw malformed("truncated JSON string")
    }

    private mutating func skipValue() throws {
        let first = try takeNonWhitespace()
        if first == 34 {
            cursor -= 1
            _ = try readString()
            return
        }
        if first == 123 {
            if try peekNonWhitespace() == 125 { _ = try takeNonWhitespace(); return }
            while true {
                guard try peekNonWhitespace() == 34 else { throw malformed("object key must be a string") }
                _ = try readString()
                try expectNonWhitespace(58)
                try skipValue()
                let next = try peekNonWhitespace()
                if next == 125 { _ = try takeNonWhitespace(); return }
                guard next == 44 else { throw malformed("expected comma in object") }
                _ = try takeNonWhitespace()
                if try peekNonWhitespace() == 125 { throw malformed("trailing comma in object") }
            }
        }
        if first == 91 {
            if try peekNonWhitespace() == 93 { _ = try takeNonWhitespace(); return }
            while true {
                try skipValue()
                let next = try peekNonWhitespace()
                if next == 93 { _ = try takeNonWhitespace(); return }
                guard next == 44 else { throw malformed("expected comma in array") }
                _ = try takeNonWhitespace()
                if try peekNonWhitespace() == 93 { throw malformed("trailing comma in array") }
            }
        }
        var token = [first]
        while let byte = try peek(), byte != 44, byte != 125, byte != 93, !isWhitespace(byte) {
            token.append(try take()!)
            if token.count > 1024 * 1024 { throw malformed("JSON scalar exceeds 1 MiB") }
        }
        guard let scalar = try? JSONSerialization.jsonObject(with: Data(token), options: [.fragmentsAllowed]),
              scalar is NSNull || scalar is NSNumber else { throw malformed("invalid JSON scalar") }
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard try take() == byte else { throw malformed("unexpected token") }
    }
    private mutating func expectNonWhitespace(_ byte: UInt8) throws {
        guard try takeNonWhitespace() == byte else { throw malformed("unexpected token") }
    }
    private mutating func peekNonWhitespace() throws -> UInt8? {
        while let byte = try peek(), isWhitespace(byte) { _ = try take() }
        return try peek()
    }
    private mutating func takeNonWhitespace() throws -> UInt8 {
        guard try peekNonWhitespace() != nil, let consumed = try take() else { throw malformed("unexpected end of file") }
        return consumed
    }
    private mutating func peek() throws -> UInt8? {
        try fill()
        return cursor < buffer.count ? buffer[cursor] : nil
    }
    private mutating func take() throws -> UInt8? {
        try fill()
        guard cursor < buffer.count else { return nil }
        defer { cursor += 1 }
        return buffer[cursor]
    }
    private mutating func fill() throws {
        if cursor < buffer.count || ended { return }
        buffer = Array(try file.read(upToCount: 16 * 1024) ?? Data())
        cursor = 0
        if buffer.isEmpty { ended = true }
    }
    private func isWhitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
    private func malformed(_ detail: String) -> InventoryIndexError { .sqlite("Invalid Glacier inventory JSON: \(detail)") }
}

private struct InventoryArchiveJSON: Decodable {
    let archiveID: String?
    let archiveDescription: String?
    let size: Int64?
    let creationDate: String?
    enum CodingKeys: String, CodingKey {
        case archiveID = "ArchiveId", archiveDescription = "ArchiveDescription", size = "Size", creationDate = "CreationDate"
    }
}
