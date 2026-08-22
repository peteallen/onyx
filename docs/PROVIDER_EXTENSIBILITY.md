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
  provider-owned conversation history locally. It advertises only the controls
  the endpoint can actually support; Codex-local tools, approvals, and sandbox
  execution are unavailable on this adapter.
- Cached catalogs for every configured connection load before provider
  switching, so manually selected or previously discovered vLLM models are
  directly selectable. Capability metadata is persisted without credentials;
  missing metadata is treated conservatively.

The catalog projector and request builder remain pure discovery/encoding
components. The Claude descriptor is configuration metadata only; there is no
Anthropic Messages codec or runtime adapter.

## Why this is not a Claude or remote-tool adapter yet

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
AgentRuntime capabilities. For example, a remote model advertising tools says
nothing about Onyx's local tool execution and approval semantics; the eventual
adapter must prove and advertise those product-level behaviors separately.

Local image paths selected in the composer are revalidated, bounded, and
resolved to image data URLs before crossing the remote endpoint boundary; the
filesystem path itself is not sent to the provider.
