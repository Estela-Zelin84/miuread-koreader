# MiuRead · WeRead Assistant

A WeRead plugin for KOReader, supporting Kindle, Kobo, Android, and other
KOReader devices.

> **MiuRead is free and not for sale.** Selling, paid distribution, paid
> installation, paid updates, commercial bundling, or monetization of MiuRead
> or any modified, renamed, ported, or repackaged version is prohibited.

## Current Release

This repository contains the beta source `4.1.0-beta.1` and is intended
for the `beta` branch.

See `CHANGELOG-4.1.0-beta.1.txt` for the release notes.

## Branches and Releases

- `main`: stable source, released through `.github/workflows/release.yml`; publishes `update.json`.
- `beta`: beta source, released through `.github/workflows/release-beta.yml`; publishes `update-beta.json`.

Both workflows should remain on the default branch so that the stable and beta
release actions remain available in GitHub Actions.

## Installation

Copy the complete `miuread.koplugin` directory from the release package into
KOReader's `plugins` directory, then fully restart KOReader.

## License and No-Sale Rule

MiuRead-owned code is distributed under the MiuRead Non-Commercial No-Sale
License 1.0. The original version and every modified, renamed, ported,
translated, merged, recompiled, or repackaged version must remain free and must
not be sold or commercially monetized.

Third-party material remains under its own license terms. See `LICENSE`,
`NOTICE`, `NON_COMMERCIAL_NOTICE.txt`, and `THIRD_PARTY_NOTICES`.
