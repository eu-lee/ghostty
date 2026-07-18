import Foundation
import Testing
@testable import Ghostty

#if os(macOS)

/// Tests for the worktree removal flow: command construction, force retry,
/// git-error mapping, and the view-model remove -> refresh path.
@MainActor
struct WorktreeRemoveTests {
    private static let commonDir = "/repo/main/.git"
    private static let porcelain = """
    worktree /repo/main
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /repo/feature
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/feature
    """

    @Test func removeRunsWorktreeRemoveAtRepoRoot() async {
        let runner = FakeRemoveRunner(commonDir: Self.commonDir, porcelain: Self.porcelain)
        let model = GitWorktreeModel(runner: runner)

        let result = await model.removeWorktree(
            path: URL(fileURLWithPath: "/repo/feature"),
            forCwd: URL(fileURLWithPath: "/repo/main/src"))

        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(runner.removeArguments == ["worktree", "remove", "/repo/feature"])
        #expect(runner.removeCwd?.path == "/repo/main")
    }

    @Test func forceRemoveAppendsForceArgument() async {
        let runner = FakeRemoveRunner(commonDir: Self.commonDir, porcelain: Self.porcelain)
        let model = GitWorktreeModel(runner: runner)

        let result = await model.removeWorktree(
            path: URL(fileURLWithPath: "/repo/feature"),
            force: true,
            forCwd: URL(fileURLWithPath: "/repo/main"))

        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(runner.removeArguments == ["worktree", "remove", "/repo/feature", "--force"])
    }

    @Test func removeOutsideRepositoryFails() async {
        let runner = FakeRemoveRunner(commonDir: nil, porcelain: nil)
        let model = GitWorktreeModel(runner: runner)

        let result = await model.removeWorktree(
            path: URL(fileURLWithPath: "/repo/feature"),
            forCwd: URL(fileURLWithPath: "/not/a/repo"))

        guard case .failure(.notARepository) = result else {
            Issue.record("expected notARepository, got \(result)")
            return
        }
        #expect(runner.removeArguments == nil)
    }

    @Test func dirtyTreeFailureCarriesGitMessage() async {
        let runner = FakeRemoveRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            removeResult: .failure(
                status: 128,
                stderr: "fatal: '/repo/feature' contains modified or untracked files, use --force to delete it"))
        let model = GitWorktreeModel(runner: runner)

        let result = await model.removeWorktree(
            path: URL(fileURLWithPath: "/repo/feature"),
            forCwd: URL(fileURLWithPath: "/repo/main"))

        guard case .failure(.git("fatal: '/repo/feature' contains modified or untracked files, use --force to delete it")) = result else {
            Issue.record("expected dirty-tree git failure, got \(result)")
            return
        }
    }

    @Test func removeSuccessRefreshesAndDropsRow() async throws {
        let runner = FakeRemoveRunner(commonDir: Self.commonDir, porcelain: Self.porcelain)
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))
        let feature = try #require(viewModel.worktrees.first { $0.branch == "feature" })

        await viewModel.removeWorktree(feature)

        #expect(viewModel.removeError == nil)
        #expect(viewModel.isRemovingWorktree == false)
        #expect(viewModel.worktrees.map(\.branch) == ["main"])
    }

    @Test func removeFailureShowsInlineErrorAndForceCandidate() async throws {
        let runner = FakeRemoveRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            removeResult: .failure(
                status: 128,
                stderr: "fatal: '/repo/feature' contains modified or untracked files, use --force to delete it"))
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))
        let feature = try #require(viewModel.worktrees.first { $0.branch == "feature" })

        await viewModel.removeWorktree(feature)

        #expect(viewModel.removeError == "'/repo/feature' contains modified or untracked files, use --force to delete it")
        #expect(viewModel.forceRemoveCandidate?.branch == "feature")
        #expect(viewModel.worktrees.map(\.branch) == ["main", "feature"])

        viewModel.clearRemoveError()
        #expect(viewModel.removeError == nil)
        #expect(viewModel.forceRemoveCandidate == nil)
    }

    @Test func removeRefusesMainWorktree() async throws {
        let runner = FakeRemoveRunner(commonDir: Self.commonDir, porcelain: Self.porcelain)
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))
        let main = try #require(viewModel.worktrees.first { $0.isMain })

        await viewModel.removeWorktree(main)

        #expect(runner.removeArguments == nil)
        #expect(viewModel.removeError == nil)
        #expect(viewModel.worktrees.map(\.branch) == ["main", "feature"])
    }
}

private final class FakeRemoveRunner: GitCommandRunning {
    private let commonDir: String?
    private var porcelain: String?
    private let removeResult: GitCommandResult
    private(set) var removeArguments: [String]?
    private(set) var removeCwd: URL?

    init(
        commonDir: String?,
        porcelain: String?,
        removeResult: GitCommandResult = .success("")
    ) {
        self.commonDir = commonDir
        self.porcelain = porcelain
        self.removeResult = removeResult
    }

    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult {
        if arguments.contains("rev-parse") {
            guard let commonDir else { return .failure(status: 128, stderr: "not a git repository") }
            return .success(commonDir)
        }
        if arguments.contains("remove") {
            removeArguments = arguments
            removeCwd = cwd
            if case .success = removeResult, let existing = porcelain {
                porcelain = existing
                    .components(separatedBy: "\n\n")
                    .filter { !$0.contains("worktree /repo/feature") }
                    .joined(separator: "\n\n")
            }
            return removeResult
        }
        if arguments.contains("list") {
            guard let porcelain else { return .failure(status: 128, stderr: "not a git repository") }
            return .success(porcelain)
        }
        return .failure(status: 1, stderr: "unexpected command \(arguments)")
    }
}

#endif
