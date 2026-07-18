# 10 — feat/wt-ui-overhaul  (Sidebar looks like a terminal split)

**Base:** `main` (M4 + base-ref merged, PR #9). · **Status:** READY.
· **Worktree:** `~/Documents/Code/ghostty-wt-ui`.

## Purpose

From the human (2026-07-17): the sidebar today is "a poorly rendered sidebar" —
macOS vibrancy material, translucent `.sidebar` list style, SF Symbol icons,
capped at 280pt. It should instead read as **another pane of the terminal**, the
way a `cmd+D` split does: terminal background color, a thin divider matching
`split-divider-color`, monospaced TUI-esque typography, and a larger footprint.
"TUI-esque rather than rendered on" is the design bar — if a row would look at
home in `git branch` output inside a terminal, it's right; if it looks like
Finder's sidebar, it's wrong.

## Reference: how a real split looks

Study these before styling anything:

- `macos/Sources/Features/Splits/TerminalSplitTreeView.swift` — split rendering;
  note `dividerColor: ghostty.config.splitDividerColor` passed to `SplitView`.
- `macos/Sources/Features/Splits/SplitView.swift` — the custom divider.
- `macos/Sources/Ghostty/Ghostty.Config.swift` — `backgroundColor` (~line 486)
  and `splitDividerColor` (~line 547) accessors. There is **no** foreground
  accessor yet (see Scope).
- `macos/Sources/Features/Terminal/TerminalViewContainer.swift` (~line 224/273)
  — how the terminal pane applies `derivedConfig.backgroundColor`.

## Scope

All in `macos/Sources/Features/Terminal/WorktreeSidebarViewController.swift`
unless noted.

### 1. Pane chrome — match the split

- **Kill the vibrancy**: `WorktreeSidebarListViewController.loadView` currently
  wraps the hosting view in an `NSVisualEffectView` (`material: .sidebar`).
  Replace with a plain hosting view whose SwiftUI root paints
  `ghostty.config.backgroundColor` edge to edge.
- **Config access**: the sidebar has no `Ghostty.App` today. Thread it through
  `TerminalController.installWorktreeSidebar` (the controller has
  `self.ghostty`) → `WorktreeSidebarViewController.init` → the SwiftUI root as
  an `@ObservedObject`. `Ghostty.App` is an `ObservableObject`, so config
  reloads re-render the sidebar with the new colors for free — verify this
  manually with a config reload.
- **Divider**: `WorktreeSidebarSplitView` (the private `NSSplitView` subclass
  already in this file) overrides `dividerColor` to return
  `NSColor(config.splitDividerColor)`. Keep `dividerStyle = .thin`.
- **Foreground color**: add a `foregroundColor` accessor to
  `Ghostty.Config` mirroring `backgroundColor` (key `"foreground"`, fallback
  `NSColor.textColor` on macOS). Primary text uses it; secondary text is the
  same color at reduced opacity (~0.5). Do not use system `.secondary` — that's
  the "rendered on" look leaking back in.

### 2. TUI-esque content

- **Monospaced throughout**: `.font(.system(size: 12, design: .monospaced))` as
  the baseline for rows, filter, and the new-worktree fields. (Using the actual
  configured terminal font family is out of scope — note a TODO.)
- **List**: replace `List` + `.listStyle(.sidebar)` with `ScrollView` +
  `LazyVStack(spacing: 0)`. This drops the translucent list chrome and row
  insets and gives full-width control of row backgrounds. Keep the whole-row
  tap-to-switch behavior and `.help` tooltips.
- **Rows read like `git branch` output**: drop the SF Symbol icons
  (`arrow.triangle.branch` etc.). A two-character text gutter instead: `*` in
  the gutter for the selected worktree, spaces otherwise; main's row keeps
  `.semibold`; detached worktrees render their name dimmed (secondary opacity)
  instead of carrying an icon. Selection highlight is a full-width block of the
  foreground color at low opacity (~0.15) — reverse-video-ish, not the accent
  color, not a rounded rect.
- **Filter field as a prompt**: replace the `line.3.horizontal.decrease.circle`
  icon with a `>` glyph in the same monospaced font; keep
  `.textFieldStyle(.plain)`.
- **New-worktree section**: keep all behavior from M4/plan 08 exactly (inline
  fields, Return/Escape, inline errors, progress, field text survives failure).
  Restyle only: `+` text glyph instead of `plus.circle`, monospaced fields,
  error text in a plain red monospaced caption.

### 3. Larger

- `sidebarItem.minimumThickness` 180 → **240**, `maximumThickness` 280 →
  **420**.
- When no session width has been recorded yet, the first expanded width should
  be ~300 (today it's whatever AppKit picks near the minimum). Easiest: default
  `sessionWidth` to 300 instead of `nil`. Session memory semantics otherwise
  unchanged (in-memory, inherited by new windows).

## Out of scope

- Terminal font family from config (system monospaced is fine for v1).
- Background opacity/blur parity with translucent terminals — the sidebar
  paints the solid config background even when `background-opacity < 1`.
- Any view-model or git-layer change; sidebar behavior (switching, creation,
  session state) is untouched. No Linux work.
- The active-indicator dots and picker from `09-wt-picker` (sibling plan).

## Verify

- `zig build` clean (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
  `PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"`).
- `cd macos && xcodebuild test -scheme Ghostty -destination 'platform=macOS'
  -only-testing:GhosttyTests/WorktreeCreateTests
  -only-testing:GhosttyTests/WorktreeSidebarViewModelTests
  -only-testing:GhosttyTests/WorktreeCycleTests` — all green (this plan is
  view-layer only; no test changes expected).
- Manual (Debug app): open the sidebar next to a `cmd+D` split — sidebar
  background matches the terminal background exactly and both dividers look the
  same; repeat with a light theme config; reload config with a different
  `background` → sidebar follows; resize beyond the old 280 cap; collapse/
  expand animation and session width memory still work; create-worktree flow
  visually matches but behaves identically.

## Workflow

- Commit here on `feat/wt-ui-overhaul`; push to `origin` (**eu-lee/ghostty
  only** — see AGENTS.md). Open a PR with `gh pr create --repo eu-lee/ghostty
  --base main`. **Do not merge** — the human merges.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`;
  PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Conflict heads-up: `09-wt-picker` and `11-wt-nested` (sibling branches) also
  touch the sidebar rows in `WorktreeSidebarViewController.swift`. Whichever
  lands second rebases; this plan owns the *look*, they own row *content*
  (indent / active dot), so resolutions should compose.
