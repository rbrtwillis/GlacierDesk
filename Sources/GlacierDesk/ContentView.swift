import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RestoreRecord: Codable, Identifiable {
    var id = UUID()
    var profile: String
    var account: String
    var bucket: String
    var key: String
    var requested: Date
    var status: String
}

@MainActor
final class GlacierDeskModel: ObservableObject {
    @Published var profiles: [String] = []
    @Published var selectedProfile = ""
    @Published var identity: AWSIdentity?
    @Published var buckets: [AWSBucket] = []
    @Published var selectedBucket: AWSBucket?
    @Published var objects: [AWSObject] = []
    @Published var prefixes: [AWSCommonPrefix] = []
    @Published var prefix = ""
    @Published var continuationToken: String?
    @Published var canLoadMore = false
    @Published var selectedObject: AWSObject?
    @Published var metadata: AWSObjectMetadata?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var activity: [String] = []
    @Published var storageClass = "STANDARD"
    @Published var restoreTier: RestoreTier = .standard
    @Published var connectedProfile: String?
    @Published var restores: [RestoreRecord] = []
    @Published var transferProgress: Double?
    @Published var transferStatus: String?
    @Published var uploadQueue: [QueuedUpload] = []
    @Published var savedTransfers: [DurableTransferSession] = []
    private var transferTask: Task<Void, Never>?
    private var retryTransfer: (() -> Void)?
    @AppStorage("restoreRecords") private var restoreData = Data()
    @AppStorage("uploadThresholdMiB") var uploadThresholdMiB = 64
    @AppStorage("uploadPartSizeMiB") var uploadPartSizeMiB = 16
    @AppStorage("uploadConnections") var uploadConnections = 4
    @AppStorage("legacyParallelFiles") var legacyParallelFiles = 1

    private var service: AWSService? {
        let profile = connectedProfile ?? selectedProfile
        return profile.isEmpty ? nil : AWSService(profile: profile)
    }

    func loadRestores() { restores = (try? JSONDecoder().decode([RestoreRecord].self, from: restoreData)) ?? [] }
    private func saveRestores() { if let data = try? JSONEncoder().encode(restores) { restoreData = data } }

    func refreshRestores() async {
        guard let service, let account = identity?.account, let profile = connectedProfile else { return }
        for record in restores where record.account == account && record.profile == profile {
            do {
                let metadata = try await service.headObject(bucket: record.bucket, key: record.key)
                if let index = restores.firstIndex(where: { $0.id == record.id }) {
                    restores[index].status = metadata.restore ?? "Archived or restore expired"
                }
            } catch {
                if let index = restores.firstIndex(where: { $0.id == record.id }) { restores[index].status = "Refresh failed: \(error.localizedDescription)" }
            }
        }
        saveRestores()
    }

