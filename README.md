# GlacierDesk 0.3

A native macOS app for browsing, uploading, restoring, and downloading Amazon S3 objects, with a focus on S3 Glacier storage classes.

Version 0.3 is an early SwiftUI development checkpoint (the app bundle reports `0.3.0`). It uses the AWS CLI and existing AWS profiles. See [CHANGELOG.md](CHANGELOG.md) for release history, [PLAN.md](PLAN.md) for limitations and next milestones, and [DESIGN.md](DESIGN.md) for the visual identity.

## What's included

- Named AWS profile selection, STS account and principal display, and bucket and prefix browsing with pagination.
- File and folder upload with storage-class selection, configurable multipart threshold, part size and parallel requests; individual and multi-selection download of available objects.
- Transfer progress, cancellation and manual retry; restore requests and locally saved restore status for S3 Glacier Flexible Retrieval and Deep Archive.
- A preview and confirmation workflow for an incomplete-multipart-upload lifecycle rule, preserving existing rules in the proposed configuration.
- Native light and dark appearances.
- Legacy Amazon Glacier vault listing, inventory browsing, archive retrieval jobs, verified downloads, multipart file and folder uploads, and reviewed archive deletion.
- Automatic refresh of in-progress legacy jobs while a vault is open, optional completion notifications, a locally indexed inventory browser, bulk retrieval, and a read-only migration comparison.
- An in-app Help window and collapsible bucket list.

This version does not support S3 object deletion, resumable multipart parts across restarts, or automatic discovery of S3 restore requests made outside the app. S3 restore requests use a three-day temporary copy. Live AWS end-to-end validation and accessibility review remain outstanding.

To upload a folder, open an S3 bucket and prefix, or open a legacy Glacier vault, then drag files or folders from Finder into the main view. Review the destinations and charges before starting the queue. S3 preserves the folder path in the object key and can replace existing objects. Legacy Glacier stores each file as a separate archive; the relative path becomes the archive description, where non-ASCII characters are replaced. Empty folders and symbolic links are skipped; zero-byte legacy archives are not supported. Legacy vaults can upload 1–16 files at once, with a separate per-file parallel request limit for multipart uploads. S3 folder queues currently upload files sequentially. Legacy part sizes are rounded up to a supported power of two and may be increased for very large files.

Each queued file is copied to a private temporary snapshot before upload, and legacy multipart uploads additionally create temporary part files. Ensure enough free disk space for snapshots and concurrent parts across all active files. Folder upload queue records persist locally; after reconnecting the original profile and account, eligible unfinished files can be reviewed and explicitly retried. Retrying starts a file again, not its completed multipart parts. An interrupted legacy upload with an unknown outcome cannot be retried automatically. On cancellation or error, incomplete multipart parts can remain billable if abort is not confirmed; check AWS for cleanup. Legacy upload completion can have an unknown outcome after a network error, so check the vault before retrying to avoid duplicate archives.

In the object list, use Command-click or Shift-click to select multiple objects, then choose **Download selected** and a destination folder. Existing local files are skipped; archived objects without a completed restore and failed downloads are reported in Activity. Batch downloads run sequentially.

To find older Glacier vaults, connect a profile, select **Legacy vaults**, choose the Region where the vaults were created, and choose **Find vaults**. Open a vault to use its Browse, Jobs, Uploads, and Retrieve sections. You can request an inventory or archive retrieval, refresh AWS jobs, open a completed inventory, search archives, download a completed archive retrieval, or upload files. Job entries show their creation time in the Mac’s local time. Archive IDs returned by uploads are saved locally; keep an independent copy. Vault inventories can take hours to prepare, reflect the last inventory rather than live contents, and may be large. AWS makes completed job output available for at least 24 hours; after opening an inventory, GlacierDesk retains a local cached snapshot until replaced or removed. Successfully uploaded archives recorded on this Mac are shown as local additions until included in a later AWS snapshot. Enable **Automatically cache inventory jobs for vaults I open** to register the current vault and other vaults you open while the setting is enabled. While GlacierDesk is open and the original profile and account remain connected, it checks those vaults in the background, including after you navigate away. Turning the setting off stops future checks. Checks and downloads can incur AWS charges; monitoring stops when the app quits. Failed capture attempts are retried no more than once every 15 minutes. A newer cached inventory is protected against replacement by an older snapshot. Retrieval, storage, requests and data transfer may incur AWS charges.

