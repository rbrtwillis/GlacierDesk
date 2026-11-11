import AppKit
import SwiftUI

/// Small value type used to hand inventory rows to the independent bulk workflow.
/// Keep this adapter separate from the inventory decoder so the view can be embedded
/// by any caller that already has archive IDs and sizes.
struct BulkRetrievalArchive: Identifiable, Hashable {
    let id: String
    let description: String?
    let size: Int64?

    var displayName: String { description?.isEmpty == false ? description! : "Unnamed archive" }
}

private struct BulkRetrievalRecord: Codable, Identifiable {
    var id: String { archiveID }
    let accountID: String
    let archiveID: String
    let archiveName: String
    let archiveSize: Int64?
    var jobID: String?
    var state: String
    var savedTo: String?
}

/// Bulk retrieval has two deliberate gates: a cost review before any AWS requests,
/// and a user-selected save destination for every completed archive.
struct BulkLegacyRetrievalView: View {
    let profile: String
    let accountID: String
    let region: String
    let vault: String
    let archives: [BulkRetrievalArchive]

    @State private var selectedIDs = Set<String>()
    @State private var tier = "Standard"
    @State private var records: [BulkRetrievalRecord] = []
    @State private var jobs: [String: LegacyJob] = [:]
    @State private var showingCostReview = false
    @State private var busy = false
    @State private var message: String?

