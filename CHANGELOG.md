# Changelog

Notable user-visible changes are recorded here. Add new work under **Unreleased** and move it into a versioned section when releasing; retain earlier release history.

## Unreleased

No changes recorded yet.

## 0.3.0 — 2026-11-11

- Browse large legacy inventories through disk-backed, paged folder listings instead of retaining the full vault tree in memory.
- Monitor opted-in vault inventories in the background while the app remains open and connected to the original account.
- Show active file and part-task counts and aggregate AWS request timings for uploads; add an opt-in macOS network capacity test.
- Add simulated concurrent stop and resume coverage and background inventory capture tests.

- Add graceful legacy queue stopping and a separate immediate cancellation action.
- Allow selected uncertain legacy upload records to be cleared locally after explicit review.
- Add opt-in capture of completed Glacier inventory jobs and prevent older snapshots replacing newer cached inventories.
- Show upload throughput and preparation timings, and add an opt-in S3 upload speed test.

## 0.2.0 — 2026-11-10

### Added

- Add a Resume control for reviewed pending or failed legacy uploads, with account and source checks.

- Allow 1–16 concurrent legacy file uploads, each with its own configured multipart request limit.

- Show the active legacy upload method, completed multipart parts, part size, and parallel request limit.

- Show selection checkboxes beside current legacy transfers in a movable, resizable queue window.
- Add completed local legacy uploads to the browsable inventory after a queue finishes, marking them until an AWS inventory includes them.

- Add separate stop, cancel pending, and clear finished controls for individual or bulk legacy queue items.

- Fix AWS CLI handling of opaque multipart upload IDs and other tokens that start with a dash, including multipart cleanup.

- Show transfer queues with live status, cancellation, and reviewed retries for S3 and legacy uploads.

- Choose files and nested folders for upload to the current S3 or legacy vault folder; clarify local inventory retention.

- Keep bucket root and parent-folder navigation available in the S3 browser, including inside empty folders.
- Reconstruct a folder and file browser for legacy vault inventories, including encoded archive paths, with archive details available on demand.

- Automatic refresh of in-progress legacy Glacier jobs while the vault view is open, with optional completion notifications.
- Account-scoped, streamed local inventory indexing with search, sorting, and pagination.
- Bulk legacy archive retrieval with an explicit cost review and per-archive download destinations.
- A read-only migration comparison that labels matching names and sizes as candidates, not verified copies.
- Persistent folder-upload queue records, with explicit review and retry of eligible unfinished files after reconnecting the original profile and account.
- An in-app Help window, collapsible Buckets section, automated tests, CI configuration, and a release signing/notarization script.

### Limitations

- Retries restart a file; multipart parts do not resume across restarts. Unknown legacy upload outcomes require manual inspection.
- Live AWS end-to-end validation remains outstanding. The development build is not signed or notarized.

## 0.1.0 — 2026-11-09

- Introduced native S3 browsing, uploads, downloads, restore requests, and incomplete-upload cleanup rule review.
- Added legacy Glacier vault discovery, inventory and retrieval jobs, archive browsing, verified downloads, and multipart uploads.
- Added Finder folder upload queues, multipart settings, light and dark colors, and the GlacierDesk icon.
