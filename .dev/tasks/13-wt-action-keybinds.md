# 13 — feat/wt-action-keybinds

**Base:** `main` (77c5a30df, PR #13 merged) · **Status:** ready now · **Worktree:** `../ghostty-wt-keybinds`

## Purpose

Make worktree **close-session** and **remove-worktree** keyboard-native. Today they
are context-menu-only (right-click a sidebar row). Add config-bindable Ghostty
keybind actions that act on the **current** worktree from anywhere (including terminal
focus), mirroring the existing `worktree_picker` void action end to end.

The in-sidebar arrow/Return/Delete navigation idea was **dropped** on purpose — the
human wants these to be plain Ghostty config keybinds, not a bespoke focus mode in the
SwiftUI list. Do not add `.focusable()` / `.onMoveCommand` / key handling to the list.

## Scope

Add two **void** keybind actions:

- `close_worktree_session` → tears down the current worktree's live session
  (calls `TerminalController.deactivateWorktree(_:)`).
- `remove_worktree` → removes the current worktree from disk
  (calls `TerminalController.deleteWorktree(_:)`).

Both already exist as methods on `TerminalController` (added by feat/wt-manage, now in
main) and both already show their own confirmation dialogs — the keybind path just needs
to resolve "the current worktree" and call them. Resolve current as
`worktreeSidebarViewController?.viewModel.selectedWorktree` (the `*` row). No-op cleanly
when there is no sidebar / no selection.

### The template: copy `worktree_picker`

`worktree_picker` is a payload-free ("void") surface action already plumbed through
every layer. To add each new action, replicate it. Run:

```
grep -rn worktree_picker src/ include/ macos/Sources
```

and add a sibling entry for `close_worktree_session` / `remove_worktree` at **every**
hit. The layers are:

1. `src/input/Binding.zig` — `Action` enum entry (near `worktree_picker`, ~L800) **and**
   the `.surface` scope list (~L1414).
2. `src/apprt/action.zig` — `Action` enum entry (~L118) **and** the C-tag `Key` enum (~L372).
3. `src/Surface.zig` — the `performAction` arm (~L5379) that forwards
   `.{ .surface = self }` with a `{}` payload.
4. `src/input/command.zig` — add to the "no commands in palette" list (~L715).
5. `include/ghostty.h` — the `GHOSTTY_ACTION_*` enum member (~L903). Regenerated from Zig
   by the build; if it does not regenerate, add it by hand next to
   `GHOSTTY_ACTION_WORKTREE_PICKER`.
6. `macos/Sources/Ghostty/Ghostty.App.swift` — the `case GHOSTTY_ACTION_*:` dispatch
   (~L540) **and** a `private static func` handler (~L1265, like `showWorktreePicker`)
   that resolves the target's `TerminalController` and calls the new entry point.
7. `macos/Sources/Features/Terminal/TerminalController.swift` — the entry-point method,
   e.g. `func closeCurrentWorktreeSession()` / `func removeCurrentWorktree()`, each
   guarding on `selectedWorktree` then calling the existing
   `deactivateWorktree`/`deleteWorktree`.

## Defaults (macOS) — `cmd+option` namespace

Ship these **compiled** into `src/config/Config.zig`'s default keybind set (next to the
`super+shift+e` → `toggle_worktree_sidebar` entry, ~L7034). Compiled defaults live in the
fork's binary, **not** in the human's `~/.config/ghostty/config`, so the stable build is
unaffected.

- `close_worktree_session` → `super+alt+w` (⌘⌥W)
- `remove_worktree` → `super+alt+backspace` (⌘⌥⌫) — destructive, but the method confirms
  first, so a default bind is acceptable. If you'd rather ship it **unbound**, that's a
  fine call — flag it.

Before committing a default, confirm the chord is free: grep the default set in
`Config.zig` for `super = true, .alt = true` collisions. If either chord is taken, pick
another `cmd+option` chord and note it.

**Do not** tell the human to add these to `~/.config/ghostty/config` — that file is shared
with the stable Ghostty, which won't recognize the new action names and will log errors.
Rely on the compiled defaults.

## Out of scope

- The `new_worktree` action and the create-worktree search popup — that's
  **feat/wt-new-search** (plan 14).
- GTK/Linux apprt — do not touch.
- Any change to the sidebar list's rendering or focus behavior.

## Merge note

Plan 14 also adds a void action (`new_worktree`) by the same copy-`worktree_picker`
recipe, so the two branches will conflict trivially on the shared enum lists
(`Binding.zig`, `action.zig`, `command.zig`, `ghostty.h`). Resolve by **keeping both**
sets of entries. No logic overlaps.

## Verify

- `zig build -Demit-macos-app=false` compiles; full macOS build launches.
- With the sidebar open on a repo: ⌘⌥W on a worktree with a live session tears it down
  (confirmation dialog appears if a process is running); the view falls back to main when
  you close the session you're viewing.
- ⌘⌥⌫ on a removable worktree shows the remove confirmation and deletes the checkout.
- Both are no-ops (no crash) with the sidebar collapsed / no worktree selected.
- A window with no config change behaves identically to before for all other keys.

## Handoff

Entry points `closeCurrentWorktreeSession()` / `removeCurrentWorktree()` on
`TerminalController` are the stable seam. Keep names stable; nothing else depends on this
branch.
