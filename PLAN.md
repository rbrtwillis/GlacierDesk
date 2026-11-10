# GlacierDesk 0.1 status and roadmap

Copyright © 2026 WillisLabs.ai. Licensed under the Apache License, Version 2.0.

## Current checkpoint

GlacierDesk 0.1 is a native SwiftUI macOS development build for S3 objects, including Glacier storage classes. It uses an installed AWS CLI v2 with explicitly selected shared profiles, displays the STS identity, and supports bucket and prefix browsing, individual file uploads, individual and batch downloads, Glacier restores, and an opt-in incomplete-upload lifecycle rule. It also lists legacy Amazon Glacier vaults by Region; inventory and archive operations for those vaults are not yet implemented.

Uploads have configurable multipart settings. The Activity view provides progress, cancellation, and manual retry; retry restarts the transfer, and active transfers do not survive app restarts. Downloads use a temporary destination before replacing the final file. Restore requests made by the app are stored locally and refreshed for the matching account and profile while the app runs; the current restore duration is three days.

The lifecycle workflow previews all rules and checks for intervening changes before writing. S3 replaces the full configuration without an atomic compare-and-swap, so a concurrent update after that check can still be overwritten. The current implementation requires the connected account to own the bucket.

## Security and credential handling

- Prefer IAM Identity Center and temporary role credentials. The app uses the existing AWS CLI profile and SSO cache; it does not create profiles, perform SSO login, or collect access keys.
- The CLI adapter removes inherited `AWS_` environment variables and selects the named profile explicitly. It displays the account and principal resolved by STS. Existing shared configuration and credential files remain sensitive; the AWS CLI may store access keys in plaintext.
- For upload settings, the app creates a private temporary copy of the AWS config and removes it after the transfer. The app does not intentionally save credentials in preferences or restore history.
- Diagnostic redaction and credential isolation require further security review and testing. Use least-privilege IAM permissions and a dedicated test bucket for evaluation.

## Next milestones

1. Validate browse, upload, download, restore, and lifecycle flows against a dedicated AWS account and bucket, including permissions, SSO expiration, interruptions, and cost behavior.
2. Add automated integration and unit tests, including redaction, profile isolation, lifecycle preservation, concurrency, transfer cancellation, and restore status across restarts.
3. Improve transfers with durable queueing, robust recovery, resumable multipart operations and cleanup, clearer progress and errors, and folder uploads.
4. Improve restores with configurable duration, clearer expiration and status, recovery after interrupted submissions, and discovery or import of externally initiated requests.
5. Complete accessibility and light/dark appearance review, security review, dependency and secret scanning, CI, signing, notarization, and distribution.

Use a dedicated test account and bucket with narrowly scoped permissions and an explicit budget. Verify a complete upload → restore → download flow and file integrity before treating 0.1 as production-ready.

## Ownership and project

- Copyright © 2026 WillisLabs.ai; Apache License 2.0. Contributors retain their own copyright unless otherwise agreed.
- Public repository: [rbrtwillis/GlacierDesk](https://github.com/rbrtwillis/GlacierDesk). A GitHub Projects board remains pending project permissions.

## References

- [AWS CLI S3 transfer configuration](https://docs.aws.amazon.com/cli/latest/topic/s3-config.html)
- [AWS IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [S3 Glacier storage classes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/glacier-storage-classes.html)
- [Archive retrieval options](https://docs.aws.amazon.com/AmazonS3/latest/userguide/restoring-objects-retrieval-options.html)
- [Incomplete multipart upload lifecycle rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpu-abort-incomplete-mpu-lifecycle-config.html)
