# Releasing Agent Monitor

This guide is for maintainers publishing an update. For local builds and tests, see [Contributing](../CONTRIBUTING.md).

[← Project overview](../README.md)

## Before tagging

- Commit and push the intended changes.
- Run the relevant Swift and Python checks and live integration checks described in the contributor guide.
- Choose an unused version after reviewing the existing tags and [published releases](https://github.com/seschulz/agent-monitor/releases).
- Confirm that the repository's `SPARKLE_PRIVATE_KEY` Actions secret is available to the release workflow.

## Publish a version

Create an annotated version tag on the commit you intend to release, then push that tag. Replace `vX.Y.Z` below with the chosen version:

```sh
git tag -a vX.Y.Z -m "Agent Monitor vX.Y.Z"
git push origin vX.Y.Z
```

A `v*` tag triggers [Build macOS release](../.github/workflows/release.yml). The workflow:

1. Builds a universal macOS Release app.
2. Writes the tag's version into `CFBundleShortVersionString` and `CFBundleVersion`.
3. Applies an ad-hoc signature and verifies the bundle.
4. Packages a drag-to-Applications DMG.
5. Generates a Sparkle appcast and signs the update using Ed25519.
6. Publishes the GitHub Release with generated notes, the DMG, appcast, and SHA-256 checksum files.

Wait for the workflow to succeed and verify that the release includes all four assets:

```text
Agent-Monitor-X.Y.Z.dmg
Agent-Monitor-X.Y.Z.dmg.sha256
appcast.xml
appcast.xml.sha256
```

The app's update feed points to the latest release's `appcast.xml`. Re-running the workflow for an existing tag replaces that release's attached files, so treat reruns as changes to a published distribution.

## Build an artifact without publishing

Run the workflow manually from the GitHub **Actions** tab on a branch. A branch-based manual run creates a downloadable workflow artifact with a `0.0.<run number>` version and does not publish a GitHub Release. A run against a tag follows the tag release path.

## Keep update signing consistent

Existing installations trust the public Ed25519 key embedded in the app's `Info.plist`. Preserve the matching private key and maintain a secure backup. Don't commit the key or casually regenerate it: changing the signing identity can break updates for existing users.

The workflow loads the private key from the encrypted `SPARKLE_PRIVATE_KEY` repository secret. It does not store the key in the repository.

## Apple signing and notarization

Current releases are ad-hoc signed and are not Apple-notarized. Public distribution without the first-launch Gatekeeper warning requires a Developer ID Application certificate and Apple notarization. A future notarized workflow should load those credentials from encrypted GitHub Actions secrets.
