# Onyx product issues and decisions

This is the durable source of truth for product/UI problems, decisions, and verification. Update it as work progresses; do not erase useful history.

Status values: **Open**, **In progress**, **Blocked**, **Done**, **Deferred**.

## Active issues

### UI-001 — Composer caret and placeholder are misaligned

- **Status:** In progress
- **Problem:** When the composer receives focus, the caret runs through the middle of the “D” in the “Describe” placeholder.
- **Decision:** The placeholder and entered text must share the same text container, font metrics, insets, and baseline.
- **Acceptance:** Focusing an empty composer places the caret at the normal insertion position beside—not through—the placeholder; typed text begins in exactly the placeholder’s position at every supported composer height.
- **Verification:** Hosted composer coverage confirms the placeholder and insertion point share the same first-line geometry. Running-preview checks at multiple composer heights in light and dark mode are still pending.

### UI-002 — Token usage adds noise below responses

- **Status:** In progress
- **Problem:** Token usage displayed below assistant responses makes the transcript busier without helping the normal reading flow.
- **Decision:** Do not show token usage beneath responses in the transcript.
- **Acceptance:** Completed and streaming responses have no token-usage footer; removing it does not leave an empty gap.
- **Verification:** Automated transcript coverage confirms known usage metadata is hidden without leaving a layout gap while unrelated response detail remains visible. Running-preview checks for short, long, and streaming responses are still pending.

### UI-003 — The latest message cannot be edited

- **Status:** In progress
- **Problem:** A user cannot correct and resubmit their most recent message as they can in Codex.
- **Decision:** Use the provider's native history-revert operation for the latest completed, failed, or interrupted user turn. Show one quiet pencil action on that message with a generous 32×32 pt target. Before the first edit, explain that conversation history after that point is removed but workspace file changes are not reverted. A provider turn containing multiple user messages is not editable as one message because reverting it would remove all of them. While a revert is pending, keep typing responsive but block Send and other writer operations; merge later draft input instead of overwriting it. An ambiguous provider outcome must reload authoritative history before unlocking Send. If that reload fails or the user has navigated elsewhere, keep the original task locked until its successful reopen without blocking unrelated tasks. Older Codex binaries that reject native revert lose the capability for the runtime session.
- **Acceptance:** The latest user message has an easy-to-discover edit action; activating it loads the full text into an editable composer; cancel is lossless; submitting the edit resumes from the corrected message without duplicating it. Older messages remain read-only for now.
- **Verification:** Automated coverage passes for the 32×32 hover/focus edit action, older-message read-only behavior, native revert, restored text and image attachment, corrected resubmission without duplication, steered-turn safety, stale callbacks, concurrent draft typing, concurrent history pagination, writer-operation gating, ambiguous-outcome reconciliation, retained lock after failed reconciliation or navigation away, unrelated-task availability, and runtime capability downgrade. Running-build verification of the warning/cancel path, multiline text, attachment preview, and unavailable state during active work is still pending, so this remains **In progress**.

### UI-004 — Interactive targets are consistently hard to click

- **Status:** In progress
- **Problem:** Controls throughout the app require too much pointer precision, making common interactions feel irritating and slow.
- **Decision:** Treat the visible control and its surrounding row/container as one generous hit target where that is unambiguous. Aim for at least 28×28 pt for compact controls and 36×36 pt for primary controls, without making the UI visually bulky.
- **Acceptance:** Sidebar rows, disclosure controls, transcript actions, toolbar controls, tabs, model/provider controls, composer actions, and inspector controls can be activated by clicking their expected visible area; adjacent targets do not overlap or trigger unexpectedly.
- **Verification:** Automated coverage enforces the shared 32 pt compact target, larger row targets, 10 pt pane splitters, whole project-header clicks, and whole folder-name clicks. A pointer audit in the running preview, including narrow-window layouts, is still pending.

### PERF-001 — Large tasks should appear tail-first