Legacy inventory browsing streams the cached snapshot into a temporary disk-backed listing for the current folder; folders and files are paged separately. Search the current folder using Enter or the Search button. Rebuilding a listing scans the cached inventory and uses temporary disk space, so very large vaults may take time to navigate.

In the legacy inventory browser, check individual archives or folders and choose **Review deletion**. A selected folder includes all known nested archives in the cached snapshot and locally recorded uploads, not just the visible page. The review lists archive IDs and requires typing `DELETE`; deletion is permanent, can incur early-deletion charges, and may affect retrieval jobs. Glacier inventories are snapshots, so archives missing from the cached snapshot cannot be included. Verify the vault afterward. Confirmed deletions are hidden locally when an older inventory is reopened. Deletion requires `glacier:DeleteArchive`.

The identity needs the relevant Glacier permissions for listing vaults and jobs, initiating and reading jobs, uploading archives and multipart parts, completing uploads, and aborting incomplete uploads. Vaults are a separate AWS service and do not appear in the S3 bucket list. Listing vaults does not start an inventory retrieval job. Downloads check the archive's Glacier tree hash before replacing a local file. If a job or upload request times out, its outcome may be unknown: check jobs or inventory before retrying to avoid duplicate charges or archives. Legacy operations have not yet been validated against a live vault.

## Build locally

Requirements: macOS 13 or later, Xcode command-line tools or Xcode with Swift 5.9 or later, and AWS CLI v2 configured with an AWS profile. For IAM Identity Center profiles, sign in using `aws sso login --profile YOUR_PROFILE` before connecting.

Run `bash scripts/build-app.sh` from the project directory, then open `dist/GlacierDesk.app`. The local build is unsigned and is intended for development; it is not a notarized distribution.

This early checkpoint uses the locally installed AWS CLI and your existing AWS configuration. AWS operations can incur charges. Use a dedicated test account and bucket when evaluating the app.

Use the sliders button in the toolbar to configure the multipart upload threshold, part size, multipart requests per file, and the number of legacy files uploaded at once (up to 16). Settings apply to new uploads; files below the threshold use a single upload. The AWS CLI may increase part size to satisfy S3 limits. GlacierDesk uses a temporary private copy of the AWS config for these settings and leaves the original unchanged. Interrupted multipart uploads can leave billable parts in S3; configure an S3 lifecycle rule to abort incomplete multipart uploads.

The legacy transfer window reports active files, active part tasks, confirmed part bytes, elapsed time, an average including local preparation, per-file snapshot and checksum times, and summed AWS request time. Concurrent request times overlap and are not wall-clock time; part tasks include preparation as well as network requests. A part counts only when AWS confirms it; single-request bytes appear after completion. These rates are not a maximum network-capacity measurement. If snapshot or checksum time dominates, check local disk throughput and CPU before raising concurrency. If the capacity test is consistently faster than the S3 test, try adjusting concurrent files or multipart requests gradually and compare results; request counts, disk use, AWS charges, and server behavior can also affect throughput. These comparisons do not identify a bottleneck conclusively. The bucket toolbar’s speedometer opens an optional S3 upload test: select a size and confirm the destination and charges before starting. The same panel offers an optional macOS `networkQuality` upload-capacity test against the system-configured Internet test server; it uses network data and is a separate measurement, not a guarantee of S3 performance. GlacierDesk attempts to delete the unique STANDARD test object (including its identified version) afterward; this requires object read and delete permissions. If cleanup cannot be confirmed, inspect the reported object and its versions. Interrupted multipart uploads may also need cleanup. The test uses temporary disk space and its timing includes AWS CLI setup.

