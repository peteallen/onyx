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

OpenAI Codex through `codex app-server` remains the default runtime. Saved
OpenAI-compatible connections are also available in the production workspace:
the new-task picker shows frequent and recent models first, then every cached
model grouped by provider, and switches provider plus model in one action.
Bearer credentials stay in Keychain, `/models` metadata drives capability-aware
controls, and provider-owned conversations stream into a local store. Existing
tasks remain pinned to the provider and model that created them. Claude/
Anthropic remains a future adapter. See
[docs/PROVIDER_EXTENSIBILITY.md](docs/PROVIDER_EXTENSIBILITY.md) for the exact
boundary.

The sidebar groups tasks under an app-owned project catalog with add, rename,
reorder, and metadata-only removal. The three workspace panes are resizable,
tool activity is collapsed by default, collaboration agents are navigable, and
Codex tasks can open an isolated ephemeral side chat without changing durable
task history.

Within the Codex path, the Git inspector supports per-file stage, unstage, and
confirmed recoverable discard; the Files inspector supports project-local
search and bounded numbered text previews; and explicit HTTP(S) links returned
by MCP, dynamic-tool, and web-search results render as native cards. These are
deliberately scoped slices: there are no inline diff comments, global Command-P
or syntax navigation, or complete rich-result/approval taxonomy yet.

## Build and run the current development preview

Requirements: macOS 15 or newer and Xcode 26 or newer.

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

Create a fully verified local DMG with one command:

```bash
scripts/release.sh 0.2.0
```

This produces a universal Apple Silicon + Intel disk image and SHA-256 checksum
under `dist-release/`. It works without Apple credentials for local testing,
while Developer ID signing and notarization activate when their optional
credentials are configured.

GitHub Actions runs the full test and packaging path for every pull request. The
manual Release workflow can make an artifact-only development build at any
selected commit. Publishing a tag or GitHub Release fails closed until
Developer ID signing and notarization are configured. See
[docs/RELEASING.md](docs/RELEASING.md) for the exact commands, safeguards, and
required publication secrets.

Onyx resolves Codex in this order:

1. `ONYX_CODEX_PATH`
2. The binary bundled with `/Applications/ChatGPT.app`
3. Homebrew paths on Apple Silicon and Intel

The live runtime is deliberately read through the documented app-server
JSON-RPC surface. This keeps Codex's durable threads, approvals, tools,
sandbox, and ChatGPT OAuth behavior intact, and no authentication token is
copied into Onyx. The installed binary is suitable for development, but it is
still a versioned subprocess dependency: a production release must pin and
bundle a known-compatible Codex build rather than assuming every installed
version is compatible.

## Verify

```bash
swift test
swift build
scripts/check-package-app.sh
```

The unit suite includes simulated app-server exit, malformed-transport,
reconnect, and future-field compatibility fixtures. Two opt-in tests exercise
the installed Codex runtime and existing Codex-managed login; they need normal
access to that existing state:

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