- **Status:** In progress
- **Problem:** Opening a large task feels slow because the user waits for the full transcript even though they usually need its most recent page.
- **Decision:** Render the newest page of a task first, keep scrolling/input responsive, and load older content incrementally above it. Codex reads metadata plus its 12 newest turns without acquiring writer ownership; reconnecting or sending resumes the task explicitly. An older Codex server that explicitly rejects the pagination method or parameters falls back to its full read/resume while Onyx still presents only the newest 120 items. Other provider or transport failures remain visible. Other providers present at most 120 already-read items initially. Every older reveal is also capped at 120 items, including an unusually large provider turn. A quiet “Load earlier messages” action fetches or reveals the next page. Prepending uses native row insertion and anchors the visible row rather than reloading the transcript or moving the reader.
- **Acceptance:** A large task shows its latest useful content immediately with an in-context loading indication for older history; the composer remains interactive; older pages load on demand or in idle time; prepending a page does not move the content currently under the reader’s eyes.
- **Verification:** Provider-tail, explicit-empty-page, suspended older-page, buffered-fallback, compatibility-fallback, constant-time planning, and hosted scroll-anchor regressions pass. Compatibility coverage exercises both JSON-RPC method-not-found and invalid-params, legacy resume before send, the 120-item bound, and refusal to fall back for unrelated failures. The hosted native view confirms valid prepends insert rows without a full reload and preserve the visible offset within 1 pt. A 20,000-row mixed conversation with grouped activity survives three older-page prepends plus 100 assistant/tool tail mutations without materializing history, rebuilding the full row index, or reloading the full projection. Additional hosted coverage verifies assistant-only history pages still shift all expected activity identities into the final rollup and that an appended plan remains the exact mounted row refreshed beyond the near-tail lookup budget. Running-preview measurement is intentionally still pending, so this issue remains **In progress**.

### RUNTIME-001 — Onyx cannot target its own preview app

- **Status:** In progress
- **Problem:** A UI automation tool call fails with `Invalid app: app.onyx.preview` when Codex tries to interact with the running Onyx preview.
- **Decision:** Preserve the one stable preview identity and repair app discovery/targeting around it. Do not work around this by renaming or rebuilding the app under a changing bundle identity.
- **Acceptance:** Codex can identify and interact with the canonical running `Onyx Preview` build without an invalid-app error or another macOS privacy/local-network approval cycle.
- **Verification:** Pending. Exercise a real app-targeted tool call against the canonical running preview and confirm the same build identity remains registered and running.

### UI-005 — Failed activity rows look like debug UI

- **Status:** In progress
- **Problem:** A failed routine activity uses an oversized bright red `Failed` badge that dominates the row, while the actual failure detail is dim and hard to read.
- **Decision:** Treat failure as a compact semantic state, not a large badge. Keep the activity summary calm, make the useful error detail readable, and reserve strong red for a small icon/accent.
- **Acceptance:** Failed tool and command rows are immediately understandable in light and dark mode without a large pill; their failure detail remains readable, selectable when expanded, and visually subordinate to the conversation.
- **Verification:** Automated transcript coverage confirms routine failures have no detached `Failed` badge, remain compact when collapsed, and keep the useful error summary readable. Light/dark running-preview inspection, including the `Invalid app` case, is still pending.

### UI-006 — Visual direction drifted away from the dark baseline

- **Status:** In progress
- **Problem:** A duplicate/legacy build opened with a lighter, busier appearance that feels markedly worse than the simpler near-black Onyx design.
- **Decision:** Keep the simpler dark, near-black workspace as the visual baseline. Larger hit targets must come from interaction geometry, not bulkier chrome, brighter panels, or inflated controls.
- **Acceptance:** The canonical preview retains a restrained near-black canvas and low-contrast chrome in dark mode while all primary controls remain easy to hit; no legacy or alternate build is launched during development.
- **Verification:** Partial. On 2026-08-22, the repo-local legacy identities were unregistered, the current source was rebuilt and launched only through `scripts/run-preview.sh`, and process inspection confirmed one canonical `dist-preview/Onyx Preview.app` process with its one owned Codex backend. The checkout still contains ignored legacy bundles (`dist/Onyx Live Preview.app` with `dev.peteallen.onyx.live-preview` and `dist/Onyx.app` with `com.peteallen.onyx`) that must not be opened; generated dark snapshots confirm the current restrained near-black hierarchy. Hands-on visual confirmation of the rebuilt canonical preview is still pending.

