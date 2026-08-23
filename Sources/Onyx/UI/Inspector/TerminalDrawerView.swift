import SwiftUI

enum TerminalDrawerLayout {
    static let minimumHeight: CGFloat = 150
    static let maximumHeight: CGFloat = 520
    static let accessibilityStep: CGFloat = 24

    static func clampedHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, minimumHeight), maximumHeight)
    }

    static func adjustedHeight(_ height: CGFloat, increasing: Bool) -> CGFloat {
        clampedHeight(height + (increasing ? accessibilityStep : -accessibilityStep))
    }

    static func accessibilityValue(for height: CGFloat) -> String {
        "\(Int(height.rounded())) points high"
    }
}

struct TerminalDrawerView: View {
    @ObservedObject var model: OnyxAppModel
    @ObservedObject var session: TerminalSessionModel
    @Binding var height: CGFloat

    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var followsOutput = true
    @State private var dragStartHeight: CGFloat?
    @FocusState private var isInputFocused: Bool
    @FocusState private var isSearchFocused: Bool

    private var selectedProjectPath: String? {
        model.selectedThread?.cwd ?? model.draftWorkspacePath
    }

    private var displayedOutput: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return session.output }
        return session.output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .joined(separator: "\n")
    }

    private var matchCount: Int {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        return session.output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .count { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                resizeHandle
                header
                Divider().overlay(Color.white.opacity(0.07))

                outputView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().overlay(Color.white.opacity(0.07))
                inputBar
            }
            .onAppear {
                if !session.isRunning, session.exitStatus == nil {
                    session.start(in: selectedProjectPath)
                }
                resizeTerminal(to: proxy.size)
                isInputFocused = true
            }
            .onChange(of: proxy.size) { _, newSize in
                resizeTerminal(to: newSize)
            }
        }
        .foregroundStyle(Color.white.opacity(0.72))
        .background(Color(red: 0.035, green: 0.037, blue: 0.045))
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: OnyxHitTarget.splitter)
            .overlay {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 34, height: 2)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                (hovering ? NSCursor.resizeUpDown : NSCursor.arrow).set()
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartHeight == nil { dragStartHeight = height }
                        let start = dragStartHeight ?? height
                        height = TerminalDrawerLayout.clampedHeight(start - value.translation.height)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .accessibilityLabel("Resize terminal")
            .accessibilityValue(TerminalDrawerLayout.accessibilityValue(for: height))
            .accessibilityHint("Drag vertically, or swipe up and down with VoiceOver, to change the height")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    height = TerminalDrawerLayout.adjustedHeight(height, increasing: true)
                case .decrement:
                    height = TerminalDrawerLayout.adjustedHeight(height, increasing: false)
                @unknown default:
                    break
                }
            }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isRunning ? "circle.fill" : "circle")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(session.isRunning ? Color.green.opacity(0.85) : Color.white.opacity(0.45))
                .accessibilityLabel(session.isRunning ? "Shell running" : "Shell stopped")
            Image(systemName: "terminal")
                .accessibilityHidden(true)
            Text("TERMINAL")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
            Text(session.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? model.projectName)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if isSearchVisible {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                    TextField("Filter output", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5))
                        .frame(width: 150)
                        .focused($isSearchFocused)
                        .accessibilityLabel("Filter terminal output")
                        .onExitCommand {
                            isSearchVisible = false
                            searchText = ""
                            isInputFocused = true
                        }
                    if !searchText.isEmpty {
                        Text("\(matchCount)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("\(matchCount) matching \(matchCount == 1 ? "line" : "lines")")
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Spacer(minLength: 6)

            Button {
                isSearchVisible.toggle()
                if isSearchVisible {
                    isSearchFocused = true
                } else {
                    searchText = ""
                    isInputFocused = true
                }
            } label: {
                Image(systemName: isSearchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .onyxHelp("Search terminal output")
            .accessibilityLabel(isSearchVisible ? "Hide terminal search" : "Search terminal output")
            .accessibilityHint(isSearchVisible ? "Clears the output filter" : "Shows and focuses the output filter")

            Button {
                followsOutput.toggle()
            } label: {
                Image(systemName: followsOutput ? "arrow.down.to.line.compact" : "pause")
                    .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .onyxHelp(followsOutput ? "Following new output" : "Resume following new output")
            .accessibilityLabel(followsOutput ? "Pause following terminal output" : "Resume following terminal output")
            .accessibilityValue(followsOutput ? "Following new output" : "Paused")

            Menu {
                Button("New Shell Here", systemImage: "arrow.clockwise") {
                    session.start(in: selectedProjectPath)
                    isInputFocused = true
                }
                Button("Clear Output", systemImage: "eraser", action: session.clear)
                    .disabled(session.output.isEmpty)
                if session.isRunning {
                    Divider()
                    Button("Interrupt Command", systemImage: "stop.fill", action: session.interrupt)
                    Button("End Shell", systemImage: "power", action: session.sendEndOfFile)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onyxHelp("Terminal actions")
            .accessibilityLabel("Terminal actions")

            Button {
                model.isBottomPanelVisible = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .onyxHelp("Hide terminal")
            .accessibilityLabel("Hide terminal")
            .accessibilityHint("Closes the terminal panel")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private var outputView: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if displayedOutput.isEmpty {
                        if session.isRunning {
                            Text("Shell ready. Type a command below.")
                                .foregroundStyle(Color.white.opacity(0.34))
                        } else {
                            Text("Shell is not running.")
                                .foregroundStyle(Color.white.opacity(0.34))
                        }
                    } else {
                        Text(displayedOutput)
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                    Color.clear.frame(height: 1).id("terminal-bottom")
                }
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: session.output.count) { _, _ in
                guard followsOutput, searchText.isEmpty else { return }
                reader.scrollTo("terminal-bottom", anchor: .bottom)
            }
            .onChange(of: searchText) { _, _ in
                reader.scrollTo("terminal-bottom", anchor: .bottom)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal output")
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("❯")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(OnyxTheme.electric)
                .accessibilityHidden(true)
            TextField(session.isRunning ? "Enter a shell command" : "Start a shell to enter commands", text: $session.input)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .focused($isInputFocused)
                .disabled(!session.isRunning)
                .onSubmit(session.sendInputLine)
                .accessibilityLabel("Shell command")
                .accessibilityHint(session.isRunning ? "Press Return to run the command" : "Start the shell before entering a command")

            if session.isRunning {
                Button(action: session.interrupt) {
                    Text("⌃C")
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .onyxHelp("Interrupt the current command")
                .accessibilityLabel("Interrupt command")
                .accessibilityHint("Sends Control-C to the shell")
            } else {
                Button {
                    session.start(in: selectedProjectPath)
                    isInputFocused = true
                } label: {
                    Text("Start")
                        .frame(minWidth: OnyxHitTarget.compact, minHeight: OnyxHitTarget.compact)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Start shell")
                .accessibilityHint("Starts a shell in the selected project")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.white.opacity(0.018))
    }

    private func resizeTerminal(to size: CGSize) {
        session.resize(
            columns: Int(max(size.width - 24, 140) / 7.1),
            rows: Int(max(size.height - 80, 60) / 15.0)
        )
    }
}
