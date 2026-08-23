import SwiftUI

/// A window-local project file palette. The surface mounts and focuses before
/// `loadRoot` starts, so opening it never waits for a filesystem walk.
struct ProjectQuickOpenView: View {
    @ObservedObject var navigator: ProjectSourceNavigatorModel
    let projectPath: String?
    let focusRequest: Int
    let chooseProject: () -> Void
    let dismiss: () -> Void
    let open: (ProjectSourceFile) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @State private var selectedIndex = 0
    @State private var priorInspectorQuery = ""
    @State private var presentedProjectPath: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)

            VStack(spacing: 0) {
                searchField

                Divider().overlay(OnyxTheme.divider)

                resultSurface
                    .frame(minHeight: 176, maxHeight: 340, alignment: .top)
            }
            .frame(maxWidth: 590)
            .background(OnyxTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
            }
            .shadow(color: Color.black.opacity(0.28), radius: 24, y: 10)
            .padding(.horizontal, 28)
            .padding(.bottom, 120)
            .transition(reduceMotion ? .identity : .opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quick open project file")
            .accessibilityIdentifier("quick-open-palette")
        }
        .onAppear {
            priorInspectorQuery = navigator.query
            presentedProjectPath = projectPath
            navigator.query = ""
            // Install and focus the native field editor before starting any
            // uncached filesystem work. Both hops are serviced by AppKit's
            // main run loop, so presentation never waits for the task executor.
            DispatchQueue.main.async {
                isSearchFocused = true
                DispatchQueue.main.async {
                    Task { await navigator.loadRootPreservingQuery(path: projectPath) }
                }
            }
        }
        .onChange(of: focusRequest) { _, _ in
            isSearchFocused = true
        }
        .onChange(of: projectPath) { _, path in
            Task { await navigator.loadRootPreservingQuery(path: path) }
        }
        .onExitCommand(perform: cancel)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            TextField("Quick Open", text: $navigator.query)
                .textFieldStyle(.plain)
                .font(.system(size: OnyxTypography.paneTitle))
                .focused($isSearchFocused)
                .onSubmit(openSelection)
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    cancel()
                    return .handled
                }
                .accessibilityIdentifier("quick-open-field")

            if navigator.isSearching || isIndexing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(isIndexing ? "Indexing project files" : "Finding matching files")
            } else if !navigator.query.isEmpty {
                Button {
                    navigator.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onyxHelp("Clear file search")
                .accessibilityLabel("Clear file search")
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, 10)
        .frame(height: 52)
        .onChange(of: navigator.query) { _, _ in selectedIndex = 0 }
        .onChange(of: navigator.searchResults) { _, results in
            selectedIndex = min(selectedIndex, max(0, results.count - 1))
        }
    }

    @ViewBuilder
    private var resultSurface: some View {
        switch navigator.indexState {
        case .noProject:
            if projectPath == nil {
                quietState(
                    icon: "folder.badge.questionmark",
                    title: "Choose a project first",
                    detail: "Quick Open searches files in the current project."
                ) {
                    Button("Choose Project…") {
                        cancel()
                        chooseProject()
                    }
                    .controlSize(.small)
                }
            } else {
                preparingState
            }
        case .loading:
            preparingState
        case let .failed(message):
            quietState(
                icon: "exclamationmark.triangle",
                title: "Could not search this project",
                detail: message
            ) {
                Button("Try Again") {
                    Task { await navigator.reloadRoot(path: projectPath) }
                }
                .controlSize(.small)
            }
        case .loaded:
            loadedResults
        }
    }

    @ViewBuilder
    private var loadedResults: some View {
        let trimmedQuery = navigator.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            quietState(
                icon: "command",
                title: "Type a file name or path",
                detail: "Use the arrow keys to choose, then press Return to open."
            )
        } else if navigator.isSearching {
            quietState(
                icon: "magnifyingglass",
                title: "Finding matches",
                detail: "Typing stays available while results are ranked."
            )
        } else if navigator.searchResults.isEmpty {
            quietState(
                icon: "doc.text.magnifyingglass",
                title: "No matching files",
                detail: "Try part of a filename or folder path."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(navigator.searchResults.enumerated()), id: \.element.id) { index, file in
                            resultRow(file, index: index)
                                .id(file.id)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selectedIndex) { _, index in
                    guard navigator.searchResults.indices.contains(index) else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.08)) {
                        proxy.scrollTo(navigator.searchResults[index].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var preparingState: some View {
        quietState(
            icon: "folder",
            title: "Preparing project files",
            detail: "You can type now; matches will appear when the bounded index is ready."
        )
    }

    private func resultRow(_ file: ProjectSourceFile, index: Int) -> some View {
        Button {
            openResult(file)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .frame(width: 15)
                    .foregroundStyle(index == selectedIndex ? OnyxTheme.electric : Color.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if file.relativePath != file.name {
                        Text(file.relativePath)
                            .font(.system(size: OnyxTypography.metadata, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)
                if index == selectedIndex {
                    Text("↩")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
            .background {
                if index == selectedIndex {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(file.relativePath)")
        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
    }

    private func quietState<Actions: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 22)
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: OnyxTypography.navigation, weight: .medium))
            Text(detail)
                .font(.system(size: OnyxTypography.secondary))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 370)
            actions()
            Spacer(minLength: 22)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func quietState(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        quietState(icon: icon, title: title, detail: detail) { EmptyView() }
    }

    private var isIndexing: Bool {
        if case .loading = navigator.indexState { return true }
        return false
    }

    private func moveSelection(by offset: Int) {
        guard !navigator.searchResults.isEmpty else { return }
        selectedIndex = min(
            max(0, selectedIndex + offset),
            navigator.searchResults.count - 1
        )
    }

    private func openSelection() {
        guard navigator.searchResults.indices.contains(selectedIndex) else { return }
        openResult(navigator.searchResults[selectedIndex])
    }

    private func cancel() {
        restoreInspectorQuery()
        dismiss()
    }

    private func openResult(_ file: ProjectSourceFile) {
        restoreInspectorQuery()
        open(file)
    }

    private func restoreInspectorQuery() {
        // The Files inspector and palette intentionally share one index, but
        // opening and cancelling the palette must not destroy the inspector's
        // visible search. A project switch invalidates that old query.
        navigator.query = projectPath == presentedProjectPath ? priorInspectorQuery : ""
    }
}

@MainActor
enum ProjectQuickOpenWorkspaceRouting {
    @discardableResult
    static func open(
        _ file: ProjectSourceFile,
        model: OnyxAppModel,
        navigator: ProjectSourceNavigatorModel
    ) -> Task<Void, Never> {
        model.inspectorTab = .files
        model.isInspectorVisible = true
        return Task { await navigator.preview(file) }
    }
}