### UI-007 — Workspace panes need direct resizing

- **Status:** In progress
- **Problem:** Fixed pane widths make the transcript, project list, and inspector fight for space instead of adapting to the task.
- **Decision:** Keep the three-pane workspace, add persistent drag resizing for the project sidebar and inspector, and protect a useful minimum conversation width in compact windows.
- **Acceptance:** Both dividers are easy to acquire and drag; widths persist per window; collapsing or reopening a pane restores a sensible width; neither side pane can crush the composer or transcript.
- **Verification:** Layout coverage exercises persisted widths, compact-window arbitration, accessibility adjustments, window isolation, and 10 pt splitter acquisition. Hands-on dragging in the canonical preview is still pending.

### UI-008 — Chats need project grouping and management

- **Status:** In progress
- **Problem:** A flat task list becomes difficult to scan and does not provide basic project organization.
- **Decision:** Group provider-scoped tasks under an app-owned project catalog. Support add/import, rename, reorder, and metadata-only removal; removing a project grouping must not delete its folder or provider tasks.
- **Acceptance:** Projects can be added, renamed, moved, and removed from the sidebar; tasks appear in the correct project even when providers reuse task IDs; ordering persists; failures remain local to the initiating window.
- **Verification:** Automated catalog and sidebar coverage exercises grouping, ordering, persistence, provider-scoped identity, large catalogs, and project-header interaction. Running-preview management checks, especially removal wording and recovery, are still pending.

### UI-009 — Routine tool activity overwhelms the conversation

- **Status:** In progress
- **Problem:** Tool calls and command output are too verbose in the normal reading flow.
- **Decision:** Show routine activity as a quiet one-line summary, collapsed by default. Expanded rows should reveal complete readable output, attachments, and links without turning the transcript into a stack of debug cards.
- **Acceptance:** Routine tool, command, plan, and file activity starts collapsed; the summary preserves the first useful information; expansion is obvious and lossless; approvals and true errors remain prominent.
- **Verification:** Automated transcript coverage exercises collapsed/expanded activity, complete expanded media, readable failures, truncation, keyboard disclosure, and accessibility state. Final light/dark running-preview inspection is pending.

### UI-010 — Subagents need click-through detail

- **Status:** In progress
- **Problem:** Seeing that subagents exist is not enough if their individual conversation and state cannot be opened.
- **Decision:** Make each collaboration-agent row a navigable control that opens the provider-owned child conversation when an ID is available, with a clear unavailable message otherwise.
- **Acceptance:** Clicking an agent opens that agent’s conversation without losing the parent task from the project list; missing or unsupported child conversations fail clearly; rows are easy to hit and keyboard accessible.
- **Verification:** Model and hosted presentation coverage exercises child-task navigation, agent aggregation, and generous row targets. A real multi-agent Codex task still needs running-preview verification.

### UI-011 — Side chat is missing from the task workflow

- **Status:** In progress
- **Problem:** Users need a lightweight branch for a question or experiment without changing the durable task conversation.
- **Decision:** Offer a Codex side chat as an isolated ephemeral fork over the main conversation rather than another permanent sidebar task.
- **Acceptance:** Side chat opens from an eligible task, streams and accepts images/interactions independently, does not shrink or mutate the main conversation, interrupts safely when closed, and never appears as a durable task.
- **Verification:** Automated side-chat and native-fork coverage exercises isolation, streaming, image paste, interactions, navigation, cancellation, and unsupported runtimes. Running-preview verification is pending.

### UI-012 — Waiting feedback belongs inside the conversation

- **Status:** In progress
- **Problem:** A detached `Working` label above the chat does not clearly communicate that the assistant owes the user a response.
- **Decision:** Keep a calm pending-response row at the end of the transcript from send acceptance until assistant text begins streaming. Busy composer controls may remain available, but they are not the primary response indicator; when the composer is collapsed during active work, its button is an explicit `Write a follow-up` action rather than a second copy of the waiting status.
- **Acceptance:** The pending state appears immediately beside the conversation, uses review-specific wording when relevant, disappears only when response content arrives or work ends, and never duplicates an assistant response.
- **Verification:** Transcript-state coverage and opt-in visual fixtures exercise the inline pending row and its handoff to streaming text. Busy-composer coverage and regenerated dark/narrow busy snapshots confirm the distinct `Write a follow-up` affordance. Final running-preview timing and appearance checks are pending.

