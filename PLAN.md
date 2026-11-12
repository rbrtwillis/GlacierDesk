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

## Queue follow-up

- [ ] Improve legacy vault inventory freshness, retention, and browser scalability. Investigate AWS Glacier inventory generation and completed-job output retention limits, document which limits AWS controls, and ensure the locally indexed snapshot remains available beyond the AWS job-output window. Design an opt-in, cost-aware way to capture completed inventory jobs before their output expires and to reconcile confirmed local uploads or other known changes without representing the snapshot as a live AWS listing. Review large-vault indexing, folder navigation, search, pagination, and responsiveness; clearly show snapshot age, local additions, failures, and when a new AWS inventory is needed. Add tests for cache persistence, reconciliation, large inventories, and expired job output.

- [ ] Add upload throughput diagnostics and a way to assess available network capacity. Show aggregate and per-file transfer rates, bytes and elapsed time, active files and multipart requests, and time spent preparing snapshots, checksumming, and waiting on AWS. Offer an explicitly started, cost-aware throughput test with a user-selected destination and data size; distinguish measured end-to-end AWS upload speed from local network capacity and avoid claiming a theoretical maximum. Use the measurements to identify likely bottlenecks and help tune file concurrency, part size, and per-file connections. Document test costs, temporary storage use, and cleanup, and test calculations with simulated transfers.

- [ ] Make **Stop** a graceful queue stop: do not start any additional files, allow each active file to finish uploading its remaining parts and complete normally, then leave never-started files pending for explicit resume. Keep a separate clearly labeled immediate cancellation action if interrupting active transfers is needed. Test concurrent uploads, stop/resume, errors, and queue persistence across restart.

- [ ] Allow an operator to review and clear selected legacy upload records marked `outcomeUnknown` from the local transfer queue. Show the archive path and known multipart upload ID, explain that clearing the local record does not abort or delete anything in AWS, and require an explicit acknowledgement before removing the record. Preserve the existing restriction against automatic retry of uncertain uploads; offer guidance for inspecting and cleaning up an incomplete multipart upload in the correct account, Region, and vault. Include individual and bulk selection tests and verify that other queue entries are unaffected.

### Implementation status

- Implemented: opt-in inventory capture while the vault is open, persistent local snapshots, and protection against replacing a newer dated snapshot with an older one. Large-vault memory use, background capture, and broader browser scalability remain to be addressed.
- Implemented: confirmed-part byte counts, average upload rates, snapshot/checksum timing, and an opt-in S3 upload test. The test attempts to delete its object and identified version and reports unconfirmed cleanup; separate network-capacity measurement, active-request counts, detailed AWS wait timing, and tuning recommendations remain open.
- Implemented: graceful stop and separate immediate cancellation, plus reviewed clearing of selected uncertain local records. Dedicated concurrent stop/resume integration coverage and live AWS validation remain open.

## Next milestones

1. Validate browse, upload, download, restore, and lifecycle flows against a dedicated AWS account and bucket, including permissions, SSO expiration, interruptions, and cost behavior.
2. Add automated integration and unit tests, including redaction, profile isolation, lifecycle preservation, concurrency, transfer cancellation, and restore status across restarts.
3. Improve transfers with durable queueing, robust recovery, resumable multipart operations and cleanup, and clearer progress and errors.
4. Improve restores with configurable duration, clearer expiration and status, recovery after interrupted submissions, and discovery or import of externally initiated requests.
5. Complete accessibility and light/dark appearance review, security review, dependency and secret scanning, CI, signing, notarization, and distribution.

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
