import Foundation
import Testing
@testable import Ghostty

#if os(macOS)

/// Tests for listing fetched remote branches in the palette and checking one
/// out: ref parsing, the local-branch exclusion, and the single
/// `git worktree add -b <name> <remote>/<name>` that turns a read-only
/// remote-tracking ref into a writable local branch with a worktree.
@MainActor
struct WorktreeRemoteBranchTests {
    private static let commonDir = "/repo/main/.git"
    private static let porcelain = """
    worktree /repo/main
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main
    """

    // MARK: Ref parsing

    @Test func parsesRemoteAndBranchName() {
        let branch = RemoteBranch(shortRef: "origin/feature")
        #expect(branch?.remote == "origin")
        #expect(branch?.name == "feature")
        #expect(branch?.ref == "origin/feature")
    }

    @Test func branchNameKeepsItsOwnSlashes() {
        // Only the first path component is the remote: `feat/wt/new` on
        // `upstream` must round-trip as a branch name, not be re-split.
        let branch = RemoteBranch(shortRef: "upstream/feat/wt/new")
        #expect(branch?.remote == "upstream")
        #expect(branch?.name == "feat/wt/new")
    }

    @Test func rejectsRefsThatAreNotCheckoutableBranches() {
        // `<remote>/HEAD` is a symbolic alias for the remote's default branch.
        #expect(RemoteBranch(shortRef: "origin/HEAD") == nil)
        #expect(RemoteBranch(shortRef: "origin") == nil)
        #expect(RemoteBranch(shortRef: "origin/") == nil)
        #expect(RemoteBranch(shortRef: "") == nil)
    }

    // MARK: Pure helpers

    @Test func excludesRemotesThatAlreadyHaveALocalBranch() {
        let remotes = [
            RemoteBranch(shortRef: "origin/main"),
            RemoteBranch(shortRef: "origin/feature"),
            RemoteBranch(shortRef: "origin/stale"),
        ].compactMap(\.self)

        let result = WorktreeSidebar.remoteBranchesWithoutLocal(
            remoteBranches: remotes,
            localBranches: ["main", "feature"])

        #expect(result.map(\.ref) == ["origin/stale"])
    }

    @Test func keepsSameBranchOnDifferentRemotes() {
        let remotes = [
            RemoteBranch(shortRef: "origin/feature"),
            RemoteBranch(shortRef: "fork/feature"),
        ].compactMap(\.self)

        let result = WorktreeSidebar.remoteBranchesWithoutLocal(
            remoteBranches: remotes,
            localBranches: [])

        // Both survive under their own ref; disambiguating them is the user's
        // call, made by picking a row.
        #expect(result.map(\.ref) == ["origin/feature", "fork/feature"])
    }

    @Test func preservesInputOrdering() {
        let remotes = [
            RemoteBranch(shortRef: "origin/newest"),
            RemoteBranch(shortRef: "origin/middle"),
            RemoteBranch(shortRef: "origin/oldest"),
        ].compactMap(\.self)

        let result = WorktreeSidebar.remoteBranchesWithoutLocal(
            remoteBranches: remotes,
            localBranches: [])

        // git sorts by -committerdate; that ordering must survive the filter.
        #expect(result.map(\.name) == ["newest", "middle", "oldest"])
    }

    // MARK: Model

    @Test func listsRemoteBranchesSortedByRecency() async {
        let runner = FakeRemoteRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            remoteBranches: "origin/HEAD\norigin/feature\norigin/old\n")
        let model = GitWorktreeModel(runner: runner)

        let branches = await model.remoteBranches(forCwd: URL(fileURLWithPath: "/repo/main"))

