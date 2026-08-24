# Releasing Onyx

Onyx releases are ordinary drag-to-Applications disk images. The same local
scripts build both contributor previews and GitHub release artifacts, so CI does
not have a separate packaging implementation that can drift from local builds.

## Publish the current public release

The normal download is always the public
[latest GitHub Release](https://github.com/peteallen/onyx/releases/latest). It
contains the universal DMG and its matching `.dmg.sha256` checksum as direct,
non-expiring release assets.

There are two supported ways to cut a release:

1. **Actions → Release → Run workflow:** choose the `main` branch and enter the
   three-part version from `support/Info.plist` (for example, `0.1.0`). The
   workflow verifies that the selected commit is still the current `main` head,
   runs the complete test/package path, and creates `v0.1.0` at that exact SHA.
2. **Push a semver tag:** after the same checks have passed locally, push a new
   tag such as `v0.1.0`. The tag-triggered path verifies that the tag points at
   the event commit before publishing.

The workflow refuses to move an existing tag or replace a mismatched release. A
retry for an exact same-SHA tag/release is safe: it rechecks the immutable tag,
reuses the already-published release only when its source-commit note, public
state, exact DMG/checksum pair, server digests, and downloaded checksum all
match. The retry verifies the existing published bytes rather than comparing
them with a newly rebuilt DMG (GitHub's run number and disk-image metadata can
legitimately differ between runs), and fails closed for a draft, prerelease,
wrong target, wrong source note, or wrong asset set. Manual tag creation happens
after the verified build through the GitHub ref API, so a concurrent creator
cannot silently retarget the release.
It publishes only after the checksum and mounted DMG checks pass, and verifies
the public release is non-draft, non-prerelease, marked latest, and contains
exactly the expected DMG/checksum pair. The notes include the exact source
commit.
Public builds are ad-hoc signed and not notarized development distributions, so
macOS may show an unidentified-developer warning.

## Create and verify a local release

Requirements are macOS 15 or newer and Xcode 26 or newer.

Restore the pinned Codex packages before a local build or release. This is a
one-time download per checkout; later runs verify and reuse the cached bytes:

```bash
scripts/fetch-codex-runtime.sh --architectures universal
```

```bash
scripts/release.sh 0.1.0
```

This builds a universal Apple Silicon + Intel release in an isolated staging
directory, embeds the pinned Codex app-server helper, and creates:

- `dist-release/Onyx-0.1.0-macOS.dmg`
- `dist-release/Onyx-0.1.0-macOS.dmg.sha256`

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

`release.sh` accepts `--signing-identity -` and `--no-notarize` to force the
development/ad-hoc path. CI passes both flags explicitly, so a runner's
`ONYX_CODESIGN_IDENTITY` or `ONYX_NOTARIZE` environment cannot silently turn a
workflow artifact into a differently signed or notarized build. Local reviewed
release commands may instead omit those flags and opt into Developer ID signing.

At first launch the app creates only
`~/Library/Application Support/Onyx/Codex` and passes that path as
`CODEX_HOME`; it must never read or migrate `~/.codex`.

For a faster host-architecture-only local smoke test, pass
`--architectures native`. GitHub release artifacts always use the default
universal build.

To verify a downloaded artifact independently:

```bash
(cd dist-release && /usr/bin/shasum -a 256 -c Onyx-0.1.0-macOS.dmg.sha256)
scripts/verify-dmg.sh dist-release/Onyx-0.1.0-macOS.dmg \
  --app-name Onyx.app \
  --bundle-id app.onyx.agent \
  --version 0.1.0 \
  --require-universal
```

That independent check mounts and inspects the image but does not execute its
helper. Add `--probe-runtime` only for an artifact built from a checkout you
trust; local packaging uses that opt-in to prove the bundled helper initializes
from its final mounted location.

## Developer ID signing and notarization

Export a **Developer ID Application** certificate and private key as a `.p12`,
then use its exact Keychain identity when building:

```bash
ONYX_CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
scripts/release.sh 0.1.0
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
scripts/release.sh 0.1.0
```

`create-dmg.sh` also supports App Store Connect API-key credentials and direct
Apple ID environment variables. See `scripts/create-dmg.sh --help` for their
names. A notarized build is not moved into place until `notarytool`, stapling,
Gatekeeper assessment of both the image and its mounted app, and the normal
mounted-image checks all pass.

Use these local signing paths only from a reviewed checkout. The public GitHub
workflow intentionally cannot access a Developer ID private key or notarization
credential; adding those secrets would change the trust boundary and requires a
separate protected release design.

## GitHub Actions

The `CI` workflow runs on pushes to `main`, pull requests, and manual requests.
It runs the unit suite, exercises app-packaging failure safeguards, then builds
and mounts an unsigned release DMG as an end-to-end packaging check.

The `Release` workflow accepts a semver tag push or a manual dispatch from the
current `main` head. It builds the same verified universal DMG as the local
script, then publishes the DMG and checksum directly as a public GitHub Release.
It has no Apple secrets and pins the Onyx display name, bundle ID, universal
architecture, ad-hoc identity, and no-notarize mode on the command line.

Release versions must use three numeric components because macOS stores them in
`CFBundleShortVersionString`. GitHub's run number becomes `CFBundleVersion`.
These ad-hoc releases are useful development distributions. A future Developer
ID/notarized workflow remains a separate hardening project.

`scripts/check-release-automation.sh` enforces the public-release contract in
both CI and the Release workflow. It checks immutable action pins, exact source
and tag targeting, universal pinned-runtime packaging, direct DMG/checksum
assets, non-draft postconditions, and the no-launch contract. Changing the
publication policy therefore requires changing a visible, executable gate
together with the workflow and this document.

### Automated Developer ID release gate

The selectable GitHub `Release` workflow intentionally receives no Apple
credentials. It publishes only after checking an exact `main` SHA or semver tag,
and the resulting release is clearly labeled ad-hoc and unnotarized. A future
signed automation path must use a protected environment and immutable trusted
source, keep the pinned runtime manifest inside that trust boundary, and make
signing the final isolated stage after build verification. Until then, Developer
ID signing and notarization are local, reviewed-checkout operations only.

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
