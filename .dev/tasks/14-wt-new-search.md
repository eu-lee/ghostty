# 14 — feat/wt-new-search

**Base:** `main` (77c5a30df, PR #13 merged) · **Status:** ready now · **Worktree:** `../ghostty-wt-new-search`

## Purpose

Make **creating a worktree** keyboard-native by turning it into a search-style popup bar
— the same centered overlay as the "Go to worktree" picker — instead of the click-to-
expand inline field pinned at the bottom of the sidebar. The human's words: *"lets go
with search for new worktree. Like the popup bar."*

You trigger it with a keybind, a text field appears, you type the branch name, press
Return, and the worktree is created. No clicking.

## Model to copy: the worktree picker

The existing "Go to worktree" picker is exactly the interaction to mirror:

- Overlay view: `macos/Sources/Features/Command Palette/TerminalWorktreePicker.swift`
  (`TerminalWorktreePickerView`), built on the shared `CommandPaletteView`.
- Mounted in `macos/Sources/Features/Terminal/TerminalView.swift` (~L125) behind
  `viewModel.worktreePickerViewModel` / `$viewModel.worktreePickerIsShowing`.
- State on `BaseTerminalController` (~L52): `@Published var worktreePickerIsShowing`.
- Presented by `TerminalController.showWorktreePicker()` (which flips
  `worktreePickerIsShowing = true` and resigns the surface's first responder).
- Reached by the `worktree_picker` void keybind action.

Build the create-flow as a parallel of all of the above.

## Scope

### 1. The `new_worktree` void keybind action

Plumb a payload-free surface action `new_worktree` by copying `worktree_picker` across
every layer. Run `grep -rn worktree_picker src/ include/ macos/Sources` and add a sibling
entry at each hit:

- `src/input/Binding.zig` — `Action` enum (~L800) + `.surface` scope list (~L1414).
- `src/apprt/action.zig` — `Action` enum (~L118) + C-tag `Key` enum (~L372).
- `src/Surface.zig` — `performAction` arm (~L5379), `{}` payload.
- `src/input/command.zig` — no-command list (~L715).
- `include/ghostty.h` — `GHOSTTY_ACTION_NEW_WORKTREE` (regenerated from Zig; hand-add next
  to `GHOSTTY_ACTION_WORKTREE_PICKER` if it doesn't).
- `macos/Sources/Ghostty/Ghostty.App.swift` — `case GHOSTTY_ACTION_NEW_WORKTREE:` dispatch
  (~L540) + a `private static func showNewWorktree(...)` handler (~L1265, like
  `showWorktreePicker`) that resolves the `TerminalController` and calls the entry point.
- `macos/Sources/Features/Terminal/TerminalController.swift` — `func showNewWorktree()`
  that flips the new overlay's `isShowing` state (parallels `showWorktreePicker()`).

**Default (macOS):** `super+alt+n` (⌘⌥N), compiled into `src/config/Config.zig`'s default
keybind set (near the `super+shift+e` → `toggle_worktree_sidebar` entry, ~L7034). Verify
no `super+alt` collision first. Do **not** instruct the human to add it to
`~/.config/ghostty/config` (shared with the stable build, which won't know the action).

### 2. The create-worktree popup

A new overlay `TerminalNewWorktreeView`, mirroring `TerminalWorktreePickerView`:

- Centered popup bar (reuse `CommandPaletteView` chrome if it fits a free-text field; if
  the palette is too list-centric, a minimal styled `TextField` in the same centered
  card, matching the picker's geometry and `ghosttyConfig.backgroundColor`).
- Placeholder: `New worktree branch name…`.
- **Return** → create via the existing view-model call
  `WorktreeSidebarViewModel.createWorktree(branch:base:)` (already in main from M4).
  Base defaults to `viewModel.defaultBaseBranch ?? "main HEAD"` — same default the inline
  field uses today (`WorktreeSidebarViewController.swift`).
- **Escape** → dismiss, restore first responder to the surface (copy the
  `onChange(of: isPresented)` → `makeFirstResponder` handling from the picker).
- While creating: show progress and disable input (`viewModel.isCreatingWorktree`).
- On failure: surface `viewModel.createError` inline in the popup (never an NSAlert —
  matches the M4 guide). Keep the popup open with the typed name so it can be corrected.
- On success: dismiss, and if the sidebar is open, the new row appears via the normal
  refresh path.

**Base override (optional, nice-to-have):** a second line in the popup to override the
base ref (defaulting to `defaultBaseBranch`), matching the inline flow's "from" field. If
it complicates the popup, ship name-only for v1 and note the gap.

### 3. Wiring

- Add `@Published var newWorktreeIsShowing` to `BaseTerminalController` (parallel to
  `worktreePickerIsShowing`), and mutual-exclude it with the command palette / picker the
  same way those exclude each other (~L1439).
- Mount `TerminalNewWorktreeView` in `TerminalView.swift` next to the picker (~L125).

### 4. Keep the inline button

Leave the existing bottom-of-sidebar "New worktree…" inline affordance
(`WorktreeSidebarViewController.swift`, `newWorktreeSection`) as the mouse path — it is no
longer the *only* way in, but don't remove it. (If it's cleaner to have the inline button
just call `showNewWorktree()` and delete the inline fields, that's an acceptable
simplification — flag it before doing so.)

## Out of scope

- `close_worktree_session` / `remove_worktree` keybinds — that's **feat/wt-action-keybinds**
  (plan 13).
- GTK/Linux apprt — do not touch.
- The "create from the go-to-picker query when nothing matches" idea — not this branch.

## Merge note

Plan 13 also adds void actions by the same copy-`worktree_picker` recipe, so the branches
conflict trivially on the shared enum lists (`Binding.zig`, `action.zig`, `command.zig`,
`ghostty.h`). Resolve by **keeping both** sets of entries.

## Verify

- `zig build` compiles; macOS build launches.
- ⌘⌥N (with `cd` into a git repo first) pops the create bar over the terminal, sidebar
  open or closed.
- Typing a branch name + Return creates the worktree; the popup dismisses and focus
  returns to the terminal. With the sidebar open, the new row shows up.
- A bad name (e.g. an existing branch) keeps the popup open and shows the inline error.
- Escape dismisses without creating and restores terminal focus.
- No config change → all other keys behave as before.

## Handoff

`showNewWorktree()` on `TerminalController` and `newWorktreeIsShowing` on
`BaseTerminalController` are the stable seam. The inline sidebar button may route through
`showNewWorktree()` too, unifying both entry points on one popup.
