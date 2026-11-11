# Changelog

Notable user-visible changes are recorded here. Add new work under **Unreleased** and move it into a versioned section when releasing; retain earlier release history.

## Unreleased

No changes recorded yet.

## 0.2.0 — 2026-11-10

### Added

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