### UI-013 — Composer image paste is missing

- **Status:** In progress
- **Problem:** Images copied from another app cannot be pasted into a message, interrupting a common feedback workflow.
- **Decision:** Accept validated image data and file URLs from the clipboard, show removable session-only previews immediately, and send image-only or mixed text/image turns only when the selected runtime/model supports them.
- **Acceptance:** Pasting a supported image adds a visible preview without inserting junk text; unsupported, unsafe, or oversized data fails clearly without damaging the draft; send failure restores the same attachment.
- **Verification:** Automated composer, runtime, persistence, and side-chat coverage exercises paste, capability gating, image-only sends, mixed history, and failure restoration. Composer previews now use the bounded transcript image loader asynchronously instead of decoding files or data URLs from SwiftUI `body`, so typing and streaming do not repeat full-image work on the main actor. Hands-on paste from screenshots and Finder is still pending.

### UI-014 — Folder names should expand the Files tree

- **Status:** In progress
- **Problem:** Requiring the tiny disclosure chevron to expand a folder makes the Files pane unnecessarily precise and frustrating.
- **Decision:** Treat the folder icon and name as the disclosure action while keeping trailing file actions distinct.
- **Acceptance:** Clicking anywhere on a folder’s main row expands or collapses it exactly once; file rows still preview files; the trailing menu does not also toggle the folder.
- **Verification:** A hosted pointer test confirms a click on the folder name toggles the directory, and file-tree coverage protects bounded loading behavior. Running-preview checks across nested rows are pending.

### UI-015 — Typography and layout still feel unfinished

- **Status:** In progress
- **Problem:** Even with the darker palette restored, the workspace hierarchy, spacing, and typography remain noticeably less clean and composed than the Codex reference. The conversation also sits too far from the left edge of its pane, wasting space and weakening its connection to the task header.
- **Decision:** Do not clone Codex pixel-for-pixel. Use it as a quality bar for calm hierarchy, readable measure, alignment, density, and typographic consistency while retaining Onyx’s restrained near-black identity. Keep the readable line length, but bias the transcript and composer toward a smaller leading gutter instead of centering unused space equally on both sides.
- **Acceptance:** The project list, transcript, composer, and inspector share a coherent type scale and spacing rhythm; the conversation is the obvious focal point; transcript and composer share a visibly tighter left axis without crowding compact windows; controls align cleanly at common window sizes; light and dark appearances avoid muddy or competing surfaces.
- **Verification:** Layout coverage confirms the composer uses a 14–20 pt leading gutter and wide transcripts keep the same readable width while moving spare space to the trailing side. Final light/dark busy-workspace comparisons and running-preview validation with representative short and large tasks are still pending.

### UI-016 — Opening Review should not surprise-request Documents access

- **Status:** In progress
- **Problem:** Merely opening the Review pane can trigger a broad-looking macOS Documents Folder request with no explanation.
- **Decision:** Selecting Review must not read the checkout. Require an explicit, project-named `Inspect Changes` action before Git access so any macOS protected-folder prompt has clear context.
- **Acceptance:** Opening Review alone never reads the project or prompts for folder access; the pane names the exact project before inspection; choosing inspection reads only that checkout and explains why macOS may show a protected-folder prompt.
- **Verification:** Automated review-model coverage confirms project preparation performs no filesystem read until the explicit action. Canonical-preview verification in a Documents-hosted checkout is still pending.

### UI-017 — Project files need an immediate global quick open

