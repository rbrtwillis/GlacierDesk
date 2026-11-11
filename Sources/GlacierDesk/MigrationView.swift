import SwiftUI

/// Read-only presentation for a MigrationAssessment. Callers are responsible
/// for obtaining a completed vault inventory and the complete S3 listing.
struct MigrationView: View {
    let assessment: MigrationAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Migration comparison").font(.title2.weight(.semibold))
            Text("\(assessment.vaultName) → s3://\(assessment.bucketName)/\(assessment.prefix)")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text("Glacier inventory: \(assessment.inventoryDate ?? "date unavailable") · \(assessment.rows.count) archive entries · \(assessment.candidateCount) candidate matches · \(assessment.ambiguousCount) ambiguous · \(assessment.missingCount) unmatched")
                .font(.caption).foregroundStyle(.secondary)
            Label("Candidate matches use archive description as the exact S3 key (under the selected prefix) and compare reported sizes only. They do not verify object contents or prove a successful migration.", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            List {
                Section("Vault archives") {
                    ForEach(assessment.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.archive.description?.isEmpty == false ? row.archive.description! : "(no archive description)")
                                    .font(.body).lineLimit(2).textSelection(.enabled)
                                Spacer()
                                stateLabel(row.state)
                            }
                            Text("ID: \(row.archive.archiveID) · \(row.archive.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "size unavailable")")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            switch row.state {
                            case .candidate(let object):
                                Text("S3 key: \(object.key)").font(.caption.monospaced()).textSelection(.enabled)
                            case .ambiguous(let objects):
                                Text("Multiple archives or listed objects share this candidate key (\(objects.count) matching objects). Review manually.")
                                    .font(.caption).foregroundStyle(.orange)
                            case .missing:
                                Text("No object with the exact description-derived key and size was found in this listing.")
                                    .font(.caption).foregroundStyle(.secondary)
                            case .insufficientMetadata:
                                Text("Description or size is unavailable; this entry could not be compared.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3)
                    }
                }
                if !assessment.unmatchedObjects.isEmpty {
                    Section("S3 objects without a candidate archive") {
                        ForEach(assessment.unmatchedObjects) { object in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(object.key).font(.caption.monospaced()).textSelection(.enabled)
                                Text(object.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "size unavailable")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }.padding(16).frame(minWidth: 620, minHeight: 420)
    }

    @ViewBuilder private func stateLabel(_ state: MigrationMatchState) -> some View {
        switch state {
        case .candidate: Label("Candidate", systemImage: "questionmark.circle").foregroundStyle(.orange)
        case .ambiguous: Label("Ambiguous", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .missing: Label("No match", systemImage: "minus.circle").foregroundStyle(.secondary)
        case .insufficientMetadata: Label("Cannot compare", systemImage: "info.circle").foregroundStyle(.secondary)
        }
    }
}
