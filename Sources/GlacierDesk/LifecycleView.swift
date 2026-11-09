import SwiftUI

struct LifecycleView: View {
    let service: AWSService
    let bucket: String
    let account: String
    @Environment(\.dismiss) private var dismiss
    @State private var prefix = ""
    @State private var days = 7
    @State private var snapshot: LifecycleSnapshot?
    @State private var proposed: Data?
    @State private var busy = false
    @State private var error: String?
    @State private var success = false
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Incomplete upload cleanup").font(.title2.weight(.semibold))
            Text("Bucket: \(bucket) · Account: \(account)").font(.callout).textSelection(.enabled)
            Text("S3 will abort incomplete multipart uploads after the selected number of days, including uploads started before this rule. Completed objects are unaffected.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("Prefix (empty means the entire bucket)", text: $prefix).textFieldStyle(.roundedBorder)
                .disabled(busy).onChange(of: prefix) { _ in proposed = nil }
            Stepper("Days after initiation: \(days)", value: $days, in: 1...3650)
                .disabled(busy).onChange(of: days) { _ in proposed = nil }
            HStack {
                Button("Preview configuration") { Task { await preview() } }.disabled(busy || success)
                if busy { ProgressView().controlSize(.small) }
            }
            if let proposed {
                Text("Proposed complete lifecycle configuration").font(.headline)
                ScrollView {
                    Text(String(decoding: proposed, as: UTF8.self)).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(minHeight: 160).background(Color(nsColor: .textBackgroundColor))
                Text("S3 replaces the whole lifecycle configuration. Existing rules are included above. Concurrent changes after the final check could still be overwritten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if success { Text("Cleanup rule applied. Check the bucket’s lifecycle configuration to verify it.").foregroundStyle(.green) }
            HStack {
                Spacer()
                Button(success ? "Done" : "Cancel") { dismiss() }.disabled(busy)
                Button("Apply rule…") { confirm = true }.buttonStyle(.borderedProminent).disabled(proposed == nil || busy || success)
            }
        }.padding(22).frame(width: 640, height: 600)
        .confirmationDialog("Apply cleanup to \(bucket)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Apply lifecycle configuration") { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("S3 will abort matching incomplete multipart uploads after \(days) days, including existing uploads. The full lifecycle configuration will be replaced with the previewed rules.")
        }
    }

    private func preview() async {
        busy = true; error = nil; proposed = nil
        defer { busy = false }
        do {
            let current = try await service.lifecycleSnapshot(bucket: bucket, account: account)
            proposed = try current.addingCleanup(prefix: prefix, days: days)
            snapshot = current
        } catch { self.error = error.localizedDescription }
    }

    private func apply() async {
        guard let snapshot, let proposed else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await service.addCleanupRule(bucket: bucket, account: account, original: snapshot, proposed: proposed); success = true }
        catch { self.error = error.localizedDescription; self.proposed = nil }
    }
}
