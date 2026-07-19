import Combine
import Foundation

#if os(macOS)

/// Observable view model backing the worktree sidebar.
///
/// The sidebar shell (M1) rendered from a static `WorktreeSidebarDataSource`.
/// This model replaces that seam with reactive state fed by the git data
/// layer (`GitWorktreeModel`): an async `refresh(cwd:)` loads the worktrees
/// for whatever repository the given cwd belongs to, and the SwiftUI list
/// observes the published state so async loads update the UI.
///
/// Workspace switching is out of scope for M2. This model only *exposes* the
/// active/selected worktree (`selectedWorktree`) as observable, driveable
/// state so the M3 switching layer can both read and set it.
@MainActor
final class WorktreeSidebarViewModel: ObservableObject {
    /// All worktrees for the current repository, main pinned first (the model
    /// already returns them in that order — we preserve it).
    @Published private(set) var worktrees: [Worktree] = []

    /// Local branches that do not currently have a linked worktree.
    @Published private(set) var branchesWithoutWorktree: [String] = []

    /// The active/selected worktree. Initialized on each refresh to the
    /// worktree containing the source cwd (the "active" one, highlighted in the
    /// list). Exposed as settable observable state so the M3 switching layer
    /// can read the current selection and drive navigation to a new one.
    @Published var selectedWorktree: Worktree?

    /// Whether a refresh has completed at least once. Used to distinguish the
    /// initial (pre-load) state from a genuinely empty / non-repo result.
    @Published private(set) var hasLoaded: Bool = false

    /// True while a `git worktree add` is running. Prevents concurrent
    /// create/open operations from the palette.
    @Published private(set) var isCreatingWorktree: Bool = false

    /// True while `git worktree remove` is running. Prevents duplicate
    /// removal attempts from repeated menu/button actions.
    @Published private(set) var isRemovingWorktree: Bool = false

    /// Canonical paths for worktrees that currently have a live workspace in
    /// this window: the attached tree and any detached workspaces.
    @Published private(set) var activeWorktreePaths: Set<URL> = []

    /// The last worktree-removal failure, rendered inline near the list.
    @Published private(set) var removeError: String?

    /// Worktree whose last removal failed with a dirty/untracked-tree style
    /// git error, making a force retry appropriate.
    @Published private(set) var forceRemoveCandidate: Worktree?

    /// The last worktree create/open failure, as a short user-facing message
    /// rendered inline in the palette (never an alert). Nil when the last
    /// operation succeeded or the user dismissed the message.
    @Published private(set) var createError: String?

    /// Canonical paths for worktrees with at least one surface whose bell is
    /// active.
    @Published private(set) var bellWorktreePaths: Set<URL> = []

    /// Invoked when the user picks a worktree row. The M3 switching layer
    /// (TerminalController) wires this to the workspace switch; selection
    /// state is then updated by the switcher, so the highlight tracks the
    /// active workspace rather than the click.
    var onSelect: ((Worktree) -> Void)?
    var onDeactivate: ((Worktree) -> Void)?
    var onDelete: ((Worktree) -> Void)?

    private let model: GitWorktreeModel

    /// The working directory the sidebar was last refreshed against — i.e. the
    /// pwd of the surface it was activated from. Shown in the sidebar header.
    @Published private(set) var currentCwd: URL?

    init(model: GitWorktreeModel = GitWorktreeModel()) {
        self.model = model
    }

    /// True once a load has completed and the source cwd is not a git
    /// repository (or there is no cwd at all) — drives the "Not a git
    /// repository" empty state.
    var isEmptyState: Bool {
        hasLoaded && worktrees.isEmpty
    }

    /// Default base ref for creating a new worktree. v1 uses the currently
    /// active workspace branch; changing that policy later should only touch
    /// this property.
    var defaultBaseBranch: String? {
        selectedWorktree?.branch
    }

    /// Whether `worktree` already has a live workspace in this window.
    func isLive(_ worktree: Worktree) -> Bool {
        activeWorktreePaths.contains(WorktreeWorkspaceManager.key(worktree.path))
    }

