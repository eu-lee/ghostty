# 09 — feat/wt-picker  (Worktree picker + active-only cycling)

**Base:** `feat/wt-new-flow-m4` (stacks on PR #8; retarget the PR to `main` after #8
merges). · **Status:** READY. · **Worktree:** `~/Documents/Code/ghostty-wt-picker`.
Supersedes the abandoned `09-wt-sidebar-keyboard` plan (focus-cycling into the
sidebar — dropped: switching never required sidebar focus in the first place).

## Purpose

Two keyboard-navigation problems from the human (2026-07-17):

1. There's no way to jump *directly* to a specific worktree — only cycling.
2. Cycling (`goto_worktree:next/previous`) visits every worktree on the way, and
   each first visit lazily creates a terminal session (M3 behavior). Passing
   through spawns sessions the user never wanted.

Revamped model: a **searchable worktree picker** (command-palette style) for direct
jumps to *any* worktree, and **cycling narrowed to "active" worktrees only** — ones
that already have a live session — so `next/previous` becomes "switch between open
workspaces" and never creates sessions in passing. The picker is the only path that
opens an inactive worktree (deliberately, since it's a direct jump).

**Definitions:** a worktree is *active* when it has a live workspace in this window:
it's the attached tree (`WorktreeWorkspaceManager.activePath`) or has a detached
workspace (`manager.detached` keys). Everything else is *inactive* (a visit would
lazily create a session).

## Scope

### 1. New keybind action `worktree_picker` (Zig core + plumbing)

Follow the existing `toggle_worktree_sidebar` parameterless action end to end —
same files, same shape (see the `feat/wt-keybinds` history, PR #2, for the pattern):

- `src/input/Binding.zig` — action enum (near `toggle_worktree_sidebar`, ~line 799)
  and its actionable/performable classification (~line 1411).
- `src/apprt/action.zig` — apprt action (~line 117 area).
- `include/ghostty.h` — `GHOSTTY_ACTION_WORKTREE_PICKER` (~line 903 area).
- `src/Surface.zig` — action dispatch (grep `toggle_worktree_sidebar`).
- `macos/Sources/Ghostty/Ghostty.App.swift` — action-case dispatch to the key
  window's `TerminalController` (~line 525 area).
- **No default binding.** Document an example in the README:
  `keybind = cmd+alt+p=worktree_picker`. Also add a "Go to Worktree…" View-menu
  item next to "Worktree Sidebar" (see `AppDelegate.setupWorktreeSidebarMenuItem`)
  so the feature is discoverable and bindable via macOS keyboard settings.

### 2. Picker UI (macOS)

- Study `macos/Sources/Features/Command Palette/` (`CommandPalette.swift`,
  `TerminalCommandPalette.swift`) and how `TerminalController` presents the
  terminal command palette; **reuse those components/pattern** rather than
  building a new overlay from scratch.
- Content: one row per worktree — branch name (bold for main, existing
  `WorktreeSidebar.displayName`) + directory path as secondary text. Typing
  filters as-you-type (reuse `WorktreeSidebar.filter`; substring is fine, fuzzy
  is optional polish). Arrow keys move the highlight, **Return switches** to the
  highlighted worktree (`switchToWorktree`, the M3 path), **Escape closes**.
  Top match is pre-highlighted so type-then-Return is the fast path (this is the
  "autofill" ask).
- **Active first:** results sort active worktrees above inactive (stable within
  each group, main's pinned-first order preserved within groups). Active rows get
  a small indicator (e.g. a filled dot); inactive rows render secondary/dimmed —
  visually communicating "Return will open a new session here".
- Works with the sidebar closed: load worktrees on demand from the window cwd,
  exactly like the `gotoWorktree` keybind path does today
  (`TerminalController.gotoWorktree`, `worktreeSidebarCwd`).

### 3. Active/inactive state exposure

- Expose the active set from `WorktreeWorkspaceManager` (attached + detached
  keys) as a `Set<URL>` of canonical worktree keys; surface it through
  `TerminalController` into observable state the picker and sidebar read (e.g. a
  published `activeWorktreePaths` on the sidebar view model, updated on every
  switch/detach/workspace-close). Compare via `WorktreeWorkspaceManager.key(_:)`
  — never raw paths (case/symlink canonicalization, see M3's fix).
- Sidebar rows show the same active indicator dot (small, unobtrusive).

### 4. Cycling narrowed to active worktrees

- `goto_worktree:next/previous` cycles **only active worktrees**, in sidebar
  order. Fewer than 2 active → no-op (the picker is the discovery path). This is
  a deliberate behavior change from M3 — call it out in the PR body and update
  the README's cycling bullet.
- Implement in the pure layer: extend/wrap `WorktreeSidebar.cycleTarget` (e.g.
  filter the list to the active set before cycling, keeping canonical-path
  matching of `current`). Update `WorktreeCycleTests` for the new semantics and
  keep the old tests meaningful by passing "all active".

## Out of scope

- Worktree deletion, dirty indicators, persistence (still v1 non-goals). No Linux
  support; the new action is a documented no-op on non-macOS apprts (match what
  `toggle_worktree_sidebar` does there). No changes to sidebar click behavior or
  the New-worktree flow (that's `08-wt-new-base`, a sibling branch).

## Verify

- `zig build` clean (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
  `PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"`). Run the Zig binding tests for
  the new action too: `zig build test -Dtest-filter=worktree_picker` (add a parse
  test alongside the existing `goto_worktree`/`toggle_worktree_sidebar` ones).
- macOS suites green, including new coverage for active-first sorting and
  active-only cycling: `cd macos && xcodebuild test -scheme Ghostty -destination
  'platform=macOS' -only-testing:GhosttyTests/WorktreeCreateTests
  -only-testing:GhosttyTests/WorktreeSidebarViewModelTests
  -only-testing:GhosttyTests/WorktreeCycleTests` (+ any new picker test suite).
- Manual (Debug app): bind `cmd+alt+p=worktree_picker`, reload config. Picker
  opens with sidebar closed; typing filters; Return on an inactive worktree opens
  a session there directly with no intermediate sessions created; actives sort
  first with dots; `cmd+alt+[`/`]` only cycles worktrees that have sessions and
  no-ops with a single session; Escape closes the picker without switching.

## Workflow

- Commit here on `feat/wt-picker`; push to `origin` (**eu-lee/ghostty only** — see
  AGENTS.md). Open a PR with `gh pr create --repo eu-lee/ghostty --base
  feat/wt-new-flow-m4`. **Do not merge** — the human merges.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`;
  PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Heads-up: `08-wt-new-base` (sibling branch) also edits
  `WorktreeSidebarViewController.swift` and the README; expect small conflicts at
  merge time.