- **Status:** In progress
- **Problem:** Opening a known project file requires navigating to the Files inspector and manually searching there, which interrupts keyboard-driven work.
- **Decision:** Command-P opens a restrained, window-local file palette immediately and focuses its search field before any project indexing begins. The palette and Files inspector share one bounded source navigator; indexing and ranked search stay off the main actor, superseded work is cancelled, and no more than 40 matches are published.
- **Acceptance:** Command-P works from an active task or new-task workspace; arrow keys move the selection; Return reveals the Files inspector and previews the selected file; Escape closes without changing the previously visible panes, inspector tab, or file preview; a missing project has a clear state; an existing task without a provider workspace never inherits the new-task draft project; typing remains responsive with 4,000 indexed files.
- **Verification:** Hosted coverage confirms the palette and its immediately focusable native search field paint while a delayed 4,000-file index is still running; after the XCTest host installs that field editor, native arrow/Return opens the selected result and Escape dismisses without opening a file or losing the Files inspector's prior query. Typing only schedules off-main ranking, results stay capped at 40, stale rows are removed before a replacement query finishes, superseded project indexes are cancelled, and command routing remains window-local. Search-model coverage also protects stale-query rejection and shared indexing for an unchanged project. Multiwindow coverage confirms a cwd-less existing task cannot reuse a staged new-task project in Files, Review, Terminal, Summary, or Command-P. Automatic focus and the complete flow still require canonical-preview verification.

### PERF-002 — New Task can beachball the app

- **Status:** In progress
- **Problem:** Clicking New Task with a large history can block the window instead of immediately presenting a fresh composer.
- **Decision:** Publish the welcome/composer state synchronously from bounded cached state, keep draft persistence off the interaction path, and reuse rather than restart an in-flight task refresh.
- **Acceptance:** The first click visibly switches to a usable blank task within one frame where practical; repeated clicks are harmless; the previous draft is preserved; large catalogs do not get synchronously reprojected.
- **Verification:** Model coverage stays below 50 ms and a hosted 4,824-task click-to-paint check stays below 100 ms. The hosted benchmark waits only when SwiftUI genuinely defers mounting the welcome prompt or composer, so unrelated executor scheduling on a busy CI host is not charged to an already-complete paint. A canonical-preview check with Pete’s real task history is still pending.

### RUNTIME-002 — Repeated use still crashes

- **Status:** In progress
- **Problem:** The app has crashed during ordinary task use, making visual and performance improvements irrelevant.
- **Decision:** Treat every reproducible crash as a release blocker. Keep transcript collection changes atomic, bound expensive presentation work, and preserve crash scenarios as hosted regression tests. A Return-key submission must release the native editor from the responder chain before SwiftUI can replace it with the busy state.
- **Acceptance:** Streaming, expanding tool rows, adding an inline pending response, resizing panes, opening large tasks, switching tasks repeatedly, and submitting with Return do not terminate or hang the app; failures surface as recoverable UI state.
- **Verification:** A canonical-build crash report from 2026-08-22 identified a main-thread key-up failure after the native composer was replaced. Hosted coverage now reproduces that submit/replace/key-up sequence and confirms the editor resigns before deferred submission; the focused regression passes. Transcript stress coverage also survives repeated row changes, activity-group growth, pending-response insertion, layout, lone-activity rollup replacement, live-tool rollup joins, and the eight-to-nine activity boundary through atomic suffix updates. Focused hosted regressions additionally assert the exact mounted assistant, activity rollup, ninth activity, and waiting row while replacing or inserting them in the same collection transaction. A rebuilt-preview keyboard check and sustained soak are still required before this can be **Done**.

### PROVIDER-001 — OpenAI-compatible models need capability-aware behavior

