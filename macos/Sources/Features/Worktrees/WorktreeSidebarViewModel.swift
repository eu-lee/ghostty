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

    /// Case-insensitive substring filter applied over branch + directory names.
    @Published var filterText: String = ""

    /// The active/selected worktree. Initialized on each refresh to the
    /// worktree containing the source cwd (the "active" one, highlighted in the
    /// list). Exposed as settable observable state so the M3 switching layer
    /// can read the current selection and drive navigation to a new one.
    @Published var selectedWorktree: Worktree?

    /// Whether a refresh has completed at least once. Used to distinguish the
    /// initial (pre-load) state from a genuinely empty / non-repo result.
    @Published private(set) var hasLoaded: Bool = false

    /// True while a `git worktree add` is running (M4). Drives the inline
    /// progress indicator and prevents concurrent creations.
    @Published private(set) var isCreatingWorktree: Bool = false

    /// The last worktree-creation failure, as a short user-facing message
    /// rendered inline in the sidebar (never an alert). Nil when the last
    /// creation succeeded or the user dismissed the message.
    @Published private(set) var createError: String?

    /// Worktrees that already have a live workspace in this window, keyed by
    /// `WorktreeWorkspaceManager.key(_:)`.
    @Published private(set) var activeWorktreePaths: Set<URL> = []

    /// Invoked when the user picks a worktree row. The M3 switching layer
    /// (TerminalController) wires this to the workspace switch; selection
    /// state is then updated by the switcher, so the highlight tracks the
    /// active workspace rather than the click.
    var onSelect: ((Worktree) -> Void)?

    private let model: GitWorktreeModel
    private(set) var currentCwd: URL?

    init(model: GitWorktreeModel = GitWorktreeModel()) {
        self.model = model
    }

    /// True once a load has completed and the source cwd is not a git
    /// repository (or there is no cwd at all) — drives the "Not a git
    /// repository" empty state.
    var isEmptyState: Bool {
        hasLoaded && worktrees.isEmpty
    }

    /// The worktrees to display, after applying `filterText`.
    var filteredWorktrees: [Worktree] {
        WorktreeSidebar.filter(worktrees, query: filterText)
    }

    func isLive(_ worktree: Worktree) -> Bool {
        activeWorktreePaths.contains(WorktreeWorkspaceManager.key(worktree.path))
    }

    /// Load worktrees for the repository containing `cwd`. A nil cwd (e.g. a
    /// window whose first surface reports no pwd and has no configured
    /// working-directory) resolves to the empty state.
    func refresh(cwd: URL?) async {
        currentCwd = cwd

        let loaded: [Worktree]
        if let cwd {
            loaded = await model.worktrees(forCwd: cwd)
        } else {
            loaded = []
        }

        worktrees = loaded
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
        activeWorktreePaths = paths
    }

    /// Forward a row click to the switching layer (see `onSelect`).
    func select(_ worktree: Worktree) {
        onSelect?(worktree)
    }

    /// Create a worktree (and branch) named `branch` via `git worktree add`,
    /// then refresh the list and open the new worktree (M4). Failures land in
    /// `createError` for the sidebar to render inline.
    func createWorktree(branch: String) async {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreatingWorktree else { return }
        guard let cwd = currentCwd else {
            createError = "No working directory"
            return
        }

        isCreatingWorktree = true
        createError = nil
        defer { isCreatingWorktree = false }

        switch await model.createWorktree(branch: trimmed, forCwd: cwd) {
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

    /// Clear a pending creation error (the user dismissed the new-worktree
    /// field or started typing a fresh attempt).
    func clearCreateError() {
        createError = nil
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

    /// Case-insensitive substring filter over branch + directory names. An
    /// empty/whitespace query returns the input unchanged.
    static func filter(_ worktrees: [Worktree], query: String) -> [Worktree] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return worktrees }

        return worktrees.filter { worktree in
            let haystacks = [displayName(for: worktree), worktree.path.lastPathComponent]
            return haystacks.contains { $0.range(of: trimmed, options: .caseInsensitive) != nil }
        }
    }

    /// Filtered worktrees with live workspaces first, preserving the input
    /// order within active and inactive groups.
    static func activeFirst(_ worktrees: [Worktree], activeWorktreePaths: Set<URL>) -> [Worktree] {
        let keyed = worktrees.map { (worktree: $0, isActive: activeWorktreePaths.contains(WorktreeWorkspaceManager.key($0.path))) }
        return keyed.filter { $0.isActive }.map { $0.worktree } +
            keyed.filter { !$0.isActive }.map { $0.worktree }
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
