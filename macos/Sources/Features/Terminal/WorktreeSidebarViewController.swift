import AppKit
import SwiftUI

final class WorktreeSidebarViewController: NSSplitViewController {
    /// Sidebar state remembered for the app session (M4). Persistence across
    /// restarts is a v1 non-goal, so this is deliberately in-memory: new
    /// windows inherit the collapsed state and width the sidebar last had in
    /// any window, and each window tracks its own from there.
    private static var sessionIsCollapsed = true
    private static var sessionWidth: CGFloat?

    private let terminalViewContainer: TerminalViewContainer
    let viewModel: WorktreeSidebarViewModel
    private var sidebarSplitViewItem: NSSplitViewItem?
    private var didApplySessionWidth = false

    init(
        contentView terminalViewContainer: TerminalViewContainer,
        viewModel: WorktreeSidebarViewModel? = nil
    ) {
        self.terminalViewContainer = terminalViewContainer
        // Construct the default view model in the init body (main-actor isolated)
        // rather than as a default argument, which Swift evaluates in a nonisolated
        // context and would reject for the @MainActor view model.
        self.viewModel = viewModel ?? WorktreeSidebarViewModel()
        super.init(nibName: nil, bundle: nil)

        // NSSplitViewController manages `splitView`, not `view`: items added
        // via addSplitViewItem land in `splitView`. Assigning a custom split
        // view to `view` in loadView leaves `splitView` as a detached default
        // NSSplitView, so the window's content view stays empty. The custom
        // subclass must be assigned to `splitView` before the view loads.
        let splitView = WorktreeSidebarSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.terminalViewContainer = terminalViewContainer
        self.splitView = splitView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarViewController = WorktreeSidebarListViewController(viewModel: viewModel)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = Self.sessionIsCollapsed
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 280

        let terminalViewController = NSViewController()
        terminalViewController.view = terminalViewContainer
        let terminalItem = NSSplitViewItem(viewController: terminalViewController)
        terminalItem.canCollapse = false

        addSplitViewItem(sidebarItem)
        addSplitViewItem(terminalItem)

        sidebarSplitViewItem = sidebarItem
        (splitView as? WorktreeSidebarSplitView)?.sidebarItem = sidebarItem

        // Track divider drags so new windows inherit the width. Notification
        // observation rather than the delegate method: NSSplitViewController
        // is its split view's delegate, and overriding delegate methods it
        // doesn't itself declare is brittle across SDKs.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView)
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        // Apply the session width once the view is in a window (divider
        // positions set before layout don't stick).
        if !didApplySessionWidth {
            didApplySessionWidth = true
            if let width = Self.sessionWidth,
               !(sidebarSplitViewItem?.isCollapsed ?? true) {
                splitView.setPosition(width, ofDividerAt: 0)
            }
        }
    }

    @objc private func splitViewDidResize(_ notification: Notification) {
        guard didApplySessionWidth else { return }
        guard let sidebarSplitViewItem, !sidebarSplitViewItem.isCollapsed else { return }

        // Ignore transient widths from the collapse animation; only widths a
        // visible sidebar can actually have are worth remembering.
        let width = sidebarSplitViewItem.viewController.view.frame.width
        guard width >= sidebarSplitViewItem.minimumThickness else { return }
        Self.sessionWidth = width
    }

    var isSidebarCollapsed: Bool {
        sidebarSplitViewItem?.isCollapsed ?? true
    }

    /// Reload the sidebar's worktrees for the given cwd. The cwd is sourced by
    /// the owning `TerminalController` from its first surface (see
    /// `TerminalController.refreshWorktreeSidebar`).
    func refresh(cwd: URL?) {
        Task { await viewModel.refresh(cwd: cwd) }
    }

    override func toggleSidebar(_ sender: Any?) {
        guard let sidebarSplitViewItem else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            sidebarSplitViewItem.animator().isCollapsed = !sidebarSplitViewItem.isCollapsed
        } completionHandler: {
            Self.sessionIsCollapsed = sidebarSplitViewItem.isCollapsed
            self.view.invalidateIntrinsicContentSize()
        }
    }
}

private final class WorktreeSidebarSplitView: NSSplitView {
    weak var terminalViewContainer: TerminalViewContainer?
    weak var sidebarItem: NSSplitViewItem?