- **Status:** In progress
- **Problem:** A generic provider connection should not expose controls a model cannot use or hide capabilities the endpoint actually advertises. Qwen reasoning is currently hidden when vLLM’s `/models` payload omits effort metadata even though the configured Qwen request mode supports it.
- **Decision:** Discover model metadata from `/models`, preserve advertised input modalities, reasoning parameters, context limits, and tool-use evidence, and default unknown fields conservatively. An exact, verified model-family profile is also valid capability evidence when a sparse catalog identifies that family: the configured Qwen 3.8/vLLM deployment offers `None`, `Low`, `Medium`, and `X-High` only. A per-task effort overrides the older provider-wide disable-thinking option; selecting `None` preserves Qwen's native `enable_thinking=false` behavior. Endpoint tool metadata alone does not enable Onyx local tools; the adapter must implement the full execution and approval behavior before advertising that product capability.
- **Acceptance:** Image and reasoning controls adapt to the selected model; configured Qwen models expose working reasoning selection even with sparse vLLM metadata; unsupported inputs are blocked before sending; unknown metadata stays usable for text without inventing features; changing endpoint or credentials cannot retain a stale capability catalog.
- **Verification:** Provider capability, Settings discovery, app-model selection, request-codec, and OpenAI-compatible runtime coverage exercise OpenRouter metadata, exact and sparse vLLM metadata, unknown model baselines, images, reasoning, stale-catalog invalidation, and conservative tool behavior. On 2026-08-23, the configured Qwen 3.8 server schema advertised the generic reasoning enum; tiny live probes confirmed that this model accepts `none`, `low`, `medium`, and `xhigh` while rejecting `high` and `max`; and the opt-in runtime test passed end to end with a streamed `medium` request and no conflicting disable-thinking field. The canonical preview was then rebuilt and launched with one Onyx process and one owned Codex backend. Automated picker inspection remains blocked by RUNTIME-001's app-targeting failure, so direct running-preview selection plus a second provider family are still pending.

### PROVIDER-002 — vLLM models are absent or buried in task model selection

- **Status:** In progress
- **Problem:** After adding a vLLM provider, its model was not available for a task, and commonly used models take too much effort to find.
- **Decision:** Use one provider-and-model picker in the composer. Load saved catalogs before connection, keep manually configured models selectable when discovery is empty or omits them, and rank accepted usage by frequency then recency. New tasks may switch providers; existing tasks may switch the model for the next turn only within their bound provider and can reset to the task default.
- **Acceptance:** A saved vLLM model appears without requiring a restart or successful rediscovery; selecting it changes provider and model together for a new task; frequent/recent models appear first; existing tasks clearly show their provider and current/default model behavior.
- **Verification:** Automated host, Settings, runtime, and draft-safety coverage exercises cached/manual vLLM catalogs, provider switching, frequent/recent ranking, accepted-send usage, next-turn model overrides, reset, and task deletion cleanup. Hands-on selection against Pete’s configured vLLM endpoint is still pending.

## Decision log

### D-001 — Perceived responsiveness is the top product constraint

- **Status:** Active
- **Decision:** Prioritize immediate input, selection, navigation, and visible feedback on the main thread. Background throughput does not compensate for a UI that feels blocked.
- **Consequence:** Prefer progressive rendering, cached projections, bounded main-thread work, and cancellation over waiting for complete results before updating the interface.
- **Verification:** Every relevant change must be exercised with large real-world data, not only small fixtures.

### D-002 — Keep Codex app-server

- **Status:** Active
- **Decision:** Keep Codex `app-server` as the native Codex backend rather than reimplementing its protocol and lifecycle behavior.
- **Consequence:** The app owns a modular provider boundary, while Codex-specific authentication, sessions, tool events, and execution continue through `app-server`.
- **Verification:** Codex flows must be tested through the bundled/selected `app-server`, including startup, task loading, streaming, tools, and shutdown.

### D-003 — Keep one stable preview identity

- **Status:** Active
- **Decision:** Build and launch only `dist-preview/Onyx Preview.app`, with display name `Onyx Preview`, bundle ID `app.onyx.preview`, and signing identity `71E83D4C74C2320E54ABA79ABA79B2D75B8A1B8A`. Rebuild/relaunch through `scripts/run-preview.sh`.
- **Consequence:** Do not rename the preview app or vary its bundle identity; doing so causes repeated macOS privacy and local-network prompts.
- **Verification:** Before handoff, confirm the path, display name, bundle ID, signing identity, one running preview process, and its one owned `app-server` child.

### D-004 — The primary agent owns the preview lifecycle

- **Status:** Active
- **Decision:** Only the primary agent may launch or relaunch the development preview, and only through `scripts/run-preview.sh`. Subagents build, test, and render snapshots without opening an app bundle.
- **Consequence:** Never use `swift run Onyx`, `.build/*/Onyx`, `dist/Onyx.app`, test bundles, or renamed copies for UI verification. This avoids inconsistent second instances, stale window state, and repeated macOS permission prompts.
- **Verification:** Before each handoff, confirm that the only running Onyx executable is inside `dist-preview/Onyx Preview.app`.

