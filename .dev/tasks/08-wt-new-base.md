# 08 — feat/wt-new-base  (New-worktree base branch)

**Base:** `feat/wt-new-flow-m4` (stacks on PR #8; retarget the PR to `main` after #8
merges). · **Status:** READY. · **Worktree:** `~/Documents/Code/ghostty-wt-base`.

## Purpose

The "New worktree…" flow (M4) always branches off the *main worktree's HEAD* because
`git worktree add -b <branch>` with no start point uses the HEAD of the repo it runs
in (we run it at the main repo root). Make the start point explicit and controllable:
the user can type the base branch/ref they're targeting, and when they don't, it
defaults to **the branch of the currently active worktree** (the sidebar's selected
row). Decision from the human (2026-07-17): default = current branch, not `main` —
on the main workspace those are the same thing, and the default must be *visible* in
the UI so it's never a mystery. Flipping the default later should be a one-liner.

## Scope

- **Model** (`macos/Sources/Features/Worktrees/Worktree.swift`):
  `GitWorktreeModel.createWorktree(branch:forCwd:)` gains an optional `from base:
  String?`. A non-nil base is appended as the explicit start point:
  `git worktree add <dest> -b <branch> <base>`. Nil keeps today's behavior (HEAD of
  the main root). Git validates the ref — a bad base surfaces through the existing
  `WorktreeCreateError.git` path, no client-side validation.
- **View model** (`macos/Sources/Features/Worktrees/WorktreeSidebarViewModel.swift`):
  - `createWorktree(branch:base:)`: trim the base; if empty, fall back to
    `defaultBaseBranch`; if that's nil too, pass nil.
  - New `var defaultBaseBranch: String? { selectedWorktree?.branch }` — a single
    place defining the default, used by both the create path and the UI placeholder.
- **UI** (`macos/Sources/Features/Terminal/WorktreeSidebarViewController.swift`,
  `newWorktreeSection` in `WorktreeSidebarList`): a second inline field under the
  branch-name field, e.g. `from  [base field]`, whose *placeholder is the resolved
  default* (`defaultBaseBranch ?? "main HEAD"`). Keyboard-native: Tab moves between
  the two fields, **Return submits from either field**, Escape cancels from either.
  Existing behavior stays: inline errors only (never alerts), field text survives
  a failure, progress indicator while creating.
- **Tests** (`macos/Tests/Worktrees/WorktreeCreateTests.swift`): extend
  `FakeCreateRunner`'s argument capture. Cover: explicit base is passed through as
  the trailing argument; blank base falls back to the selected worktree's branch;
  no selection and no base → no start-point argument; bad base → inline error
  (reuse the `.git` stderr path). Update the existing arg-assertion tests.

## Out of scope

- No config key for the default; no branch-name autocomplete; no validation beyond
  git's own. No fetch before branching (documented M4 behavior). Don't touch the
  switching (M3) layer.

## Verify

- `zig build` clean (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
  `PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"`).
- `cd macos && xcodebuild test -scheme Ghostty -destination 'platform=macOS'
  -only-testing:GhosttyTests/WorktreeCreateTests
  -only-testing:GhosttyTests/WorktreeSidebarViewModelTests
  -only-testing:GhosttyTests/WorktreeCycleTests` — all green.
- Manual: from a non-main workspace, create with base blank → new branch stacks on
  the active branch. Type `main` as base → branches from main. Bad base ref →
  inline error, field text intact.
- Update the README's "Create a worktree" bullet for the base field + default.

## Workflow

- Commit here on `feat/wt-new-base`; push to `origin` (**eu-lee/ghostty only** — see
  AGENTS.md). Open a PR with `gh pr create --repo eu-lee/ghostty --base
  feat/wt-new-flow-m4`. **Do not merge** — the human merges.
- Heads-up: `09-wt-sidebar-keyboard` (sibling branch) also edits
  `WorktreeSidebarViewController.swift`; expect a small conflict at merge time.
