# GlacierDesk 0.1

A native macOS app for browsing, uploading, restoring, and downloading Amazon S3 objects, with a focus on S3 Glacier storage classes.

Version 0.1 is an early SwiftUI development checkpoint (the app bundle reports `0.1.0`). It uses the AWS CLI and existing AWS profiles. See [PLAN.md](PLAN.md) for current limitations and next milestones, and [DESIGN.md](DESIGN.md) for the visual identity.

## What's included

- Named AWS profile selection, STS account and principal display, and bucket and prefix browsing with pagination.
- Single-file upload with storage-class selection, configurable multipart threshold, part size and parallel requests; individual and multi-selection download of available objects.
- Transfer progress, cancellation and manual retry; restore requests and locally saved restore status for S3 Glacier Flexible Retrieval and Deep Archive.
- A preview and confirmation workflow for an incomplete-multipart-upload lifecycle rule, preserving existing rules in the proposed configuration.
- Native light and dark appearances.
- Legacy Amazon Glacier vault listing, inventory browsing, archive retrieval jobs, verified downloads, and single-file uploads up to 4 GiB.

This version does not support folder uploads, deletion, multipart uploads to legacy vaults, resumable transfers across restarts, or automatic discovery of S3 restore requests made outside the app. S3 restore requests use a three-day temporary copy. Live AWS end-to-end validation and accessibility review remain outstanding.

In the object list, use Command-click or Shift-click to select multiple objects, then choose **Download selected** and a destination folder. Existing local files are skipped; archived objects without a completed restore and failed downloads are reported in Activity. Batch downloads run sequentially.

To find older Glacier vaults, connect a profile, select **Legacy vaults**, choose the Region where the vaults were created, and choose **Find vaults**. Open a vault to request an inventory or archive retrieval, refresh AWS jobs, open a completed inventory, search archives, or download a completed archive retrieval. You can also enter an archive ID directly or upload a single file up to 4 GiB. Archive IDs returned by uploads are saved locally; keep an independent copy. Vault inventories can take hours to prepare, reflect the last inventory rather than live contents, and may be large. Glacier job output is available for a limited time after completion. Retrieval, storage, requests and data transfer may incur AWS charges.

The identity needs the relevant `glacier:ListVaults`, `glacier:ListJobs`, `glacier:InitiateJob`, `glacier:GetJobOutput`, and `glacier:UploadArchive` permissions for the actions used. Vaults are a separate AWS service and do not appear in the S3 bucket list. Listing vaults does not start an inventory retrieval job. Downloads check the archive's Glacier tree hash before replacing a local file. If a job or upload request times out, its outcome may be unknown: check jobs or inventory before retrying to avoid duplicate charges or archives. Legacy operations have not yet been validated against a live vault.

## Build locally

Requirements: macOS 13 or later, Xcode command-line tools or Xcode with Swift 5.9 or later, and AWS CLI v2 configured with an AWS profile. For IAM Identity Center profiles, sign in using `aws sso login --profile YOUR_PROFILE` before connecting.

Run `bash scripts/build-app.sh` from the project directory, then open `dist/GlacierDesk.app`. The local build is unsigned and is intended for development; it is not a notarized distribution.

This early checkpoint uses the locally installed AWS CLI and your existing AWS configuration. AWS operations can incur charges. Use a dedicated test account and bucket when evaluating the app.

Use the sliders button in the toolbar to configure the multipart upload threshold, part size, and maximum parallel requests. Settings apply to new uploads; files below the threshold use a single upload. The AWS CLI may increase part size to satisfy S3 limits. GlacierDesk uses a temporary private copy of the AWS config for these settings and leaves the original unchanged. Interrupted multipart uploads can leave billable parts in S3; configure an S3 lifecycle rule to abort incomplete multipart uploads.

To configure cleanup, select a bucket and click the lifecycle button in the toolbar. Choose the number of days and optionally a key prefix, then preview the entire proposed lifecycle configuration and confirm. An empty prefix applies to the entire bucket, including incomplete uploads created by other applications and uploads that already exist. GlacierDesk checks for configuration changes before writing, but S3 has no atomic compare-and-swap for this operation, so another change made between that check and the write could be overwritten. The selected account must own the bucket and have `s3:GetLifecycleConfiguration` and `s3:PutLifecycleConfiguration` permissions. Review existing rules and coordinate with other bucket administrators before applying.

The Activity view shows transfer progress and offers cancellation and retry. Retry starts the transfer again; it does not resume individual multipart parts. Downloads use a temporary file and replace the destination only after a successful transfer. Transfers and retry actions do not survive an app restart.

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