        #expect(branches.map(\.ref) == ["origin/feature", "origin/old"])
        #expect(runner.remoteRefArguments == [
            "for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/remotes",
        ])
    }

    @Test func listingOutsideRepositoryIsEmpty() async {
        let runner = FakeRemoteRunner(commonDir: nil, porcelain: nil)
        let model = GitWorktreeModel(runner: runner)

        let branches = await model.remoteBranches(forCwd: URL(fileURLWithPath: "/not/a/repo"))

        #expect(branches.isEmpty)
    }

    // MARK: View model

    @Test func refreshExposesRemotesWithoutLocalCounterparts() async {
        let runner = FakeRemoteRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            localBranches: "main\n",
            remoteBranches: "origin/HEAD\norigin/main\norigin/feature\n")
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        #expect(viewModel.remoteBranchesWithoutLocal.map(\.ref) == ["origin/feature"])
    }

    @Test func checkOutCreatesLocalBranchFromRemoteRefAndOpensIt() async throws {
        let runner = FakeRemoteRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            remoteBranches: "origin/feature\n",
            addedBlock: """
            worktree /repo/main-worktrees/feature
            HEAD 2222222222222222222222222222222222222222
            branch refs/heads/feature
            """)
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        var opened: Worktree?
        viewModel.onSelect = { opened = $0 }
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        let remote = try #require(viewModel.remoteBranchesWithoutLocal.first)
        await viewModel.checkOutRemoteBranch(remote)

        // `-b feature origin/feature`: the local ref is what HEAD can advance,
        // and git wires up its upstream from the remote-tracking start point.
        #expect(runner.addArguments == [
            "worktree", "add", "/repo/main-worktrees/feature", "-b", "feature", "origin/feature",
        ])
        #expect(viewModel.createError == nil)
        #expect(opened?.branch == "feature")
    }

    @Test func checkOutFailureShowsInlineError() async throws {
        let runner = FakeRemoteRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            remoteBranches: "origin/feature\n",
            addResult: .failure(status: 128, stderr: "fatal: invalid reference: origin/feature"))
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))
        let remote = try #require(viewModel.remoteBranchesWithoutLocal.first)
        await viewModel.checkOutRemoteBranch(remote)

        #expect(viewModel.createError == "invalid reference: origin/feature")
        // The listing survives a failed checkout so the row stays pickable.
        #expect(viewModel.remoteBranchesWithoutLocal.map(\.ref) == ["origin/feature"])
    }

    @Test func checkOutMovesTheBranchOutOfTheRemoteSection() async throws {
        let runner = FakeRemoteRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            localBranches: "main\n",
            remoteBranches: "origin/feature\n",
            localBranchesAfterAdd: "main\nfeature\n",
            addedBlock: """
            worktree /repo/main-worktrees/feature
            HEAD 2222222222222222222222222222222222222222
            branch refs/heads/feature
            """)
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: runner))

        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))
        let remote = try #require(viewModel.remoteBranchesWithoutLocal.first)
        await viewModel.checkOutRemoteBranch(remote)

        // Now that a local `feature` exists it belongs to the worktree list,
        // not the remote section.
        #expect(viewModel.remoteBranchesWithoutLocal.isEmpty)
        #expect(viewModel.worktrees.map(\.branch) == ["main", "feature"])
    }
}

/// A `GitCommandRunning` fake covering the commands the remote-branch flow
/// issues, distinguishing `refs/heads` from `refs/remotes` the way real git
/// does. A successful add appends `addedBlock` to the porcelain and swaps in
/// `localBranchesAfterAdd`, mirroring the local branch git creates.
private final class FakeRemoteRunner: GitCommandRunning {
    private let commonDir: String?
    private var porcelain: String?
    private var localBranches: String
    private let remoteBranches: String
    private let localBranchesAfterAdd: String?
    private let addResult: GitCommandResult
    private let addedBlock: String?
    private(set) var addArguments: [String]?
    private(set) var remoteRefArguments: [String]?

    init(
        commonDir: String?,
        porcelain: String?,
        localBranches: String = "main\n",
        remoteBranches: String = "",
        localBranchesAfterAdd: String? = nil,
        addResult: GitCommandResult = .success(""),
        addedBlock: String? = nil
    ) {
        self.commonDir = commonDir
        self.porcelain = porcelain
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self.localBranchesAfterAdd = localBranchesAfterAdd
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
            if case .success = addResult {
                if let addedBlock, let existing = porcelain {
                    porcelain = existing + "\n\n" + addedBlock
                }
                if let localBranchesAfterAdd {
                    localBranches = localBranchesAfterAdd
                }
            }
            return addResult
        }
        if arguments.contains("list") {
            guard let porcelain else { return .failure(status: 128, stderr: "not a git repository") }
            return .success(porcelain)
        }
        if arguments.contains("for-each-ref") {
            guard arguments.contains("refs/remotes") else { return .success(localBranches) }
            remoteRefArguments = arguments
            return .success(remoteBranches)
        }
        return .failure(status: 1, stderr: "unexpected command \(arguments)")
    }
}

#endif
