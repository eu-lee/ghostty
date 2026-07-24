import AppKit

// worktree-sidebar: M3 — workspace switching. The active workspace's split
// tree is detached and retained (processes, scrollback, and layout survive)
// and the target worktree's tree is attached in its place. See
// WorktreeWorkspaceManager for the ownership model.

extension TerminalController {
    /// The workspace manager, created on first use.
    private func ensureWorktreeWorkspaces() -> WorktreeWorkspaceManager {
        if let worktreeWorkspaces { return worktreeWorkspaces }
        let manager = WorktreeWorkspaceManager()
        manager.onWorkspaceStateChange = { [weak self] in
            self?.syncWorktreeStatus()
        }
        worktreeWorkspaces = manager
        return manager
    }

    func syncActiveWorktreePaths(_ paths: Set<URL>? = nil) {
        syncWorktreeStatus(activePaths: paths)
    }

    func refreshActiveWorktreePaths() {
        syncWorktreeStatus()
    }

    func syncWorktreeStatus(activePaths paths: Set<URL>? = nil) {
        guard let viewModel = worktreeSidebarViewController?.viewModel else { return }

        // The attached worktree's key. The manager only ever stores *detached*
        // workspaces (never the attached tree — see its class doc), so the
        // controller must always contribute the attached one itself.
        let attachedKey = worktreeWorkspaces?.activePath
            ?? viewModel.selectedWorktree.map { WorktreeWorkspaceManager.key($0.path) }

        var active = paths ?? worktreeWorkspaces?.activeWorktreePaths ?? []
        // Insert it unconditionally, not just when the set is otherwise empty:
        // once main is pre-warmed as a detached workspace the manager already
        // reports a non-empty set, so a "seed only when empty" shortcut would
        // silently drop the attached worktree from the active list.
        if let attachedKey {
            active.insert(WorktreeWorkspaceManager.key(attachedKey))
        }
        viewModel.setActiveWorktreePaths(active)

        var bellWorktrees: Set<URL> = []
        if let attachedKey, surfaceTree.contains(where: { $0.bell }) {
            bellWorktrees.insert(WorktreeWorkspaceManager.key(attachedKey))
        }
        if let worktreeWorkspaces {
            bellWorktrees.formUnion(worktreeWorkspaces.detached.compactMap { key, workspace in
                workspace.tree.contains(where: { $0.bell }) ? key : nil
            })
        }
        viewModel.setBellWorktreePaths(bellWorktrees)
    }

    /// Ensure the main worktree has a live (detached) workspace so it is always
    /// an active, swappable session — regardless of which worktree the window
    /// opened into — landing on a warm shell when the user cycles or clicks to
    /// it. Idempotent, and a no-op when the window already sits on main.
    ///
    /// This creates a terminal *workspace* rooted at the existing main working
    /// tree (`main.path`, the repo root `git worktree list` reports first). It
    /// is emphatically **not** a new git worktree: no `git worktree add`, no
    /// `-worktrees/main` directory. Workspaces are live sessions this window
    /// holds; worktrees are checkouts on disk.
    func ensureMainWorktreeActive() {
        guard let viewModel = worktreeSidebarViewController?.viewModel else { return }
        guard let ghosttyApp = ghostty.app else { return }
        guard let main = viewModel.worktrees.first(where: { $0.isMain }) else { return }

        let manager = ensureWorktreeWorkspaces()
        let mainKey = WorktreeWorkspaceManager.key(main.path)

        // Nothing to do when main is the attached worktree, or already has a
        // detached workspace (keeps repeated refreshes from leaking shells).
        let attachedKey = manager.activePath
            ?? viewModel.selectedWorktree.map { WorktreeWorkspaceManager.key($0.path) }
        if attachedKey == mainKey { return }
        if manager.workspace(for: mainKey) != nil { return }

        // Create a warm, detached session rooted at the main worktree.
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = main.path.path
        let surfaceView = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
        manager.detach(.init(
            worktreePath: main.path,
            tree: SplitTree(view: surfaceView),
            lastFocusedSurface: surfaceView))

        syncWorktreeStatus()
    }

