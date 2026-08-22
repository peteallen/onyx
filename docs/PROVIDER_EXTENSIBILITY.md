# Provider extensibility boundary

Onyx's default workspace ships OpenAI Codex through `codex app-server`. It also
contains a tested OpenAI-compatible runtime that can be configured from
Settings, while the production workspace selector remains Codex-only for now.

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
  /chat/completions JSON body for text and already-resolved HTTP/data-URL
  images. It validates streaming, usage, reasoning, image, and protocol
  requirements before encoding.
- Provider Settings validates and normalizes HTTP(S) endpoints, requires an
  explicit acknowledgement for non-loopback clear-text HTTP, discovers models
  through `/models`, and stores bearer values only through Keychain.
- OpenAICompatibleRuntime streams chat-completions responses and persists
  provider-owned conversation history locally. It advertises only the controls
  the endpoint can actually support; Codex-local tools, approvals, and sandbox
  execution are unavailable on this adapter.

The catalog projector and request builder remain pure discovery/encoding
components. The Claude descriptor is configuration metadata only; there is no
Anthropic Messages codec or runtime adapter.

## Why this is not an OpenRouter or Claude adapter yet

AgentRuntime includes durable thread discovery/resume, Codex approvals,
sandbox policy, local terminal/tool execution, steering, archive/fork/delete,
and provider event projection. A plain OpenAI-compatible chat endpoint does
not provide those semantics, and Anthropic's native Messages API is a
different wire protocol. Implementing a fake adapter that silently drops
those controls would make the desktop behavior misleading.

The OpenAI-compatible adapter intentionally has no RuntimeRegistry registration
in the default composition yet. A future production selector can add it after
the conversation catalog, restoration, and provider-scoped UI are wired
together. Any adapter must define an explicit mapping for lifecycle features
that its upstream does not provide (or mark them unavailable in session
capabilities), add a provider-owned conversation store, and prove live
stream/error behavior.

Provider request capabilities are deliberately not projected directly into
AgentRuntime capabilities. For example, a remote model advertising tools says
nothing about Onyx's local tool execution and approval semantics; the eventual
adapter must prove and advertise those product-level behaviors separately.

Local image paths are intentionally rejected by the codec. A future adapter
must resolve them to a validated image data URL or provider-upload reference
before crossing the remote endpoint boundary.
