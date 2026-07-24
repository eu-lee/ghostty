import Foundation
import Testing
@testable import Ghostty

#if os(macOS)

/// Tests for the pure worktree cycling helper backing the
/// `goto_worktree:next/previous` keybinds (M3).
struct WorktreeCycleTests {
    private static let worktrees: [Worktree] = [
        .init(path: URL(fileURLWithPath: "/repo/main"), branch: "main", isMain: true, isDetached: false),
        .init(path: URL(fileURLWithPath: "/repo/feature"), branch: "feature", isMain: false, isDetached: false),
        .init(path: URL(fileURLWithPath: "/repo/review"), branch: "review", isMain: false, isDetached: false),
    ]
    private static let allActive = Set(worktrees.map { WorktreeWorkspaceManager.key($0.path) })

    @Test func nextFollowsSidebarOrder() {
        let target = WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: Self.allActive,
            from: URL(fileURLWithPath: "/repo/main"),
            offset: 1)
        #expect(target?.branch == "feature")
    }

    @Test func previousFollowsSidebarOrder() {
        let target = WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: Self.allActive,
            from: URL(fileURLWithPath: "/repo/review"),
            offset: -1)
        #expect(target?.branch == "feature")
    }

    @Test func nextWrapsFromLastToFirst() {
        let target = WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: Self.allActive,
            from: URL(fileURLWithPath: "/repo/review"),
            offset: 1)
        #expect(target?.branch == "main")
    }

    @Test func previousWrapsFromFirstToLast() {
        let target = WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: Self.allActive,
            from: URL(fileURLWithPath: "/repo/main"),
            offset: -1)
        #expect(target?.branch == "review")
    }

    @Test func currentIsMatchedByStandardizedPath() {
        // A non-canonical spelling of the current path still matches its row.
        let target = WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: Self.allActive,
            from: URL(fileURLWithPath: "/repo/./feature/"),
            offset: 1)
        #expect(target?.branch == "review")
    }

    @Test func unknownCurrentLandsOnFirst() {
        let target = WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: Self.allActive,
            from: URL(fileURLWithPath: "/elsewhere"),
            offset: 1)
        #expect(target?.branch == "main")
    }

    @Test func nilCurrentLandsOnFirst() {
        let target = WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: Self.allActive,
            from: nil,
            offset: -1)
        #expect(target?.branch == "main")
    }

    @Test func emptyListHasNoTarget() {
        #expect(WorktreeSidebar.cycleTarget(in: [], activeWorktreePaths: [], from: nil, offset: 1) == nil)
    }

    /// A cwd spelled with different case than git's canonical worktree path
    /// (possible because the default macOS filesystem is case-insensitive:
    /// `cd ~/documents/...` works and the shell reports that spelling) must
    /// still resolve to its worktree. Uses real directories because the
    /// canonicalization goes through the filesystem; skipped in effect on
    /// case-sensitive filesystems where the miscased path doesn't exist.
    @Test func differentlyCasedPathsResolveToSameWorktree() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("WtCaseTest-\(UUID().uuidString.prefix(8))-Dir")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let miscased = URL(fileURLWithPath: base.path.lowercased())
        guard fm.fileExists(atPath: miscased.path) else { return }

        let worktree = Worktree(path: base, branch: "main", isMain: true, isDetached: false)
        let active = Set([WorktreeWorkspaceManager.key(base)])

        #expect(WorktreeSidebar.activeWorktree(in: [worktree], cwd: miscased)?.branch == "main")
        #expect(WorktreeSidebar.cycleTarget(in: [worktree], activeWorktreePaths: active, from: miscased, offset: 1) == nil)
    }

    @Test func singleEntryListHasNothingToSwitchTo() {
        let only = [Self.worktrees[0]]
        let target = WorktreeSidebar.cycleTarget(
            in: only,
            activeWorktreePaths: Set(only.map { WorktreeWorkspaceManager.key($0.path) }),
            from: URL(fileURLWithPath: "/repo/main"),
            offset: 1)
        #expect(target == nil)
    }

    @Test func skipsInactiveWorktrees() {
        let active = Set([
            WorktreeWorkspaceManager.key(URL(fileURLWithPath: "/repo/main")),
            WorktreeWorkspaceManager.key(URL(fileURLWithPath: "/repo/review")),
        ])
        let target = WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: active,
            from: URL(fileURLWithPath: "/repo/main"),
            offset: 1)
        #expect(target?.branch == "review")
    }

    @Test func fewerThanTwoActiveWorktreesHasNoTarget() {
        let active = Set([WorktreeWorkspaceManager.key(URL(fileURLWithPath: "/repo/main"))])
        #expect(WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: active,
            from: URL(fileURLWithPath: "/repo/main"),
            offset: 1) == nil)
    }

    /// Doc 17: a window opened into a non-main worktree pre-warms main as a
    /// second active workspace, so the active set is exactly {attached, main}.
    /// Cycling must then swap between the two — the crux of "I want to swap to
    /// main as well." With two active entries, next and previous both land on
    /// the other one.
    @Test func mainPreWarmedIsCyclableFromAttachedWorktree() {
        // feature is attached, main is the pre-warmed detached workspace.
        let active = Set([
            WorktreeWorkspaceManager.key(URL(fileURLWithPath: "/repo/feature")),
            WorktreeWorkspaceManager.key(URL(fileURLWithPath: "/repo/main")),
        ])

        let toMain = WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: active,
            from: URL(fileURLWithPath: "/repo/feature"),
            offset: 1)
        #expect(toMain?.branch == "main")

        // And back: cycling from main returns to the attached worktree, never
        // to the third worktree (review), which is still inactive.
        let backToFeature = WorktreeSidebar.cycleTarget(
            in: Self.worktrees,
            activeWorktreePaths: active,
            from: URL(fileURLWithPath: "/repo/main"),
            offset: 1)
        #expect(backToFeature?.branch == "feature")
    }
}

#endif
