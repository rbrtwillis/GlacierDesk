#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GLACIERDESK_SIGNING_IDENTITY:?Set GLACIERDESK_SIGNING_IDENTITY to a Developer ID Application identity}"
: "${GLACIERDESK_NOTARY_PROFILE:?Set GLACIERDESK_NOTARY_PROFILE to an existing notarytool keychain profile}"
bash scripts/build-app.sh "$@"
app="dist/GlacierDesk.app"
archive="dist/GlacierDesk-notarized.zip"
codesign --force --options runtime --timestamp --sign "$GLACIERDESK_SIGNING_IDENTITY" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
submission="$(mktemp -d "${TMPDIR:-/tmp}/glacierdesk-release.XXXXXX")"
trap 'rm -rf "$submission"' EXIT
ditto -c -k --keepParent "$app" "$submission/submission.zip"
xcrun notarytool submit "$submission/submission.zip" --keychain-profile "$GLACIERDESK_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$archive"
echo "Signed and notarized: $archive"
