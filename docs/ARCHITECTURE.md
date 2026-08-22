# Onyx architecture

## Product boundary

Onyx is the desktop product. Agent runtimes are replaceable integrations.

The production runtime paths today are:

```text
Native SwiftUI/AppKit presentation
                |
 per-window OnyxAppModel + provider-neutral models
                |
 app-lifetime provider-scoped SharedRuntimeCoordinator
                |
        AgentRuntime protocol
          /                 \
 CodexRuntime        OpenAICompatibleRuntime
      |                       |
codex app-server       /models + /chat/completions
 (stdio JSONL)              (HTTP/SSE)
```

The registry resolves the default Codex connection. The composition host also
resolves each app-owned OpenAI-compatible connection and keeps its runtime,
tasks, drafts, and model identity provider-scoped.

The OpenAI-compatible path includes a URL-validated, redirect-protected HTTP/SSE
transport, Keychain-backed bearer lookup, `/models` discovery, capability
negotiation, a provider-owned conversation store, and production model
selection. Remote endpoints do not provide Codex's local tools, approvals,
sandbox, or durable task lifecycle, so those controls are advertised as
unavailable. Claude/Anthropic remains descriptor-only. See
`PROVIDER_EXTENSIBILITY.md` for the exact boundary.

In the current implementation, the application owns:

- the project/task sidebar, transcript projection, search, and UI state;
- provider-neutral request, event, transcript, and capability models;
- provider connection Settings, safe endpoint validation, model discovery, and
  Keychain-only bearer credential persistence;
- capability-aware controls for the selected provider and model;
- the Codex registry plus app-owned OpenAI-compatible connections and
  connection-scoped model identities;
- performance budgets and local presentation caches.

Each runtime owns only its provider-specific execution behavior. For Codex,
that includes ChatGPT authentication, persisted Codex threads, tools,
approvals, sandboxing, compaction, and streamed events.

Provider identity is threaded through window restoration, task selection,
draft preferences, local provider conversations, and model usage ranking.
Existing tasks are immutable with respect to provider/model switching; the
unified picker is active only while composing a new task.

A versioned conversation catalog exists as a tested foundation but is not yet
wired into production task discovery. The shared-runtime coordinator is wired
into production composition: the app resolves Codex once, broadcasts every
runtime event to each window, coalesces connection/account handshakes, and
prevents sibling-window account operations from crossing an in-flight
sign-out.
Every restored scene owns a distinct `OnyxAppModel`, terminal session, focused
command context, frame identity, task selection, draft/workspace state, and
panel preferences. Pins use one app-lifetime observable store so sibling
windows update without overwriting one another. Legacy single-window state
migrates once into the first restored workspace, and sign-out clears
account-owned selected-task, draft, and workspace preferences from known
window namespaces, including windows that are currently closed.
Cross-provider continuation and a native Anthropic runtime remain incomplete.

## Why app-server stays behind an adapter

`codex app-server` is OpenAI's rich-client integration surface, but its release
cadence must not become Onyx's internal architecture. The `CodexRuntime` actor
is the sole translation boundary between JSON-RPC payloads and Onyx models.
No view stores or interprets an app-server payload.

Onyx uses Codex-managed ChatGPT authentication. The app-server owns the OAuth
ceremony, token persistence, and refresh; Onyx never receives or copies those
tokens. There is no direct-key credential path today. Any such implementation
must use an app-owned Keychain credential handle rather than UserDefaults,
process arguments, logs, or transcript state.

Development currently uses the installed Codex binary. Distribution will pin
and bundle a known-compatible version, archive its generated schema, and run
recorded protocol fixtures before upgrades.

Fixture tests currently prove that an unexpected process exit fails in-flight
requests, a malformed JSONL record closes the affected transport, and a new
connection generation can start afterward. Forward-compatible fields and
unknown notifications remain inspectable or safely ignored, while a malformed
response that has neither a result nor an error is rejected. These tests make
failure and reconnect behavior deterministic; they are not a compatibility
promise for arbitrary future app-server releases, which is why pinning remains
part of the distribution plan.

## Runtime protocol boundary

- Implemented controls use advertised runtime capabilities where available.
  Provider connection management is implemented in Settings, and the
  production new-task picker spans Codex plus saved OpenAI-compatible models.
- Threads, turns, common transcript items, approvals, plans, and collaboration
  activity use provider-neutral models. Usage and the remaining rich item
  taxonomy do not yet have complete product surfaces.
- Explicit HTTP(S) resource links returned by MCP, dynamic-tool, and web-search
  results project into provider-neutral, bounded native link cards. This is a
  narrow rich-result slice, not coverage for the remaining item taxonomy or
  every approval and permission-amendment variant.
- Raw provider payloads may be retained for diagnostics, never required by UI.
- Unknown transcript item types degrade to inspectable cards instead of
  crashing decoding; unknown notifications are currently ignored.
- Credentials stay in the provider's supported credential store.
- A failed provider process cannot own or block the main actor.

## Outbound image input

Outbound images are implemented across the current UI and Codex adapter. The
composer accepts file-picker and paste input, validates format, byte count, and
dimensions, keeps image drafts session-only, shows removable previews, and
supports image-only or text-plus-image messages. Ordered `RuntimeTurnInput`
values map to Codex `localImage` or `image` payloads for both `turn/start` and
`turn/steer`.

Automated coverage exercises validation, image-only draft/send behavior,
failure restoration, capability gating, and Codex request encoding. An opt-in
live test also generates a temporary PNG, sends it through the installed
`codex app-server`, and verifies the code read from the image in the streamed
assistant response. That proves the current installed Codex path end to end;
it does not replace broader format, model, or release-compatibility testing.

## Git inspector boundary

`GitRepositoryReader` runs explicit `git -C` commands without a shell and reads
branch/status plus staged and unstaged patches; untracked text files receive
bounded add-only previews. The inspector shows
branch tracking, staged/unstaged/untracked counts, staged and unstaged scopes,
selectable files, hunks, old/new line numbers, rename and binary metadata, and
explicit no-project, loading, clean, not-repository, and failure states.

Both command output and UI rendering are bounded, with truncation notices for
hidden files, lines, and metadata. Per-file controls can stage or unstage the
entire selected file. A confirmed discard moves existing working-copy bytes to
the macOS Trash before restoring the staged or committed version; an untracked
file is moved directly to the Trash. Mutations re-read status, use literal
pathspecs plus an explicit `--`, and are unavailable for conflicts. There are
no hunk-level actions or inline diff comments.

## Files inspector source preview

The Files inspector has a project-local quick-open field and a numbered,
selectable text preview. Indexing, search results, file size, preview bytes,
line count, directory depth, and visited entries are bounded. Heavy dependency
folders and directory symlinks are skipped, and canonical path validation
prevents a preview from escaping the selected workspace.

This is an inspector-local navigation surface. It does not provide a global
Command-P palette, syntax highlighting, symbol search, go-to-definition, or
other code navigation.

## UI performance mechanisms and targets

Implemented mechanisms:

- Streamed text is coalesced before publishing view updates.
- Transcript rows have stable identities, lazy rendering, incremental updates,
  and cached measured heights.
- JSONL framing scans newly appended bytes instead of rescanning the accumulated
  buffer.

Targets that are not yet full product guarantees:

- Keep parsing, process I/O, syntax work, and database writes off the main actor.
- Page or incrementally project large histories instead of eagerly transforming
  every stored turn.
- UI interactions should remain below one display frame where practical;
  operations exceeding 50 ms on the main actor are defects.
