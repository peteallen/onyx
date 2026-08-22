# Releasing Onyx

Onyx releases are ordinary drag-to-Applications disk images. The same local
scripts build both contributor previews and GitHub release artifacts, so CI does
not have a separate packaging implementation that can drift from local builds.

## Create and verify a local release

Requirements are macOS 15 or newer and Xcode 26 or newer.

```bash
scripts/release.sh 0.2.0
```

This builds a universal Apple Silicon + Intel release in an isolated staging
directory and creates:

- `dist-release/Onyx-0.2.0-macOS.dmg`
- `dist-release/Onyx-0.2.0-macOS.dmg.sha256`

The app is ad-hoc signed and the DMG is unsigned when no Developer ID identity
is configured. That is useful for local testing, but users will see the normal
Gatekeeper warning for an unidentified developer.

The release command checks the app signature, creates a compressed image with
an Applications shortcut, mounts it read-only, validates its bundle identity
and version, and verifies it again after the final move. It refuses to replace
an existing artifact unless `--overwrite` is explicit. Neither the release nor
verification scripts launch, install, or stop Onyx.

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
Gatekeeper assessment, and the normal mounted-image checks all pass.

## GitHub Actions

The `CI` workflow runs on pushes to `main`, pull requests, and manual requests.
It runs the unit suite, exercises app-packaging failure safeguards, then builds
and mounts an unsigned release DMG as an end-to-end packaging check.

The `Release` workflow supports two ways to cut a release:

1. Push a numeric version tag such as `v0.2.0`. A successful workflow creates
   or updates the matching GitHub Release and attaches the DMG and checksum,
   but only when Developer ID signing and notarization are fully configured.
2. Run **Actions → Release → Run workflow**. Enter `0.2.0`; leave **Publish
   release** off for an artifact-only dry run, or turn it on to create the tag
   and GitHub Release at the selected commit.

The tag route is two commands after the release commit is on `main`:

```bash
git tag -a v0.2.0 -m "Onyx 0.2.0"
git push origin v0.2.0
```

Each run also uploads the DMG and checksum as a downloadable workflow artifact.
Release versions must use three numeric components because macOS stores them in
`CFBundleShortVersionString`. GitHub's run number becomes `CFBundleVersion`.
Without Apple secrets, artifact-only workflow runs remain useful development
distributions. Publishing a GitHub Release fails closed until both signing and
notarization are configured; a pushed release tag is therefore not a shortcut
around the distribution trust requirements.

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