    /// Load worktrees for the repository containing `cwd`. A nil cwd (e.g. a
    /// window whose first surface reports no pwd and has no configured
    /// working-directory) resolves to the empty state.
    func refresh(cwd: URL?) async {
        currentCwd = cwd

        let loaded: [Worktree]
        let localBranches: [String]
        if let cwd {
            loaded = await model.worktrees(forCwd: cwd)
            localBranches = await model.localBranches(forCwd: cwd)
        } else {
            loaded = []
            localBranches = []
        }

        worktrees = loaded
        branchesWithoutWorktree = WorktreeSidebar.branchesWithoutWorktree(
            localBranches: localBranches,
            worktrees: loaded)
        hasLoaded = true

        // Preserve an existing selection if it still exists after the refresh;
        // otherwise default to the active worktree (the one containing cwd).
        //
        // TODO(worktree-sidebar): a worktree deleted on disk while its
        // workspace is open disappears from this list, orphaning the (still
        // usable) workspace. Mark such rows as missing instead of dropping
        // them so the user can still reach and close that workspace.
        if let selectedWorktree,
           loaded.contains(where: { $0.path == selectedWorktree.path }) {
            // Keep the current selection.
        } else {
            selectedWorktree = WorktreeSidebar.activeWorktree(in: loaded, cwd: cwd)
        }

        if activeWorktreePaths.isEmpty, let selectedWorktree {
            activeWorktreePaths = [WorktreeWorkspaceManager.key(selectedWorktree.path)]
        }
    }

    func setActiveWorktreePaths(_ paths: Set<URL>) {
        activeWorktreePaths = Set(paths.map { WorktreeWorkspaceManager.key($0) })
    }

    func setBellWorktreePaths(_ paths: Set<URL>) {
        bellWorktreePaths = Set(paths.map { WorktreeWorkspaceManager.key($0) })
    }

    /// Forward a row click to the switching layer (see `onSelect`).
    func select(_ worktree: Worktree) {
        onSelect?(worktree)
    }

    func deactivate(_ worktree: Worktree) {
        onDeactivate?(worktree)
    }

    func delete(_ worktree: Worktree) {
        onDelete?(worktree)
    }

    /// Create a worktree (and branch) named `branch` via `git worktree add`,
    /// then refresh the list and open the new worktree (M4). Failures land in
    /// `createError` for the palette to render inline.
    func createWorktree(branch: String, base: String? = nil) async {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreatingWorktree else { return }
        guard let cwd = currentCwd else {
            createError = "No working directory"
            return
        }

        let trimmedBase = base?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBase: String?
        if let trimmedBase, !trimmedBase.isEmpty {
            resolvedBase = trimmedBase
        } else {
            resolvedBase = defaultBaseBranch
        }

        isCreatingWorktree = true
        createError = nil
        defer { isCreatingWorktree = false }

        switch await model.createWorktree(branch: trimmed, from: resolvedBase, forCwd: cwd) {
        case .success(let path):
            await refresh(cwd: cwd)

            // Open the new worktree. Match by canonical path: git may list
            // the created worktree under a different (canonical) spelling
            // than the destination path we asked for.
            let created = WorktreeSidebar.canonicalPath(path)
            if let worktree = worktrees.first(where: {
                WorktreeSidebar.canonicalPath($0.path) == created
            }) {
                select(worktree)
            }
        case .failure(let error):
            createError = error.message
        }
    }

    /// Add a worktree for an existing local branch, then refresh and open it.
    /// Uses the same inline `createError` surface as branch creation because
    /// both operations are `git worktree add` flows from the palette.
    func openExistingBranch(_ branch: String) async {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreatingWorktree else { return }
        guard let cwd = currentCwd else {
            createError = "No working directory"
            return
        }

        isCreatingWorktree = true
        createError = nil
        defer { isCreatingWorktree = false }

        switch await model.addWorktree(forExistingBranch: trimmed, forCwd: cwd) {
        case .success(let path):
            await refresh(cwd: cwd)

            let created = WorktreeSidebar.canonicalPath(path)
            if let worktree = worktrees.first(where: {
                WorktreeSidebar.canonicalPath($0.path) == created
            }) {
                select(worktree)
            }
        case .failure(let error):
            createError = error.message
        }
    }

