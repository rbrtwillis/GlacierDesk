# Project instructions

- Keep `CHANGELOG.md` as a persistent release history. For each user-visible change or material fix, add a concise entry under `Unreleased`; when preparing a version, move the relevant entries into a dated version section without deleting prior history.
- Keep version metadata in `scripts/build-app.sh`, the README, and the changelog consistent when changing the app version.
- Do not run live AWS mutations or chargeable integration tests without a specifically authorized test environment.
