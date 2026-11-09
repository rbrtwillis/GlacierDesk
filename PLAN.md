# GlacierDesk project plan

Copyright © 2026 willislabs.ai. Ownership and licensing terms are to be finalized before publication.

## Product

GlacierDesk is a native macOS application for browsing, uploading, restoring, and downloading Amazon S3 objects, with particular attention to S3 Glacier storage classes. The separate legacy Amazon Glacier vault service is out of scope for the initial release.

## First release

- Connect with a selected AWS profile; show the resolved account and principal before operations.
- Browse buckets and object prefixes with pagination, object details, and clear permission errors.
- Upload files and folders with a selected storage class, progress, cancellation, retry, and explicit overwrite handling.
- Download available objects; request and monitor restoration of archived objects, displaying tier, duration, expected wait, and restore expiration.
- Maintain a transfer and restore activity view. Explain possible AWS charges and link to current pricing before chargeable operations.
- Keep deletion, legacy vaults, lifecycle administration, and automated bulk operations outside the first release.

## Credential security

- Prefer IAM Identity Center and assumed roles with temporary credentials. Use supported AWS SDK credential providers and let them refresh credentials; never collect AWS root credentials.
- Support explicitly selected shared AWS profiles, avoiding accidental use of a different identity due to environment variable precedence. Verify the resolved identity with STS and display account and principal. Test profile, SSO, assume-role, expired-session, and conflicting-environment cases against the chosen SDK version.
- Where supported, use the existing AWS CLI SSO login and cache; explain when reauthentication is needed. The SDK's SSO resolver may need explicit configuration; verify this in the implementation spike.
- Do not copy existing AWS credentials or SSO tokens into app storage. Shared AWS credential files and SSO caches are managed by AWS tools and can contain sensitive plaintext data; access only what the chosen provider requires.
- If manual access-key entry is added, make it an explicit fallback, store secrets only in macOS Keychain with appropriate access controls, never in preferences, logs, analytics, crash reports, or the repository; provide removal and rotation. Do not implement it until its design is reviewed.
- Never transmit credentials to willislabs.ai or any intermediary. AWS requests use TLS and the SDK's request signing. Redact secrets, session tokens, authorization headers, and sensitive request data from diagnostics.
- Document least-privilege IAM permissions by operation and bucket, including optional KMS permissions. Make denied operations understandable without asking users for administrator access.
- Review macOS sandbox, file access, credential-provider helper processes, and distribution entitlements together; validate the chosen configuration with real profiles and security-scoped file access.
- Add secret scanning, dependency updates, security reporting instructions, and tests for redaction and credential lifecycle. Security claims must be verified before release.

## Architecture

- SwiftUI with AppKit integration where macOS behavior requires it. Evaluate the AWS SDK for Swift and its credential, S3, multipart transfer, and distribution support before committing to it.
- Separate UI, domain models, AWS adapters, credential selection, transfer engine, and local persistence behind testable interfaces.
- Stream transfers, bound concurrency, retry transient failures, and account for multipart cleanup. Persist recoverable task metadata without credentials.
- Model archive state explicitly: available, archived, restore pending, restored until expiration, and unknown/error. AWS remains the source of truth.

## Delivery milestones

1. Foundation: confirm macOS deployment target, SDK feasibility, identity handling, license, repository ownership, and build tooling.
2. Browse: connect securely, identify the principal, and browse buckets and paginated objects.
3. Upload: implement storage-class selection and reliable file/folder transfers.
4. Restore and download: implement restore requests, status, expiration, and verified downloads.
5. Release: accessibility, security review, tests, documentation, CI, signing/notarization, and distribution.

## Acceptance checks

- Integration tests use a dedicated test account and bucket with narrowly scoped permissions and an explicit cost budget.
- Test expired credentials, SSO reauthentication, profile precedence, denied actions, interrupted multipart uploads, restore delays, expiration, and app restarts.
- Verify a full upload → archive restore → download flow against AWS, including integrity checking and user-visible error recovery.

## Ownership and publication decisions

- Proposed project copyright notice: `Copyright © 2026 willislabs.ai`. Confirm the legal copyright holder if it differs from the brand.
- Choose an open-source license before publishing; Apache-2.0 is a proposed default, not yet adopted. Contributor copyright and contribution terms should be reflected accurately rather than implying automatic transfer of ownership.
- Choose the GitHub account or organization that will own the public repository, and whether “GitHub project” also means a Projects board.

## References

- [AWS SDK for Swift credential providers](https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/credential-providers.html)
- [AWS IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [S3 Glacier storage classes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/glacier-storage-classes.html)
- [Archive retrieval options](https://docs.aws.amazon.com/AmazonS3/latest/userguide/restoring-objects-retrieval-options.html)
