import Foundation
import Testing
@testable import Ghostty

#if os(macOS)

/// Tests for the M2 sidebar view-model and its pure presentation helpers.
///
/// The view-model path is driven by a command-aware fake `GitCommandRunning`
/// so the full pipeline (repo detection → worktree enumeration → active
/// resolution → empty state) is exercised deterministically without touching a
/// real git repository. Presentation logic is additionally tested directly via
/// the pure `WorktreeSidebar` helpers.
@MainActor
struct WorktreeSidebarViewModelTests {
    // A repository at /repo/main with a linked "feature" worktree and a
    // detached-HEAD worktree.
    private static let commonDir = "/repo/main/.git"
    private static let porcelain = """
    worktree /repo/main
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /repo/feature
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/feature

    worktree /repo/detached-head
    HEAD 3333333333333333333333333333333333333333
    detached
    """
    private static let localBranches = "main\nfeature\nreview\n"

    private func repoModel() -> GitWorktreeModel {
        GitWorktreeModel(runner: FakeGitRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            localBranches: Self.localBranches
        ))
    }

    // MARK: View model

    @Test func mainPinnedFirstAndDetachedNaming() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())

        // A window opened directly inside a linked worktree still resolves to
        // the main repository's full list.
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/feature"))

        #expect(viewModel.worktrees.map { $0.path.standardizedFileURL.path } == [
            "/repo/main", "/repo/feature", "/repo/detached-head",
        ])
        #expect(viewModel.worktrees.first?.isMain == true)

        // Detached HEAD falls back to the directory name for its row title.
        let detached = viewModel.worktrees.last
        #expect(detached?.isDetached == true)
        #expect(detached?.branch == "detached-head")
        #expect(WorktreeSidebar.displayName(for: detached!) == "detached-head")

        #expect(viewModel.branchesWithoutWorktree == ["review"])
    }

    @Test func activeWorktreeSelectedFromCwd() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())

        // A cwd nested inside the feature worktree selects that worktree.
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/feature/src/nested"))

        #expect(viewModel.selectedWorktree?.path.standardizedFileURL.path == "/repo/feature")
        #expect(viewModel.isEmptyState == false)
    }

    @Test func nonRepoEmptyState() async {
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(
            runner: FakeGitRunner(commonDir: nil, porcelain: nil)
        ))

        await viewModel.refresh(cwd: URL(fileURLWithPath: "/not/a/repo"))

        #expect(viewModel.worktrees.isEmpty)
        #expect(viewModel.isEmptyState == true)
        #expect(viewModel.selectedWorktree == nil)
    }

    @Test func nilCwdIsEmptyState() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())

        await viewModel.refresh(cwd: nil)

        #expect(viewModel.worktrees.isEmpty)
        #expect(viewModel.isEmptyState == true)
    }

    @Test func activeWorktreePathsUseCanonicalKeys() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))
        let feature = Worktree(path: URL(fileURLWithPath: "/repo/feature"), branch: "feature", isMain: false, isDetached: false)

        viewModel.updateActiveWorktreePaths([URL(fileURLWithPath: "/repo/./feature/")])

        #expect(viewModel.isActive(feature))
        #expect(WorktreeSidebar.isActive(feature, in: viewModel.activeWorktreePaths))
    }

    @Test func selectionPreservedAcrossRefreshWhenStillPresent() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/feature"))
        #expect(viewModel.selectedWorktree?.path.standardizedFileURL.path == "/repo/feature")

        // A later refresh (e.g. window focus) with a cwd that isn't inside any
        // worktree keeps the existing selection rather than clearing it.
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main/.."))
        #expect(viewModel.selectedWorktree?.path.standardizedFileURL.path == "/repo/feature")
    }

    // MARK: Pure helpers

    @Test func displayNameFallsBackToDirectoryForDetached() {
        let branch = Worktree(path: URL(fileURLWithPath: "/w/feature"), branch: "feature", isMain: false, isDetached: false)
        let detached = Worktree(path: URL(fileURLWithPath: "/w/spike"), branch: nil, isMain: false, isDetached: true)

        #expect(WorktreeSidebar.displayName(for: branch) == "feature")
        #expect(WorktreeSidebar.displayName(for: detached) == "spike")
    }

    @Test func activeWorktreeUsesLongestPrefix() {
        let main = Worktree(path: URL(fileURLWithPath: "/repo"), branch: "main", isMain: true, isDetached: false)
        let feature = Worktree(path: URL(fileURLWithPath: "/repo/wt/feature"), branch: "feature", isMain: false, isDetached: false)
        let worktrees = [main, feature]

        // Nested cwd resolves to the more specific (longer prefix) worktree.
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: URL(fileURLWithPath: "/repo/wt/feature/src"))?.branch == "feature")
        // A cwd only under the main root resolves to main.
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: URL(fileURLWithPath: "/repo/src"))?.branch == "main")
        // Exact match.
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: URL(fileURLWithPath: "/repo/wt/feature"))?.branch == "feature")
        // Outside any worktree, and nil cwd.
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: URL(fileURLWithPath: "/elsewhere")) == nil)
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: nil) == nil)
        // A sibling that merely shares a name prefix must not match ("/repofoo").
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: URL(fileURLWithPath: "/repofoo")) == nil)
    }

    @Test func canRemoveRefusesMainOnly() {
        let main = Worktree(path: URL(fileURLWithPath: "/w/main"), branch: "main", isMain: true, isDetached: false)
        let feature = Worktree(path: URL(fileURLWithPath: "/w/feature"), branch: "feature", isMain: false, isDetached: false)

        #expect(WorktreeSidebar.canRemove(main) == false)
        #expect(WorktreeSidebar.canRemove(feature) == true)
    }

    @Test func forceRemovePredicateRecognizesDirtyWorktreeMessages() {
        #expect(WorktreeSidebar.canForceRemove(afterGitMessage: "contains modified or untracked files, use --force to delete it"))
        #expect(WorktreeSidebar.canForceRemove(afterGitMessage: "is dirty, use --force"))
        #expect(WorktreeSidebar.canForceRemove(afterGitMessage: "invalid path") == false)
    }

    @Test func activeFirstPinsMainThenOrdersRestActiveFirst() {
        let worktrees = [
            Worktree(path: URL(fileURLWithPath: "/repo/main"), branch: "main", isMain: true, isDetached: false),
            Worktree(path: URL(fileURLWithPath: "/repo/feature"), branch: "feature", isMain: false, isDetached: false),
            Worktree(path: URL(fileURLWithPath: "/repo/review"), branch: "review", isMain: false, isDetached: false),
            Worktree(path: URL(fileURLWithPath: "/repo/spike"), branch: "spike", isMain: false, isDetached: false),
        ]
        // main is inactive, review is active, feature/spike inactive. main still
        // pins to the top; among the rest, active comes before inactive.
        let active = Set([
            WorktreeWorkspaceManager.key(URL(fileURLWithPath: "/repo/review")),
        ])

        #expect(WorktreeSidebar.activeFirst(worktrees, activeWorktreePaths: active).map(\.branch) == [
            "main", "review", "feature", "spike",
        ])
    }

    @Test func branchesWithoutWorktreeSubtractsLoadedWorktreeBranches() {
        let worktrees = [
            Worktree(path: URL(fileURLWithPath: "/repo/main"), branch: "main", isMain: true, isDetached: false),
            Worktree(path: URL(fileURLWithPath: "/repo/feature"), branch: "feature", isMain: false, isDetached: false),
        ]

        #expect(WorktreeSidebar.branchesWithoutWorktree(
            localBranches: ["main", "feature", "review"],
            worktrees: worktrees) == ["review"])
    }

    @Test func bellStatusUsesCanonicalKeys() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))
        let feature = Worktree(path: URL(fileURLWithPath: "/repo/feature"), branch: "feature", isMain: false, isDetached: false)

        viewModel.updateBellWorktreePaths([URL(fileURLWithPath: "/repo/./feature/")])

        #expect(viewModel.hasBell(feature))
        #expect(WorktreeSidebar.hasBell(feature, in: viewModel.bellWorktreePaths))
    }

    @Test func resolveCwdPrefersPwdThenConfiguredDirectory() {
        #expect(WorktreeSidebar.resolveCwd(pwd: "/live/pwd", configuredWorkingDirectory: "/config")?.path == "/live/pwd")
        #expect(WorktreeSidebar.resolveCwd(pwd: nil, configuredWorkingDirectory: "/config")?.path == "/config")
        #expect(WorktreeSidebar.resolveCwd(pwd: "", configuredWorkingDirectory: "/config")?.path == "/config")
        #expect(WorktreeSidebar.resolveCwd(pwd: nil, configuredWorkingDirectory: nil) == nil)
        #expect(WorktreeSidebar.resolveCwd(pwd: nil, configuredWorkingDirectory: "") == nil)
    }
}

/// A `GitCommandRunning` that answers the two commands the model issues:
/// `rev-parse --git-common-dir` and `worktree list --porcelain`. A nil
/// `commonDir` simulates a non-repository directory.
private struct FakeGitRunner: GitCommandRunning {
    let commonDir: String?
    let porcelain: String?
    let localBranches: String
    let remoteBranches: String

    init(
        commonDir: String?,
        porcelain: String?,
        localBranches: String = "",
        remoteBranches: String = ""
    ) {
        self.commonDir = commonDir
        self.porcelain = porcelain
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
    }

    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult {
        if arguments.contains("rev-parse") {
            guard let commonDir else { return .failure(status: 128, stderr: "not a git repository") }
            return .success(commonDir)
        }
        if arguments.contains("list") {
            guard let porcelain else { return .failure(status: 128, stderr: "not a git repository") }
            return .success(porcelain)
        }
        if arguments.contains("for-each-ref") {
            return .success(arguments.contains("refs/remotes") ? remoteBranches : localBranches)
        }
        return .failure(status: 1, stderr: "unexpected command \(arguments)")
    }
}

#endif
