# Releasing Onyx

Onyx releases are ordinary drag-to-Applications disk images. The same local
scripts build both contributor previews and GitHub release artifacts, so CI does
not have a separate packaging implementation that can drift from local builds.

## Create and verify a local release

Requirements are macOS 15 or newer and Xcode 26 or newer.

Restore the pinned Codex packages before a local build or release. This is a
one-time download per checkout; later runs verify and reuse the cached bytes:

```bash
scripts/fetch-codex-runtime.sh --architectures universal
```

```bash
scripts/release.sh 0.2.0
```

This builds a universal Apple Silicon + Intel release in an isolated staging
directory, embeds the pinned Codex app-server helper, and creates:

- `dist-release/Onyx-0.2.0-macOS.dmg`
- `dist-release/Onyx-0.2.0-macOS.dmg.sha256`

The app is ad-hoc signed and the DMG is unsigned when no Developer ID identity
is configured. That is useful for local testing, but users will see the normal
Gatekeeper warning for an unidentified developer.

The release command checks the app signature, verifies each bundled Codex
runtime package against its pinned archive hash and package manifest, creates a
compressed image with an Applications shortcut, mounts it read-only, validates
its exact top-level payload, bundle identity, and version, initializes the
mounted native Codex helper against a fresh private data folder, and verifies
the artifact again before publishing its matching DMG/checksum pair. If pair
publication fails, the previous pair is restored.
It refuses to replace an existing artifact unless `--overwrite` is explicit.
Neither the release nor verification scripts launch, install, or stop Onyx.
The packaged app must not depend on ChatGPT/Codex being installed separately.

At first launch the app creates only
`~/Library/Application Support/Onyx/Codex` and passes that path as
`CODEX_HOME`; it must never read or migrate `~/.codex`.

For a faster host-architecture-only local smoke test, pass
`--architectures native`. GitHub release artifacts always use the default
universal build.

To verify a downloaded artifact independently:

```bash
(cd dist-release && /usr/bin/shasum -a 256 -c Onyx-0.2.0-macOS.dmg.sha256)
scripts/verify-dmg.sh dist-release/Onyx-0.2.0-macOS.dmg \
  --app-name Onyx.app \
  --bundle-id app.onyx.agent \
  --version 0.2.0 \
  --require-universal
```

## Developer ID signing and notarization

Export a **Developer ID Application** certificate and private key as a `.p12`,
then use its exact Keychain identity when building:

```bash
ONYX_CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
scripts/release.sh 0.2.0
```

That enables the hardened runtime and timestamps both the app and the disk
image. For notarization, first store credentials in the login Keychain; the
command prompts for the app-specific password rather than placing it in shell
history:

```bash
xcrun notarytool store-credentials onyx-notary \
  --apple-id developer@example.com \
  --team-id TEAMID

ONYX_CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
ONYX_NOTARIZE=1 \
ONYX_NOTARY_PROFILE=onyx-notary \
scripts/release.sh 0.2.0
```

`create-dmg.sh` also supports App Store Connect API-key credentials and direct
Apple ID environment variables. See `scripts/create-dmg.sh --help` for their
names. A notarized build is not moved into place until `notarytool`, stapling,
Gatekeeper assessment of both the image and its mounted app, and the normal
mounted-image checks all pass.

## GitHub Actions

The `CI` workflow runs on pushes to `main`, pull requests, and manual requests.
It runs the unit suite, exercises app-packaging failure safeguards, then builds
and mounts an unsigned release DMG as an end-to-end packaging check.

The `Release` workflow is currently artifact-only. Run **Actions → Release →
Run workflow**, enter `0.2.0`, and it uploads the verified DMG and checksum as a
downloadable workflow artifact. It has read-only repository permissions, no
tag trigger, and no GitHub Release publication step.

Release versions must use three numeric components because macOS stores them in
`CFBundleShortVersionString`. GitHub's run number becomes `CFBundleVersion`.
Without Apple secrets, artifact-only workflow runs remain useful development
distributions.

Do not add tag-triggered or manual GitHub Release publication until the runtime
verification checklist below has passed on the release candidate, including
clean-machine OAuth and cross-app mutation isolation. Re-enabling publication
is a separate reviewed change, not a workflow input.

### Optional repository secrets

The release workflow succeeds without secrets. Configure all values in a group
to activate that stage; partial groups fail early instead of silently producing
a differently signed artifact. Add them under **Settings → Secrets and
variables → Actions** in the GitHub repository.

| Secret | Purpose |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_DEVELOPER_ID_APPLICATION` | Exact certificate identity shown by Keychain Access |
| `APPLE_NOTARY_APPLE_ID` | Apple developer account email |
| `APPLE_NOTARY_TEAM_ID` | Apple Developer team identifier |
| `APPLE_NOTARY_PASSWORD` | App-specific password for `notarytool` |

The first three secrets enable Developer ID signing. The last three additionally
enable notarization and require the signing group. The workflow imports the
certificate into a temporary, unlocked keychain, removes the `.p12` immediately
after import, and deletes the keychain at the end of the job.

To copy a `.p12` as base64 on macOS without creating another file:

```bash
/usr/bin/base64 -i DeveloperIDApplication.p12 | /usr/bin/pbcopy
```

Paste the clipboard contents into `APPLE_DEVELOPER_ID_P12_BASE64`.

## Bundled Codex runtime contract

The helper is part of a pinned, release-owned Codex package rather than a
machine-local dependency. Packaging accepts one architecture-specific package
per target, validates its archive hash and manifest, and preserves the complete
runtime tree under `Contents/Helpers/CodexRuntime/<platform>/`, including the
app-server, code-mode host, packaged `rg`, shell resources, and package
metadata. It fails closed when any required file, executable bit, hash, or
manifest entry does not match. The same packages must be present in preview and
release bundles.

Run `scripts/fetch-codex-runtime.sh --architectures universal` to populate the
default ignored cache at `.artifacts/codex-runtime`. Packaging never downloads.
For a different local cache set `ONYX_CODEX_RUNTIME_CACHE_DIR`; automation may
instead pass exact archive paths through `ONYX_CODEX_RUNTIME_ARCHIVE_ARM64` and
`ONYX_CODEX_RUNTIME_ARCHIVE_X86_64`. Every input is still checked against the
checked-in v0.149.0 size, SHA-256, layout, metadata, and architecture.

Runtime verification must prove all of the following before publication:

- the app-server reports the exact Onyx `CODEX_HOME` during initialization;
- a clean Onyx home starts signed out even when official Codex is signed in;
- Onyx-created tasks do not appear in official Codex, and official tasks do
  not appear in Onyx;
- rename, archive, delete, sign-out, and relaunch operations stay within the
  owning app; and
- a clean Mac with no ChatGPT/Codex installation can authenticate and run the
  bundled helper.

`ONYX_CODEX_PATH` and installed-runtime discovery are test/development-only
escape hatches. They must never be used by a production composition or
silently replace a missing bundled helper.
