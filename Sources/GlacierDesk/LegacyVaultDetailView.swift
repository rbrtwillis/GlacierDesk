import AppKit
import SwiftUI

private struct VaultInventory: Decodable {
    let InventoryDate: String?
    let ArchiveList: [VaultArchive]
}
private struct VaultArchive: Decodable, Identifiable {
    let ArchiveId: String
    let ArchiveDescription: String?
    let Size: Int64?
    let CreationDate: String?
    var id: String { ArchiveId }
}
private struct SavedLegacyUpload: Codable, Identifiable {
    let id: String
    let profile: String
    let region: String
    let vault: String
    let filename: String
}

struct LegacyVaultDetailView: View {
    let profile: String
    let region: String
    let vault: LegacyVault
    let back: () -> Void
    @State private var jobs: [LegacyJob] = []
    @State private var inventory: [VaultArchive] = []
    @State private var inventoryDate: String?
    @State private var search = ""
    @State private var archiveID = ""
    @State private var tier = "Standard"
    @State private var busy = false
    @State private var status: String?
    @State private var confirmInventory = false
    @State private var confirmRetrieval = false
    @State private var confirmUpload = false
    @State private var showingFilePicker = false
    @State private var uploadFile: URL?
    @AppStorage("legacyUploadedArchives") private var uploadedData = Data()
    private var service: AWSService { AWSService(profile: profile) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button("← All vaults", action: back).disabled(busy)
                Text(vault.vaultName).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text("\(region) · Legacy Glacier vault").foregroundStyle(.secondary)
                Text("Inventory and archive retrieval are asynchronous and may take hours. Job output is available for a limited time. Requests and downloads may incur AWS charges.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Request inventory…") { confirmInventory = true }.disabled(busy)
                    Button("Refresh jobs") { Task { await refresh() } }.disabled(busy)
                    Button("Upload archive…") { showingFilePicker = true }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let status { Text(status).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                Divider()
                Text("Jobs").font(.headline)
                if jobs.isEmpty { Text("No recent jobs found. Refresh to check AWS.").foregroundStyle(.secondary) }
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(job.action ?? "Job") · \(job.statusCode ?? "Unknown")").font(.subheadline.weight(.semibold))
                        Text("Job ID: \(job.jobId)").font(.caption.monospaced()).textSelection(.enabled)
                        if let id = job.archiveId { Text("Archive ID: \(id)").font(.caption.monospaced()).textSelection(.enabled) }
                        if job.statusCode == "Succeeded" && job.action == "InventoryRetrieval" {
                            Button("Open inventory") { Task { await openInventory(job) } }.disabled(busy)
                        }
                        if job.statusCode == "Succeeded" && job.action == "ArchiveRetrieval" {
                            Button("Download archive…") { chooseDestination(job) }.disabled(busy)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                let saved = ((try? JSONDecoder().decode([SavedLegacyUpload].self, from: uploadedData)) ?? []).filter { $0.profile == profile && $0.region == region && $0.vault == vault.vaultName }
                if !saved.isEmpty {
                    Text("Archives uploaded from this Mac").font(.headline)
                    ForEach(saved) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.filename).font(.subheadline.weight(.medium))
                            Text(item.id).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Select for retrieval") { archiveID = item.id }.disabled(busy)
                        }.padding(.vertical, 4)
                    }
                    Divider()
                }
                Text("Browse inventory").font(.headline)
                if let inventoryDate { Text("Inventory date: \(inventoryDate) · \(inventory.count) archives").font(.caption).foregroundStyle(.secondary) }
                Text("Open a completed inventory job above. The first 200 matches are shown; search by description or archive ID.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Search archives", text: $search).textFieldStyle(.roundedBorder)
                let matches = inventory.lazy.filter { search.isEmpty || $0.ArchiveId.localizedCaseInsensitiveContains(search) || ($0.ArchiveDescription ?? "").localizedCaseInsensitiveContains(search) }
                ForEach(Array(matches.prefix(200))) { archive in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(archive.ArchiveDescription?.isEmpty == false ? archive.ArchiveDescription! : "Unnamed archive").font(.subheadline.weight(.medium)).textSelection(.enabled)
                        Text(archive.ArchiveId).font(.caption.monospaced()).textSelection(.enabled)
                        Text("\(archive.Size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown size") · \(archive.CreationDate ?? "Unknown date")").font(.caption).foregroundStyle(.secondary)
                        Button("Select for retrieval") { archiveID = archive.ArchiveId }.disabled(busy)
                    }.padding(.vertical, 5)
                }
                Divider()
                Text("Retrieve an archive").font(.headline)
                TextField("Archive ID", text: $archiveID).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Retrieval tier", selection: $tier) { Text("Standard").tag("Standard"); Text("Bulk").tag("Bulk"); Text("Expedited").tag("Expedited") }.frame(width: 260)
                    Button("Request retrieval…") { confirmRetrieval = true }.disabled(busy || archiveID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Link("AWS Glacier pricing", destination: URL(string: "https://aws.amazon.com/s3/pricing/")!)
            }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await refresh() }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): uploadFile = url; confirmUpload = true
            case .failure(let error): status = error.localizedDescription
            }
        }
        .confirmationDialog("Request vault inventory?", isPresented: $confirmInventory, titleVisibility: .visible) {
            Button("Request inventory") { Task { await requestInventory() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("An inventory job may take hours. AWS charges may apply. Check existing jobs before submitting another request.") }
        .confirmationDialog("Request archive retrieval?", isPresented: $confirmRetrieval, titleVisibility: .visible) {
            Button("Request \(tier) retrieval") { Task { await requestArchive() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Retrieval charges apply and availability is limited. Check AWS pricing before continuing.") }
        .confirmationDialog("Upload archive?", isPresented: $confirmUpload, titleVisibility: .visible) {
            Button("Upload") { if let file = uploadFile { Task { await upload(file) } } }
            Button("Cancel", role: .cancel) { uploadFile = nil }
        } message: { Text("Storage and request charges apply. Single-file uploads are limited to 4 GiB. Save the returned archive ID.") }
    }

    @MainActor private func refresh() async {
        busy = true; defer { busy = false }
        do { jobs = try await service.listLegacyJobs(vault: vault.vaultName, region: region); status = nil }
        catch { status = error.localizedDescription }
    }
    @MainActor private func requestInventory() async {
        busy = true; defer { busy = false }
        do {
            let id = try await service.startLegacyJob(vault: vault.vaultName, region: region, archiveID: nil)
            status = "Inventory requested. Job ID: \(id)"
            do { jobs = try await service.listLegacyJobs(vault: vault.vaultName, region: region) }
            catch { status = "Inventory requested. Job ID: \(id). Refresh jobs later: \(error.localizedDescription)" }
        } catch { status = "Request failed or its result is unknown: \(error.localizedDescription). Refresh jobs before retrying." }
    }
    @MainActor private func requestArchive() async {
        busy = true; defer { busy = false }
        do {
            let id = try await service.startLegacyJob(vault: vault.vaultName, region: region, archiveID: archiveID.trimmingCharacters(in: .whitespacesAndNewlines), tier: tier)
            status = "Retrieval requested. Job ID: \(id)"
            do { jobs = try await service.listLegacyJobs(vault: vault.vaultName, region: region) }
            catch { status = "Retrieval requested. Job ID: \(id). Refresh jobs later: \(error.localizedDescription)" }
        } catch { status = "Request failed or its result is unknown: \(error.localizedDescription). Refresh jobs before retrying." }
    }
    @MainActor private func openInventory(_ job: LegacyJob) async {
        busy = true; defer { busy = false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-inventory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await service.legacyJobOutput(vault: vault.vaultName, region: region, job: job, destination: file)
            let parsed = try await Task.detached(priority: .utility) { try JSONDecoder().decode(VaultInventory.self, from: Data(contentsOf: file)) }.value
            inventory = parsed.ArchiveList; inventoryDate = parsed.InventoryDate ?? "Unknown"; status = "Inventory loaded."
        } catch { status = error.localizedDescription }
    }
    @MainActor private func chooseDestination(_ job: LegacyJob) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "glacier-archive"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            busy = true; defer { busy = false }
            do { try await service.legacyJobOutput(vault: vault.vaultName, region: region, job: job, destination: destination); status = "Archive downloaded and checksum verified." }
            catch { status = error.localizedDescription }
        }
    }
    @MainActor private func upload(_ file: URL) async {
        busy = true; defer { busy = false; uploadFile = nil }
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        do {
            let id = try await service.uploadLegacyArchive(vault: vault.vaultName, region: region, file: file)
            var saved = (try? JSONDecoder().decode([SavedLegacyUpload].self, from: uploadedData)) ?? []
            saved.insert(SavedLegacyUpload(id: id, profile: profile, region: region, vault: vault.vaultName, filename: file.lastPathComponent), at: 0)
            if let data = try? JSONEncoder().encode(saved) { uploadedData = data }
            status = "Upload complete. Archive ID (also saved on this Mac): \(id)"
        }
        catch { status = "Upload failed or its result is unknown: \(error.localizedDescription). Check your vault inventory before retrying to avoid a duplicate." }
    }
}
