import AppKit
import SwiftUI

final class WorktreeSidebarViewController: NSSplitViewController {
    /// Sidebar state remembered for the app session (M4). Persistence across
    /// restarts is a v1 non-goal, so this is deliberately in-memory: new
    /// windows inherit the collapsed state and width the sidebar last had in
    /// any window, and each window tracks its own from there.
    private static var sessionIsCollapsed = true
    private static var sessionWidth: CGFloat = 300

    private let ghostty: Ghostty.App
    private let terminalViewContainer: TerminalViewContainer
    let viewModel: WorktreeSidebarViewModel
    private var sidebarSplitViewItem: NSSplitViewItem?
    private var didApplySessionWidth = false

    init(
        ghostty: Ghostty.App,
        contentView terminalViewContainer: TerminalViewContainer,
        viewModel: WorktreeSidebarViewModel? = nil
    ) {
        self.ghostty = ghostty
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
        splitView.ghostty = ghostty
        splitView.terminalViewContainer = terminalViewContainer
        self.splitView = splitView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarViewController = WorktreeSidebarListViewController(ghostty: ghostty, viewModel: viewModel)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = Self.sessionIsCollapsed
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 420

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
            if !(sidebarSplitViewItem?.isCollapsed ?? true) {
                applySessionWidth()
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
        let willExpand = sidebarSplitViewItem.isCollapsed

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            sidebarSplitViewItem.animator().isCollapsed = !sidebarSplitViewItem.isCollapsed
        } completionHandler: {
            Self.sessionIsCollapsed = sidebarSplitViewItem.isCollapsed
            if willExpand {
                self.applySessionWidth()
            }
            self.view.invalidateIntrinsicContentSize()
        }
    }

    private func applySessionWidth() {
        guard let sidebarSplitViewItem else { return }
        let width = min(
            max(Self.sessionWidth, sidebarSplitViewItem.minimumThickness),
            sidebarSplitViewItem.maximumThickness
        )
        splitView.setPosition(width, ofDividerAt: 0)
    }
}

private final class WorktreeSidebarSplitView: NSSplitView {
    weak var ghostty: Ghostty.App?
    weak var terminalViewContainer: TerminalViewContainer?
    weak var sidebarItem: NSSplitViewItem?

    override var dividerColor: NSColor {
        guard let ghostty else { return super.dividerColor }
        return NSColor(ghostty.config.splitDividerColor)
    }

    override var intrinsicContentSize: NSSize {
        if sidebarItem?.isCollapsed ?? true,
           let terminalViewContainer {
            return terminalViewContainer.intrinsicContentSize
        }

        return super.intrinsicContentSize
    }
}

private final class WorktreeSidebarListViewController: NSViewController {
    private let ghostty: Ghostty.App
    private let viewModel: WorktreeSidebarViewModel

    init(ghostty: Ghostty.App, viewModel: WorktreeSidebarViewModel) {
        self.ghostty = ghostty
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let hostingView = NSHostingView(
            rootView: WorktreeSidebarList(ghostty: ghostty, viewModel: viewModel)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        view = hostingView
    }
}

private struct WorktreeSidebarList: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var viewModel: WorktreeSidebarViewModel

    private var backgroundColor: Color {
        ghostty.config.backgroundColor
    }

    private var foregroundColor: Color {
        ghostty.config.foregroundColor
    }

    private var secondaryColor: Color {
        foregroundColor.opacity(0.5)
    }

    private var terminalFont: Font {
        // TODO: Use the configured terminal font family for the sidebar.
        .system(size: 12, design: .monospaced)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterField

            if viewModel.isEmptyState {
                emptyState
            } else {
                list
                removeErrorSection
            }
        }
        .font(terminalFont)
        .foregroundStyle(foregroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Text(">")
                .foregroundStyle(secondaryColor)
            TextField("Filter", text: $viewModel.filterText)
                .textFieldStyle(.plain)
                .font(terminalFont)
                .foregroundStyle(foregroundColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(backgroundColor)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Not a git repository")
                .foregroundStyle(secondaryColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Filtered rows with live (active) worktrees grouped above inactive ones,
    /// preserving the pinned-main order within each group.
    private var orderedWorktrees: [Worktree] {
        WorktreeSidebar.activeFirst(
            viewModel.filteredWorktrees,
            activeWorktreePaths: viewModel.activeWorktreePaths)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(orderedWorktrees, id: \.path) { worktree in
                    WorktreeSidebarRowView(
                        worktree: worktree,
                        isActive: viewModel.isLive(worktree),
                        isSelected: worktree.path == viewModel.selectedWorktree?.path,
                        hasBell: viewModel.hasBell(worktree),
                        foregroundColor: foregroundColor,
                        secondaryColor: secondaryColor,
                        terminalFont: terminalFont
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
                            Button("Remove Worktree...", role: .destructive) {
                                confirmRemove(worktree)
                            }
                        }
                    }
                }
            }
        }
        .background(backgroundColor)
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
    /// Has a live workspace (session) in this window.
    let isActive: Bool
    /// Is the currently switched-to worktree (the `*` row).
    let isSelected: Bool
    /// Has a surface with an active bell in this workspace.
    let hasBell: Bool
    let foregroundColor: Color
    let secondaryColor: Color
    let terminalFont: Font

    private var title: String {
        WorktreeSidebar.displayName(for: worktree)
    }

    var body: some View {
        HStack(spacing: 6) {
            // `*` marks the currently switched-to worktree, like the current
            // branch in `git branch` output.
            Text(isSelected ? "*" : " ")
                .foregroundStyle(foregroundColor)
                .frame(width: 12, alignment: .leading)
            Text(title)
                // Truncate long branch names in the middle, with a tooltip
                // showing the full name.
                .truncationMode(.middle)
                .lineLimit(1)
                .fontWeight(worktree.isMain ? .semibold : .regular)
                // Live worktrees read at full strength; inactive (and detached)
                // ones dim, so the active group stands out from the rest.
                .foregroundStyle((isActive && !worktree.isDetached) ? foregroundColor : secondaryColor)
            Spacer(minLength: 0)
            if hasBell {
                Image(systemName: "bell.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Bell")
            }
        }
        .font(terminalFont)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? foregroundColor.opacity(0.15) : Color.clear)
        .help(title)
    }
}

extension TerminalController {
    func installWorktreeSidebar(around container: TerminalViewContainer, in window: NSWindow) {
        let controller = WorktreeSidebarViewController(ghostty: ghostty, contentView: container)
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
        setupWorktreeStatusPublisher()
        syncWorktreeStatus()
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
            self.syncWorktreeStatus()
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

    func showWorktreePicker() {
        guard let viewModel = worktreeSidebarViewController?.viewModel else { return }

        let present = {
            self.syncActiveWorktreePaths()
            self.commandPaletteIsShowing = false
            self.worktreePickerIsShowing = true
            _ = self.focusedSurface?.resignFirstResponder()
        }

        if viewModel.hasLoaded {
            present()
        } else {
            let cwd = worktreeSidebarCwd
            Task { @MainActor in
                await viewModel.refresh(cwd: cwd)
                present()
            }
        }
    }

    @IBAction func showWorktreePicker(_ sender: Any?) {
        showWorktreePicker()
    }
}
