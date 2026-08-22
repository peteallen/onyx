# Product parity ledger

This is the completion ledger for the full Onyx objective. A checked
implementation item has current automated evidence; hands-on live-runtime proof
is tracked separately when it is still outstanding. Visual resemblance alone is
not enough. A checked item explicitly labeled as a foundation records tested
enabling work only, not a completed user surface.

## Application shell

- [x] Native macOS window, command rail, project/task sidebar, transcript, and context inspector
- [x] Responsive three-pane sizing with inspector visibility control
- [x] Persisted drag-resizing for sidebar and inspector with compact-window safeguards
- [x] App-owned project catalog with grouped tasks, add, rename, reorder, and metadata-only removal
- [x] Multiple independently restored workspace windows with per-window task, draft, panel, terminal, command, and frame ownership
- [x] Production shared-runtime event broadcast, single-flight connection/account handshakes, and cross-window sign-out boundary
- [x] Native tabbing, core keyboard commands and task menus, plus window-frame restoration
- [x] Focused VoiceOver, keyboard-focus, non-color status, and reduced-motion pass
- [ ] Full VoiceOver traversal and large-text audit
- [x] Ad-hoc signed, staged, and verified development `.app` packaging with the custom Onyx icon and configurable destination, display name, and bundle ID for isolated preview builds
- [x] Stable preview path/name/bundle identity, optional persistent local signing identity, atomic replacement, and executable-owned graceful stop
- [ ] Sandboxed, notarized, and updateable production distribution

## Codex runtime

- [x] Replaceable runtime protocol
- [x] Spawn and initialize `codex app-server` over stdio
- [x] Account/model discovery and live thread listing
- [x] Read a stored thread and project common transcript items
- [x] Start a thread and turn, steer, interrupt, and consume streamed text
- [x] Active and archived task discovery with read-only archived history
- [x] Resume available tasks and preserve drafts when another client owns the active writer
- [x] Stable protocol mappings for fork, compaction, delete, archive, restore, rename, and lifecycle notifications
- [x] Model reasoning effort plus real read-only, workspace-write, and full-access execution policies
- [x] Provider-neutral inbound image attachments and native previews for user, MCP/tool, image-view, and image-generation items
- [x] Outbound composer image picking and paste, validated session-only previews, image-only or mixed messages, and image-capable Codex turn/steer payloads
- [x] Safe, bounded clickable HTTP(S) resource-link cards for MCP, dynamic-tool, and web-search results
- [x] Opt-in live outbound-image proof through an installed `codex app-server`, using a generated local PNG and its streamed assistant result
- [ ] Remaining item taxonomy and non-image rich tool results beyond resource-link cards
- [ ] Approval UX and protocol coverage for every command, file, MCP, user-input, and permission-amendment variant
- [ ] Hands-on verification for every destructive task-management action
- [x] Read-only plan, task-attention, and collaboration-agent progress in the transcript, sidebar, and inspector
- [x] Click-through collaboration-agent detail and isolated ephemeral Codex side chat
- [ ] Skills, plugins, apps, MCP authentication, goals, collaboration controls, and usage surfaces
- [ ] Worktree creation, handoff, Git review, and cloud/local task parity

## Workspace tools

- [x] Working-tree Codex review for staged, unstaged, and untracked changes
- [x] Git diff viewer with branch/tracking status, staged/unstaged/untracked counts, scope switching, selectable files, hunks, and old/new line numbers
- [x] Tested bounded Git commands and rendering, including untracked previews, binary/metadata handling, truncation notices, and explicit empty/loading/error states
- [x] Per-file stage and unstage actions with status revalidation, literal pathspecs, and conflict guards
- [ ] Inline diff comments
- [x] Confirmed whole-file discard that moves existing working-copy bytes to the macOS Trash before replacement
- [x] Persistent project PTY while the application is open, with resize, search, clear, interrupt, and restart
- [ ] Relaunch-persistent background terminal sessions and full terminal emulation
- [x] Bounded project file browser with native open and Finder reveal
- [x] Files-inspector quick-open search and bounded, numbered, selectable UTF-8 source preview
- [ ] Global Command-P, syntax highlighting, symbol search, and code navigation
- [x] Image thumbnails and accessible previews
- [ ] Audio, PDF, document, and visualization presentation

## Multi-provider platform

- [x] One registry-owned default Codex connection plus host-resolved configured OpenAI-compatible connections
- [x] Tested opaque adapter, connection, and connection-scoped model identity foundation
- [x] Tested versioned conversation-catalog foundation with app-owned IDs, provider bindings, and lineage validation
- [x] Tested provider connection descriptors, credential references, model capability negotiation, OpenRouter catalog projection, and OpenAI-compatible request codec
- [x] Provider Settings for OpenAI-compatible connections, safe URL validation, `/models` discovery, and Keychain-only bearer credentials
- [x] OpenAI-compatible runtime adapter with streamed chat and provider-owned local conversation persistence
- [x] Production provider/model selection with cached catalogs and frequent/recent ranking
- [x] Capability-aware OpenAI-compatible image and reasoning controls with conservative unknowns
- [ ] Production integration of the conversation catalog with task discovery, drafts, and restoration
- [ ] End-to-end capability negotiation through a second live runtime adapter
- [ ] Claude runtime adapter (not implemented)
- [ ] Usable cross-provider continuation with explicit lineage

## Quality gates

- [x] Unit fixtures for protocol value decoding and Codex projection
- [x] Incremental transcript layout-cache and JSONL framing regression tests
- [ ] Recorded large-history performance suite
- [x] Reconnect transport isolation, single-flight retry, cached-state continuity, and selected-task rehydration suite
- [x] App-server process-exit, malformed-transport reconnect, and future-field/version-skew resilience fixtures
- [ ] End-to-end OAuth, approvals, tool execution, and persistence suite
- [x] Opt-in dark-appearance shell, typed-interaction, and terminal snapshot checks
- [ ] Baseline-diffed visual regression suite in light and dark appearances
