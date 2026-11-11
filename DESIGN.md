# GlacierDesk 0.2 visual identity

Copyright © 2026 WillisLabs.ai.

The GlacierDesk mark combines an iceberg and an archive drawer to suggest durable cold storage. The navy icon tile keeps the mark recognizable in both macOS appearances. The generated master is [Assets/GlacierDesk.png](Assets/GlacierDesk.png); the build script produces the macOS icon from it.

The interface follows the macOS appearance automatically. System text and controls retain their native semantic colors; GlacierDesk adds these adaptive colors:

| Role | Light | Dark |
| --- | --- | --- |
| Accent | `#006D91` | `#54D5F3` |
| Main background | `#F4F9FC` | `#101D2C` |
| Sidebar | `#E8F2F7` | `#142536` |

Use accent color for navigation and actions, not as the only indicator of status. Preserve native accessibility settings and check contrast and appearance on real displays before release.
