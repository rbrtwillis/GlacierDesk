import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

private struct SavedLegacyUpload: Codable, Identifiable {
    let id: String
    let profile: String
    let accountID: String?
    let region: String
    let vault: String
    let filename: String

    init(id: String, profile: String, accountID: String? = nil, region: String, vault: String, filename: String) {
        self.id = id; self.profile = profile; self.accountID = accountID
        self.region = region; self.vault = vault; self.filename = filename
    }
}

struct LegacyVaultDetailView: View {
    let profile: String
    let accountID: String
    let region: String
    let vault: LegacyVault
    @Binding var externalBusy: Bool
    let back: () -> Void
    @State private var jobs: [LegacyJob] = []
    @State private var refreshInFlight = false
    @State private var hasLoadedJobs = false
    @State private var notifiedJobStates: [String: String] = [:]
    @State private var jobRefreshError: String?
    @State private var inventoryDate: String?
    @State private var inventoryFolders: LegacyInventoryFolders?
    @State private var locallyAddedArchiveIDs = Set<String>()
    @State private var currentInventoryFolder = ""
    @State private var visibleInventoryFolders: [String] = []
    @State private var inventoryPage: GlacierArchivePage?
    @State private var inventoryIndexError: String?
    @State private var inventoryOffset = 0
    @State private var inventoryQueryToken = UUID()
    @State private var cachedInventoryIndex: GlacierInventoryIndex?
    @State private var inventorySortChoice = "creationDate"
    @State private var inventoryAscending = false
    private let inventoryPageSize = 100
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
    @AppStorage("legacyJobNotificationsEnabled") private var jobNotificationsEnabled = false
    @AppStorage("uploadThresholdMiB") private var uploadThresholdMiB = 64
    @AppStorage("uploadPartSizeMiB") private var uploadPartSizeMiB = 16
    @AppStorage("uploadConnections") private var uploadConnections = 4
    @AppStorage("legacyParallelFiles") private var legacyParallelFiles = 1
    @State private var folderPlan: FolderUploadPlan?
    @State private var folderScopes: [URL] = []
    @State private var showFolderReview = false
    @State private var preparingDrop = false
    @State private var dropTargeted = false
    @State private var uploadQueue: [QueuedUpload] = []
    @State private var queueTask: Task<Void, Never>?
    @State private var queueProgress: Double = 0
    @State private var activeUploadDetail: String?
    @State private var activeUploadToken: UUID?
    @State private var preparingFolderUpload = false
    @State private var durableQueue: DurableTransferQueue?
    @State private var durableTransferHistory: [DurableTransferSession] = []
    @State private var showTransferHistory = false
    @State private var clearingPendingQueue = false
    @State private var selectedQueueItems = Set<UUID>()
    @State private var currentQueueIDs: [UUID: UUID] = [:]
    @State private var openQueueAfterReview = false
    @State private var reviewedLegacyRetrySession: DurableTransferSession?
    @State private var reviewedLegacyRetryItems: [DurableTransferItem] = []
    @State private var confirmLegacyRetry = false
    @State private var showMigration = false
    @State private var migrationBuckets: [AWSBucket] = []
    @State private var migrationBucket = ""
    @State private var migrationPrefix = ""
    @State private var migrationAssessment: MigrationAssessment?
    @State private var showBulkRetrieval = false
    private var service: AWSService { AWSService(profile: profile) }
    private var inventoryScope: GlacierInventoryScope {
        GlacierInventoryScope(profile: profile, accountID: accountID, region: region, vault: vault.vaultName)
    }
    private var inventoryIndex: GlacierInventoryIndex? {
        if let cachedInventoryIndex { return cachedInventoryIndex }
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let database = root.appendingPathComponent("GlacierDesk/legacy-inventory.sqlite", isDirectory: false)
        let index = try? GlacierInventoryIndex(databaseURL: database)
        cachedInventoryIndex = index
        return index
    }
    private var selectedInventorySort: GlacierArchiveSort {
        switch inventorySortChoice {
        case "description": .description
        case "size": .size
        case "archiveID": .archiveID
        default: .creationDate
        }
    }
    private var visibleArchives: [IndexedGlacierArchive] {
        inventoryPage?.archives ?? []
    }

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
                    Button("Upload files or folders…") { chooseLegacyUpload() }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                Text(dropTargeted ? "Drop to prepare upload" : "Drag files or folders from Finder here to prepare an upload queue.")
                    .font(.caption).foregroundStyle(GlacierTheme.accent)
                if !uploadQueue.isEmpty {
                    ProgressView(value: queueProgress)
                    if queueTask != nil { Button("Cancel queue") { queueTask?.cancel() } }
                    ForEach(uploadQueue) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.item.key).font(.caption.monospaced()).textSelection(.enabled)
                            Text(entry.state).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                Button("Transfer queue…") { showTransferHistory = true; Task { await refreshTransferHistory() } }
                if let status { Text(status).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                Divider()
                Text("Jobs").font(.headline)
                Toggle("Notify me when a Glacier job finishes", isOn: $jobNotificationsEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                if let jobRefreshError { Text("Automatic job refresh failed: \(jobRefreshError)").font(.caption).foregroundStyle(.secondary) }
                if jobs.isEmpty { Text("No recent jobs found. Refresh to check AWS.").foregroundStyle(.secondary) }
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(job.action ?? "Job") · \(job.statusCode ?? "Unknown")").font(.subheadline.weight(.semibold))
                        if job.statusCode == "Succeeded" && (job.action == "ArchiveRetrieval" || job.action == "InventoryRetrieval") {
                            Label("AWS keeps job output for at least 24 hours; opened inventories remain cached on this Mac", systemImage: "clock")
                                .font(.caption).foregroundStyle(.orange)
                        } else if job.statusCode == "InProgress" {
                            Label("AWS is processing this job; jobs refresh automatically while in progress", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
                let saved = ((try? JSONDecoder().decode([SavedLegacyUpload].self, from: uploadedData)) ?? []).filter { $0.profile == profile && $0.accountID == accountID && $0.region == region && $0.vault == vault.vaultName }
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
                let olderUploads = ((try? JSONDecoder().decode([SavedLegacyUpload].self, from: uploadedData)) ?? []).filter { $0.profile == profile && $0.accountID == nil && $0.region == region && $0.vault == vault.vaultName }
                if !olderUploads.isEmpty {
                    DisclosureGroup("Older uploads with unverified account (\(olderUploads.count))") {
                        Text("These records predate account tracking. Verify the AWS account before using an archive ID.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(olderUploads) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.filename).font(.caption)
                                Text(item.id).font(.caption.monospaced()).textSelection(.enabled)
                            }.padding(.vertical, 3)
                        }
                    }
                    Divider()
                }
                Text("Browse inventory").font(.headline)
                if let inventoryDate { Text("Cached inventory date: \(inventoryDate) · Saved on this Mac until replaced or removed").font(.caption).foregroundStyle(.secondary) }
                if inventoryDate != nil {
                    Button("Compare inventory with S3…") { showMigration = true; migrationAssessment = nil }
                        .disabled(busy || inventoryPage == nil || inventoryIndexError != nil)
                    Button("Bulk retrieve visible archives…") { showBulkRetrieval = true }
                        .disabled(busy || inventoryPage == nil || inventoryIndexError != nil)
                    Text("Read-only comparison. Candidate matches are based on archive description and reported size; they do not verify object contents.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !locallyAddedArchiveIDs.isEmpty { Text("Includes \(locallyAddedArchiveIDs.count) locally recorded uploads not yet present in the AWS inventory snapshot.").font(.caption).foregroundStyle(.secondary) }
                Text("Folders are reconstructed from archive descriptions. Search applies to the current folder; files without a usable path appear at the root.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("← Parent folder") {
                        currentInventoryFolder = currentInventoryFolder.split(separator: "/").dropLast().joined(separator: "/")
                        inventoryOffset = 0; Task { await loadInventoryPage() }
                    }.disabled(currentInventoryFolder.isEmpty)
                    Button("Vault root") { currentInventoryFolder = ""; inventoryOffset = 0; Task { await loadInventoryPage() } }
                        .disabled(currentInventoryFolder.isEmpty)
                    Text(currentInventoryFolder.isEmpty ? "/" : "/" + currentInventoryFolder).textSelection(.enabled)
                }
                TextField("Search current folder", text: $search).textFieldStyle(.roundedBorder)
                    .onChange(of: search) { _ in inventoryOffset = 0; Task { await loadInventoryPage() } }
                HStack {
                    Picker("Sort", selection: $inventorySortChoice) {
                        Text("Date").tag("creationDate"); Text("Name").tag("description")
                        Text("Size").tag("size"); Text("Archive ID").tag("archiveID")
                    }.frame(width: 200)
                    Toggle("Ascending", isOn: $inventoryAscending).toggleStyle(.checkbox).font(.caption)
                }
                .onChange(of: inventorySortChoice) { _ in inventoryOffset = 0; Task { await loadInventoryPage() } }
                .onChange(of: inventoryAscending) { _ in inventoryOffset = 0; Task { await loadInventoryPage() } }
                if let inventoryIndexError { Text("Local inventory index is unavailable. Reload a completed inventory before browsing or comparing: \(inventoryIndexError)").font(.caption).foregroundStyle(.orange) }
                ForEach(visibleInventoryFolders, id: \.self) { folder in
                    Button {
                        currentInventoryFolder = currentInventoryFolder.isEmpty ? folder : currentInventoryFolder + "/" + folder
                        search = ""; inventoryOffset = 0; Task { await loadInventoryPage() }
                    } label: { Label(folder, systemImage: "folder.fill").frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).padding(.vertical, 5)
                }
                ForEach(visibleArchives) { archive in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(LegacyInventoryFolders.filename(archive), systemImage: "doc").font(.subheadline.weight(.medium)).textSelection(.enabled)
                        if locallyAddedArchiveIDs.contains(archive.archiveID) { Text("Uploaded from this Mac · not yet in AWS inventory snapshot").font(.caption).foregroundStyle(.secondary) }
                        DisclosureGroup("Archive details") {
                            Text("Archive ID: \(archive.archiveID)").font(.caption.monospaced()).textSelection(.enabled)
                            if let description = archive.description { Text("Description: \(description)").font(.caption).textSelection(.enabled) }
                        }
                        Text("\(archive.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown size") · \(archive.creationDate ?? "Unknown date")").font(.caption).foregroundStyle(.secondary)
                        Button("Select for retrieval") { archiveID = archive.archiveID }.disabled(busy)
                    }.padding(.vertical, 5)
                }
                if let page = inventoryPage, page.totalCount > inventoryPageSize {
                    HStack {
                        Button("Previous") { inventoryOffset = max(0, inventoryOffset - inventoryPageSize); Task { await loadInventoryPage() } }
                            .disabled(busy || inventoryOffset == 0)
                        Text("\(inventoryOffset + 1)–\(min(inventoryOffset + page.archives.count, page.totalCount)) of \(page.totalCount)").font(.caption).foregroundStyle(.secondary)
                        Button("Next") { inventoryOffset += inventoryPageSize; Task { await loadInventoryPage() } }
                            .disabled(busy || inventoryOffset + page.archives.count >= page.totalCount)
                    }
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
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: acceptDrop)
        .onChange(of: busy) { externalBusy = $0 }
        .onDisappear { externalBusy = false }
        .sheet(isPresented: $showFolderReview, onDismiss: {
            releaseFolderScopes()
            if openQueueAfterReview { openQueueAfterReview = false; showTransferHistory = true }
        }) {
            if let plan = folderPlan { folderReview(plan) }
        }
        .sheet(isPresented: $showMigration) {
            if let assessment = migrationAssessment {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Done") { showMigration = false; migrationAssessment = nil }
                    MigrationView(assessment: assessment)
                }.padding(12).frame(minWidth: 680, minHeight: 480)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Compare inventory with S3").font(.title2.weight(.semibold))
                    Text("Choose a destination bucket and optional prefix. GlacierDesk will read the complete object listing under that location to compare names and reported sizes. AWS request charges may apply. No objects will be changed.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("Destination bucket", selection: $migrationBucket) {
                        Text("Select a bucket").tag("")
                        ForEach(migrationBuckets) { bucket in Text(bucket.name).tag(bucket.name) }
                    }.disabled(migrationBuckets.isEmpty || busy)
                    TextField("Destination prefix (optional)", text: $migrationPrefix)
                        .textFieldStyle(.roundedBorder).disabled(busy)
                    if migrationBuckets.isEmpty && !busy { Text("No S3 buckets are available for this profile.").foregroundStyle(.secondary) }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack {
                        Button("Cancel") { showMigration = false }
                        Spacer()
                        Button("Read listing and compare") { Task { await compareInventory() } }
                            .buttonStyle(.borderedProminent).disabled(busy || migrationBucket.isEmpty)
                    }
                }.padding(22).frame(width: 560)
                    .task { await loadMigrationBuckets() }
            }
        }
        .sheet(isPresented: $showBulkRetrieval) {
            BulkLegacyRetrievalView(profile: profile, accountID: accountID, region: region, vault: vault.vaultName,
                archives: visibleArchives.map { BulkRetrievalArchive(id: $0.archiveID, description: $0.description, size: $0.size) })
                .frame(minWidth: 680, minHeight: 560)
        }
        .background(FloatingQueueWindow(isPresented: $showTransferHistory, content:
            VStack(alignment: .leading, spacing: 12) {
                Text("Legacy transfer queue").font(.title2.weight(.semibold))
                if let status { Text(status).textSelection(.enabled) }
                if queueTask != nil {
                    ProgressView("Overall queue", value: queueProgress)
                    if let activeUploadDetail { Text(activeUploadDetail).font(.callout).textSelection(.enabled) }
                }
                HStack {
                    Button("Stop all active transfers") { queueTask?.cancel() }.disabled(queueTask == nil)
                    Button("Resume…") { Task { await prepareResume() } }
                        .disabled(busy || queueTask != nil || clearingPendingQueue || !hasResumableItems)
                    Button(selectedQueueItems.isEmpty ? "Cancel all pending" : "Cancel selected pending") { Task { await editQueue(clear: false) } }
                        .disabled(clearingPendingQueue)
                    Button(selectedQueueItems.isEmpty ? "Clear finished" : "Clear selected finished") { Task { await editQueue(clear: true) } }
                        .disabled(clearingPendingQueue || queueTask != nil)
                    Spacer()
                }
                Text("Select items below to act on individual files; with nothing selected, actions apply to all eligible files. Clear removes completed, failed, and cancelled items; uncertain results remain for inspection.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("A result marked outcome unknown may have created an archive in AWS. Inspect the vault before taking any further action. Resume starts eligible files again after review; multipart parts do not resume. Uncertain uploads cannot be retried safely without inspection.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                List {
                    if !uploadQueue.isEmpty {
                        Section("Current queue") {
                            ForEach(uploadQueue) { item in
                                HStack(alignment: .top) {
                                    if let recordID = currentQueueIDs[item.id] {
                                        Toggle("Select \(item.item.key)", isOn: Binding(get: { selectedQueueItems.contains(recordID) }, set: { selected in if selected { selectedQueueItems.insert(recordID) } else { selectedQueueItems.remove(recordID) } }))
                                            .labelsHidden().toggleStyle(.checkbox)
                                    }
                                    VStack(alignment: .leading) {
                                        Text(item.item.key).font(.caption.monospaced()).textSelection(.enabled)
                                        Text(item.state).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                    ForEach(durableTransferHistory) { session in
                        Section("\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(session.region ?? "Region unknown") · \(session.vault ?? "Vault unknown")") {
                            if session.kind == .legacyArchiveUpload && session.profile == profile && session.accountID == accountID {
                                Button("Review safe pending items…") { Task { await prepareLegacyRetryReview(session) } }
                                    .disabled(busy || queueTask != nil)
                            }
                            ForEach(session.items) { item in
                                HStack(alignment: .top) {
                                    Toggle("Select \(item.target)", isOn: Binding(get: { selectedQueueItems.contains(item.id) }, set: { selected in if selected { selectedQueueItems.insert(item.id) } else { selectedQueueItems.remove(item.id) } }))
                                        .labelsHidden().toggleStyle(.checkbox)
                                    VStack(alignment: .leading, spacing: 3) {
                                    Text(item.target).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(item.detail.map { "\(item.state.rawValue) · \($0)" } ?? item.state.rawValue)
                                        .font(.caption).foregroundStyle(item.state == .outcomeUnknown ? .orange : .secondary).textSelection(.enabled)
                                    }
                                }.padding(.vertical, 3)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Refresh history") { Task { await refreshTransferHistory() } }
                    Button("Done") { showTransferHistory = false }
                }
            }.padding(18).frame(minWidth: 620, minHeight: 440)
            .confirmationDialog("Retry selected legacy folder uploads?", isPresented: $confirmLegacyRetry, titleVisibility: .visible) {
                Button("I reviewed the risks — retry \(reviewedLegacyRetryItems.count) items") {
                    guard let session = reviewedLegacyRetrySession else { return }
                    Task { await retryLegacyFolderItems(session) }
                }
                Button("Cancel", role: .cancel) { clearLegacyRetryReview() }
            } message: { Text(legacyRetryReviewText) }
        ))
        .task {
            await refresh()
            await restoreCachedInventory()
            await refreshTransferHistory()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                guard jobs.contains(where: { $0.statusCode == "InProgress" }) else { continue }
                await refresh(automatic: true)
            }
        }
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
        } message: { Text("Storage and request charges apply. Multipart uploads use the configured transfer settings. Save the returned archive ID.") }
    }

    @MainActor private func refresh(automatic: Bool = false) async {
        guard !refreshInFlight, !busy else { return }
        refreshInFlight = true; busy = true
        defer { refreshInFlight = false; busy = false }
        do {
            let updated = try await service.listLegacyJobs(vault: vault.vaultName, region: region)
            let previous = Dictionary(uniqueKeysWithValues: jobs.map { ($0.jobId, $0.statusCode ?? "Unknown") })
            jobs = updated
            if hasLoadedJobs {
                for job in updated {
                    let state = job.statusCode ?? "Unknown"
                    let oldState = previous[job.jobId] ?? notifiedJobStates[job.jobId]
                    if oldState == "InProgress" && (state == "Succeeded" || state == "Failed" || state == "Expired") {
                        notifyJobCompletion(job, state: state)
                    }
                }
            }
            notifiedJobStates = Dictionary(uniqueKeysWithValues: updated.map { ($0.jobId, $0.statusCode ?? "Unknown") })
            hasLoadedJobs = true
            jobRefreshError = nil
            if !automatic { status = nil }
        } catch {
            jobRefreshError = error.localizedDescription
            if !automatic { status = error.localizedDescription }
        }
    }

    @MainActor private func notifyJobCompletion(_ job: LegacyJob, state: String) {
        guard jobNotificationsEnabled else { return }
        let title = "Glacier job \(state.lowercased())"
        let message = "\(job.action ?? "Job") in vault \(vault.vaultName) has \(state.lowercased())."
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default
            let request = UNNotificationRequest(identifier: "glacier-job-\(job.jobId)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    @MainActor private func loadMigrationBuckets() async {
        guard migrationBuckets.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            migrationBuckets = try await service.listBuckets()
            if migrationBuckets.count == 1 { migrationBucket = migrationBuckets[0].name }
            status = nil
        } catch { status = "Could not load S3 buckets: \(error.localizedDescription)" }
    }

    @MainActor private func compareInventory() async {
        guard inventoryDate != nil, !migrationBucket.isEmpty, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let objects = try await service.listAllObjects(bucket: migrationBucket, prefix: migrationPrefix)
            guard let index = inventoryIndex else { throw InventoryIndexError.sqlite("Application Support directory is unavailable") }
            let scope = inventoryScope, date = inventoryDate, vaultName = vault.vaultName
            let bucket = migrationBucket, prefix = migrationPrefix
            let sort = selectedInventorySort, ascending = inventoryAscending
            migrationAssessment = try await Task.detached(priority: .userInitiated) {
                var archives: [MigrationArchive] = []
                try index.forEachArchive(scope: scope, sort: sort, ascending: ascending) { archive in
                    archives.append(MigrationArchive(archiveID: archive.archiveID, description: archive.description,
                        size: archive.size, creationDate: archive.creationDate))
                }
                return MigrationAssessmentBuilder.build(archives: archives, inventoryDate: date,
                    vaultName: vaultName, bucketName: bucket, prefix: prefix, objects: objects)
            }.value
            status = nil
        } catch { status = "S3 listing or comparison failed: \(error.localizedDescription)" }
    }
    @MainActor private func requestInventory() async {
        busy = true; defer { busy = false }
        do {
            let id = try await service.startLegacyJob(vault: vault.vaultName, region: region, archiveID: nil)
            let requestStatus = "Inventory requested. Job ID: \(id)"
            busy = false
            await refresh()
            status = requestStatus
        } catch { status = "Request failed or its result is unknown: \(error.localizedDescription). Refresh jobs before retrying." }
    }
    @MainActor private func requestArchive() async {
        busy = true; defer { busy = false }
        do {
            let id = try await service.startLegacyJob(vault: vault.vaultName, region: region, archiveID: archiveID.trimmingCharacters(in: .whitespacesAndNewlines), tier: tier)
            let requestStatus = "Retrieval requested. Job ID: \(id)"
            busy = false
            await refresh()
            status = requestStatus
        } catch { status = "Request failed or its result is unknown: \(error.localizedDescription). Refresh jobs before retrying." }
    }
    @MainActor private func openInventory(_ job: LegacyJob) async {
        busy = true; defer { busy = false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-inventory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await service.legacyJobOutput(vault: vault.vaultName, region: region, job: job, destination: file)
            guard let index = inventoryIndex else { throw InventoryIndexError.sqlite("Application Support directory is unavailable") }
            let scope = inventoryScope
            let date = try await Task.detached(priority: .utility) { try index.importInventoryJSON(at: file, scope: scope) }.value
            inventoryDate = date ?? "Unknown"
            inventoryFolders = nil; currentInventoryFolder = ""; visibleInventoryFolders = []
            inventoryIndexError = nil
            inventoryOffset = 0
            await loadInventoryPage()
            status = "Inventory loaded and indexed."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func restoreCachedInventory() async {
        guard let index = inventoryIndex else { return }
        let scope = inventoryScope
        do {
            let snapshot = try await Task.detached(priority: .utility) { try index.snapshot(scope: scope) }.value
            guard let snapshot else { return }
            inventoryDate = snapshot.inventoryDate ?? "Unknown"
            await loadInventoryPage()
        } catch { inventoryIndexError = error.localizedDescription }
    }

    @MainActor private func loadInventoryPage() async {
        guard let index = inventoryIndex else { inventoryIndexError = "Application Support directory is unavailable"; inventoryPage = nil; return }
        let token = UUID(); inventoryQueryToken = token
        let scope = inventoryScope, query = search, offset = inventoryOffset, size = inventoryPageSize
        let sort = selectedInventorySort, ascending = inventoryAscending
        do {
            let existing = inventoryFolders, folder = currentInventoryFolder, existingLocal = locallyAddedArchiveIDs
            let locallySaved = ((try? JSONDecoder().decode([SavedLegacyUpload].self, from: uploadedData)) ?? []).filter { $0.profile == profile && $0.accountID == accountID && $0.region == region && $0.vault == vault.vaultName }.map { IndexedGlacierArchive(archiveID: $0.id, description: String($0.filename.unicodeScalars.map { (32...126).contains($0.value) ? Character($0) : "_" }.prefix(1024))) }
            let result = try await Task.detached(priority: .utility) {
                var tree = existing ?? LegacyInventoryFolders()
                var localIDs = existingLocal
                if existing == nil {
                    var savedByID = Dictionary(locallySaved.map { ($0.archiveID, $0) }, uniquingKeysWith: { first, _ in first })
                    try index.forEachArchive(scope: scope) { archive in tree.add(archive); savedByID.removeValue(forKey: archive.archiveID) }
                    localIDs = Set(savedByID.keys)
                    for archive in savedByID.values { tree.add(archive) }
                }
                return (tree, tree.listing(folder: folder, search: query, offset: offset, pageSize: size, sort: sort, ascending: ascending), localIDs)
            }.value
            guard inventoryQueryToken == token else { return }
            inventoryFolders = result.0
            locallyAddedArchiveIDs = result.2
            visibleInventoryFolders = result.1.folders
            inventoryPage = result.1.page
            inventoryIndexError = nil
        } catch { guard inventoryQueryToken == token else { return }; inventoryIndexError = error.localizedDescription; inventoryPage = nil }
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
            var settings = UploadSettings(); settings.thresholdMiB = uploadThresholdMiB; settings.partSizeMiB = uploadPartSizeMiB; settings.connections = uploadConnections
            let id = try await service.uploadLegacyArchive(vault: vault.vaultName, region: region, file: file, settings: settings)
            saveUpload(id: id, filename: file.lastPathComponent)
            status = "Upload complete. Archive ID (also saved on this Mac): \(id)"
        }
        catch { status = "Upload failed or its result is unknown: \(error.localizedDescription). Check your vault inventory before retrying to avoid a duplicate." }
    }

    @MainActor private func saveUpload(id: String, filename: String) {
        var saved = (try? JSONDecoder().decode([SavedLegacyUpload].self, from: uploadedData)) ?? []
        saved.insert(SavedLegacyUpload(id: id, profile: profile, accountID: accountID, region: region, vault: vault.vaultName, filename: filename), at: 0)
        if let data = try? JSONEncoder().encode(saved) { uploadedData = data }
    }

    private func folderReview(_ plan: FolderUploadPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review legacy vault upload").font(.title2.weight(.semibold))
            Text("\(plan.items.count) archives → \(vault.vaultName) · \(region) · /\(plan.prefix)")
            Text("Threshold: \(plan.settings.thresholdMiB) MiB · Part size: \(plan.settings.partSizeMiB) MiB · Multipart requests per file: \(plan.settings.connections) · Files at once: \(min(16, max(1, legacyParallelFiles)))").font(.caption)
            Text("Legacy Glacier stores independent archives, not folders. Paths are stored as archive descriptions; non-ASCII characters are replaced and descriptions are limited to 1,024 bytes. Parts are rounded up to a supported power-of-two size. Private snapshots and parallel parts require temporary disk space. Uploads incur AWS charges; empty files, folders and symbolic links are not supported.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(plan.items) { item in Text(item.key).font(.caption.monospaced()).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { showFolderReview = false }
                Button("Upload \(plan.items.count) files") { openQueueAfterReview = true; showFolderReview = false; Task { await startFolderUpload(plan) } }
                    .buttonStyle(.borderedProminent).disabled(busy || preparingFolderUpload)
            }
        }.padding(20).frame(width: 680, height: 520)
    }

    @MainActor private func releaseFolderScopes() {
        for url in folderScopes { url.stopAccessingSecurityScopedResource() }
        folderScopes = []; folderPlan = nil
    }

    @MainActor private func chooseLegacyUpload() {
        guard !busy, !preparingDrop else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        let roots = panel.urls, prefix = currentInventoryFolder.isEmpty ? "" : currentInventoryFolder + "/"
        for url in roots where url.startAccessingSecurityScopedResource() { folderScopes.append(url) }
        var settings = UploadSettings(); settings.thresholdMiB = uploadThresholdMiB; settings.partSizeMiB = uploadPartSizeMiB; settings.connections = uploadConnections
        preparingDrop = true
        Task { @MainActor in
            defer { preparingDrop = false }
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try FolderUploadPlan.build(roots: roots, bucket: vault.vaultName, prefix: prefix, profile: profile, storageClass: "Legacy Glacier", settings: settings)
                }.value
                guard !busy, prefix == (currentInventoryFolder.isEmpty ? "" : currentInventoryFolder + "/") else { throw FolderUploadError.message("The destination changed while preparing the queue. Choose the files again.") }
                folderPlan = plan; showFolderReview = true
            } catch { releaseFolderScopes(); status = error.localizedDescription }
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy, !preparingDrop else { return false }
        var settings = UploadSettings(); settings.thresholdMiB = uploadThresholdMiB; settings.partSizeMiB = uploadPartSizeMiB; settings.connections = uploadConnections
        let prefix = currentInventoryFolder.isEmpty ? "" : currentInventoryFolder + "/"
        preparingDrop = true
        Task { @MainActor in
            defer { preparingDrop = false }
            do {
                var roots: [URL] = []
                for provider in providers {
                    let url: URL = try await withCheckedThrowingContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                            if let error { continuation.resume(throwing: error); return }
                            if let url = item as? URL { continuation.resume(returning: url); return }
                            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { continuation.resume(returning: url); return }
                            continuation.resume(throwing: FolderUploadError.message("Could not read a Finder item."))
                        }
                    }
                    guard url.isFileURL else { throw FolderUploadError.message("Only local files and folders can be uploaded.") }
                    roots.append(url)
                    if url.startAccessingSecurityScopedResource() { folderScopes.append(url) }
                }
                let plan = try await Task.detached(priority: .userInitiated) {
                    try FolderUploadPlan.build(roots: roots, bucket: vault.vaultName, prefix: prefix, profile: profile, storageClass: "Legacy Glacier", settings: settings)
                }.value
                guard !busy, prefix == (currentInventoryFolder.isEmpty ? "" : currentInventoryFolder + "/") else { throw FolderUploadError.message("The destination changed or the vault became busy. Drop the folder again.") }
                folderPlan = plan; showFolderReview = true
            } catch { releaseFolderScopes(); status = error.localizedDescription }
        }
        return true
    }

    @MainActor private func startFolderUpload(_ plan: FolderUploadPlan) async {
        guard !busy, !preparingFolderUpload, queueTask == nil else { status = "The vault is busy. Prepare the upload again."; return }
        preparingFolderUpload = true
        busy = true
        defer { preparingFolderUpload = false }
        let access = plan.roots.map { ($0, $0.startAccessingSecurityScopedResource()) }
        let uploadService = service
        let sessionID = UUID()
        let queue: DurableTransferQueue
        let session: DurableTransferSession
        do {
            queue = try getDurableTransferQueue()
            let durableItems = try plan.items.map { item -> DurableTransferItem in
                let fileBookmark = try legacyDurableBookmark(for: item.file)
                let rootBookmark = try legacyDurableBookmark(for: item.root)
                let rootIdentity = item.rootIdentity ?? item.fileIdentity
                return DurableTransferItem(sourcePath: item.file.path, sourceBookmark: fileBookmark,
                    sourceDevice: UInt64(item.fileIdentity.device), sourceInode: UInt64(item.fileIdentity.inode),
                    target: item.key, rootPath: item.root.path, rootBookmark: rootBookmark,
                    rootDevice: UInt64(rootIdentity.device), rootInode: UInt64(rootIdentity.inode),
                    relativeComponents: item.components)
            }
            session = DurableTransferSession(id: sessionID, kind: .legacyArchiveUpload, accountID: accountID,
                profile: profile, destination: "glacier://\(region)/\(vault.vaultName)",
                thresholdMiB: plan.settings.thresholdMiB, partSizeMiB: plan.settings.partSizeMiB,
                connections: plan.settings.connections, vault: vault.vaultName, region: region, items: durableItems)
            try await queue.add(session)
        } catch {
            for (url, granted) in access where granted { url.stopAccessingSecurityScopedResource() }
            busy = false
            status = "Could not save the durable upload queue; no AWS upload was started: \(error.localizedDescription)"
            return
        }
        durableQueue = queue
        uploadQueue = plan.items.map { QueuedUpload(item: $0) }
        currentQueueIDs = Dictionary(uniqueKeysWithValues: zip(uploadQueue.map(\.id), session.items.map(\.id)))
        queueProgress = 0
        await refreshTransferHistory()
        queueTask = Task { @MainActor in
            defer {
                for (url, granted) in access where granted { url.stopAccessingSecurityScopedResource() }
                busy = false; queueTask = nil; activeUploadToken = nil; activeUploadDetail = nil
            }
            let completed = await runParallelLegacy(items: plan.items, records: session.items, sessionID: sessionID, settings: plan.settings, queue: queue, service: uploadService)
            await refreshTransferHistory()
            if completed > 0 && inventoryDate != nil { inventoryFolders = nil; await loadInventoryPage() }
        }
    }

    private func legacyDurableBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    @MainActor private func getDurableTransferQueue() throws -> DurableTransferQueue {
        if let durableQueue { return durableQueue }
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DurableTransferQueueError.database("Application Support directory is unavailable.")
        }
        let queue = try DurableTransferQueue.shared(fileURL: root.appendingPathComponent("GlacierDesk/transfers.sqlite"))
        durableQueue = queue
        return queue
    }

    private var hasResumableItems: Bool {
        durableTransferHistory.contains { session in
            session.items.contains { item in (item.state == .queued || item.state == .failed) && (selectedQueueItems.isEmpty || selectedQueueItems.contains(item.id)) }
        }
    }

    @MainActor private func prepareResume() async {
        await refreshTransferHistory()
        let eligibleSessions = durableTransferHistory.filter { session in
            session.items.contains { item in (item.state == .queued || item.state == .failed) && (selectedQueueItems.isEmpty || selectedQueueItems.contains(item.id)) }
        }
        let currentIDs = Set(currentQueueIDs.values)
        let session = eligibleSessions.last(where: { $0.items.contains { currentIDs.contains($0.id) } }) ?? eligibleSessions.last
        guard let session else { status = "No eligible pending or failed files to resume."; return }
        if !selectedQueueItems.isEmpty && eligibleSessions.count > 1 {
            status = "Select files from one saved queue at a time to resume."; return
        }
        await prepareLegacyRetryReview(session)
    }

    private var legacyRetryReviewText: String {
        let session = reviewedLegacyRetrySession
        let targets = reviewedLegacyRetryItems.prefix(10).map(\.target).joined(separator: ", ") + (reviewedLegacyRetryItems.count > 10 ? ", …" : "")
        return "\(reviewedLegacyRetryItems.count) queued or failed item(s) will be retried in \(session?.vault ?? vault.vaultName) (\(session?.region ?? region)) using the original saved session. AWS upload and request charges may apply. A prior ambiguous request may already have created an archive; inspect Glacier before any manual retry. Items marked outcome unknown, in progress, or completed are never included. This retry is explicit and is not automatic. Items: \(targets)"
    }

    @MainActor private func clearLegacyRetryReview() {
        reviewedLegacyRetrySession = nil
        reviewedLegacyRetryItems = []
    }

    @MainActor private func prepareLegacyRetryReview(_ session: DurableTransferSession) async {
        guard !busy, queueTask == nil, session.kind == .legacyArchiveUpload,
              session.profile == profile, session.accountID == accountID,
              session.vault == vault.vaultName, session.region == region else {
            status = "This saved queue does not match the current profile, account, Region, and vault."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let identity = try await service.identity()
            guard identity.account == accountID else {
                throw DurableTransferQueueError.accountMismatch(expected: accountID, actual: identity.account)
            }
            let queue = try getDurableTransferQueue()
            let eligible = try await queue.retryableItems(sessionID: session.id, selectedProfile: profile, currentAccountID: identity.account)
            let selected = selectedQueueItems.isEmpty ? eligible : eligible.filter { selectedQueueItems.contains($0.id) }
            guard !selected.isEmpty else { throw DurableTransferQueueError.noRetryableItems }
            reviewedLegacyRetrySession = session
            reviewedLegacyRetryItems = selected
            confirmLegacyRetry = true
        } catch {
            status = "Could not prepare a safe retry review: \(error.localizedDescription)"
        }
    }

    @MainActor private func retryLegacyFolderItems(_ reviewedSession: DurableTransferSession) async {
        guard !busy, queueTask == nil, reviewedSession.kind == .legacyArchiveUpload,
              reviewedSession.profile == profile, reviewedSession.accountID == accountID,
              reviewedSession.vault == vault.vaultName, reviewedSession.region == region else {
            clearLegacyRetryReview()
            status = "This saved queue no longer matches the current profile, account, Region, and vault."
            return
        }
        busy = true
        var scopes: [(URL, Bool)] = []
        do {
            guard let threshold = reviewedSession.thresholdMiB,
                  let partSize = reviewedSession.partSizeMiB,
                  let connections = reviewedSession.connections else {
                throw DurableTransferQueueError.invalidSource("The saved upload settings are incomplete; prepare the upload again.")
            }
            let identity = try await service.identity()
            guard identity.account == accountID else {
                throw DurableTransferQueueError.accountMismatch(expected: accountID, actual: identity.account)
            }
            let queue = try getDurableTransferQueue()
            let eligible = try await queue.retryableItems(sessionID: reviewedSession.id, selectedProfile: profile, currentAccountID: identity.account)
            let reviewedIDs = Set(reviewedLegacyRetryItems.map(\.id))
            let records = eligible.filter { reviewedIDs.contains($0.id) }
            guard !records.isEmpty, Set(records.map(\.id)) == reviewedIDs else {
                throw DurableTransferQueueError.noRetryableItems
            }

            var rootsByPath: [String: URL] = [:]
            for record in records {
                guard let bookmark = record.rootBookmark else {
                    throw DurableTransferQueueError.invalidSource("A saved folder bookmark is missing. Prepare the upload again.")
                }
                var stale = false
                let root: URL
                do { root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) }
                catch { root = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) }
                guard !stale, root.standardizedFileURL.path == record.rootPath else {
                    throw DurableTransferQueueError.invalidSource("A saved folder bookmark is stale or points to another folder; prepare the upload again.")
                }
                rootsByPath[root.path] = root
            }
            scopes = rootsByPath.values.map { ($0, $0.startAccessingSecurityScopedResource()) }
            let items = try await queue.reconstructFolderItems(records)
            var settings = UploadSettings()
            settings.thresholdMiB = threshold; settings.partSizeMiB = partSize; settings.connections = connections
            let uploadService = service
            uploadQueue = items.map { QueuedUpload(item: $0) }
            currentQueueIDs = Dictionary(uniqueKeysWithValues: zip(uploadQueue.map(\.id), records.map(\.id)))
            queueProgress = 0
            clearLegacyRetryReview()
            queueTask = Task { @MainActor in
                defer {
                    for (url, active) in scopes where active { url.stopAccessingSecurityScopedResource() }
                    busy = false; queueTask = nil; activeUploadToken = nil; activeUploadDetail = nil
                }
                let completed = await runParallelLegacy(items: items, records: records, sessionID: reviewedSession.id, settings: settings, queue: queue, service: uploadService)
                await refreshTransferHistory()
                if completed > 0 && inventoryDate != nil { inventoryFolders = nil; await loadInventoryPage() }
            }
        } catch {
            for (url, active) in scopes where active { url.stopAccessingSecurityScopedResource() }
            busy = false
            status = "Could not retry saved legacy items: \(error.localizedDescription). No retry was started unless a result is marked outcome unknown."
            clearLegacyRetryReview()
        }
    }

