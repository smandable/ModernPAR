# Security Policy

## Supported versions

Only the latest release on the [Releases page](https://github.com/smandable/ModernPAR/releases)
receives fixes. Installed copies update in place through the app's signed Sparkle feed.

## Reporting a vulnerability

Please report security issues privately rather than in a public issue:

1. Use [GitHub private vulnerability reporting](https://github.com/smandable/ModernPAR/security/advisories/new)
   for this repository.
2. If that page says private reporting is not enabled, open a
   [regular issue](https://github.com/smandable/ModernPAR/issues/new) titled "Security contact
   request" with **no details of the problem**, and a private channel will be arranged there.

Include the app version (About window), macOS version, and steps or a sample file that
reproduces the problem. Expect an acknowledgement within a week.

## What is in scope

ModernPAR processes untrusted input: PAR1/PAR2 sets, RAR and ZIP archives downloaded from
anywhere. Crashes, memory-safety bugs, or path-escape/overwrite behaviour triggered by a
crafted file are all in scope, as is anything that weakens the app sandbox, code signing, or
the update channel.

## Release integrity

Releases are built by the tag-gated GitHub Actions workflow in this repository, signed with a
Developer ID certificate, notarized by Apple, and stapled. Updates are EdDSA-signed and
verified by Sparkle before installation.