    func cancelTransfer() { transferTask?.cancel(); transferStatus = "Cancelling…" }
    func retryLastTransfer() { retryTransfer?() }
    var canRetryTransfer: Bool { transferTask == nil && retryTransfer != nil }
    var transferActive: Bool { transferTask != nil }
    func startUpload(_ url: URL) {
        guard transferTask == nil else { return }
        retryTransfer = { [weak self] in self?.startUpload(url) }
        transferTask = Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() }; transferTask = nil }
            await upload(url)
        }
    }
    private func transferStore() throws -> DurableTransferQueue {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DurableTransferQueueError.database("Application Support directory is unavailable.")
        }
        return try DurableTransferQueue.shared(fileURL: root.appendingPathComponent("GlacierDesk/transfers.sqlite"))
    }

    func loadTransferHistory() async {
        do { savedTransfers = try await transferStore().allSessions() }
        catch { errorMessage = "Could not load transfer history: \(error.localizedDescription)" }
    }

    func startFolderUpload(_ plan: FolderUploadPlan, resuming: (DurableTransferSession, [DurableTransferItem])? = nil) {
        guard transferTask == nil, !isBusy, let account = identity?.account, connectedProfile == plan.profile,
              (resuming.map { $0.0.accountID == account } ?? (selectedBucket?.name == plan.bucket && prefix == plan.prefix)) else {
            errorMessage = "The selected account or destination changed. Prepare the upload again."
            return
        }
        let access = plan.roots.map { ($0, $0.startAccessingSecurityScopedResource()) }
        let uploadService = AWSService(profile: plan.profile)
        uploadQueue = plan.items.map { QueuedUpload(item: $0) }
        retryTransfer = nil
        isBusy = true
        transferTask = Task { [self] in
            defer {
                for (url, granted) in access where granted { url.stopAccessingSecurityScopedResource() }
                isBusy = false; transferTask = nil
            }
            let queue: DurableTransferQueue
            let session: DurableTransferSession
            let durableItems: [DurableTransferItem]
            do {
                queue = try transferStore()
                if let resumed = resuming {
                    session = resumed.0; durableItems = resumed.1
                } else {
                    session = try await Task.detached(priority: .utility) {
                        try DurableTransferSession.s3Upload(from: plan, accountID: account, storageClass: plan.storageClass)
                    }.value
                    try await queue.add(session)
                    durableItems = session.items
                }
            } catch {
                transferStatus = "Could not save transfer queue; no upload started: \(error.localizedDescription)"
                await loadTransferHistory()
                return
            }
            var succeeded = 0, failed = 0, persistenceFailed = false
            for index in plan.items.indices {
                if Task.isCancelled { break }
                let item = plan.items[index]
                uploadQueue[index].state = "Preparing secure snapshot"
                transferStatus = "Uploading \(index + 1) of \(plan.items.count): \(item.key)"
                transferProgress = Double(index) / Double(plan.items.count)
                var submitted = false
                do {
                    let snapshot = try await item.snapshot()
                    defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
                    do {
                        try await queue.updateItem(sessionID: session.id, itemID: durableItems[index].id, state: .inProgress,
                                                   detail: "Upload started; completion may be uncertain after interruption.")
                    } catch { persistenceFailed = true; throw error }
                    submitted = true
                    uploadQueue[index].state = "Uploading"
                    try await uploadService.upload(fileURL: snapshot, bucket: plan.bucket, key: item.key,
                                                   storageClass: plan.storageClass, settings: plan.settings,
                                                   progress: { [weak self] fraction in
                        Task { @MainActor in self?.transferProgress = (Double(index) + fraction) / Double(plan.items.count) }
                    })
                    do { try await queue.updateItem(sessionID: session.id, itemID: durableItems[index].id, state: .completed) }
                    catch { persistenceFailed = true; throw error }
                    uploadQueue[index].state = "Complete"; succeeded += 1
                } catch {
                    let state: DurableTransferItem.State = submitted ? .interrupted : .failed
                    do { try await queue.updateItem(sessionID: session.id, itemID: durableItems[index].id, state: state, detail: error.localizedDescription) }
                    catch { transferStatus = "Queue persistence failed. Stop and inspect AWS before retrying: \(error.localizedDescription)"; failed += 1; break }
                    if Task.isCancelled { uploadQueue[index].state = "Cancelled"; break }
                    uploadQueue[index].state = "Failed: \(error.localizedDescription)"; failed += 1
                    if persistenceFailed { break }
                }
            }
            if Task.isCancelled {
                for index in uploadQueue.indices where uploadQueue[index].state == "Queued" { uploadQueue[index].state = "Cancelled" }
                transferProgress = nil
                transferStatus = "Cancelled: \(succeeded) uploaded, \(failed) failed. Incomplete multipart parts may remain in S3."
            } else if persistenceFailed {
                transferProgress = nil
                transferStatus = "Queue stopped because its state could not be saved. Inspect AWS before retrying."
            } else {
                transferProgress = 1
                transferStatus = "Upload queue finished: \(succeeded) uploaded, \(failed) failed."
            }
            activity.insert("Folder upload: \(succeeded) uploaded, \(failed) failed to \(plan.bucket)", at: 0)
            await loadTransferHistory()
        }
    }

    func resumeS3Transfer(_ session: DurableTransferSession) async {
        guard transferTask == nil, !isBusy, let profile = connectedProfile, let account = identity?.account,
              session.kind == .s3Upload, let bucket = session.bucket, let prefix = session.prefix,
              let storage = session.storageClass, let threshold = session.thresholdMiB,
              let partSize = session.partSizeMiB, let connections = session.connections else {
            errorMessage = "Connect the original profile and account before retrying this queue."
            return
        }
        isBusy = true
        var scopes: [(URL, Bool)] = []
        var handedOff = false
        defer {
            for (url, active) in scopes where active { url.stopAccessingSecurityScopedResource() }
            if !handedOff { isBusy = false }
        }
        do {
            let current = try await AWSService(profile: profile).identity()
            guard current.account == account else { throw DurableTransferQueueError.accountMismatch(expected: account, actual: current.account) }
            let queue = try transferStore()
            let records = try await queue.retryableItems(sessionID: session.id, selectedProfile: profile, currentAccountID: current.account, confirmInterruptedS3: true)
            var seen = Set<String>()
            for record in records {
                guard let bookmark = record.rootBookmark else { throw DurableTransferQueueError.invalidSource("The saved folder bookmark is missing.") }
                var stale = false
                let root: URL
                do { root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) }
                catch { root = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) }
                guard !stale else { throw DurableTransferQueueError.invalidSource("A saved folder bookmark is stale; prepare the queue again.") }
                if seen.insert(root.path).inserted { scopes.append((root, root.startAccessingSecurityScopedResource())) }
            }
            let items = try await queue.reconstructFolderItems(records)
            var settings = UploadSettings(); settings.thresholdMiB = threshold; settings.partSizeMiB = partSize; settings.connections = connections
            let plan = FolderUploadPlan(bucket: bucket, prefix: prefix, profile: profile, storageClass: storage,
                                        settings: settings, roots: scopes.map(\.0), items: items)
            isBusy = false
            startFolderUpload(plan, resuming: (session, records))
            handedOff = transferTask != nil
        } catch { errorMessage = "Could not retry saved queue: \(error.localizedDescription)" }
    }
    func startDownload(_ object: AWSObject, to destination: URL) {
        guard transferTask == nil else { return }
        retryTransfer = { [weak self] in self?.startDownload(object, to: destination) }
        transferTask = Task { defer { transferTask = nil }; await download(object, to: destination) }
    }
    func startBatchDownload(_ objects: [AWSObject], to directory: URL) {
        guard transferTask == nil, let service, let bucket = selectedBucket else { return }
        retryTransfer = nil
        transferTask = Task {
            isBusy = true
            defer { isBusy = false; transferTask = nil }
            var completed = 0
            var skipped: [String] = []
            for (index, object) in objects.enumerated() {
                if Task.isCancelled { break }
                let filename = URL(fileURLWithPath: object.key).lastPathComponent
                let destination = directory.appendingPathComponent(filename)
                transferProgress = Double(index) / Double(objects.count)
                transferStatus = "Downloading \(index + 1) of \(objects.count): \(filename)"
                if filename.isEmpty || FileManager.default.fileExists(atPath: destination.path) {
                    skipped.append("\(object.key): destination already exists or name is invalid")
                    continue
                }
                do {
                    if ["GLACIER", "DEEP_ARCHIVE"].contains(object.storageClass?.uppercased() ?? "") {
                        let metadata = try await service.headObject(bucket: bucket.name, key: object.key)
                        guard metadata.restore?.contains("ongoing-request=\"false\"") == true else {
                            skipped.append("\(object.key): restore required or pending")
                            continue
                        }
                    }
                    try await service.download(bucket: bucket.name, key: object.key, to: destination, overwrite: false)
                    completed += 1
                } catch {
                    if Task.isCancelled { break }
                    skipped.append("\(object.key): \(error.localizedDescription)")
                }
            }
            transferProgress = Task.isCancelled ? nil : 1
            transferStatus = "\(Task.isCancelled ? "Cancelled. " : "")Downloaded \(completed) of \(objects.count)." + (skipped.isEmpty ? "" : " Skipped or failed:\n" + skipped.joined(separator: "\n"))
            activity.insert("Downloaded \(completed) of \(objects.count) selected objects", at: 0)
        }
    }

    func disconnect() {
        retryTransfer = nil
        identity = nil; connectedProfile = nil; buckets = []; selectedBucket = nil
        objects = []; prefixes = []; selectedObject = nil; metadata = nil; prefix = ""
    }

    func loadProfiles() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let found = try await AWSService(profile: "default").listProfiles()
            profiles = found
            if selectedProfile.isEmpty { selectedProfile = found.first ?? "" }
            if found.isEmpty { notice = "No shared AWS profiles were found. Configure one with `aws configure` or `aws configure sso`." }
        } catch { errorMessage = error.localizedDescription }
    }

    func connect() async {
        guard let service else { return }
        retryTransfer = nil
        isBusy = true; errorMessage = nil; identity = nil; connectedProfile = nil; buckets = []; selectedBucket = nil
        defer { isBusy = false }
        do {
            let who = try await service.identity()
            identity = who
            connectedProfile = selectedProfile
            buckets = try await service.listBuckets()
            activity.insert("Connected as \(who.arn)", at: 0)
            await refreshRestores()
        } catch { errorMessage = error.localizedDescription }
    }

    func openBucket(_ bucket: AWSBucket) async {
        retryTransfer = nil
        selectedBucket = bucket; prefix = ""; continuationToken = nil; objects = []; prefixes = []; selectedObject = nil
        await loadPage(reset: true)
    }

    func openPrefix(_ value: String) async {
        retryTransfer = nil
        prefix = value; continuationToken = nil; objects = []; prefixes = []; selectedObject = nil
        await loadPage(reset: true)
    }

    func loadPage(reset: Bool = false) async {
        guard let service, let selectedBucket else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let page = try await service.listObjects(bucket: selectedBucket.name,
                                                     prefix: prefix.isEmpty ? nil : prefix,
                                                     continuationToken: reset ? nil : continuationToken,
                                                     maxKeys: 500)
            if reset { objects = []; prefixes = [] }
            objects += page.contents ?? []
            prefixes += page.commonPrefixes ?? []
            continuationToken = page.nextContinuationToken
            canLoadMore = page.isTruncated == true && continuationToken != nil
        } catch { errorMessage = error.localizedDescription }
    }

    func inspect(_ object: AWSObject) async {
        selectedObject = object; metadata = nil
        guard let service, let bucket = selectedBucket else { return }
        do { metadata = try await service.headObject(bucket: bucket.name, key: object.key) }
        catch { errorMessage = error.localizedDescription }
    }

    func upload(_ url: URL) async {
        guard let service, let bucket = selectedBucket else { return }
        isBusy = true
        transferStatus = "Uploading \(url.lastPathComponent)"; transferProgress = 0
        defer { isBusy = false }
        do {
            var settings = UploadSettings()
            settings.thresholdMiB = uploadThresholdMiB
            settings.partSizeMiB = uploadPartSizeMiB
            settings.connections = uploadConnections
            try await service.upload(fileURL: url, bucket: bucket.name,
                                     key: prefix + url.lastPathComponent, storageClass: storageClass, settings: settings,
                                     progress: { [weak self] value in Task { @MainActor in self?.transferProgress = value } })
            activity.insert("Uploaded \(url.lastPathComponent) to \(bucket.name)", at: 0)
            transferStatus = "Upload complete"; transferProgress = 1; retryTransfer = nil
            notice = "Upload complete."
            await loadPage(reset: true)
        } catch { transferStatus = Task.isCancelled ? "Upload cancelled; incomplete parts may remain in S3." : "Upload failed: \(error.localizedDescription)" }
    }

    func download(_ object: AWSObject, to destination: URL) async {
        guard let service, let bucket = selectedBucket else { return }
        isBusy = true
        transferStatus = "Downloading \(object.key)"; transferProgress = 0
        defer { isBusy = false }
        do {
            try await service.download(bucket: bucket.name, key: object.key, to: destination,
                                       progress: { [weak self] value in Task { @MainActor in self?.transferProgress = value } })
            transferStatus = "Download complete"; transferProgress = 1; retryTransfer = nil
            activity.insert("Downloaded \(object.key)", at: 0); notice = "Download complete."
        } catch { transferStatus = Task.isCancelled ? "Download cancelled" : "Download failed: \(error.localizedDescription)" }
    }

    func restore(_ object: AWSObject) async {
        guard let service, let bucket = selectedBucket else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            try await service.restore(bucket: bucket.name, key: object.key, days: 3, tier: restoreTier)
            if let account = identity?.account, let profile = connectedProfile {
                restores.removeAll { $0.account == account && $0.bucket == bucket.name && $0.key == object.key }
                restores.insert(RestoreRecord(profile: profile, account: account, bucket: bucket.name, key: object.key, requested: Date(), status: "Restore requested; awaiting AWS status"), at: 0)
                saveRestores()
            }
            activity.insert("Restore requested for \(object.key) (\(restoreTier.rawValue))", at: 0)
            notice = "Restore request submitted. Refresh object details to check its status. AWS retrieval and temporary-copy charges may apply."
            await inspect(object)
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ContentView: View {
    @StateObject private var model = GlacierDeskModel()
    @State private var showUpload = false
    @State private var pendingUploadURL: URL?
    @State private var uploadURLAccess = false
    @State private var pendingRestore: AWSObject?
    @State private var showUploadConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var selectedSection = "Browse"
    @State private var showTransferSettings = false
    @State private var showLifecycle = false
    @State private var selectedKeys: Set<String> = []
    @State private var pendingRecovery: DurableTransferSession?
    @State private var showRecoveryConfirmation = false
    @State private var folderPlan: FolderUploadPlan?
    @State private var showFolderReview = false
    @State private var showTransferQueue = false
    @State private var openQueueAfterReview = false
    @State private var queueRetryConfirmation = false
    @State private var folderScopes: [URL] = []
    @State private var preparingDrop = false
    @State private var dropTargeted = false
    @AppStorage("bucketsExpanded") private var bucketsExpanded = true

    var body: some View {
        NavigationSplitView {
            ScrollView { sidebar }
                .frame(maxHeight: .infinity, alignment: .top)
                .background(GlacierTheme.sidebar)
        } detail: {
            Group {
                switch selectedSection {
                case "Activity": activityView
                case "Restores": restoresView
                case "Vaults":
                    if let profile = model.connectedProfile, let account = model.identity?.account { LegacyVaultView(profile: profile, accountID: account, externalBusy: $model.isBusy) }
                    else { EmptyState(title: "Connect to AWS", icon: "link", detail: "Connect a profile to find legacy Glacier vaults.") }
                default: browser
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GlacierTheme.background)
        }
        .toolbar { toolbar }
        .onChange(of: model.selectedBucket?.name) { _ in selectedKeys = [] }
        .onChange(of: model.prefix) { _ in selectedKeys = [] }
        .onChange(of: selectedKeys) { keys in
            if keys.count == 1, let key = keys.first, let object = model.objects.first(where: { $0.key == key }) { Task { await model.inspect(object) } }
            else { model.selectedObject = nil; model.metadata = nil }
        }
        .sheet(isPresented: $showLifecycle) {
            if let bucket = model.selectedBucket, let account = model.identity?.account, let profile = model.connectedProfile {
                LifecycleView(service: AWSService(profile: profile), bucket: bucket.name, account: account)
            }
        }
        .sheet(isPresented: $showFolderReview, onDismiss: {
            releaseFolderScopes()
            if openQueueAfterReview { openQueueAfterReview = false; showTransferQueue = true }
        }) {
            if let plan = folderPlan { folderReview(plan) }
        }
        .sheet(isPresented: $showTransferQueue) { transferQueueWindow }
        .tint(GlacierTheme.accent)
        .task {
            model.loadRestores()
            await model.loadTransferHistory()
            await model.loadProfiles()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                await model.refreshRestores()
            }
        }
        .fileImporter(isPresented: $showUpload, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                uploadURLAccess = url.startAccessingSecurityScopedResource()
                pendingUploadURL = url
                showUploadConfirmation = true
            } else if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .alert("GlacierDesk", isPresented: alertShown) {
            Button("OK", role: .cancel) { model.errorMessage = nil; model.notice = nil }
        } message: { Text(model.errorMessage ?? model.notice ?? "") }
        .confirmationDialog("Upload to S3?", isPresented: $showUploadConfirmation, titleVisibility: .visible) {
            Button("Upload \(pendingUploadURL?.lastPathComponent ?? "file")") {
                guard let url = pendingUploadURL else { return }
                model.startUpload(url)
                if uploadURLAccess { url.stopAccessingSecurityScopedResource() }
                uploadURLAccess = false
                pendingUploadURL = nil
            }
            Button("Cancel", role: .cancel) {
                if let url = pendingUploadURL, uploadURLAccess { url.stopAccessingSecurityScopedResource() }
                uploadURLAccess = false
                pendingUploadURL = nil
            }
        } message: {
            Text("If this key already exists, S3 will replace it. Storage and request charges may apply. Review the selected storage class before continuing.")
        }
        .confirmationDialog("Request archive restore?", isPresented: $showRestoreConfirmation, titleVisibility: .visible) {
            Button("Request \(model.restoreTier.rawValue) restore") {
                if let object = pendingRestore { Task { await model.restore(object) } }
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("AWS may charge for retrieval and for the temporary restored copy. The request lasts 3 days. Check current S3 pricing before proceeding.")
        }
        .confirmationDialog("Retry saved S3 queue?", isPresented: $showRecoveryConfirmation, titleVisibility: .visible) {
            Button("Retry unfinished files") {
                if let session = pendingRecovery { Task { await model.resumeS3Transfer(session) } }
            }
            Button("Cancel", role: .cancel) { pendingRecovery = nil }
        } message: {
            Text("Interrupted uploads may already have completed in AWS. Inspect the destination first. Retrying starts those files again and can overwrite objects and incur charges; completed files are not retried.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if let icon = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/GlacierDesk.png")) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    Image(systemName: "snowflake").font(.title2).foregroundStyle(GlacierTheme.accent).frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("GlacierDesk").font(.headline)
                    Text("S3 archive browser").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 14).padding(.top, 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("AWS PROFILE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 14)
                HStack(spacing: 8) {
                    Picker("Profile", selection: $model.selectedProfile) {
                        if model.profiles.isEmpty { Text("No profiles found").tag("") }
                        ForEach(model.profiles, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().disabled(model.isBusy || model.identity != nil).frame(maxWidth: .infinity)
                    Button { Task { await model.loadProfiles() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help("Reload AWS profiles")
                }.padding(.horizontal, 12)
                Button { Task { await model.connect() } } label: {
                    HStack { Image(systemName: model.identity == nil ? "link" : "checkmark.circle.fill"); Text(model.identity == nil ? "Connect" : "Reconnect") }
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(model.selectedProfile.isEmpty || model.isBusy).padding(.horizontal, 12)
                if let identity = model.identity {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Account  \(identity.account)").font(.caption.monospaced())
                        Text(identity.arn).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 12)
                    Button("Disconnect") { model.disconnect() }
                        .disabled(model.isBusy).padding(.horizontal, 12)
                } else {
                    Text("Confirm the account and principal before browsing or transferring objects.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
                }
            }

            Divider().padding(.horizontal, 12)
            List(selection: $selectedSection) {
                Label("Browse", systemImage: "externaldrive").tag("Browse")
                Label("Activity", systemImage: "clock.arrow.circlepath").tag("Activity")
                Label("Restores", systemImage: "archivebox").tag("Restores")
                Label("Legacy vaults", systemImage: "archivebox.fill").tag("Vaults")
            }.listStyle(.sidebar).frame(minHeight: 150, maxHeight: 190).disabled(model.isBusy)

            DisclosureGroup(isExpanded: $bucketsExpanded) {
                if model.identity == nil {
                    Text("Connect to load buckets.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                } else if model.buckets.isEmpty {
                    Text("No buckets available.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.buckets) { bucket in
                                Button { selectedSection = "Browse"; Task { await model.openBucket(bucket) } } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: "bucket").foregroundStyle(GlacierTheme.accent)
                                        Text(bucket.name).lineLimit(nil).fixedSize(horizontal: false, vertical: true).help(bucket.name)
                                        Spacer()
                                        if model.selectedBucket?.id == bucket.id { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                                    }.font(.callout).padding(.vertical, 7).padding(.horizontal, 8)
                                        .background(model.selectedBucket?.id == bucket.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain).disabled(model.isBusy)
                            }
                        }
                    }.frame(minHeight: 80, maxHeight: 300)
                }
            } label: {
                HStack {
                    Text("BUCKETS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if model.isBusy { ProgressView().controlSize(.small) }
                }.contentShape(Rectangle())
            }.padding(.horizontal, 14)
            Spacer(minLength: 4)
            Text("AWS CLI profile selection is explicit. Choose a vault to manage its archives.")
                .font(.caption2).foregroundStyle(.tertiary).padding(14)
        }
        .frame(minWidth: 250, idealWidth: 320)
        .navigationSplitViewColumnWidth(min: 250, ideal: 320, max: 600)
        .background(GlacierTheme.sidebar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showTransferQueue = true; Task { await model.loadTransferHistory() } } label: { Image(systemName: "list.bullet.rectangle") }
                .help("Transfer queue")
            Button { showTransferSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Upload settings")
                .disabled(model.isBusy)
                .popover(isPresented: $showTransferSettings) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Upload settings").font(.headline)
                        Stepper("Multipart threshold: \(model.uploadThresholdMiB) MiB", value: $model.uploadThresholdMiB, in: 1...5120)
                        Stepper("Part size: \(model.uploadPartSizeMiB) MiB", value: $model.uploadPartSizeMiB, in: 5...5120)
                        Stepper("Multipart requests per file: \(model.uploadConnections)", value: $model.uploadConnections, in: 1...32)
                        Stepper("Legacy files at once: \(model.legacyParallelFiles)", value: $model.legacyParallelFiles, in: 1...16)
                        Text("Up to the file limit × multipart requests may run at once. Each active file uses temporary disk space.").font(.caption).foregroundStyle(.secondary)
                        Text("Files above the threshold use multipart upload. AWS may increase the part size for very large files. Settings apply to new uploads.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(18).frame(width: 340)
                }
            if model.selectedBucket != nil && selectedSection == "Browse" {
                Button { chooseBatchDirectory() } label: { Label("Download selected (\(selectedKeys.count))", systemImage: "arrow.down.doc") }
                    .disabled(selectedKeys.isEmpty || model.isBusy)
                Button { showLifecycle = true } label: { Image(systemName: "clock.badge.checkmark") }
                    .help("Configure incomplete upload cleanup").disabled(model.isBusy || model.identity == nil)
                Picker("Storage class", selection: $model.storageClass) {
                    Text("Standard").tag("STANDARD")
                    Text("Intelligent Tiering").tag("INTELLIGENT_TIERING")
                    Text("Glacier Instant").tag("GLACIER_IR")
                    Text("Glacier Flexible").tag("GLACIER")
                    Text("Deep Archive").tag("DEEP_ARCHIVE")
                }.frame(width: 175).help("Storage class for the next upload")
                Button { chooseBucketUpload() } label: { Label("Upload", systemImage: "arrow.up.doc") }
                    .disabled(model.identity == nil || model.selectedBucket == nil || model.isBusy)
            }
            Button { Task { await model.loadPage(reset: true) } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh current location").disabled(selectedSection != "Browse" || model.selectedBucket == nil || model.isBusy)
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            if model.identity == nil {
                welcome
            } else if model.selectedBucket == nil {
                EmptyState(title: "Choose a bucket", icon: "externaldrive", detail: "Select a bucket from the sidebar to browse its objects.")
            } else {
                locationHeader
                Divider()
                HStack(spacing: 0) {
                    objectBrowser
                    Divider()
                    inspector.frame(width: 290)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if model.identity != nil && model.selectedBucket != nil {
                Text(dropTargeted ? "Drop to prepare upload" : "Drag files or folders here to upload")
                    .font(.caption).padding(8).background(.regularMaterial, in: Capsule()).padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: acceptDrop)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "snowflake").font(.system(size: 42, weight: .light)).foregroundStyle(GlacierTheme.accent)
            VStack(spacing: 6) {
                Text("Explore your S3 archives").font(.title2.weight(.semibold))
                Text("Choose a shared AWS profile, connect, and browse buckets and prefixes.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Button { Task { await model.connect() } } label: { Label("Connect to AWS", systemImage: "link") }
                .buttonStyle(.borderedProminent).disabled(model.selectedProfile.isEmpty || model.isBusy)
            if model.profiles.isEmpty {
                Text("No profiles detected yet. Set up an AWS profile with the AWS CLI, then reload.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var locationHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "bucket.fill").foregroundStyle(GlacierTheme.accent)
            Text(model.selectedBucket?.name ?? "").font(.headline).lineLimit(2).textSelection(.enabled).help(model.selectedBucket?.name ?? "")
            if !model.prefix.isEmpty {
                Text("/").foregroundStyle(.tertiary)
                Text(model.prefix).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(model.objects.count) objects").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var objectBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("SIZE").frame(width: 90, alignment: .trailing)
                Text("STORAGE CLASS").frame(width: 150, alignment: .trailing)
            }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
            Divider()
            HStack {
                Button("← Parent folder") { Task { await model.openPrefix(parentPrefix(model.prefix)) } }
                    .disabled(model.prefix.isEmpty || model.isBusy)
                Button("Bucket root") { Task { await model.openPrefix("") } }
                    .disabled(model.prefix.isEmpty || model.isBusy)
                Text(model.prefix.isEmpty ? "/" : "/" + model.prefix)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if model.objects.filter({ $0.key != model.prefix }).isEmpty && model.prefixes.isEmpty && !model.isBusy && !model.canLoadMore {
                EmptyState(title: "This folder is empty", icon: "folder", detail: "Upload a file or navigate to another folder.")
            } else {
                List(selection: $selectedKeys) {
                    ForEach(model.prefixes) { folder in
                        Button { Task { await model.openPrefix(folder.prefix) } } label: {
                            HStack { Label(folderName(folder.prefix), systemImage: "folder.fill").foregroundStyle(GlacierTheme.accent); Spacer(); Text("Folder").font(.caption).foregroundStyle(.secondary) }
                        }.buttonStyle(.plain)
                    }
                    ForEach(model.objects.filter { $0.key != model.prefix }) { object in
                        HStack {
                            Label(objectName(object.key), systemImage: archiveIcon(object.storageClass))
                                .lineLimit(2).help(object.key).frame(maxWidth: .infinity, alignment: .leading)
                            Text(formatSize(object.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                            Text(object.storageClass ?? "STANDARD").font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing).lineLimit(1)
                        }.tag(object.key).contentShape(Rectangle())
                    }
                }.listStyle(.plain)
                if model.canLoadMore {
                    Button { Task { await model.loadPage() } } label: {
                        HStack { Spacer(); Text("Load next page"); Image(systemName: "chevron.down"); Spacer() }.padding(9)
                    }.buttonStyle(.plain).background(Color(nsColor: .controlBackgroundColor))
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let object = model.selectedObject {
                VStack(alignment: .leading, spacing: 5) {
                    Text("OBJECT DETAILS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(objectName(object.key)).font(.headline).lineLimit(3).textSelection(.enabled)
                }
                Divider()
                detailRow("Key", object.key)
                detailRow("Size", formatSize(model.metadata?.contentLength ?? object.size))
                detailRow("Storage class", model.metadata?.storageClass ?? object.storageClass ?? "STANDARD")
                detailRow("Modified", dateString(model.metadata?.lastModified ?? object.lastModified))
                if let restore = model.metadata?.restore { restoreStatus(restore) }
                else if isArchive(object.storageClass) {
                    Text("Archived object").font(.caption.weight(.medium)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    Text("Restore it before downloading. Retrieval charges may apply.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if isArchive(object.storageClass) {
                    Picker("Retrieval tier", selection: $model.restoreTier) {
                        ForEach(availableRestoreTiers(for: model.selectedObject), id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu)
                    Button { pendingRestore = object; showRestoreConfirmation = true } label: { Label("Request restore", systemImage: "shippingbox") }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(model.isBusy || isRestorePending(model.metadata?.restore))
                    Button { Task { await model.inspect(object) } } label: { Label("Refresh restore status", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity).disabled(model.isBusy)
                }
                Button { chooseDownloadDestination(for: object) } label: { Label("Download…", systemImage: "arrow.down.doc") }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    .disabled(model.isBusy || (isArchive(object.storageClass) && !isRestored(model.metadata?.restore)))
                Link("S3 Glacier pricing", destination: URL(string: "https://aws.amazon.com/s3/pricing/")!)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                EmptyState(title: "Select an object", icon: "doc.text.magnifyingglass", detail: "Details and archive actions will appear here.")
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var activityView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(.title2.weight(.semibold))
                Spacer()
                Button("Transfer queue…") { showTransferQueue = true; Task { await model.loadTransferHistory() } }
            }.padding(20)
            Divider()
            if let status = model.transferStatus {
                VStack(alignment: .leading, spacing: 8) {
                    Text(status).textSelection(.enabled)
                    if let progress = model.transferProgress { ProgressView(value: progress) }
                    HStack {
                        if model.isBusy { Button("Cancel transfer") { model.cancelTransfer() } }
                        if model.canRetryTransfer { Button("Retry transfer") { model.retryLastTransfer() } }
                    }
                }.padding(16)
                Divider()
            }
            if !model.uploadQueue.isEmpty {
                Text("Upload queue").font(.headline).padding(.horizontal, 20).padding(.top, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.uploadQueue) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.item.key).font(.callout).textSelection(.enabled)
                                Text(entry.state).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(16)
                }.frame(maxHeight: 300)
                Divider()
            }
            let savedS3 = model.savedTransfers.filter { $0.kind == .s3Upload }
            if !savedS3.isEmpty {
                Text("Saved upload queues").font(.headline).padding(.horizontal, 20).padding(.top, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(savedS3) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.destination).font(.callout).textSelection(.enabled)
                                Text("Account \(session.accountID) · \(session.profile) · \(session.items.filter { $0.state == .completed }.count)/\(session.items.count) complete")
                                    .font(.caption).foregroundStyle(.secondary)
                                if session.items.contains(where: { [.queued, .failed, .interrupted].contains($0.state) }) {
                                    Button("Review and retry unfinished…") { pendingRecovery = session; showRecoveryConfirmation = true }
                                        .disabled(model.isBusy || model.connectedProfile != session.profile || model.identity?.account != session.accountID)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(16)
                }.frame(maxHeight: 220)
                Divider()
            }
            if model.activity.isEmpty {
                EmptyState(title: "No activity yet", icon: "clock.arrow.circlepath", detail: "Uploads, downloads, and restore requests will appear here.")
            } else {
                List(model.activity, id: \.self) { item in Label(item, systemImage: "checkmark.circle").padding(.vertical, 5) }.listStyle(.plain)
            }
        }
    }

    private var transferQueueWindow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transfer queue").font(.title2.weight(.semibold))
            if let status = model.transferStatus { Text(status).textSelection(.enabled) }
            if let progress = model.transferProgress { ProgressView(value: progress) }
            HStack {
                if model.transferActive { Button("Cancel transfer") { model.cancelTransfer() } }
                if model.canRetryTransfer { Button("Retry transfer") { model.retryLastTransfer() } }
                Spacer()
                Button("Refresh history") { Task { await model.loadTransferHistory() } }
            }
            List {
                if !model.uploadQueue.isEmpty {
                    Section("Current queue") {
                        ForEach(model.uploadQueue) { entry in
                            VStack(alignment: .leading) {
                                Text(entry.item.key).textSelection(.enabled)
                                Text(entry.state).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                ForEach(model.savedTransfers.filter { $0.kind == .s3Upload }) { session in
                    Section("\(session.destination) · \(session.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                        if session.items.contains(where: { [.queued, .failed, .interrupted].contains($0.state) }) {
                            Button("Review and retry unfinished…") { pendingRecovery = session; queueRetryConfirmation = true }
                                .disabled(model.transferActive || model.isBusy || model.connectedProfile != session.profile || model.identity?.account != session.accountID)
                        }
                        ForEach(session.items) { item in
                            VStack(alignment: .leading) {
                                Text(item.target).font(.caption.monospaced()).textSelection(.enabled)
                                Text(item.detail.map { "\(item.state.rawValue) · \($0)" } ?? item.state.rawValue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Close") { showTransferQueue = false } }
        }.padding(18).frame(minWidth: 680, minHeight: 480)
        .task { await model.loadTransferHistory() }
        .confirmationDialog("Retry saved S3 queue?", isPresented: $queueRetryConfirmation, titleVisibility: .visible) {
            Button("Retry unfinished files") { if let session = pendingRecovery { Task { await model.resumeS3Transfer(session) } } }
            Button("Cancel", role: .cancel) { pendingRecovery = nil }
        } message: { Text("Interrupted uploads may already have completed in AWS. Inspect the destination first. Retrying starts those files again and can overwrite objects and incur charges; completed files are not retried.") }
    }

    private func folderReview(_ plan: FolderUploadPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review upload queue").font(.title2.weight(.semibold))
            Text("\(plan.items.count) files → s3://\(plan.bucket)/\(plan.prefix)").textSelection(.enabled)
            Text("Storage class: \(plan.storageClass) · Multipart threshold: \(plan.settings.thresholdMiB) MiB · Part size: \(plan.settings.partSizeMiB) MiB · Parallel requests: \(plan.settings.connections)").font(.caption)
            Text("Folders and subfolders are preserved. Existing objects with the same keys will be replaced; storage and request charges may apply. Empty folders and symbolic links are skipped. Each file is copied to private temporary storage before upload.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(plan.items) { item in Text(item.key).font(.caption.monospaced()).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { showFolderReview = false }
                Button("Upload \(plan.items.count) files") {
                    model.startFolderUpload(plan)
                    openQueueAfterReview = true
                    showFolderReview = false
                    selectedSection = "Activity"
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 680, height: 520)
    }

    private func releaseFolderScopes() {
        for url in folderScopes { url.stopAccessingSecurityScopedResource() }
        folderScopes = []
        folderPlan = nil
    }

    @MainActor private func chooseBucketUpload() {
        guard selectedSection == "Browse", model.identity != nil, let bucket = model.selectedBucket?.name,
              let profile = model.connectedProfile, !model.isBusy, !preparingDrop else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        let roots = panel.urls, prefix = model.prefix, storageClass = model.storageClass
        for url in roots where url.startAccessingSecurityScopedResource() { folderScopes.append(url) }
        var settings = UploadSettings(); settings.thresholdMiB = model.uploadThresholdMiB; settings.partSizeMiB = model.uploadPartSizeMiB; settings.connections = model.uploadConnections
        preparingDrop = true
        Task { @MainActor in
            defer { preparingDrop = false }
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try FolderUploadPlan.build(roots: roots, bucket: bucket, prefix: prefix, profile: profile, storageClass: storageClass, settings: settings)
                }.value
                guard model.connectedProfile == profile, model.selectedBucket?.name == bucket, model.prefix == prefix, !model.isBusy else { throw FolderUploadError.message("The destination changed while preparing the queue. Choose the files again.") }
                folderPlan = plan; showFolderReview = true
            } catch { releaseFolderScopes(); model.errorMessage = error.localizedDescription }
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard selectedSection == "Browse", model.identity != nil, let bucket = model.selectedBucket?.name,
              let profile = model.connectedProfile, !model.isBusy, !preparingDrop else { return false }
        let prefix = model.prefix, storageClass = model.storageClass
        var settings = UploadSettings()
        settings.thresholdMiB = model.uploadThresholdMiB
        settings.partSizeMiB = model.uploadPartSizeMiB
        settings.connections = model.uploadConnections
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
                    try FolderUploadPlan.build(roots: roots, bucket: bucket, prefix: prefix, profile: profile, storageClass: storageClass, settings: settings)
                }.value
                guard model.connectedProfile == profile, model.selectedBucket?.name == bucket, model.prefix == prefix, !model.isBusy else {
                    throw FolderUploadError.message("The destination changed while preparing the queue. Drop the folder again.")
                }
                folderPlan = plan
                showFolderReview = true
            } catch {
                releaseFolderScopes()
                model.errorMessage = error.localizedDescription
            }
        }
        return true
    }

    private var restoresView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Restores").font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh") { Task { await model.refreshRestores() } }.disabled(model.identity == nil)
            }.padding(20)
            Divider()
            if model.restores.isEmpty {
                EmptyState(title: "No restore requests", icon: "archivebox", detail: "Requests made in GlacierDesk appear here and are refreshed when connected.")
            } else {
                List(model.restores) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(record.bucket) / \(record.key)").font(.headline).textSelection(.enabled)
                        Text("Account \(record.account) · \(record.profile) · requested \(record.requested.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        Text(record.status).font(.caption).textSelection(.enabled)
                    }.padding(.vertical, 5)
                }.listStyle(.plain)
            }
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil || model.notice != nil }, set: { if !$0 { model.errorMessage = nil; model.notice = nil } })
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func restoreStatus(_ value: String) -> some View {
        let restored = value.contains("ongoing-request=\"false\"")
        return VStack(alignment: .leading, spacing: 5) {
            Label(restored ? "Restore available" : "Restore in progress", systemImage: restored ? "checkmark.circle.fill" : "clock")
                .font(.caption.weight(.semibold)).foregroundColor(restored ? .green : .orange)
            Text(value.replacingOccurrences(of: "\"", with: "")).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
    private func chooseDownloadDestination(for object: AWSObject) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: object.key).lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.startDownload(object, to: url)
        showTransferQueue = true
    }
    private func chooseBatchDirectory() {
        let objects = model.objects.filter { selectedKeys.contains($0.key) }
        guard !objects.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Download here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.startBatchDownload(objects, to: folder)
        showTransferQueue = true
        selectedSection = "Activity"
    }
    private func availableRestoreTiers(for object: AWSObject?) -> [RestoreTier] {
        object?.storageClass?.uppercased() == "DEEP_ARCHIVE" ? [.standard, .bulk] : RestoreTier.allCases
    }
    private func folderName(_ value: String) -> String { String(value.dropLast().split(separator: "/").last ?? "") }
    private func objectName(_ value: String) -> String { URL(fileURLWithPath: value).lastPathComponent }
    private func parentPrefix(_ value: String) -> String {
        let trimmed = String(value.dropLast())
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...slash])
    }
    private func formatSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    private func isArchive(_ storageClass: String?) -> Bool { ["GLACIER", "DEEP_ARCHIVE"].contains(storageClass?.uppercased() ?? "") }
    private func archiveIcon(_ storageClass: String?) -> String { isArchive(storageClass) ? "archivebox.fill" : "doc" }
    private func isRestored(_ value: String?) -> Bool { value?.contains("ongoing-request=\"false\"") == true }
    private func isRestorePending(_ value: String?) -> Bool { value?.contains("ongoing-request=\"true\"") == true }
}

private struct EmptyState: View {
    let title: String
    let icon: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

