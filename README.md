# Onyx

This repository is public for reference and experimentation. It is currently
all rights reserved; no license is granted to copy, modify, or redistribute
the source unless the copyright holder gives written permission.

Onyx is a native macOS agent workspace inspired by the interaction model of the
Codex desktop app. It keeps the familiar project, task, transcript, approval,
diff, and terminal workflow while giving the interface a faster native render
path and a distinct polished-stone visual language.

Onyx is an independent, unofficial project. It is not affiliated with,
endorsed by, or sponsored by OpenAI.

> **Download Onyx 0.1.0:** [universal macOS DMG](https://github.com/peteallen/onyx/releases/download/v0.1.0/Onyx-0.1.0-macOS.dmg) · [SHA-256 checksum](https://github.com/peteallen/onyx/releases/download/v0.1.0/Onyx-0.1.0-macOS.dmg.sha256) · [release notes](https://github.com/peteallen/onyx/releases/tag/v0.1.0)

OpenAI Codex through the bundled `codex app-server` remains the default runtime. Saved
OpenAI-compatible connections are also available in the production workspace:
the new-task picker shows frequent and recent models first, then every cached
model grouped by provider, and switches provider plus model in one action.
Bearer credentials stay in Keychain, `/models` metadata drives capability-aware
controls, and provider-owned conversations stream into a local store. Existing
tasks stay bound to the provider that created them; their original model remains
the default, while later turns can use another model from that same provider.
Claude/Anthropic remains a future adapter. See
[docs/PROVIDER_EXTENSIBILITY.md](docs/PROVIDER_EXTENSIBILITY.md) for the exact
boundary.

The sidebar groups tasks under an app-owned project catalog with add, rename,
reorder, and metadata-only removal. The three workspace panes are resizable,
tool activity is collapsed by default, collaboration agents are navigable, and
Codex tasks can open an isolated ephemeral side chat without changing durable
task history.

Within the Codex path, the Git inspector supports per-file stage, unstage, and
confirmed recoverable discard; the Files inspector and global Command-P palette
share project-local search and bounded numbered text previews; and explicit
HTTP(S) links returned
by MCP, dynamic-tool, and web-search results render as native cards. These are
deliberately scoped slices: there are no inline diff comments, syntax navigation,
or complete rich-result/approval taxonomy yet.

## Build and run the current development preview

Requirements: macOS 15 or newer and Xcode 26 or newer.

The first time you build from a fresh checkout, restore the pinned official
Codex app-server packages (one per architecture). The archives are cached
under `.artifacts/` and are hash-checked before every package:

```bash
scripts/fetch-codex-runtime.sh --architectures universal
```

```bash
swift build
```

That command builds without launching a second unbundled copy of Onyx. Do not
use `swift run Onyx` for UI development: it bypasses the stable preview identity
and can run beside the packaged app with different macOS permissions and saved
window state.

To package without launching, always reuse the stable path, display name, and
bundle identifier:

```bash
scripts/package-preview.sh
```

To package, replace, and launch that same preview identity in one step, use:

```bash
scripts/run-preview.sh
```

This is the only supported development launch path.

Before opening the rebuilt bundle, the launcher unregisters repo-local legacy
Onyx identities and force-registers the canonical preview. This keeps Finder,
automation targeting, and macOS privacy grants from drifting back to an older
renamed build; it does not delete those bundles or reset LaunchServices.

This always replaces `dist-preview/Onyx Preview.app` with bundle ID
`app.onyx.preview`; it never invents a timestamped app identity. If that exact
preview is running, quit it first or pass `--stop-running`. That option resolves
the process from the existing preview executable, sends only that process a
graceful termination signal, and refuses to force-kill anything. The preview
owns its stdio `codex app-server`, so that child exits through the app's normal
shutdown/process-pipe lifecycle; the script never searches for or kills a
machine-wide `codex app-server`.

Packaging is staged and verified beside the destination before it replaces an
existing bundle atomically. If that exact destination is currently running,
the general package command refuses to overwrite it. Its explicit
`--allow-running-overwrite` escape hatch only replaces files; it never quits or
relaunches a process.

Ad-hoc signatures have a code-hash identity that changes on every build. To keep
privacy and automation approvals stable, this checkout pins the certificate
already associated with the canonical preview. Override that SHA-1 fingerprint
only when moving the checkout to another machine or deliberately rotating the
preview certificate:

```bash
ONYX_PREVIEW_CODESIGN_IDENTITY='CERTIFICATE_SHA1' \
scripts/package-preview.sh --stop-running
```

An Apple Development or local identity is development-only and is not a
substitute for Developer ID distribution signing or notarization. A machine
without a valid identity now fails closed so it cannot silently produce a
preview whose permissions reset on every rebuild. Set
`ONYX_PREVIEW_CODESIGN_IDENTITY=-` only when an explicitly ad-hoc preview is
acceptable. For an explicitly certificate-pinned identity, set
`ONYX_PREVIEW_CODESIGN_REQUIREMENT` to a requirement body such as
`identifier "app.onyx.preview" and anchor trusted and certificate leaf =
H"CERTIFICATE_SHA1"`. `scripts/package-app.sh --help` exposes the same advanced
override for other package destinations.

If this checkout has already created older preview/development bundles,
LaunchServices may retain their old registrations. The repair helper unregisters
only repo-local legacy Onyx IDs (including timestamped previews), then registers
the stable bundle:

```bash
scripts/repair-preview-registration.sh
```

The helper never uses the destructive `lsregister -delete` database reset. Its
default mode is limited to this checkout; its optional `--gc` mode is broader
and is available only when deleted old paths still appear in Finder.

## Releases

### Download the current build

The current universal macOS build is published on the public
[Onyx Releases page](https://github.com/peteallen/onyx/releases/latest). Download
the `.dmg` and its matching `.dmg.sha256` checksum from the latest release.
These public builds are ad-hoc signed development distributions, so macOS may
show an unidentified-developer warning until Developer ID signing and
notarization are added.

Create a fully verified local DMG with one command:

```bash
scripts/release.sh 0.1.0
```

This produces a universal Apple Silicon + Intel disk image and SHA-256 checksum
under `dist-release/`. It works without Apple credentials for local testing,
while Developer ID signing and notarization activate when their optional
credentials are configured.

GitHub Actions runs the full test and packaging path for every pull request. The
Release workflow builds the same verified universal DMG, then publishes the DMG
and checksum as a public semver release from the current `main` SHA
or its matching `vX.Y.Z` tag. It deliberately receives no Apple signing or
notarization secrets; the release notes identify the build as ad-hoc and
unnotarized. Developer ID signing and notarization remain a future distribution
upgrade, not a prerequisite for finding the current development build.
See [docs/RELEASING.md](docs/RELEASING.md) for the exact commands, safeguards,
and release safeguards.

Production resolves only the pinned Codex package inside the Onyx app bundle.
An explicit development/live-test API may use `ONYX_CODEX_PATH`, an installed
ChatGPT/Codex app, or Homebrew; none of those paths can become a production
fallback.

The live runtime is deliberately read through the documented app-server
JSON-RPC surface. Release and preview bundles carry a pinned helper at
`Onyx.app/Contents/Helpers/CodexRuntime/<platform>/bin/codex-app-server`;
production does not search for or depend on an installed ChatGPT/Codex app.
Onyx launches it with
`CODEX_HOME=~/Library/Application Support/Onyx/Codex`, so tasks, auth files,
SQLite state, rollouts, skills, memories, and MCP configuration are owned by
Onyx and never mixed with `~/.codex`. Onyx does not copy existing Codex
credentials or history. The installed runtime remains available only to the
explicit development/live-test path (`CodexRuntime.makeDevelopmentInstalled`)
and `ONYX_CODEX_PATH`; those are not production fallbacks.

## Verify

```bash
swift test
swift build
scripts/check-package-app.sh
```

The unit suite includes simulated app-server exit, malformed-transport,
reconnect, and future-field compatibility fixtures. The opt-in tests exercise
the development-installed Codex runtime and its separate Onyx-owned home; they
need normal access to that opt-in test state:

```bash
ONYX_LIVE_CODEX_TEST=1 swift test --disable-sandbox --filter CodexRuntimeLiveTests
ONYX_LIVE_CODEX_IMAGE_TEST=1 swift test --disable-sandbox --filter CodexRuntimeImageLiveTests
```

The image test generates a temporary PNG, sends it as a local image input, and
checks the streamed answer. Neither live test copies credentials into Onyx.

The OpenAI-compatible live test is also opt-in and deliberately takes its
endpoint and model from the environment, so a checkout never contains a local
LAN address:

```bash
ONYX_LIVE_OPENAI_COMPATIBLE_TEST=1 \
ONYX_LIVE_OPENAI_COMPATIBLE_URL="http://127.0.0.1:8002/v1" \
ONYX_LIVE_OPENAI_COMPATIBLE_MODEL="your-model-id" \
swift test --disable-sandbox --filter OpenAICompatibleRuntimeTests/testLiveModelDiscoveryAndStreamingIsOptIn
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the provider boundary and
[docs/PRODUCT_PARITY.md](docs/PRODUCT_PARITY.md) for the completion ledger.
