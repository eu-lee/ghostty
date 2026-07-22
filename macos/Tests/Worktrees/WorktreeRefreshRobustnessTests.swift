import Foundation
import Testing
@testable import Ghostty

#if os(macOS)

/// Regression tests for the "sidebar randomly drops to 'Not a git repository'"
/// bug: a transient `git` failure during a background refresh (a timeout under
/// load, an index/ref lock race while `git switch` runs, a launch failure) must
/// never blank a repository the user is sitting in. Only git's own authoritative
/// "not a git repository" verdict is allowed to show the empty state.
@MainActor
struct WorktreeRefreshRobustnessTests {
    private static let commonDir = "/repo/main/.git"
    private static let porcelain = """
    worktree /repo/main
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /repo/feature
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/feature
    """
    private static let localBranches = "main\nfeature\n"

    @Test func transientFailureKeepsLastGoodState() async {
        let runner = TogglingRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            localBranches: Self.localBranches)
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        // Healthy load populates the sidebar.
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))
        #expect(!viewModel.worktrees.isEmpty)
        #expect(viewModel.isEmptyState == false)
        let worktreesBefore = viewModel.worktrees
        let selectionBefore = viewModel.selectedWorktree
        let commonDirBefore = viewModel.gitCommonDir

        // A subsequent refresh whose git calls all time out must not mutate any
        // of the loaded state.
        runner.mode = .timeout
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        #expect(viewModel.isEmptyState == false)
        #expect(viewModel.worktrees == worktreesBefore)
        #expect(viewModel.selectedWorktree == selectionBefore)
        #expect(viewModel.gitCommonDir == commonDirBefore)
    }

    @Test func nonZeroFailureThatIsNotNonRepoKeepsState() async {
        let runner = TogglingRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            localBranches: Self.localBranches)
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))
        let before = viewModel.worktrees

        // A generic nonzero exit (e.g. a lock race) is transient, not a verdict
        // that the directory is not a repository.
        runner.mode = .failure(status: 128, stderr: "fatal: Unable to create '.git/index.lock': File exists.")
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        #expect(viewModel.isEmptyState == false)
        #expect(viewModel.worktrees == before)
    }

    @Test func worktreeListFailureKeepsLastGoodState() async {
        let runner = TogglingRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            localBranches: Self.localBranches)
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))
        let before = viewModel.worktrees

        // `rev-parse` confirms this is a repository, but enumeration can still
        // fail during concurrent git activity. That is transient too.
        runner.mode = .failWorktreeList(status: 128, stderr: "fatal: Unable to read worktree metadata")
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        #expect(viewModel.isEmptyState == false)
        #expect(viewModel.worktrees == before)
    }

    @Test func branchListFailureKeepsRepositoryWorktrees() async {
        let runner = TogglingRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            localBranches: Self.localBranches)
        runner.mode = .failBranchLists
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        // Branch lists are supplementary palette data. If they fail, the
        // repository and worktrees should still load.
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        #expect(viewModel.worktrees.map(\.branch) == ["main", "feature"])
        #expect(viewModel.branchesWithoutWorktree.isEmpty)
        #expect(viewModel.remoteBranchesWithoutLocal.isEmpty)
        #expect(viewModel.isEmptyState == false)
    }

    @Test func authoritativeNonRepoShowsEmptyState() async {
        let runner = TogglingRunner(commonDir: Self.commonDir, porcelain: Self.porcelain)
        runner.mode = .failure(
            status: 128,
            stderr: "fatal: not a git repository (or any of the parent directories): .git")
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        await viewModel.refresh(cwd: URL(fileURLWithPath: "/tmp/not-a-repo"))

        #expect(viewModel.isEmptyState == true)
        #expect(viewModel.worktrees.isEmpty)
    }

    @Test func firstLoadTransientFailureIsNotFalseEmptyState() async {
        let runner = TogglingRunner(commonDir: Self.commonDir, porcelain: Self.porcelain)
        runner.mode = .timeout
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        // A timeout on the very first load must not assert "Not a git
        // repository" — hasLoaded stays false, so isEmptyState is false.
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        #expect(viewModel.hasLoaded == false)
        #expect(viewModel.isEmptyState == false)
        #expect(viewModel.worktrees.isEmpty)
    }
}

/// A runner whose behavior can be flipped between calls so a test can load a
/// healthy repo and then force a transient failure on the next refresh. In
/// `.normal` it answers the four commands `load` issues.
private final class TogglingRunner: GitCommandRunning, @unchecked Sendable {
    enum Mode {
        case normal
        case timeout
        case failure(status: Int32, stderr: String)
        case failWorktreeList(status: Int32, stderr: String)
        case failBranchLists
    }

    var mode: Mode = .normal
    let commonDir: String
    let porcelain: String
    let localBranches: String
    let remoteBranches: String

    init(
        commonDir: String,
        porcelain: String,
        localBranches: String = "",
        remoteBranches: String = ""
    ) {
        self.commonDir = commonDir
        self.porcelain = porcelain
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
    }

    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult {
        switch mode {
        case .timeout:
            return .timedOut
        case .failure(let status, let stderr):
            return .failure(status: status, stderr: stderr)
        case .failWorktreeList, .failBranchLists:
            break
        case .normal:
            break
        }

        if arguments.contains("rev-parse") { return .success(commonDir) }
        if case .failWorktreeList(let status, let stderr) = mode,
           arguments.contains("list") {
            return .failure(status: status, stderr: stderr)
        }
        if arguments.contains("list") { return .success(porcelain) }
        if case .failBranchLists = mode,
           arguments.contains("for-each-ref") {
            return .failure(status: 1, stderr: "fatal: packed-refs is locked")
        }
        if arguments.contains("for-each-ref") {
            return .success(arguments.contains("refs/remotes") ? remoteBranches : localBranches)
        }
        return .failure(status: 1, stderr: "unexpected command \(arguments)")
    }
}

#endif
