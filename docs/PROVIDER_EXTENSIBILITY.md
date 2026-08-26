# Provider extensibility boundary

Onyx's default workspace ships OpenAI Codex through `codex app-server`. It also
ships a tested OpenAI-compatible runtime configured from Settings. Both appear
in one production new-task model picker; a selected task remains bound to its
original provider and model.

## What is implemented

- ProviderConnectionDescriptor is a durable, credential-free description of
  an account/endpoint. It stores an opaque connection ID, adapter ID, wire
  protocol, endpoint, and a Keychain/Codex credential locator. It never stores
  an API key, OAuth token, or authorization header.
- ProviderModelDescriptor and ProviderCapabilitySet preserve model discovery
  metadata such as input/output modalities, supported request parameters,
  reasoning efforts, context length, and output limits.
- ProviderCapabilityNegotiator rejects a model whose wire protocol does not
  match the configured connection. It does not invent capabilities that a
  catalog or endpoint did not advertise.
- OpenRouter /models-shaped metadata can be projected into
  ProviderModelDescriptor. Unknown future fields are ignored.
- OpenAICompatibleChatRequestBuilder produces a deterministic
  /chat/completions JSON body for text, HTTP/data-URL images, and validated
  bounded local image attachments converted to data URLs. It validates
  streaming, usage, reasoning, image, and protocol requirements before
  encoding.
- Provider Settings validates and normalizes HTTP(S) endpoints, restricts
  clear-text HTTP to explicitly acknowledged literal loopback/private/link-local
  IPs with no bearer credential, discovers models through `/models`, and stores
  bearer values only through Keychain.
- OpenAICompatibleRuntime streams chat-completions responses and persists
  provider-owned conversation history locally. It is the compatibility
  fallback and advertises no local tools, approvals, or sandbox execution.
- Cached catalogs for every configured connection load before provider
  switching, so manually selected or previously discovered vLLM models are
  directly selectable. Capability metadata is persisted without credentials;
  missing metadata is treated conservatively. Catalog and history projection
  never wait on a provider network request; only the selected metadata-poor
  model starts one bounded compatibility probe in the background.

The catalog projector and request builder remain pure discovery/encoding
components. The Claude descriptor is configuration metadata only; there is no
Anthropic Messages codec or runtime adapter.

## Full agent path for compatible Responses endpoints

Bundled `codex app-server` supports a custom `modelProvider` per thread. When
an OpenAI-compatible model advertises tools/function calling—or, for sparse
catalogs, passes a bounded Responses/tool probe—Onyx composes that capability
instead of reimplementing the Codex agent loop:

```text
Onyx CodexRuntime
    |
pinned codex app-server -- thread-scoped custom modelProvider
    |
unauthenticated literal-loopback Responses connection
    |
Onyx credential-injecting proxy
    |
configured provider Responses endpoint
```

The proxy is a credential boundary, not a second agent runtime. It reads the
provider's bearer credential from Keychain, injects it only on the validated
upstream request, strips sensitive headers across redirects, and avoids prompt,
response, and credential logging. App-server owns the mature multi-round tool
loop, workspace sandbox, approval requests, cancellation, and streamed task
lifecycle. The existing chat runtime remains available for metadata-poor
models that do not pass the compatibility probe. A stale probe failure cannot
demote a model whose current catalog explicitly advertises tool use.

Lane selection is capability-based, never a model-name allow-list. Current
catalog metadata advertising tools or function calling selects the agent lane
immediately, regardless of model identity. For an otherwise-unknown selected
model, catalog and history loading continue while its single bounded probe
runs. If the user creates a task before that result arrives, task creation
joins the same in-flight probe (or starts it if necessary) before committing
durable ownership: compatible models start as agent tasks, while models that
prove incompatible start as useful chat tasks. The probe begins with a small
ordinary Responses request and retries the whole harmless round once with a
larger output allowance only after an explicit incomplete/output-limited
response. It never adds a model-family reasoning field to establish tool use.

Once a task is created, its persisted agent/chat owner remains stable. Later
catalog refreshes or probe results can affect future tasks, but never migrate
an existing chat history into the agent runtime or demote an existing agent
history into chat.

A clean-home probe against bundled app-server 0.149.0 verified custom-provider
Responses routing, app-server-supplied tool schemas, four request rounds,
command approval, continuation after a declined call, rejection of a
sibling-directory write, and a successful workspace write. The production
adaptive runtime, loopback proxy, and durable per-task lane routing now use
that same boundary.

## Why the fallback is not a Claude or agent adapter

AgentRuntime includes durable thread discovery/resume, Codex approvals,
sandbox policy, local terminal/tool execution, steering, archive/fork/delete,
and provider event projection. A plain OpenAI-compatible chat endpoint does
not provide those semantics, and Anthropic's native Messages API is a
different wire protocol. Implementing a fake adapter that silently drops
those controls would make the desktop behavior misleading.

The composition host resolves saved OpenAI-compatible connections beside the
registry-owned default Codex connection. Any future adapter must still define
an explicit mapping for lifecycle features that its upstream does not provide
(or mark them unavailable in session capabilities), add a provider-owned
conversation store, and prove live stream/error behavior.

Provider request capabilities are deliberately not projected into the plain
chat adapter. An explicit tool/function-call advertisement selects an
app-server agent attempt; metadata-poor models use the behavioral probe.
App-server—not the model catalog—supplies the tool parsing, sandbox, approvals,
execution, and lifecycle semantics. Probe-incompatible models remain on the
chat fallback, while advertised or probe-compatible models receive local tools
only through the app-server sandbox and approval boundary.

Local image paths selected in the composer are revalidated, bounded, and
resolved to image data URLs before crossing the remote endpoint boundary; the
filesystem path itself is not sent to the provider.
