import SwiftUI

struct LegacyVaultView: View {
    let profile: String
    @AppStorage("legacyVaultRegion") private var region = "us-east-1"
    @State private var vaults: [LegacyVault] = []
    @State private var loadedRegion: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Legacy Glacier vaults").font(.title2.weight(.semibold))
            Text("Vaults belong to the older Amazon Glacier service and are listed one AWS Region at a time. They are separate from S3 buckets.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("AWS Region")
                TextField("e.g. us-east-1", text: $region).textFieldStyle(.roundedBorder).frame(width: 180)
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
                    }.padding(.vertical, 6)
                }
                }
            } else {
                Text("Enter the Region where your vaults were created and select Find vaults.").foregroundStyle(.secondary).padding(.vertical, 20)
            }
            Text("Vault counts reflect the last inventory. Archive browsing, retrieval, and uploads for legacy vaults are not yet supported.")
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