    /// Clear a pending creation error after the palette is reopened.
    func clearCreateError() {
        createError = nil
    }

    func updateActiveWorktreePaths(_ paths: Set<URL>) {
        activeWorktreePaths = Set(paths.map { WorktreeWorkspaceManager.key($0) })
    }

    func updateBellWorktreePaths(_ paths: Set<URL>) {
        bellWorktreePaths = Set(paths.map { WorktreeWorkspaceManager.key($0) })
    }

    func isActive(_ worktree: Worktree) -> Bool {
        WorktreeSidebar.isActive(worktree, in: activeWorktreePaths)
    }

    func hasBell(_ worktree: Worktree) -> Bool {
        WorktreeSidebar.hasBell(worktree, in: bellWorktreePaths)
    }

    /// Remove a linked worktree from disk, then refresh the list. Workspace
    /// teardown is owned by the controller before this is called.
    func removeWorktree(_ worktree: Worktree, force: Bool = false) async {
        guard WorktreeSidebar.canRemove(worktree), !isRemovingWorktree else { return }
        guard let cwd = currentCwd else {
            removeError = "No working directory"
            forceRemoveCandidate = nil
            return
        }

        isRemovingWorktree = true
        removeError = nil
        forceRemoveCandidate = nil
        defer { isRemovingWorktree = false }

        switch await model.removeWorktree(path: worktree.path, force: force, forCwd: cwd) {
        case .success:
            await refresh(cwd: cwd)
        case .failure(let error):
            let message = error.message
            removeError = message
            forceRemoveCandidate = WorktreeSidebar.canForceRemove(afterGitMessage: message) ? worktree : nil
        }
    }

    func clearRemoveError() {
        removeError = nil
        forceRemoveCandidate = nil
    }
}

/// Pure, side-effect-free helpers for the sidebar. Kept free of `@MainActor`
/// and async so the presentation logic (active resolution, filtering, display
/// naming, cwd resolution) is trivially unit-testable.
enum WorktreeSidebar {
    /// Display name for a worktree row: the branch name, falling back to the
    /// directory name for a detached HEAD (which has no branch).
    static func displayName(for worktree: Worktree) -> String {
        if let branch = worktree.branch, !branch.isEmpty {
            return branch
        }
        return worktree.path.lastPathComponent
    }

    static func canRemove(_ worktree: Worktree) -> Bool {
        !worktree.isMain
    }

    static func isActive(_ worktree: Worktree, in active: Set<URL>) -> Bool {
        active.contains(URL(fileURLWithPath: canonicalPath(worktree.path)))
    }

    static func hasBell(_ worktree: Worktree, in bellWorktreePaths: Set<URL>) -> Bool {
        bellWorktreePaths.contains(URL(fileURLWithPath: canonicalPath(worktree.path)))
    }

    static func canForceRemove(afterGitMessage message: String) -> Bool {
        let lowercased = message.lowercased()
        guard lowercased.contains("force") else { return false }

        return lowercased.contains("modified") ||
            lowercased.contains("untracked") ||
            lowercased.contains("dirty")
    }

