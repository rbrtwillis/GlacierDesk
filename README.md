# GlacierDesk

A planned native macOS app for browsing, uploading, restoring, and downloading Amazon S3 objects, with a focus on S3 Glacier storage classes.

GlacierDesk is an early native SwiftUI application. See [PLAN.md](PLAN.md) for the planned features, credential-security design, architecture, and milestones.

## Build locally

Requirements: macOS 13 or later, Xcode command-line tools or Xcode with Swift 5.9 or later, and AWS CLI v2 configured with an AWS profile. For IAM Identity Center profiles, sign in using `aws sso login --profile YOUR_PROFILE` before connecting.

Run `bash scripts/build-app.sh` from the project directory, then open `dist/GlacierDesk.app`. The local build is unsigned and is intended for development; it is not a notarized distribution.

This early checkpoint uses the locally installed AWS CLI and your existing AWS configuration. AWS operations can incur charges. Use a dedicated test account and bucket when evaluating the app.

## Copyright and license

Copyright © 2026 WillisLabs.ai. Licensed under the [Apache License, Version 2.0](LICENSE).
