import Foundation
import Testing
@testable import Ghostty

#if os(macOS)

/// Tests for the M4 "New worktree…" flow: the destination-path convention,
/// `git worktree add` result mapping, and the view-model creation pipeline
/// (create → refresh → open), driven by a stateful fake `GitCommandRunning`.
@MainActor
struct WorktreeCreateTests {
    private static let commonDir = "/repo/main/.git"
    private static let porcelain = """
    worktree /repo/main
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main
    """

    // MARK: Pure helpers

    @Test func newWorktreePathIsVisibleSiblingContainer() {
        let path = WorktreeSidebar.newWorktreePath(
            repoRoot: URL(fileURLWithPath: "/Users/x/Code/ghostty"),
            branch: "myfix")
        #expect(path.path == "/Users/x/Code/ghostty-worktrees/myfix")
    }

    @Test func branchSlashesFlattenToDashes() {
        #expect(WorktreeSidebar.directoryName(forBranch: "review/design") == "review-design")

        let path = WorktreeSidebar.newWorktreePath(
            repoRoot: URL(fileURLWithPath: "/repo/main/"),
            branch: "feat/wt/new")
        #expect(path.path == "/repo/main-worktrees/feat-wt-new")
    }

    @Test func errorMessagesStripGitNoise() {
        #expect(WorktreeCreateError.git("fatal: invalid reference: bad..name").message
            == "invalid reference: bad..name")
        #expect(WorktreeCreateError.git("").message == "git worktree add failed")
        #expect(WorktreeCreateError.notARepository.message == "Not a git repository")
        #expect(WorktreeCreateError.timedOut.message == "git worktree add timed out")
        #expect(WorktreeCreateError.launchFailed("no git").message == "Could not launch git: no git")
    }

    // MARK: Model

    @Test func createRunsWorktreeAddAtConventionalPath() async {
        let runner = FakeCreateRunner(commonDir: Self.commonDir, porcelain: Self.porcelain)
        let model = GitWorktreeModel(runner: runner)

        // A cwd nested inside the repo still creates relative to the root.
        let result = await model.createWorktree(
            branch: "myfix",
            forCwd: URL(fileURLWithPath: "/repo/main/src/nested"))

        guard case .success(let url) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(url.path == "/repo/main-worktrees/myfix")
        #expect(runner.addArguments == ["worktree", "add", "/repo/main-worktrees/myfix", "-b", "myfix"])
    }

    @Test func createOutsideRepositoryFails() async {
        let runner = FakeCreateRunner(commonDir: nil, porcelain: nil)
        let model = GitWorktreeModel(runner: runner)

        let result = await model.createWorktree(
            branch: "myfix",
            forCwd: URL(fileURLWithPath: "/not/a/repo"))

        #expect(result == .failure(.notARepository))
        #expect(runner.addArguments == nil)
    }

    @Test func gitFailureCarriesStderr() async {
        let runner = FakeCreateRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            addResult: .failure(status: 128, stderr: "fatal: invalid reference: bad..name"))
        let model = GitWorktreeModel(runner: runner)

        let result = await model.createWorktree(
            branch: "bad..name",
            forCwd: URL(fileURLWithPath: "/repo/main"))

        #expect(result == .failure(.git("fatal: invalid reference: bad..name")))
    }

    // MARK: View model

    @Test func createSuccessRefreshesAndOpensNewWorktree() async {
        let runner = FakeCreateRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            addedBlock: """
            worktree /repo/main-worktrees/myfix
            HEAD 2222222222222222222222222222222222222222
            branch refs/heads/myfix
            """)
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        var opened: Worktree?
        viewModel.onSelect = { opened = $0 }
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        await viewModel.createWorktree(branch: "myfix")

        #expect(viewModel.createError == nil)
        #expect(viewModel.isCreatingWorktree == false)
        #expect(viewModel.worktrees.map(\.branch) == ["main", "myfix"])
        #expect(opened?.branch == "myfix")
    }

    @Test func createFailureShowsInlineErrorAndKeepsList() async {
        let runner = FakeCreateRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            addResult: .failure(status: 128, stderr: "fatal: invalid reference: bad..name"))
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        var opened: Worktree?
        viewModel.onSelect = { opened = $0 }
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        await viewModel.createWorktree(branch: "bad..name")

        #expect(viewModel.createError == "invalid reference: bad..name")
        #expect(viewModel.worktrees.map(\.branch) == ["main"])
        #expect(opened == nil)

        viewModel.clearCreateError()
        #expect(viewModel.createError == nil)
    }

    @Test func blankBranchNameIsIgnored() async {
        let runner = FakeCreateRunner(commonDir: Self.commonDir, porcelain: Self.porcelain)
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        await viewModel.createWorktree(branch: "   ")

        #expect(runner.addArguments == nil)
        #expect(viewModel.createError == nil)
    }

    @Test func createWithoutCwdShowsError() async {
        let runner = FakeCreateRunner(commonDir: Self.commonDir, porcelain: Self.porcelain)
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        // Never refreshed: no cwd to resolve the repository from.
        await viewModel.createWorktree(branch: "myfix")

        #expect(viewModel.createError == "No working directory")
        #expect(runner.addArguments == nil)
    }
}

/// A `GitCommandRunning` fake that answers the three commands the create flow
/// issues: `rev-parse --git-common-dir`, `worktree list --porcelain`, and
/// `worktree add`. A successful add appends `addedBlock` to the porcelain so
/// the post-create refresh sees the new worktree, mirroring real git.
private final class FakeCreateRunner: GitCommandRunning {
    private let commonDir: String?
    private var porcelain: String?
    private let addResult: GitCommandResult
    private let addedBlock: String?
    private(set) var addArguments: [String]?

    init(
        commonDir: String?,
        porcelain: String?,
        addResult: GitCommandResult = .success(""),
        addedBlock: String? = nil
    ) {
        self.commonDir = commonDir
        self.porcelain = porcelain
        self.addResult = addResult
        self.addedBlock = addedBlock
    }

    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult {
        if arguments.contains("rev-parse") {
            guard let commonDir else { return .failure(status: 128, stderr: "not a git repository") }
            return .success(commonDir)
        }
        if arguments.contains("add") {
            addArguments = arguments
            if case .success = addResult, let addedBlock, let existing = porcelain {
                porcelain = existing + "\n\n" + addedBlock
            }
            return addResult
        }
        if arguments.contains("list") {
            guard let porcelain else { return .failure(status: 128, stderr: "not a git repository") }
            return .success(porcelain)
        }
        return .failure(status: 1, stderr: "unexpected command \(arguments)")
    }
}

#endif