    /// Keep a bounded number of files active; each service call independently limits multipart requests.
    @MainActor private func runParallelLegacy(items: [FolderUploadItem], records: [DurableTransferItem], sessionID: UUID,
                                               settings: UploadSettings, queue: DurableTransferQueue, service: AWSService) async -> Int {
        let limit = min(16, max(1, legacyParallelFiles)), total = items.count
        var next = 0, finished = 0, succeeded = 0, failures = 0, stopScheduling = false
        status = "Uploading up to \(limit) files at once · up to \(settings.connections) multipart requests per file"
        await withTaskGroup(of: (Bool, Bool).self) { group in
            func schedule(_ index: Int) {
                group.addTask { @MainActor in
                    await uploadLegacyQueueItem(index: index, item: items[index], record: records[index], sessionID: sessionID, settings: settings, queue: queue, service: service)
                }
            }
            while next < min(limit, total) { schedule(next); next += 1 }
            while let (success, uncertain) = await group.next() {
                finished += 1
                if success { succeeded += 1 } else { failures += 1 }
                if uncertain { stopScheduling = true }
                queueProgress = Double(finished) / Double(max(1, total))
                status = "\(finished) of \(total) processed · \(succeeded) uploaded · \(failures) failed or cancelled"
                if Task.isCancelled { group.cancelAll(); stopScheduling = true }
                if !stopScheduling && next < total { schedule(next); next += 1 }
            }
        }
        if Task.isCancelled { status = "Transfers stopped. Pending files remain queued; review uncertain results." }
        else if stopScheduling { status = "Queue stopped after an uncertain upload. Review its result before retrying; pending files remain queued." }
        else { status = "Queue finished: \(succeeded) uploaded, \(failures) failed or cancelled." }
        return succeeded
    }