### D-005 — Paginate provider history without weakening provider neutrality

- **Status:** Active
- **Decision:** Use native turn cursors when a runtime advertises them; otherwise keep the runtime contract unchanged and progressively reveal a bounded in-memory transcript.
- **Consequence:** Codex avoids decoding and projecting complete task history on open. OpenAI-compatible and future providers still get the same responsive transcript presentation without pretending they support a cursor API they do not have.
- **Verification:** Runtime capability/fallback tests and app-model pagination tests must both pass; unsupported provider operations must remain explicit.

### D-006 — Edit history through an explicit provider capability

- **Status:** Active
- **Decision:** Expose latest-message editing only when the active runtime advertises native history reversion; do not simulate it by duplicating context into a new turn.
- **Consequence:** Codex can safely remove a single-user-message turn suffix and resume from corrected input. Turns with multiple user messages remain read-only. Providers without equivalent semantics remain read-only until their adapter implements the capability explicitly; a selected Codex binary that rejects the method is downgraded for the runtime session.
- **Verification:** The native runtime request and model/UI eligibility regressions must pass, followed by running-build verification of the destructive-history warning and resubmission flow.

### D-007 — Browsing history does not change task recency

- **Status:** Active
- **Decision:** Preserve the provider's task `updatedAt` when reading or paginating history. Item timestamps are presentation metadata only; when persisted Codex items omit them, use the stable turn time for display rather than treating the read itself as new activity.
- **Consequence:** Opening an old task cannot bubble it above genuinely recent work. Only provider lifecycle updates and new user/agent activity may change sidebar and project ordering.
- **Verification:** Full-history, bounded-read, and bounded-resume regressions assert that server task recency survives projection while timestamp-free items inherit their turn time.

### D-008 — Optimize the primary macOS app before pursuing portability

- **Status:** Active
- **Decision:** Use a native Swift/SwiftUI application with targeted AppKit surfaces where they materially improve transcript, composer, and window responsiveness.
- **Consequence:** macOS interaction quality and native system behavior take priority over a cross-platform UI abstraction. Provider and runtime boundaries remain portable concepts, but the current presentation layer does not compromise for hypothetical platforms.
- **Verification:** Main interaction paths must meet the performance targets in this ledger on shipping macOS hardware and preserve standard keyboard, pointer, accessibility, and window behavior.

### D-009 — Provider capabilities require evidence

- **Status:** Active
- **Decision:** Adapt controls from model-catalog and transport evidence, treating missing metadata conservatively. Do not equate an endpoint’s `tools` flag with Onyx having implemented safe local tool execution and approvals for that adapter.
- **Consequence:** Modalities and request options can adapt automatically while product-level tools, task lifecycle, and approvals remain explicitly unavailable until their adapter implements and tests them.
- **Verification:** Every provider adapter must cover advertised, absent, stale, and unknown capability metadata, plus the user-facing unavailable states for product features it does not implement.

### D-010 — Model switching preserves task ownership

- **Status:** Active
- **Decision:** A new task can choose any configured provider/model pair. Once created, the task remains owned by that provider; the user may choose another model exposed by the same provider for a later turn and reset to the recorded task default.
- **Consequence:** Model selection stays convenient without silently converting or duplicating durable conversation history across providers. Cross-provider continuation remains a separate, explicit future feature.
- **Verification:** Provider/model picker, restored task binding, next-turn override, reset, usage ranking, and deletion-cleanup regressions must pass for each production adapter.

### D-011 — Global navigation paints before it prepares data

- **Status:** Active
- **Decision:** Global palettes must become visible and keyboard-ready before starting data preparation. Project indexing is shared per window, search results are bounded and published asynchronously, and stale work cannot replace newer input.
- **Consequence:** Keyboard navigation never waits for a complete filesystem scan or synchronous path ranking, and opening both Command-P and Files cannot start duplicate indexes for the same project.
- **Verification:** Hosted large-project coverage must prove the palette mounts promptly while indexing is suspended, plus cancellation, stale-result, result-bound, and shared-index regressions.
