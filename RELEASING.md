# Preparing a GlacierDesk release

The normal `scripts/build-app.sh` produces a local development build. A public macOS release also requires an Apple Developer ID Application certificate and Apple notarization credentials. Never put private keys, passwords, or API keys in this repository or CI logs.

1. Run the test suite and complete a live integration exercise in a dedicated AWS account and bucket with a budget. Verify the app's version in `scripts/build-app.sh` and its documentation.
2. Ensure `security find-identity -v -p codesigning` shows the intended Developer ID Application identity. Configure a `notarytool` keychain profile using Apple's documented process.
3. Set `GLACIERDESK_SIGNING_IDENTITY` to that identity and `GLACIERDESK_NOTARY_PROFILE` to the keychain profile name. Run `bash scripts/release.sh`.
4. The script rebuilds, signs with the hardened runtime, submits for notarization, staples and validates the ticket, checks Gatekeeper, and creates `dist/GlacierDesk-notarized.zip`. Inspect the artifact on a clean Mac before distributing it.

The release script does not publish or upload a GitHub release. Notarization uploads the signed application to Apple. The local machine currently may lack a signing identity; a successful local build is not proof of signing or notarization.
