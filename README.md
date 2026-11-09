# GlacierDesk

A planned native macOS app for browsing, uploading, restoring, and downloading Amazon S3 objects, with a focus on S3 Glacier storage classes.

GlacierDesk is an early native SwiftUI application. See [PLAN.md](PLAN.md) for the planned features, credential-security design, architecture, and milestones.

## Build locally

Requirements: macOS 13 or later, Xcode command-line tools or Xcode with Swift 5.9 or later, and AWS CLI v2 configured with an AWS profile. For IAM Identity Center profiles, sign in using `aws sso login --profile YOUR_PROFILE` before connecting.

Run `bash scripts/build-app.sh` from the project directory, then open `dist/GlacierDesk.app`. The local build is unsigned and is intended for development; it is not a notarized distribution.

This early checkpoint uses the locally installed AWS CLI and your existing AWS configuration. AWS operations can incur charges. Use a dedicated test account and bucket when evaluating the app.

## Set up an AWS profile

GlacierDesk uses AWS CLI named profiles. Install [AWS CLI version 2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), then check that `aws --version` works in Terminal. You need an AWS identity with permissions for the S3 buckets and actions you intend to use; ask your AWS administrator if you do not have one.

### IAM Identity Center (recommended)

IAM Identity Center uses temporary credentials. Obtain your organization's SSO start URL (or issuer URL), its SSO Region, and an assigned account and permission set from your administrator. The SSO Region can differ from your bucket's Region.

1. In Terminal, run:

   ```sh
   aws configure sso --profile glacierdesk
   ```

2. Follow the prompts to name the SSO session, enter the URL and SSO Region, and authorize in your browser. Select the intended AWS account and role, then choose a default AWS Region and output format (for example, `json`). Accept the suggested registration scope unless your administrator specifies otherwise.
3. Sign in when needed, including after your session expires:

   ```sh
   aws sso login --profile glacierdesk
   ```

See [AWS's IAM Identity Center setup guide](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html) for the full flow and troubleshooting.

### IAM access keys (alternative)

If your environment requires IAM user access keys, create a named profile interactively:

```sh
aws configure --profile glacierdesk
```

Enter the access key ID, secret access key, default Region, and output format when prompted. Prefer temporary credentials where possible, use least-privilege permissions, and never use root-user access keys. The AWS CLI stores these long-lived keys in the shared credentials file in plaintext; protect the file and do not share or commit it. See [AWS's credential-file documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html).

### Connect GlacierDesk

1. List available profiles with `aws configure list-profiles`.
2. Verify the account and principal with `aws sts get-caller-identity --profile glacierdesk`. If environment credentials are set in your shell, they can affect this check; clear them or verify the identity shown by GlacierDesk itself.
3. Open GlacierDesk, click the refresh button beside the profile picker, select `glacierdesk`, and click **Connect**. Confirm the account and principal shown in the sidebar before browsing or transferring files.

Replace `glacierdesk` with your chosen profile name throughout. To switch profiles, disconnect in the app first. GlacierDesk does not create profiles or perform SSO login itself in this checkpoint.

## Copyright and license

Copyright © 2026 WillisLabs.ai. Licensed under the [Apache License, Version 2.0](LICENSE).