    private var service: AWSService { AWSService(profile: profile) }
    private var persistenceKey: String {
        "bulkLegacyRetrievals.v1." + [profile, accountID, region, vault].joined(separator: "|")
    }
    private var selectedArchives: [BulkRetrievalArchive] { archives.filter { selectedIDs.contains($0.id) } }
    private var selectedBytes: Int64? {
        let sizes = selectedArchives.compactMap(\.size)
        guard sizes.count == selectedArchives.count else { return nil }
        var total: Int64 = 0
        for size in sizes {
            let (next, overflow) = total.addingReportingOverflow(size)
            if overflow || size < 0 { return nil }
            total = next
        }
        return total
    }
    private var pendingRecords: [BulkRetrievalRecord] {
        records.filter { $0.jobID != nil && $0.state != "Saved" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bulk archive retrieval").font(.headline)
            Text("Select inventory entries, review the request and size totals, then confirm before Glacier jobs are submitted. AWS charges depend on your account, Region, tier, and retrieval volume.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker("Tier", selection: $tier) {
                    Text("Standard").tag("Standard")
                    Text("Bulk").tag("Bulk")
                    Text("Expedited").tag("Expedited")
                }.frame(width: 220)
                Button("Select first 100") { selectedIDs = Set(archives.prefix(100).map(\.id)) }.disabled(busy || archives.isEmpty)
                Button("Clear selection") { selectedIDs.removeAll() }.disabled(busy || selectedIDs.isEmpty)
            }

            if archives.isEmpty {
                Text("Load an inventory to choose archives.").foregroundStyle(.secondary)
            } else {
                List(archives) { archive in
                    Button {
                        if selectedIDs.contains(archive.id) { selectedIDs.remove(archive.id) }
                        else if selectedIDs.count < 100 { selectedIDs.insert(archive.id) }
                        else { message = "Limit each batch to 100 archives. Submit another batch for additional archives." }
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: selectedIDs.contains(archive.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(archive.id) ? GlacierTheme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(archive.displayName).font(.subheadline.weight(.medium))
                                Text(archive.id).font(.caption.monospaced()).textSelection(.enabled)
                                Text(archive.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unavailable")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(busy)
                }.frame(minHeight: 150, maxHeight: 280)
            }

            HStack {
                Text("\(selectedIDs.count) selected · \(selectedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "total size unavailable")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Review costs and request…") { showingCostReview = true }
                    .disabled(busy || selectedIDs.isEmpty)
            }

            if !records.isEmpty {
                Divider()
                HStack {
                    Text("Bulk retrieval queue").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Refresh jobs") { Task { await refreshJobs() } }.disabled(busy)
                    Button("Save completed…") { Task { await saveCompletedQueue() } }
                        .disabled(busy || !pendingRecords.contains { $0.jobID.flatMap { jobs[$0] }?.statusCode == "Succeeded" })
                }
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.archiveName).font(.subheadline)
                        if let jobID = record.jobID {
                            Text("Job ID: \(jobID)").font(.caption.monospaced()).textSelection(.enabled)
                            if let job = jobs[jobID] {
                                Text("\(job.action ?? "Retrieval") · \(job.statusCode ?? "Unknown")")
                                    .font(.caption).foregroundStyle(job.statusCode == "Failed" ? .red : .secondary)
                            } else { Text(record.state).font(.caption).foregroundStyle(.secondary) }
                            if let path = record.savedTo {
                                Text("Saved to \(path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            } else if jobs[jobID]?.statusCode == "Succeeded" {
                                Button("Choose destination…") { saveOne(record) }.disabled(busy)
                            }
                        } else {
                            Text(record.state).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.vertical, 3)
                }
            }
            if let message { Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Link("AWS Glacier pricing", destination: URL(string: "https://aws.amazon.com/s3/pricing/")!)
                .font(.caption)
        }
        .task { loadRecords(); await refreshJobs() }
        .confirmationDialog("Review bulk Glacier retrieval", isPresented: $showingCostReview, titleVisibility: .visible) {
            Button("I reviewed the charges — request \(selectedArchives.count) jobs") { Task { await submitReviewedBatch() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(costReviewText)
        }
    }

    private var costReviewText: String {
        let total = selectedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown (one or more sizes are missing)"
        return "Profile: \(profile) · Account: \(accountID) · Region: \(region) · Vault: \(vault). Tier: \(tier). Archives: \(selectedArchives.count). Total archive size: \(total). This app cannot calculate a reliable dollar estimate from inventory data. Glacier retrieval and request charges may apply; check AWS pricing and your account terms before confirming. Each job is submitted separately."
    }

    @MainActor private func submitReviewedBatch() async {
        guard !selectedArchives.isEmpty else { return }
        let unresolved = selectedArchives.filter { archive in
            records.contains { $0.archiveID == archive.id }
        }
        guard unresolved.isEmpty else {
            message = "One or more selected archives already have a retrieval record. Review the saved queue before requesting them again."
            return
        }
        busy = true
        defer { busy = false }
        let batch = selectedArchives
        // Persist every intended item before sending requests. If the app exits or an
        // AWS response is ambiguous, the record remains visible and is never retried.
        for archive in batch {
            records.append(BulkRetrievalRecord(accountID: accountID, archiveID: archive.id, archiveName: archive.displayName, archiveSize: archive.size,
                                               jobID: nil, state: "Not submitted", savedTo: nil))
        }
        persist()
        for archive in batch {
            guard let index = records.firstIndex(where: { $0.archiveID == archive.id }), records[index].jobID == nil,
                  records[index].state == "Not submitted" else { continue }
            records[index].state = "Submitting — do not repeat until jobs are refreshed"
            persist()
            do {
                let jobID = try await service.startLegacyJob(vault: vault, region: region, archiveID: archive.id, tier: tier)
                records[index].jobID = jobID
                records[index].state = "InProgress"
                persist()
            } catch {
                records[index].state = "Outcome unknown. Refresh AWS jobs and compare before any manual retry. \(safeMessage(error))"
                persist()
                message = "The batch stopped because AWS did not confirm this request. Earlier job IDs are saved. Refresh jobs before making another request."
                return
            }
        }
        selectedIDs.subtract(batch.map(\.id))
        message = "Submitted \(batch.count) retrieval request(s). Job IDs are saved on this Mac. Refresh jobs to track completion."
    }

    @MainActor private func refreshJobs() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        loadRecords()
        do {
            let latest = try await service.listLegacyJobs(vault: vault, region: region)
            jobs = Dictionary(uniqueKeysWithValues: latest.map { ($0.jobId, $0) })
            for index in records.indices {
                guard let id = records[index].jobID, let job = jobs[id] else { continue }
                if records[index].savedTo == nil { records[index].state = job.statusCode ?? "Unknown" }
            }
            persist()
            message = nil
        } catch { message = "Could not refresh Glacier jobs: \(safeMessage(error)) Saved job IDs remain available for a later refresh." }
    }

    @MainActor private func saveOne(_ record: BulkRetrievalRecord) {
        guard let jobID = record.jobID, let job = jobs[jobID], job.statusCode == "Succeeded" else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFilename(record.archiveName)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await save(record, job: job, to: destination) }
    }

    @MainActor private func saveCompletedQueue() async {
        // NSSavePanel runs once per item so each output path is explicit and the user
        // controls every write. Existing files are subject to the system panel prompt.
        let completed = pendingRecords.filter { $0.jobID.flatMap { jobs[$0] }?.statusCode == "Succeeded" }
        for record in completed {
            guard let jobID = record.jobID, let job = jobs[jobID] else { continue }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = safeFilename(record.archiveName)
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { break }
            await save(record, job: job, to: destination)
        }
    }

    @MainActor private func save(_ record: BulkRetrievalRecord, job: LegacyJob, to destination: URL) async {
        guard let index = records.firstIndex(where: { $0.archiveID == record.archiveID }) else { return }
        busy = true
        defer { busy = false }
        do {
            try await service.legacyJobOutput(vault: vault, region: region, job: job, destination: destination)
            records[index].savedTo = destination.path
            records[index].state = "Saved"
            persist()
            message = "Archive saved and checksum verified: \(destination.lastPathComponent)"
        } catch { message = "Download failed; the destination was not accepted: \(safeMessage(error))" }
    }

    private func loadRecords() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([BulkRetrievalRecord].self, from: data) else { return }
        records = decoded.filter { $0.accountID == accountID }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func safeFilename(_ source: String) -> String {
        let value = source.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || "/:".unicodeScalars.contains($0) ? "_" : String($0) }.joined()
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "glacier-archive" : cleaned
    }

    private func safeMessage(_ error: Error) -> String {
        // CLI errors can contain request details; keep only a bounded display string.
        String(error.localizedDescription.prefix(500))
    }
}
