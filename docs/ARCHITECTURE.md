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
 CodexRuntime     OpenAICompatibleAdaptiveRuntime
      |               /                      \
codex app-server  plain chat fallback     agent lane
 (stdio JSONL)    /chat/completions       codex app-server
                                             |
                                    Onyx loopback proxy
                                             |
                               compatible Responses provider
```

The registry resolves the default Codex connection. The composition host also
resolves each app-owned OpenAI-compatible connection and keeps its runtime,
tasks, drafts, and model identity provider-scoped.

The implemented OpenAI-compatible path includes a URL-validated,
redirect-protected HTTP/SSE transport, Keychain-backed bearer lookup, `/models`
discovery, capability negotiation, a provider-owned conversation store, and
production model selection. Its plain chat lane does not advertise local
tools. The adaptive production path routes models that advertise
tool/function-call support—or sparse models that pass a bounded Responses/tool
compatibility probe—through the pinned app-server as a thread-scoped custom
model provider. An Onyx-owned loopback proxy injects the
Keychain credential upstream so neither app-server configuration nor its
environment contains the third-party secret. Claude/Anthropic remains
descriptor-only. See `PROVIDER_EXTENSIBILITY.md` for the exact boundary.

Catalog and history projection never wait for provider network probing. For a
metadata-poor selected model, Onyx starts only one bounded check in the
background; if a new task is created while it is running, creation joins that
same check before persisting the task's lane. Advertised tool support or a
compatible probe selects the agent lane, while an incompatible result keeps
the model usable through chat. Agent capability is never inferred from or
denied by a model name; probe fallback behavior is driven by the endpoint's
Responses events.

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
approvals, sandboxing, compaction, and streamed events. The production Codex
runtime is an Onyx-owned app-server binary at
`Contents/Helpers/CodexRuntime/<platform>/bin/codex-app-server`; it is not
resolved from a separately installed ChatGPT/Codex app.

Onyx gives that child process an explicit private home at
`~/Library/Application Support/Onyx/Codex` through `CODEX_HOME`. It prepares
the directory with private permissions, removes inherited Codex state-routing
variables, and never imports or filters `~/.codex`. This keeps Onyx's tasks,
SQLite databases, rollout files, memories, skills, MCP configuration, and
ChatGPT OAuth credential files separate from the official Codex application.
The app-server initialization response is checked against the expected home
before the runtime is considered usable. Signing out, renaming, archiving, or
deleting in either app therefore cannot mutate the other's history.

Provider identity is threaded through window restoration, task selection,
draft preferences, local provider conversations, and model usage ranking.
Existing tasks remain bound to their original provider. Their original model is
the task default, while the unified picker can select another model from that
provider for a later turn or reset to the default. New tasks can select any
configured provider/model pair. Each OpenAI-compatible task also keeps its
persisted agent/chat owner: later catalog or probe evidence affects future task
creation, not the execution lane of existing history.

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
Bounded Codex-to-configured-provider delegation is now wired into production
composition. This is distinct from general cross-provider continuation, which
remains incomplete alongside a native Anthropic runtime.

## Codex-to-configured-provider delegation

Onyx mediates delegation instead of teaching `codex app-server` how to
authenticate with third-party providers:

```text
new Codex thread
      |
`onyx_delegate` app-server dynamic tool
      |
app-lifetime Onyx delegation broker
      |
configured provider's existing SharedRuntimeCoordinator
      |
durable, text-only child conversation
      |
bounded result to Codex + provider-scoped child destination to Onyx
```

The production host injects the broker only into the default Codex runtime.
When a new Codex thread starts, `CodexRuntime` builds the tool definition from
saved, credential-free provider/model catalogs and sends it through
`thread/start.dynamicTools`. Current app-server protocol exposes no equivalent
way to add a dynamic tool to an existing thread, so Codex threads created
before this wiring do not gain delegation retroactively.

For each call, the broker re-reads the current provider/model catalog, validates
the exact connection/model pair, text input support, and requested reasoning
effort, and rejects delegation back to Codex. Endpoint URLs, bearer tokens, and
credential handles have no representation in the tool contract. Model-authored
endpoint or credential fields are ignored, and provider failures are reduced to
bounded, sanitized messages before a result returns to Codex.

After validation, the broker resolves the same provider-scoped runtime
coordinator used by normal workspace windows. It starts a durable child task
with the selected model, reasoning effort, and parent working directory under a
read-only execution policy and `never` approval policy. The current path sends
only a self-contained text prompt; it does not grant the remote child Codex
tools or local file access. Successful output is bounded and returned once as
structured text containing the job, provider connection, model, reasoning
effort, child conversation, and result metadata. A terminal turn with no
non-whitespace assistant answer fails closed: the app-created child is removed
and Codex receives a bounded failure without child-navigation metadata.

Codex still records the exchange as a dynamic-tool item, but projection renders
`onyx_delegate` as quiet collaboration activity instead of a generic noisy tool
card. When child metadata is available, selecting the agent switches to the
owning provider connection and opens that durable conversation while the parent
Codex task remains in its project. Calls are bounded by global concurrency,
duplicate call IDs are rejected, and parent interruption or runtime teardown
cancels queued or active work.

Focused protocol, executor, broker, production-composition, projection, and
navigation fixtures cover this path, including answerless terminal cleanup and
its bounded broker failure. On 2026-08-23, the opt-in live Qwen/vLLM broker test
completed a real `medium` request, returned the bounded structured result, and
verified that the provider-scoped child was durably persisted. The installed
app-server also accepted the advertised dynamic tool and delivered one real
`onyx_delegate` invocation to Onyx with the expected provider, model, prompt,
thread, and working directory. Running-preview verification of the combined
invocation, result presentation, and provider-aware child click-through remains
pending. Richer input modalities, child tools, recursive delegation, and
general cross-provider continuation remain future capability work.

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

Production always uses the pinned helper packaged inside Onyx. The explicit
`ONYX_CODEX_PATH` override and installed ChatGPT/Codex search are available
only through `CodexRuntime.makeDevelopmentInstalled` for opt-in development
and live tests; they are not a production fallback. Release packaging must
include the helper, preserve its executable bit, verify its checksum, and
exercise startup against a clean Onyx state directory before publication.

The bundled helper is launched with file-backed ChatGPT OAuth credentials in
the isolated home. Onyx does not copy credentials from `~/.codex`, and a clean
Mac with no official Codex harness installed can complete its own OAuth flow.
The generated app-server schema is archived with the pinned runtime and
protocol fixtures run before upgrades.

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

The Files inspector and window-local Command-P palette share this bounded source
navigator. The palette does not provide syntax highlighting, symbol search,
go-to-definition, or other code navigation.

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
