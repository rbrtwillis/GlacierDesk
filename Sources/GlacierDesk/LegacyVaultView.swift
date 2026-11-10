import SwiftUI

struct LegacyVaultView: View {
    // AWS General Reference: Amazon Glacier service endpoints.
    private let regions: [(code: String, name: String)] = [
        ("us-east-1", "US East (N. Virginia)"), ("us-east-2", "US East (Ohio)"),
        ("us-west-1", "US West (N. California)"), ("us-west-2", "US West (Oregon)"),
        ("af-south-1", "Africa (Cape Town)"), ("ap-east-1", "Asia Pacific (Hong Kong)"),
        ("ap-southeast-3", "Asia Pacific (Jakarta)"), ("ap-south-1", "Asia Pacific (Mumbai)"),
        ("ap-northeast-3", "Asia Pacific (Osaka)"), ("ap-northeast-2", "Asia Pacific (Seoul)"),
        ("ap-southeast-1", "Asia Pacific (Singapore)"), ("ap-southeast-2", "Asia Pacific (Sydney)"),
        ("ap-northeast-1", "Asia Pacific (Tokyo)"), ("ca-central-1", "Canada (Central)"),
        ("eu-central-1", "Europe (Frankfurt)"), ("eu-west-1", "Europe (Ireland)"),
        ("eu-west-2", "Europe (London)"), ("eu-south-1", "Europe (Milan)"),
        ("eu-west-3", "Europe (Paris)"), ("eu-north-1", "Europe (Stockholm)"),
        ("me-south-1", "Middle East (Bahrain)"), ("sa-east-1", "South America (São Paulo)"),
        ("us-gov-east-1", "AWS GovCloud (US-East)"), ("us-gov-west-1", "AWS GovCloud (US-West)")
    ]
    let profile: String
    @Binding var externalBusy: Bool
    @AppStorage("legacyVaultRegion") private var region = "us-east-1"
    @State private var vaults: [LegacyVault] = []
    @State private var loadedRegion: String?
    @State private var error: String?
    @State private var busy = false
    @State private var selectedVault: LegacyVault?

    var body: some View {
        if let vault = selectedVault, let loadedRegion {
            LegacyVaultDetailView(profile: profile, region: loadedRegion, vault: vault, externalBusy: $externalBusy) { selectedVault = nil }
        } else {
            vaultList
        }
    }

    private var vaultList: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Legacy Glacier vaults").font(.title2.weight(.semibold))
            Text("Vaults belong to the older Amazon Glacier service and are listed one AWS Region at a time. They are separate from S3 buckets.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("AWS Region", selection: $region) {
                    if !regions.contains(where: { $0.code == region }) {
                        Text("\(region) (previously selected)").tag(region)
                    }
                    ForEach(regions, id: \.code) { item in
                        Text("\(item.name) — \(item.code)").tag(item.code)
                    }
                }.frame(width: 370).disabled(busy)
                Button("Find vaults") { Task { await load() } }.disabled(busy || region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let loadedRegion {
                Text("\(vaults.count) vaults in \(loadedRegion)").font(.caption).foregroundStyle(.secondary)
                if vaults.isEmpty && !busy { Text("No vaults found in this Region for the connected account.").foregroundStyle(.secondary) }
                LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(vaults) { vault in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(vault.vaultName).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let arn = vault.vaultARN { Text(arn).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        Text("Archives: \(vault.numberOfArchives.map(String.init) ?? "—") · Size: \(vault.sizeInBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Last inventory: \(vault.lastInventoryDate ?? "Not available")").font(.caption).foregroundStyle(.secondary)
                        Button("Open vault") { selectedVault = vault }
                    }.padding(.vertical, 6)
                }
                }
            } else {
                Text("Choose the Region where your vaults were created and select Find vaults.").foregroundStyle(.secondary).padding(.vertical, 20)
            }
            Text("Vault counts reflect the last inventory. Opening a vault lets you request an inventory, browse archives, and manage retrieval jobs.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func load() async {
        let requestedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; error = nil; loadedRegion = nil; vaults = []
        defer { busy = false }
        do { vaults = try await AWSService(profile: profile).listLegacyVaults(region: requestedRegion); loadedRegion = requestedRegion }
        catch { self.error = error.localizedDescription }
    }
}