To configure cleanup, select a bucket and click the lifecycle button in the toolbar. Choose the number of days and optionally a key prefix, then preview the entire proposed lifecycle configuration and confirm. An empty prefix applies to the entire bucket, including incomplete uploads created by other applications and uploads that already exist. GlacierDesk checks for configuration changes before writing, but S3 has no atomic compare-and-swap for this operation, so another change made between that check and the write could be overwritten. The selected account must own the bucket and have `s3:GetLifecycleConfiguration` and `s3:PutLifecycleConfiguration` permissions. Review existing rules and coordinate with other bucket administrators before applying.

The Activity view shows transfer progress, saved S3 folder queues, cancellation, and explicit retry. In a legacy vault, **Transfer queue** opens a movable, resizable window showing each active file’s upload method and completed multipart parts. Check boxes select individual entries; with none selected, cancellation and clearing apply to all eligible entries. **Stop after active files** lets active uploads complete and leaves pending files queued; **Cancel active now** interrupts active uploads and may leave uncertain results; **Cancel pending** marks selected or all pending files cancelled; **Clear finished** removes eligible completed, failed, or cancelled records. **Resume** reviews and restarts eligible pending or failed files from one saved queue. Unknown outcomes remain excluded from automatic retry. After inspecting AWS, select uncertain records and use **Clear selected uncertain** to remove them from local history; this does not change anything in AWS. Retry starts the file again; it does not resume individual multipart parts. Downloads use a temporary file and replace the destination only after a successful transfer. Active downloads and single-file transfers do not resume across app restarts.

The Restores view saves requests made in GlacierDesk on this Mac and refreshes their S3 status when you connect and approximately once a minute while the app is open. Connect to the same profile and account to refresh a request. The S3 restore response includes an expiry date when a temporary copy is available. Requests initiated elsewhere are not automatically added to this list. If the app exits before a restore response is received, inspect the object in S3 before submitting another request.

## Set up an AWS profile

GlacierDesk uses AWS CLI named profiles. Install [AWS CLI version 2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), then check that `aws --version` works in Terminal. You need an AWS identity with permissions for the S3 buckets and actions you intend to use; ask your AWS administrator if you do not have one.

### IAM Identity Center (recommended)

IAM Identity Center uses temporary credentials. Obtain your organization's SSO start URL (or issuer URL), its SSO Region, and an assigned account and permission set from your administrator. The SSO Region can differ from your bucket's Region.

1. In Terminal, run:

   ```sh
   aws configure sso --profile glacierdesk
   ```

2. Follow the prompts to name the SSO session, enter the URL and SSO Region, and authorize in your browser. Select the intended AWS account and role, then choose a default AWS Region and output format (for example, `json`). Accept the suggested registration scope unless your administrator specifies otherwise.
3. Sign in when needed, including after your session expires:

   ```sh
   aws sso login --profile glacierdesk
   ```

See [AWS's IAM Identity Center setup guide](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html) for the full flow and troubleshooting.

### IAM access keys (alternative)

If your environment requires IAM user access keys, create a named profile interactively:

```sh
aws configure --profile glacierdesk
```

Enter the access key ID, secret access key, default Region, and output format when prompted. Prefer temporary credentials where possible, use least-privilege permissions, and never use root-user access keys. The AWS CLI stores these long-lived keys in the shared credentials file in plaintext; protect the file and do not share or commit it. See [AWS's credential-file documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html).

### Connect GlacierDesk

1. List available profiles with `aws configure list-profiles`.
2. Verify the account and principal with `aws sts get-caller-identity --profile glacierdesk`. If environment credentials are set in your shell, they can affect this check; clear them or verify the identity shown by GlacierDesk itself.
3. Open GlacierDesk, click the refresh button beside the profile picker, select `glacierdesk`, and click **Connect**. Confirm the account and principal shown in the sidebar before browsing or transferring files.

Replace `glacierdesk` with your chosen profile name throughout. To switch profiles, disconnect in the app first. GlacierDesk does not create profiles or perform SSO login itself in this checkpoint.

## Copyright and license

Copyright © 2026 WillisLabs.ai. Licensed under the [Apache License, Version 2.0](LICENSE).
