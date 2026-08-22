# Onyx

This repository is public for reference and experimentation. It is currently
all rights reserved; no license is granted to copy, modify, or redistribute
the source unless the copyright holder gives written permission.

Onyx is a native macOS agent workspace inspired by the interaction model of the
Codex desktop app. It keeps the familiar project, task, transcript, approval,
diff, and terminal workflow while giving the interface a faster native render
path and a distinct polished-stone visual language.

The default production workspace still starts one provider/runtime path: OpenAI
Codex through `codex app-server`. A Codex-only registry resolves that default
connection, and the native UI consumes the provider-neutral `AgentRuntime`
boundary.

The repository also contains a tested OpenAI-compatible runtime slice: provider
connections can be added and edited in Settings, bearer credentials are stored
through Keychain, `/models` discovery is supported, and conversations stream
into a provider-owned local store. Those saved connections are not yet wired
into the production workspace selector, and Claude/Anthropic remains a future
adapter. See [docs/PROVIDER_EXTENSIBILITY.md](docs/PROVIDER_EXTENSIBILITY.md)
for the exact boundary.

Within the Codex path, the Git inspector supports per-file stage, unstage, and
confirmed recoverable discard; the Files inspector supports project-local
search and bounded numbered text previews; and explicit HTTP(S) links returned
by MCP, dynamic-tool, and web-search results render as native cards. These are
deliberately scoped slices: there are no inline diff comments, global Command-P
or syntax navigation, or complete rich-result/approval taxonomy yet.

## Run the current development build

Requirements: macOS 15 or newer and Xcode 26 or newer.

```bash
swift run Onyx
```

To build, package, ad-hoc sign, and verify the native development application:

```bash
scripts/package-app.sh debug
```

That creates `dist/Onyx.app` and includes the custom Onyx app icon. The packaging
command does not launch or stop the app. To make an isolated preview build that
can live beside the default build, give it a different destination, display
name, and bundle ID:

```bash
scripts/package-app.sh debug "dist-check/Onyx Preview.app" \
  --display-name "Onyx Preview" \
  --bundle-id app.onyx.preview
```

The display name and bundle ID can also be supplied through
`ONYX_APP_DISPLAY_NAME` and `ONYX_BUNDLE_IDENTIFIER`. Run
`scripts/package-app.sh --help` for version/build-number options. The separate
destination prevents overwriting the default bundle, the display name makes the
preview recognizable in macOS, and the bundle ID gives it an independent app
identity.

Packaging is staged and verified beside the destination before it replaces an
existing bundle. If that exact destination is currently running, the command
refuses to overwrite it. Prefer a different destination for test builds. The
explicit `--allow-running-overwrite` escape hatch only replaces the files; it
never quits or relaunches the running process.

## Releases

Create a fully verified local DMG with one command:

```bash
scripts/release.sh 0.2.0
```

This produces a universal Apple Silicon + Intel disk image and SHA-256 checksum
under `dist-release/`. It works without Apple credentials for local testing,
while Developer ID signing and notarization activate when their optional
credentials are configured.

GitHub Actions runs the full test and packaging path for every pull request. A
tag such as `v0.2.0` publishes a downloadable DMG to GitHub Releases; the manual
Release workflow can also make an artifact-only dry run or publish a release at
the selected commit. See [docs/RELEASING.md](docs/RELEASING.md) for the exact
commands, safeguards, and optional repository secrets.

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
