# GlacierDesk 0.3 status and roadmap

Copyright © 2026 WillisLabs.ai. Licensed under the Apache License, Version 2.0.

## Current checkpoint

GlacierDesk 0.3 is a native SwiftUI macOS development build for S3 objects, including Glacier storage classes. It uses an installed AWS CLI v2 with explicitly selected shared profiles, displays the STS identity, and supports bucket and prefix browsing, file and folder uploads, individual and batch downloads, Glacier restores, and an opt-in incomplete-upload lifecycle rule. It also lists legacy Glacier vaults by Region and supports asynchronous inventory and retrieval jobs, account-scoped local inventory indexing, verified downloads, and file and folder uploads with multipart support. Live-vault validation remains outstanding.

Uploads have configurable multipart settings. Folder queue records persist across restarts and eligible files can be explicitly retried after reconnecting the original account; retries restart files rather than resuming uploaded parts. Unknown legacy upload outcomes require manual inspection. Downloads use a temporary destination before replacing the final file. Restore requests made by the app are stored locally and refreshed for the matching account and profile while the app runs; the current restore duration is three days.

The lifecycle workflow previews all rules and checks for intervening changes before writing. S3 replaces the full configuration without an atomic compare-and-swap, so a concurrent update after that check can still be overwritten. The current implementation requires the connected account to own the bucket.

## Security and credential handling

- Prefer IAM Identity Center and temporary role credentials. The app uses the existing AWS CLI profile and SSO cache; it does not create profiles, perform SSO login, or collect access keys.
- The CLI adapter removes inherited `AWS_` environment variables and selects the named profile explicitly. It displays the account and principal resolved by STS. Existing shared configuration and credential files remain sensitive; the AWS CLI may store access keys in plaintext.
- For upload settings, the app creates a private temporary copy of the AWS config and removes it after the transfer. The app does not intentionally save credentials in preferences or restore history.
- Diagnostic redaction and credential isolation require further security review and testing. Use least-privilege IAM permissions and a dedicated test bucket for evaluation.

## Transfer and inventory to-do

- [ ] Show total and remaining upload files and bytes, separating pending and active work. Account for confirmed multipart progress without double-counting; handle unknown sizes, failed, cancelled, and uncertain outcomes across stop, retry, resume, and restart. Test mixed sizes and states.
- [ ] Resume multipart uploads from confirmed completed parts after interruption, with account and source verification, safe recovery, and cleanup of abandoned uploads. Current retries restart a file.
- [ ] Validate graceful stop, immediate cancellation, explicit resume, and reviewed clearing of uncertain records against realistic concurrent failures and restarts; improve guidance for inspecting and cleaning up uncertain AWS uploads.
- [ ] Validate inventory capture, caching, local-upload reconciliation, expiration handling, and browsing performance with large vaults. Improve snapshot freshness and navigation as needed without presenting stale data as a live AWS listing. Background capture currently runs only while the app is open and connected.
- [ ] Validate throughput measurements and speed-test cleanup; improve bottleneck identification and tuning guidance. Distinguish S3 throughput from the separate macOS network-capacity test and account for request, storage, data-transfer, and temporary-disk costs.

### Already implemented

- Disk-backed paged folder listings, local inventory snapshots, opt-in capture while the app is open, local upload reconciliation, and protection against replacing newer snapshots with older ones.
- Active file and part-task counts, confirmed bytes, transfer rates, snapshot/checksum and AWS request timing, an opt-in S3 test with attempted version-aware cleanup, and an opt-in macOS network capacity test.
- Graceful stop, separate immediate cancellation, explicit retry of eligible files, and reviewed clearing of selected uncertain local records. Simulated concurrency, restart, inventory, and account-scope tests exist; live AWS validation remains outstanding.

## Later S3 interface work

- [ ] Revisit the sidebar bucket list when improving the S3 interface. Consider moving bucket navigation into the S3 Browse experience so it does not take space or appear to be loading while working with legacy vaults. Fix loading, empty, error, and collapsed states; keep long bucket names usable and retain access to all buckets. Verify the behavior when switching between S3 and legacy vaults, reconnecting, and resizing the window.

## Legacy vault protection

- [ ] Add a WORM protection workflow for legacy Glacier vaults using AWS Vault Lock policies. Allow users to inspect the current lock state, configure and preview a retention policy that enforces the intended write-once/read-many restrictions, and review the account, Region, vault, retention period, and affected operations. Support the separate initiation and completion steps, explain the 24-hour initiation window, and make the permanent, irreversible effect of completing a lock unmistakable before explicit confirmation. Handle existing locks, failed or expired initiation, permissions, and policy validation; test with simulated AWS responses without locking a live vault.

## Validation and release to-do

- [ ] Validate browsing, upload, download, restore, lifecycle rules, and legacy vault workflows in a specifically authorized AWS test account and bucket, including permission failures, expired SSO sessions, interruptions, and costs.
- [ ] Expand automated integration and unit tests for redaction, profile and account isolation, lifecycle preservation, transfer concurrency and cancellation, restore status, and recovery across restarts.
- [ ] Improve restores with configurable duration, expiration and status, recovery after interrupted submissions, and discovery or import of requests initiated elsewhere.
- [ ] Complete security, dependency, and secret-scanning reviews; verify CI, accessibility, and light/dark appearance.
- [ ] Complete code signing, notarization, and a distribution process.

Use a dedicated test account and bucket with narrowly scoped permissions and an explicit budget. Verify a complete upload → restore → download flow and file integrity before treating 0.3 as production-ready.

## Ownership and project

- Copyright © 2026 WillisLabs.ai; Apache License 2.0. Contributors retain their own copyright unless otherwise agreed.
- Public repository: [rbrtwillis/GlacierDesk](https://github.com/rbrtwillis/GlacierDesk). A GitHub Projects board remains pending project permissions.

## References

- [AWS CLI S3 transfer configuration](https://docs.aws.amazon.com/cli/latest/topic/s3-config.html)
- [AWS IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [S3 Glacier storage classes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/glacier-storage-classes.html)
- [Archive retrieval options](https://docs.aws.amazon.com/AmazonS3/latest/userguide/restoring-objects-retrieval-options.html)
- [Incomplete multipart upload lifecycle rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpu-abort-incomplete-mpu-lifecycle-config.html)
