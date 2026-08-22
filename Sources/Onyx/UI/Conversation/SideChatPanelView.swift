import SwiftUI

/// A lightweight trailing panel for an ephemeral fork of the selected task.
/// It intentionally has its own transcript and composer bindings; the main
/// conversation view never renders this panel's items.
struct SideChatPanelView: View {
    @ObservedObject var model: OnyxAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textHeight: CGFloat = 42

    private var canSend: Bool {
        model.canSendSideChat
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(OnyxTheme.divider)

            ZStack {
                NativeTranscriptView(
                    items: model.sideChatTranscriptSnapshot.items,
                    isAwaitingResponse: model.isSideChatTurnRunning
                        && model.sideChatInteraction == nil,
                    workingLabel: "Working on a response…",
                    revision: model.sideChatTranscriptSnapshot.revision,
                    changeHint: model.sideChatTranscriptSnapshot.changeHint
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.isSideChatLoading {
                    VStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Forking this task's context…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .onyxPanel(radius: 12)
                } else if model.sideChatTimeline.isEmpty, model.sideChatError == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(OnyxTheme.iris)
                        Text("Ask a quick follow-up")
                            .font(.system(size: 14, weight: .semibold))
                        Text("This private branch disappears when you close it.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 240)
                }
            }

            if let interaction = model.sideChatInteraction {
                UserInteractionView(model: model, interaction: interaction)
                    .id(interaction)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }

            if let error = model.sideChatError {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(OnyxTheme.destructive)
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(OnyxTheme.destructive.opacity(0.06))
            }

            composer
        }
        .frame(minWidth: 300, idealWidth: 380, maxWidth: 460)
        .background(OnyxTheme.chrome)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(OnyxTheme.border)
                .frame(width: OnyxTheme.hairline)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 14, x: -4, y: 0)
        .transition(
            reduceMotion
                ? .identity
                : .move(edge: .trailing).combined(with: .opacity)
        )
        .zIndex(2)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(OnyxTheme.iris)
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 1) {
                Text("Side chat")
                    .font(.system(size: 13, weight: .semibold))
                Text(parentTitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button(action: model.closeSideChat) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .onyxHelp("Close side chat")
            .accessibilityLabel("Close side chat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(OnyxTheme.chrome)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            NativeComposerTextView(
                text: $model.sideChatComposerText,
                measuredHeight: $textHeight,
                isEnabled: model.canRunAgent && !model.isSideChatLoading,
                onSubmit: {
                    if canSend { model.sendSideChat() }
                },
                onPasteImages: { _ in }
            )
            .frame(height: textHeight)
            .padding(.horizontal, 10)
            .padding(.top, 7)

            HStack(spacing: 8) {
                Text("\(model.sideChatModelName) · \(model.sideChatReasoningEffortName)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if model.isSideChatTurnRunning {
                    Button(action: model.interruptSideChat) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Color.primary)
                            .foregroundStyle(OnyxTheme.canvas)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onyxHelp("Stop side chat")
                    .accessibilityLabel("Stop side chat")
                } else {
                    Button(action: model.sendSideChat) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 27, height: 27)
                            .background(
                                canSend
                                    ? AnyShapeStyle(OnyxTheme.accentGradient)
                                    : AnyShapeStyle(Color.secondary.opacity(0.16))
                            )
                            .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.58))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .onyxHelp("Send side chat message (Return)")
                    .accessibilityLabel("Send side chat message")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(OnyxTheme.raisedSurface)
    }

    private var parentTitle: String {
        guard let parentID = model.sideChatParentThreadID else { return "Current task" }
        return model.threads.first(where: { $0.id == parentID })?.title ?? "Current task"
    }
}
