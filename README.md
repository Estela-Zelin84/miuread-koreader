# MiuRead · WeRead Assistant

A WeRead plugin for KOReader, supporting Kindle, Kobo, Android, and other KOReader devices.

## Current Release

This repository contains the beta `4.1.0-beta.1` source and is intended for the `beta` branch.

See `CHANGELOG-4.1.0-beta.1.txt` for the release notes.

## Branches and Releases

- `main`: stable source, released through `.github/workflows/release.yml`; publishes `update.json`.
- `beta`: beta source, released through `.github/workflows/release-beta.yml`; publishes `update-beta.json`.

Both workflows should remain on the default branch so that the stable and beta release actions remain available in GitHub Actions.

## Installation

Copy the complete `miuread.koplugin` directory from the release package into KOReader's `plugins` directory, then fully restart KOReader.

## Origin and License

MiuRead originated as a modified version of `finlater/weread.koplugin` v0.1.1 and has since undergone substantial restructuring, modification, and extension.

Copyright in code originating from the upstream project remains with its original copyright holders. Copyright in later additions and modifications belongs to the respective MiuRead contributors.

This project is distributed under the GNU Affero General Public License version 3 only (`AGPL-3.0-only`). Anyone who modifies, combines, or redistributes this project must preserve the applicable copyright, attribution, modification, and license notices and provide the corresponding source code as required by the license.

See `LICENSE` and `NOTICE` for details.
