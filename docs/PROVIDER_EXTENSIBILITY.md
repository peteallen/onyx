# Provider extensibility boundary

Onyx's default workspace ships OpenAI Codex through `codex app-server`. It also
ships a tested OpenAI-compatible runtime configured from Settings. Both appear
in one production new-task model picker. A selected task remains bound to its
original provider and durable execution lane; later model changes stay within
that provider.

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
  provider-owned conversation history locally. It remains the plain-chat lane
  for existing chat-owned tasks and advertises no local tools, approvals, or
  sandbox execution; it is not a probe-selected fallback for new tasks.
- Cached catalogs for every configured connection load before provider
  switching, so manually selected or previously discovered vLLM models are
  directly selectable. Capability metadata is persisted without credentials;
  missing metadata is treated conservatively for input, reasoning, and display
  controls. Catalog and history projection never wait on a provider network
  request, and production routing does not start a compatibility probe. An
  explicit diagnostic may start one bounded check without affecting admission.

The catalog projector and request builder remain pure discovery/encoding
components. The Claude descriptor is configuration metadata only; there is no
Anthropic Messages codec or runtime adapter.

## Default agent path for OpenAI-compatible Responses endpoints

Bundled `codex app-server` supports a custom `modelProvider` per thread. Every
new OpenAI-compatible task attempts this path instead of waiting for a model
allowlist or synthetic capability check. Catalog metadata and optional probe
outcomes remain diagnostics; app-server and the provider's real Responses
behavior determine whether the attempt succeeds:

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
lifecycle. The existing chat runtime remains available for already persisted
chat-owned tasks. Missing, stale, or failed probe evidence never demotes a new
model to that lane; an incompatible endpoint fails clearly from the agent path.

Lane selection for new tasks is agent-first and never a model-name allow-list.
Advertised tool metadata, compatible probe evidence, failed probe evidence,
and unavailable probe evidence all leave a new task on the agent lane. Normal
catalog loading, task creation, and agent-task model switching do not start or
await a probe. The optional diagnostic probe begins with a small ordinary
Responses request and retries the harmless round once with a larger output
allowance only after an explicit incomplete/output-limited response. It never
adds a model-family reasoning field to establish tool use.

Once a task is created, its persisted agent/chat owner remains stable. Newly
created generic tasks keep the agent owner even when metadata is sparse or a
diagnostic probe fails; legacy chat-owned tasks remain on chat. Later catalog
refreshes or probe results never migrate an existing history between lanes.

A clean-home probe against bundled app-server 0.149.0 verified custom-provider
Responses routing, app-server-supplied tool schemas, four request rounds,
command approval, continuation after a declined call, rejection of a
sibling-directory write, and a successful workspace write. The production
adaptive runtime, loopback proxy, and durable per-task lane routing now use
that same boundary.

## Why plain chat remains a separate lane

AgentRuntime includes durable thread discovery/resume, Codex approvals,
sandbox policy, local terminal/tool execution, steering, archive/fork/delete,
and provider event projection. A plain OpenAI-compatible chat endpoint does
not provide those semantics, and Anthropic's native Messages API is a
different wire protocol. Implementing a fake adapter that silently drops
those controls would make the desktop behavior misleading. Chat therefore
remains an honest lane for existing chat-owned histories; a new generic task
is not silently downgraded when its real agent attempt fails.

The composition host resolves saved OpenAI-compatible connections beside the
registry-owned default Codex connection. Any future adapter must still define
an explicit mapping for lifecycle features that its upstream does not provide
(or mark them unavailable in session capabilities), add a provider-owned
conversation store, and prove live stream/error behavior.

Provider request capabilities are deliberately not projected into the plain
chat adapter. Every new generic task receives an app-server agent attempt;
advertised tool metadata and optional probe outcomes are diagnostics, not
admission gates. App-server—not the model catalog—supplies tool parsing,
sandboxing, approvals, execution, and lifecycle semantics. An incompatible
endpoint reports a bounded agent failure instead of creating a reply-only task;
existing chat-owned tasks continue to receive only chat capabilities.

Local image paths selected in the composer are revalidated, bounded, and
resolved to image data URLs before crossing the remote endpoint boundary; the
filesystem path itself is not sent to the provider.