    /// Canonicalize a file URL's path for comparison: resolves symlinks and
    /// filesystem case via the filesystem itself. The default macOS filesystem
    /// is case-insensitive, so a user-typed `cd ~/documents/...` makes the
    /// shell report a differently-cased pwd than git's canonical worktree
    /// paths — a plain string comparison then never matches. Falls back to
    /// the standardized path when the path doesn't exist on disk (which also
    /// keeps the pure-path unit tests deterministic).
    static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        if let canonical = try? standardized.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return canonical
        }
        return standardized.path
    }

    /// The worktree containing `cwd`, if any. Uses a longest-path-prefix match
    /// so that a cwd inside a linked worktree resolves to that worktree rather
    /// than to the (ancestor) main repository root.
    static func activeWorktree(in worktrees: [Worktree], cwd: URL?) -> Worktree? {
        guard let cwd else { return nil }
        let target = canonicalPath(cwd)

        return worktrees
            .filter { worktree in
                let base = canonicalPath(worktree.path)
                return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
            }
            .max { canonicalPath($0.path).count < canonicalPath($1.path).count }
    }

    /// Main pinned to the very top, then live workspaces, then the rest —
    /// preserving the input order within each group. Main stays anchored at the
    /// top no matter which worktree is currently attached, so switching away
    /// from it never shuffles it down the list.
    static func activeFirst(_ worktrees: [Worktree], activeWorktreePaths: Set<URL>) -> [Worktree] {
        let keyed = worktrees.map { (worktree: $0, isActive: activeWorktreePaths.contains(WorktreeWorkspaceManager.key($0.path))) }
        let main = keyed.filter { $0.worktree.isMain }.map { $0.worktree }
        let rest = keyed.filter { !$0.worktree.isMain }
        return main +
            rest.filter { $0.isActive }.map { $0.worktree } +
            rest.filter { !$0.isActive }.map { $0.worktree }
    }

    static func branchesWithoutWorktree(localBranches: [String], worktrees: [Worktree]) -> [String] {
        let branchesWithWorktree = Set(worktrees.compactMap(\.branch))
        return localBranches.filter { !branchesWithWorktree.contains($0) }
    }

    /// The worktree `offset` steps away from `current` in sidebar order,
    /// wrapping around either end, but only among worktrees that already have
    /// live workspaces. `current` is matched by canonical path; when it is nil
    /// or not active, the first active worktree is returned so cycling from an
    /// unknown state lands somewhere deterministic. Returns nil when fewer
    /// than two worktrees are active.
    static func cycleTarget(
        in worktrees: [Worktree],
        activeWorktreePaths: Set<URL>,
        from current: URL?,
        offset: Int
    ) -> Worktree? {
        let active = worktrees.filter {
            activeWorktreePaths.contains(WorktreeWorkspaceManager.key($0.path))
        }
        guard active.count >= 2 else { return nil }

        let currentPath = current.map { canonicalPath($0) }
        guard let index = active.firstIndex(where: {
            canonicalPath($0.path) == currentPath
        }) else {
            return active.first
        }

        let count = active.count
        let target = ((index + offset) % count + count) % count
        guard target != index else { return nil }
        return active[target]
    }

    /// The conventional location for a new worktree: a visible container
    /// directory sibling to the main repository root, holding one directory
    /// per branch — e.g. repo `~/Code/ghostty` + branch `myfix` →
    /// `~/Code/ghostty-worktrees/myfix`. Chosen over dot-hidden or in-repo
    /// locations so worktrees stay reachable from Finder and file pickers
    /// while staying out of in-repo greps and watchers.
    static func newWorktreePath(repoRoot: URL, branch: String) -> URL {
        let root = repoRoot.standardizedFileURL
        return root
            .deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-worktrees")
            .appendingPathComponent(directoryName(forBranch: branch))
    }

    /// A branch name flattened to a single path component: `review/design`
    /// becomes the directory name `review-design`.
    static func directoryName(forBranch branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    /// Resolve the cwd to source worktrees from: prefer the surface's live pwd,
    /// falling back to the configured `working-directory` (bare commands report
    /// no pwd — see the research spike). Returns nil when neither is available.
    static func resolveCwd(pwd: String?, configuredWorkingDirectory: String?) -> URL? {
        if let pwd, !pwd.isEmpty {
            return URL(fileURLWithPath: pwd)
        }
        if let configured = configuredWorkingDirectory, !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        return nil
    }
}

#endif