    override var intrinsicContentSize: NSSize {
        if sidebarItem?.isCollapsed ?? true,
           let terminalViewContainer {
            return terminalViewContainer.intrinsicContentSize
        }

        return super.intrinsicContentSize
    }
}

private final class WorktreeSidebarListViewController: NSViewController {
    private let viewModel: WorktreeSidebarViewModel

    init(viewModel: WorktreeSidebarViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .sidebar
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active

        let hostingView = NSHostingView(
            rootView: WorktreeSidebarList(viewModel: viewModel)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
        ])

        view = visualEffectView
    }
}

private struct WorktreeSidebarList: View {
    @ObservedObject var viewModel: WorktreeSidebarViewModel

    @State private var isNamingNewWorktree = false
    @State private var newBranchName = ""
    @State private var newBaseRef = ""
    @FocusState private var newWorktreeFieldFocused: NewWorktreeField?

    private enum NewWorktreeField: Hashable {
        case branch
        case base
    }

    var body: some View {
        VStack(spacing: 0) {
            filterField

            if viewModel.isEmptyState {
                emptyState
            } else {
                list
                removeErrorSection
                newWorktreeSection
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $viewModel.filterText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Not a git repository")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "New worktree…" affordance pinned under the list (M4). Clicking it
    /// swaps in inline branch-name and base-ref fields: Return creates the
    /// worktree (`git worktree add`), Escape cancels. Failures render as a
    /// small inline message here — never an alert (M4 guide).
    private var newWorktreeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()

            if isNamingNewWorktree {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                        TextField("Branch name", text: $newBranchName)
                            .textFieldStyle(.plain)
                            .disabled(viewModel.isCreatingWorktree)
                            .focused($newWorktreeFieldFocused, equals: .branch)
                            .onAppear { newWorktreeFieldFocused = .branch }
                            .onSubmit(submitNewWorktree)
                            .onExitCommand(perform: cancelNewWorktree)
                        if viewModel.isCreatingWorktree {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    HStack(spacing: 6) {
                        Text("from")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        TextField(viewModel.defaultBaseBranch ?? "main HEAD", text: $newBaseRef)
                            .textFieldStyle(.plain)
                            .disabled(viewModel.isCreatingWorktree)
                            .focused($newWorktreeFieldFocused, equals: .base)
                            .onSubmit(submitNewWorktree)
                            .onExitCommand(perform: cancelNewWorktree)
                    }
                }
            } else {
                Button {
                    newBranchName = ""
                    newBaseRef = ""
                    isNamingNewWorktree = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text("New worktree…")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if let error = viewModel.createError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .help(error)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func submitNewWorktree() {
        let branch = newBranchName
        let base = newBaseRef
        Task {
            await viewModel.createWorktree(branch: branch, base: base)

            // Keep the field (and its text) around on failure so the name can
            // or base can be corrected next to the error message.
            if viewModel.createError == nil {
                isNamingNewWorktree = false
                newBranchName = ""
                newBaseRef = ""
            }
        }
    }

    private func cancelNewWorktree() {
        isNamingNewWorktree = false
        newBranchName = ""
        newBaseRef = ""
        viewModel.clearCreateError()
    }

    private var list: some View {
        List(viewModel.filteredWorktrees, id: \.path) { worktree in
            WorktreeSidebarRowView(
                worktree: worktree,
                isActive: viewModel.isActive(worktree)
            )
            // Whole row is clickable; the click switches workspaces (M3).
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.select(worktree)
            }
            .contextMenu {
                if viewModel.isActive(worktree) {
                    Button("Close Session") {
                        viewModel.deactivate(worktree)
                    }
                }

                if WorktreeSidebar.canRemove(worktree) {
                    Button("Remove Worktree…", role: .destructive) {
                        confirmRemove(worktree)
                    }
                }
            }
            .listRowBackground(
                viewModel.isActive(worktree)
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var removeErrorSection: some View {
        Group {
            if let error = viewModel.removeError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .help(error)

                    if let candidate = viewModel.forceRemoveCandidate {
                        Button {
                            confirmForceRemove(candidate)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                Text("Force remove")
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .disabled(viewModel.isRemovingWorktree)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    private func confirmRemove(_ worktree: Worktree) {
        guard confirmDestructive(
            messageText: "Remove Worktree?",
            informativeText: "This deletes the worktree checkout from disk. The branch is left intact.",
            confirmButtonTitle: "Remove Worktree"
        ) else {
            return
        }

        viewModel.delete(worktree)
    }

    private func confirmForceRemove(_ worktree: Worktree) {
        guard confirmDestructive(
            messageText: "Force Remove Worktree?",
            informativeText: "This deletes the worktree checkout even if it contains modified or untracked files. The branch is left intact.",
            confirmButtonTitle: "Force Remove"
        ) else {
            return
        }

        Task {
            await viewModel.removeWorktree(worktree, force: true)
        }
    }

    private func confirmDestructive(
        messageText: String,
        informativeText: String,
        confirmButtonTitle: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let response = alert.runModal()
        return [.alertFirstButtonReturn, .OK].contains(response)
    }
}

private struct WorktreeSidebarRowView: View {
    let worktree: Worktree
    let isActive: Bool

    private var title: String {
        WorktreeSidebar.displayName(for: worktree)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: worktree.isDetached ? "arrow.triangle.pull" : "arrow.triangle.branch")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            Text(title)
                // Truncate long branch names in the middle, with a tooltip
                // showing the full name.
                .truncationMode(.middle)
                .lineLimit(1)
                .fontWeight(worktree.isMain ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help(title)
    }
}

extension TerminalController {
    func installWorktreeSidebar(around container: TerminalViewContainer, in window: NSWindow) {
        let controller = WorktreeSidebarViewController(contentView: container)
        worktreeSidebarViewController = controller
        window.contentViewController = controller

        // Clicking a row switches to that worktree's workspace (M3).
        controller.viewModel.onSelect = { [weak self] worktree in
            self?.switchToWorktree(worktree)
        }
        controller.viewModel.onDeactivate = { [weak self] worktree in
            self?.deactivateWorktree(worktree)
        }
        controller.viewModel.onDelete = { [weak self] worktree in
            self?.deleteWorktree(worktree)
        }
    }

    /// The cwd to source worktrees from: the window's first surface's live pwd,
    /// falling back to the configured `working-directory` (bare commands report
    /// no pwd). Returns nil when neither is available.
    ///
    /// Internal (not private) because the goto_worktree keybind path in
    /// TerminalController.swift loads the sidebar data on demand from this cwd
    /// when the sidebar has never been opened.
    // worktree-sidebar:
    var worktreeSidebarCwd: URL? {
        let surface = surfaceTree.first
        return WorktreeSidebar.resolveCwd(
            pwd: surface?.pwd,
            configuredWorkingDirectory: ghostty.config.workingDirectory
        )
    }

    /// Reload the sidebar's worktrees from the current first-surface cwd.
    /// Refresh triggers: the window becoming key and the sidebar being toggled
    /// open (see `toggleWorktreeSidebar` / `windowDidBecomeKey`).
    // worktree-sidebar:
    func refreshWorktreeSidebar() {
        guard let viewModel = worktreeSidebarViewController?.viewModel else { return }
        let cwd = worktreeSidebarCwd
        Task { @MainActor in
            await viewModel.refresh(cwd: cwd)
            self.refreshActiveWorktreePaths()
        }
    }

    /// Semantic entry point for toggling the sidebar. This no-arg signature is kept
    /// aligned with the `toggle_worktree_sidebar` keybind stub in feat/wt-keybinds so
    /// that, at integration, the keybind path replaces that stub's body rather than
    /// silently adding a second no-op overload. A merge conflict here is intentional
    /// and correct — resolve it by keeping this real implementation.
    // worktree-sidebar:
    func toggleWorktreeSidebar() {
        guard let controller = worktreeSidebarViewController else { return }
        let willOpen = controller.isSidebarCollapsed
        controller.toggleSidebar(nil)

        // Refresh when the sidebar is being opened so it reflects the current
        // repository state without waiting for a window-focus change.
        if willOpen {
            refreshWorktreeSidebar()
        }
    }

    @IBAction func toggleWorktreeSidebar(_ sender: Any?) {
        toggleWorktreeSidebar()
    }
}
