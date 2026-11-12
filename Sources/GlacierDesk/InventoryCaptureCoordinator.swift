import Foundation
import Combine

struct MonitoredVault: Codable, Hashable {
    let profile: String
    let account: String
    let region: String
    let vault: String
    var key: String { [profile, account, region, vault].joined(separator: "\u{0}") }
}

/// Coordinates opt-in capture across views while the app and original account are connected.
@MainActor final class InventoryCaptureCoordinator: ObservableObject {
    static let shared = InventoryCaptureCoordinator()
    @Published private(set) var messages: [String: String] = [:]
    private var inFlight = Set<String>()
    private var lastAttempts: [String: Date] = [:]
    private let defaults: UserDefaults
    private let applicationSupportRoot: URL?
    private let serviceFactory: (String) -> AWSService
    init(defaults: UserDefaults = .standard, applicationSupportRoot: URL? = nil, serviceFactory: @escaping (String) -> AWSService = { AWSService(profile: $0) }) {
        self.defaults = defaults; self.applicationSupportRoot = applicationSupportRoot; self.serviceFactory = serviceFactory
    }
    private let registryKey = "legacyBackgroundVaults"
    private let capturedKey = "legacyCapturedInventoryJobs"

    func register(_ vault: MonitoredVault) {
        var entries = registered()
        if !entries.contains(vault) { entries.append(vault) }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: registryKey) }
    }
    private func registered() -> [MonitoredVault] {
        (try? JSONDecoder().decode([MonitoredVault].self, from: defaults.data(forKey: registryKey) ?? Data())) ?? []
    }
    func poll(profile: String, account: String) async {
        guard defaults.bool(forKey: "legacyAutoCaptureInventory") else { return }
        let scopes = registered().filter { $0.profile == profile && $0.account == account }
        guard !scopes.isEmpty else { return }
        let service = serviceFactory(profile)
        do {
            guard try await service.identity().account == account else { throw AWSServiceError.commandFailed("Profile account changed; inventory capture stopped.") }
        } catch {
            for scope in scopes { messages[scope.key] = error.localizedDescription }
            return
        }
        for scope in scopes {
            guard !Task.isCancelled, defaults.bool(forKey: "legacyAutoCaptureInventory") else { return }
            await capture(scope, service: service)
        }
    }
    private func capture(_ scope: MonitoredVault, service: AWSService) async {
        guard inFlight.insert(scope.key).inserted else { return }
        defer { inFlight.remove(scope.key) }
        do {
            let jobs = try await service.listLegacyJobs(vault: scope.vault, region: scope.region)
            guard let job = jobs.filter({ $0.action == "InventoryRetrieval" && $0.statusCode == "Succeeded" && $0.creationDate != nil }).max(by: { ($0.creationDate ?? "") < ($1.creationDate ?? "") }) else { return }
            var captured = (try? JSONDecoder().decode([String: String].self, from: defaults.data(forKey: capturedKey) ?? Data())) ?? [:]
            guard captured[scope.key] != job.jobId else { return }
            let attemptKey = scope.key + "\u{0}" + job.jobId
            if let last = lastAttempts[attemptKey], Date().timeIntervalSince(last) < 900 { return }
            lastAttempts[attemptKey] = Date()
            guard let root = applicationSupportRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw InventoryIndexError.sqlite("Application Support directory is unavailable") }
            let index = try GlacierInventoryIndex(databaseURL: root.appendingPathComponent("GlacierDesk/legacy-inventory.sqlite"))
            let inventoryScope = GlacierInventoryScope(profile: scope.profile, accountID: scope.account, region: scope.region, vault: scope.vault)
            if let previous = try index.snapshot(scope: inventoryScope)?.inventoryDate, let created = job.creationDate, created < previous { return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-inventory-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            try await service.legacyJobOutput(vault: scope.vault, region: scope.region, job: job, destination: file)
            _ = try await Task.detached(priority: .utility) { try index.importInventoryJSON(at: file, scope: inventoryScope) }.value
            captured = (try? JSONDecoder().decode([String: String].self, from: defaults.data(forKey: capturedKey) ?? Data())) ?? [:]
            lastAttempts.removeValue(forKey: attemptKey)
            captured[scope.key] = job.jobId
            if let data = try? JSONEncoder().encode(captured) { defaults.set(data, forKey: capturedKey) }
            messages[scope.key] = "Inventory cached locally."
            NotificationCenter.default.post(name: .legacyInventoryCaptured, object: scope.key)
        } catch { messages[scope.key] = "Background inventory capture failed: \(error.localizedDescription)" }
    }
}
extension Notification.Name { static let legacyInventoryCaptured = Notification.Name("GlacierDeskLegacyInventoryCaptured") }