    func setupWorktreeStatusPublisher() {
        worktreeStatusCancellable = surfaceValuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncWorktreeStatus()
            }
    }

    /// True when any surface in this window — the attached tree or a detached
    /// worktree workspace — still needs close confirmation.
    var anySurfaceNeedsConfirmQuit: Bool {
        surfaceTree.contains(where: { $0.needsConfirmQuit }) ||
            (worktreeWorkspaces?.needsConfirmQuit ?? false)
    }

    /// Switch the window's content to the workspace bound to `worktree`.
    ///
    /// The active tree is detached and retained, and the target worktree's
    /// tree is attached — created lazily with a single surface whose
    /// working directory is the worktree path on first visit. Revisiting
    /// restores the exact layout and refocuses the last focused surface.
    /// No-op when the worktree is already active.
    func switchToWorktree(_ worktree: Worktree) {
        guard let viewModel = worktreeSidebarViewController?.viewModel else { return }
        guard let ghosttyApp = ghostty.app else { return }
        let manager = ensureWorktreeWorkspaces()
        let targetKey = WorktreeWorkspaceManager.key(worktree.path)

        // Resolve the binding of the currently attached tree. Before the
        // first switch the window's original tree has no binding yet; adopt
        // it under the worktree the sidebar considers active (the one
        // containing the window's cwd at the last refresh).
        let currentKey: URL? = manager.activePath
            ?? viewModel.selectedWorktree.map { WorktreeWorkspaceManager.key($0.path) }

        if currentKey == targetKey {
            // Already showing this worktree; just make sure the implicit
            // binding is adopted and the highlight agrees.
            manager.activePath = targetKey
            viewModel.selectedWorktree = worktree
            syncWorktreeStatus()
            return
        }

        guard let currentKey else {
            // TODO(worktree-sidebar): the attached tree resolves to no listed
            // worktree (cwd outside the repository's worktrees), so there is
            // nowhere to detach it to. Refuse to switch rather than silently
            // dropping live surfaces.
            Ghostty.logger.warning("worktree-sidebar: current tree has no worktree binding; switch aborted")
            syncActiveWorktreePaths()
            return
        }

        // Detach the active workspace, retaining its tree (and ptys).
        manager.detach(.init(
            worktreePath: currentKey,
            tree: surfaceTree,
            lastFocusedSurface: focusedSurface))

        // Undo entries (e.g. "Close Terminal") capture whole surface trees.
        // Performing one after a switch would attach a tree belonging to a
        // different workspace and release the attached one, killing its
        // processes. Invalidate them rather than risk that.
        undoManager?.removeAllActions(withTarget: self)

        // Attach the target workspace, creating it lazily on first visit.
        let focusTarget: Ghostty.SurfaceView?
        if let existing = manager.removeForAttach(targetKey) {
            surfaceTree = existing.tree
            focusTarget = existing.lastFocusedSurface ?? existing.tree.root?.leftmostLeaf()
        } else {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = worktree.path.path
            let surfaceView = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
            surfaceTree = SplitTree(view: surfaceView)
            focusTarget = surfaceView
        }

        manager.activePath = targetKey
        viewModel.selectedWorktree = worktree
        syncWorktreeStatus()

        if let focusTarget {
            focusedSurface = focusTarget
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusTarget)
            }
        }
    }

    /// Cycle to the next/previous active worktree in sidebar order, wrapping.
    /// Backs the `goto_worktree` keybind (see `gotoWorktree`).
    func cycleWorktree(_ direction: Ghostty.WorktreeFocusDirection, viewModel: WorktreeSidebarViewModel) {
        let current = worktreeWorkspaces?.activePath ?? viewModel.selectedWorktree?.path
        syncActiveWorktreePaths()
        let target = WorktreeSidebar.cycleTarget(
            in: viewModel.worktrees,
            activeWorktreePaths: viewModel.activeWorktreePaths,
            from: current,
            offset: direction == .next ? 1 : -1)
        guard let target else { return }
        switchToWorktree(target)
    }

    /// Attach a detached workspace after the active workspace's last surface
    /// closed, instead of closing the window (which would tear down every
    /// other workspace's live processes). See `replaceSurfaceTree`.
    func attachFallbackWorkspace(_ workspace: WorktreeWorkspaceManager.Workspace) {
        guard let manager = worktreeWorkspaces else { return }
        let key = WorktreeWorkspaceManager.key(workspace.worktreePath)
        _ = manager.removeForAttach(key)

        // Same tree-capture hazard as in switchToWorktree.
        undoManager?.removeAllActions(withTarget: self)

        surfaceTree = workspace.tree
        manager.activePath = key

        // Move the sidebar highlight to the fallback's worktree when it is
        // still listed (it may have been deleted on disk since the refresh).
        if let viewModel = worktreeSidebarViewController?.viewModel {
            viewModel.selectedWorktree = viewModel.worktrees
                .first { WorktreeWorkspaceManager.key($0.path) == key }
        }
        syncWorktreeStatus()

        if let focusTarget = workspace.lastFocusedSurface ?? workspace.tree.root?.leftmostLeaf() {
            focusedSurface = focusTarget
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusTarget)
            }
        }
    }

    func deactivateWorktree(_ worktree: Worktree) {
        Task { @MainActor in
            _ = await deactivateWorktreeSession(worktree)
        }
    }

    func closeCurrentWorktreeSession() {
        // Act on the selected worktree regardless of whether the sidebar is
        // showing — requiring it expanded made the keybind feel dead (see the
        // nav actions, which have no such gate).
        guard let controller = worktreeSidebarViewController else { return }
        guard let worktree = controller.viewModel.selectedWorktree else { return }
        deactivateWorktree(worktree)
    }

    func deleteWorktree(_ worktree: Worktree) {
        Task { @MainActor in
            await deleteWorktreeAfterConfirmation(worktree)
        }
    }

    func removeCurrentWorktree() {
        // As with close, don't gate on the sidebar being expanded. The removal
        // confirmation dialog names the worktree, so this stays safe even when
        // the sidebar is hidden.
        guard let controller = worktreeSidebarViewController else { return }
        guard let worktree = controller.viewModel.selectedWorktree else { return }
        deleteWorktree(worktree)
    }

    @discardableResult
    private func deactivateWorktreeSession(_ worktree: Worktree) async -> Bool {
        guard let viewModel = worktreeSidebarViewController?.viewModel else { return false }

        // Main is the permanent anchor — it's never closeable. Deactivating it
        // is always a no-op, whether it's the session on screen or a background
        // workspace, so the window can never be left without a home to fall
        // back to. (The sidebar also withholds the Close Session affordance for
        // main; this guards the programmatic path.)
        guard !worktree.isMain else { return false }

        let manager = ensureWorktreeWorkspaces()
        let key = WorktreeWorkspaceManager.key(worktree.path)
        let activeKey = manager.activePath
            ?? viewModel.selectedWorktree.map { WorktreeWorkspaceManager.key($0.path) }

        // Background session: this worktree has a detached workspace, so it's
        // live but not the one on screen. Tear it down in place — the view
        // stays on whatever is currently attached. This is how you close a
        // session you aren't a part of.
        if let workspace = manager.workspace(for: key) {
            guard await confirmWorkspaceTeardownIfNeeded(workspace.tree) else { return false }
            manager.removeDetached(for: key)
            syncWorktreeStatus()
            return true
        }

        // No detached workspace, so if this worktree is live at all it's the
        // one we're currently viewing (its tree is the attached surfaceTree).
        guard activeKey == key else {
            syncWorktreeStatus()
            return false
        }

        // Closing the session on screen: fall back to main — always. Move there
        // first so we're not standing on the tree we're about to destroy;
        // switching detaches the closing session, making teardown identical to
        // the background case above.
        guard let main = viewModel.worktrees.first(where: \.isMain) else {
            syncWorktreeStatus()
            return false
        }

        guard await confirmWorkspaceTeardownIfNeeded(surfaceTree) else { return false }

        switchToWorktree(main)
        guard manager.workspace(for: key) != nil else {
            syncWorktreeStatus()
            return false
        }

        manager.removeDetached(for: key)
        syncWorktreeStatus()
        return true
    }

    private func deleteWorktreeAfterConfirmation(_ worktree: Worktree) async {
        guard WorktreeSidebar.canRemove(worktree) else { return }
        guard let viewModel = worktreeSidebarViewController?.viewModel else { return }

        syncActiveWorktreePaths()
        if viewModel.isActive(worktree) {
            let deactivated = await deactivateWorktreeSession(worktree)
            syncActiveWorktreePaths()
            if !deactivated, viewModel.isActive(worktree) {
                return
            }

            await viewModel.refresh(cwd: worktreeSidebarCwd)
            syncActiveWorktreePaths()
        }

        await viewModel.removeWorktree(worktree)
        syncActiveWorktreePaths()
    }

    private func confirmWorkspaceTeardownIfNeeded(_ tree: SplitTree<Ghostty.SurfaceView>) async -> Bool {
        guard tree.contains(where: { $0.needsConfirmQuit }) else { return true }

        guard let response = await confirmCloseAsync(
            messageText: "Close Session?",
            informativeText: "This worktree session still has a running process. If you close the session the process will be killed.",
            confirmButtonTitle: "Close Session"
        ) else {
            return false
        }

        return [.alertFirstButtonReturn, .OK].contains(response)
    }
}
