import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("GlacierDesk Help").font(.largeTitle.weight(.semibold))
                section("Connect an AWS profile", "Install AWS CLI v2 and create a named profile with aws configure sso --profile NAME. For Identity Center, run aws sso login --profile NAME in Terminal, then choose the profile in GlacierDesk and connect. Confirm the account and principal shown in the sidebar. Use Disconnect before switching profiles.")
                section("Browse S3 buckets", "Choose Browse and select a bucket. Open folders to navigate prefixes; use Command-click or Shift-click to select several objects for download. Click the Buckets disclosure triangle to collapse or expand the list.")
                section("Upload files and folders", "Select an S3 bucket and destination prefix, or open a legacy vault, then drag files or folders from Finder into the main view. Review the queue before uploading. The toolbar sliders set the multipart threshold, part size, and parallel requests. Uploads may replace existing S3 objects and incur AWS charges. Private file snapshots and multipart parts need temporary disk space.")
                section("Legacy Glacier vaults", "Choose Legacy vaults, select the AWS Region, and choose Find vaults. Open a vault to view jobs, request an inventory, browse a completed inventory, or request archive retrieval. In-progress jobs refresh while the vault is open; notifications are optional. Inventories and retrievals can take hours. Glacier vaults store archives separately; paths are descriptions rather than folders.")
                section("Transfers and restores", "The Activity view shows S3 transfer progress, saved folder queues, and failures. Reconnect the original profile and account to review and explicitly retry eligible unfinished files. Legacy vault folder history is available within the vault. Retry restarts a file rather than resuming its completed parts; inspect AWS before retrying an interrupted or uncertain upload. The Restores view tracks S3 requests made in this app. Legacy retrieval output is available for a limited time.")
                section("Costs and safety", "AWS may charge for storage, requests, retrieval, and data transfer. Check the destination, storage class, and retrieval tier before confirming. Interrupted multipart uploads can leave billable parts. The lifecycle button can propose an S3 cleanup rule; review the complete configuration and its warnings before applying.")
                section("Troubleshooting", "If a profile is missing, refresh the profile list after configuring it in Terminal. If access is denied, check the account, Region, IAM and bucket permissions, and any KMS permissions. If an SSO session expires, sign in again with aws sso login --profile NAME. For an uncertain upload or job result, check AWS before retrying to avoid duplicates.")
                HStack(spacing: 20) {
                    Link("Project on GitHub", destination: URL(string: "https://github.com/rbrtwillis/GlacierDesk")!)
                    Link("AWS CLI profile setup", destination: URL(string: "https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html")!)
                    Link("AWS S3 pricing", destination: URL(string: "https://aws.amazon.com/s3/pricing/")!)
                }.font(.callout)
            }.padding(26).frame(maxWidth: 800, alignment: .leading)
        }
    }
    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