    @MainActor private func uploadLegacyQueueItem(index: Int, item: FolderUploadItem, record: DurableTransferItem,
                                                  sessionID: UUID, settings: UploadSettings, queue: DurableTransferQueue,
                                                  service: AWSService) async -> (Bool, Bool) {
        guard !Task.isCancelled else { return (false, false) }
        do {
            guard try await queue.claimLegacyItem(sessionID: sessionID, itemID: record.id) else {
                uploadQueue[index].state = "Cancelled"; return (false, false)
            }
        } catch { uploadQueue[index].state = "Queue error: \(error.localizedDescription)"; return (false, true) }
        uploadQueue[index].state = "Preparing private snapshot"
        var snapshotURL: URL?, submitted = false
        defer { if let snapshotURL { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) } }
        do {
            let snapshot = try await item.snapshot(); snapshotURL = snapshot
            try Task.checkCancellation()
            try await queue.updateItem(sessionID: sessionID, itemID: record.id, state: .inProgress, detail: "Upload request is starting; an interrupted result may be unknown.")
            submitted = true
            uploadQueue[index].state = "Uploading"
            let archiveID = try await service.uploadLegacyArchive(vault: vault.vaultName, region: region, file: snapshot, description: item.key, settings: settings,
                status: { update in Task { @MainActor in
                    guard uploadQueue.indices.contains(index), uploadQueue[index].id == item.id,
                          uploadQueue[index].state.hasPrefix("Uploading") else { return }
                    uploadQueue[index].state = "Uploading · " + Self.describeUpload(update)
                } })
            try await queue.updateItem(sessionID: sessionID, itemID: record.id, state: .completed, detail: "Archive ID: \(archiveID)")
            saveUpload(id: archiveID, filename: item.key)
            uploadQueue[index].state = "Complete · Archive ID: \(archiveID)"
            return (true, false)
        } catch {
            let state: DurableTransferItem.State = submitted ? .outcomeUnknown : .failed
            let detail = submitted ? "Outcome unknown: \(error.localizedDescription). Inspect Glacier before retrying." : "Upload did not reach AWS: \(error.localizedDescription)"
            do { try await queue.updateItem(sessionID: sessionID, itemID: record.id, state: state, detail: detail) }
            catch { uploadQueue[index].state = "Queue persistence failed; inspect AWS before retrying."; return (false, true) }
            uploadQueue[index].state = detail
            return (false, submitted)
        }
    }

    @MainActor private func editQueue(clear: Bool) async {
        guard !clearingPendingQueue, !clear || queueTask == nil else { return }
        clearingPendingQueue = true
        defer { clearingPendingQueue = false }
        do {
            let queue = try getDurableTransferQueue()
            let count = try await queue.editLegacyQueue(profile: profile, accountID: accountID, region: region, vault: vault.vaultName, selected: selectedQueueItems, clear: clear)
            if clear { uploadQueue.removeAll(); selectedQueueItems.removeAll() }
            await refreshTransferHistory()
            if !clear {
                let cancelledTargets = Set(durableTransferHistory.flatMap(\.items).filter { $0.state == .cancelled }.map(\.target))
                for index in uploadQueue.indices where uploadQueue[index].state == "Queued" && cancelledTargets.contains(uploadQueue[index].item.key) { uploadQueue[index].state = "Cancelled" }
            }
            status = clear ? "Cleared \(count) finished items; uncertain uploads remain in history." : "Cancelled \(count) pending items. Active transfers continue."
        } catch { status = "Could not update the queue: \(error.localizedDescription)" }
    }

    private static func describeUpload(_ status: LegacyUploadStatus) -> String {
        switch status {
        case .preparing(let multipart): return "\(multipart ? "Multipart" : "Single request") · calculating checksum…"
        case .singleRequest: return "Single request · uploading (part progress not available)"
        case let .multipart(completed, total, partSize, connections):
            return "Multipart · \(completed) of \(total) parts complete · \(ByteCountFormatter.string(fromByteCount: partSize, countStyle: .binary)) per part · up to \(connections) parallel requests"
        case .completing: return "Multipart · all parts uploaded; confirming archive with AWS…"
        }
    }

    @MainActor private func refreshTransferHistory() async {
        do {
            let queue = try getDurableTransferQueue()
            let sessions = try await queue.allSessions()
            durableTransferHistory = sessions.filter {
                $0.kind == .legacyArchiveUpload && $0.accountID == accountID && $0.profile == profile &&
                $0.region == region && $0.vault == vault.vaultName
            }
        } catch { status = "Could not read transfer history: \(error.localizedDescription)" }
    }
}
