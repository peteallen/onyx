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
  missing metadata is treated conservatively.

The catalog projector and request builder remain pure discovery/encoding
components. The Claude descriptor is configuration metadata only; there is no
Anthropic Messages codec or runtime adapter.

## Full agent path for compatible Responses endpoints

Bundled `codex app-server` supports a custom `modelProvider` per thread. For an
OpenAI-compatible endpoint that passes a bounded Responses/tool probe, Onyx
will compose that capability instead of reimplementing the Codex agent loop:

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
lifecycle. The existing chat runtime remains available when the exact
endpoint/model/protocol combination fails, times out, or later loses the
compatibility probe.

A clean-home probe against bundled app-server 0.149.0 verified custom-provider
Responses routing, app-server-supplied tool schemas, four request rounds,
command approval, continuation after a declined call, rejection of a
sibling-directory write, and a successful workspace write. That probe is
architecture evidence; the production proxy and routing are not implemented
yet.

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

Provider request capabilities are deliberately not projected directly into
AgentRuntime capabilities. A remote model advertising tools says nothing about
whether it follows the Responses tool protocol correctly. Onyx enables the
app-server agent path only after bounded behavioral proof, and only because
app-server—not the model catalog—supplies the sandbox, approvals, execution,
and lifecycle semantics.

Local image paths selected in the composer are revalidated, bounded, and
resolved to image data URLs before crossing the remote endpoint boundary; the
filesystem path itself is not sent to the provider.
