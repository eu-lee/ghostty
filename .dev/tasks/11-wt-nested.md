# 11 — feat/wt-nested-indent  (Nested worktrees indent in the sidebar)

**Base:** `main` (M4 + base-ref merged, PR #9). · **Status:** READY.
· **Worktree:** `~/Documents/Code/ghostty-wt-nest`.

## Purpose

From the human (2026-07-17): worktrees that are nested — worktrees created *from*
another worktree, i.e. stacked branches — should render indented under their
parent in the sidebar, recursively ("worktrees of worktrees, etc.").

## Design: parentage must be recorded, not guessed

Git records no "branched from" relationship, and our path convention flattens
every worktree into the same `../<repo>-worktrees/` container beside the *main*
root (creation always runs at the main root — see
`GitWorktreeModel.createWorktree` in
`macos/Sources/Features/Worktrees/Worktree.swift`). So nesting cannot be derived
from paths or refs; we record it ourselves at creation time:

- **Custom git config key**, `branch.<child>.ghosttyparent = <base-branch>`.
  Git ignores unknown branch.* keys, so this has **zero effect on git behavior**.
  Deliberately NOT `--track`/upstream (`branch.<name>.merge`): that would change
  `git pull`/`git status` semantics for the user's branches.
- Worktrees created outside Ghostty (or before this lands) simply have no entry
  and render as roots — graceful, no migration.

## Scope

### 1. Record parentage on create (`Worktree.swift`)

- After a **successful** `git worktree add`, when the create used an explicit
  base (`from base:` non-nil — note the view model already resolves a blank
  field to `defaultBaseBranch`, so most creates have one), run best-effort:
  `git config branch.<branch>.ghosttyparent <base>` at the repo root.
  Failure is logged and swallowed — never fail the create over metadata.

### 2. Read parentage on refresh (`Worktree.swift`)

- New `GitWorktreeModel.worktreeParents(forCwd:) async -> [String: String]`
  (child branch → parent branch) via
  `git config --get-regexp '^branch\..*\.ghosttyparent$'`, run at the repo root
  with the existing 2s read timeout. Exit status 1 (no matches) → empty map.
  Parse in a pure, testable function (note: branch names may themselves contain
  dots and slashes — split on the known prefix/suffix, not naively on `.`).

### 3. Hierarchy in the pure layer (`WorktreeSidebarViewModel.swift`)

- New pure helper on `WorktreeSidebar`, e.g.
  `hierarchy(_ worktrees: [Worktree], parents: [String: String]) ->
  [(worktree: Worktree, depth: Int)]` — a DFS flattening:
  - A worktree is a **root** (depth 0) when its branch has no parent entry, its
    parent branch has no worktree in the list, or its parent chain is cyclic
    (guard with a visited set — never crash or loop on bad config).
  - Children sort under their parent; within any sibling group the existing
    sidebar order is preserved (main pinned first among roots).
  - Deleted parent (worktree removed, config entry lingering) → child promotes
    to root. Same for detached parents without a matching branch.
- View model: `refresh` fetches worktrees + parents together;
  `filteredWorktrees` becomes the depth-annotated rows. **When a filter query
  is active, matches render flat (all depth 0)** — indenting under hidden
  ancestors is misleading. `cycleTarget` input stays the flattened DFS order —
  cycling semantics unchanged.

### 4. UI (`WorktreeSidebarViewController.swift`)

- Indent each row by `depth × 14`pt leading padding. Nothing else changes:
  tap-to-switch, tooltips, selection highlight, new-worktree section all as-is.

### 5. Tests

- Parser: `--get-regexp` output → map (incl. branch names with `/` and `.`,
  empty output, status-1 no-match).
- Hierarchy: chain of three → depths 0/1/2; siblings keep order; missing parent
  → root; cycle (`a→b→a`) → both roots, no hang; main pinned first; filter
  flattens depth.
- Create flow (extend `FakeCreateRunner` in
  `macos/Tests/Worktrees/WorktreeCreateTests.swift` to capture the config
  call): successful create with base runs
  `config branch.<child>.ghosttyparent <base>`; failed create does not; config
  failure still reports the create as successful.

## Out of scope

- Cleaning up stale `ghosttyparent` keys when branches/worktrees are deleted
  (harmless residue; leave a TODO). No re-parenting UI. No inference for
  pre-existing stacks (upstream/merge-base heuristics rejected as guessy).
- Collapse/expand of subtrees — indentation only for v1.
- No Linux work; no changes to switching, cycling semantics, or creation paths.

## Verify

- `zig build` clean (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
  `PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"`).
- `cd macos && xcodebuild test -scheme Ghostty -destination 'platform=macOS'
  -only-testing:GhosttyTests/WorktreeCreateTests
  -only-testing:GhosttyTests/WorktreeSidebarViewModelTests
  -only-testing:GhosttyTests/WorktreeCycleTests` — all green including the new
  hierarchy/parser coverage.
- Manual (Debug app): create worktree B with base = worktree A's branch → B
  appears indented under A; create C with base B → two levels; filter → flat;
  `git worktree remove` A from a shell, refresh (toggle sidebar) → B promotes
  to root; a repo with no ghosttyparent keys looks exactly like today.
- Update the README worktree section: one bullet on nested display + the
  `ghosttyparent` key (so users know what wrote it and that it's safe to
  delete).

## Workflow

- Commit here on `feat/wt-nested-indent`; push to `origin` (**eu-lee/ghostty
  only** — see AGENTS.md). Open a PR with `gh pr create --repo eu-lee/ghostty
  --base main`. **Do not merge** — the human merges.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`;
  PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Conflict heads-up: `10-wt-ui-overhaul` restyles the same sidebar rows and
  `09-wt-picker` adds an active dot to them; whichever lands second rebases.
  This plan's logic lives in the pure layer, so conflicts should be view-only
  (the indent padding line).
