# 15 — feat/wt-unified-palette

**Base:** `main` (87b3e4395) · **Status:** ready now · **Worktree:** `../ghostty-wt-unified`

## Purpose

Merge the three separate worktree entry points into **one search palette** — the same
searchbar overlay the "Go to worktree" picker already uses. You open one palette, type,
and it does whichever of these fits what you typed:

| You type… | Match | Enter does | (was) |
|---|---|---|---|
| part of a live worktree's name | **Worktrees** section | switch to that worktree | `worktree_picker` |
| a branch that exists but has no worktree | **Branches** section | `git worktree add <path> <branch>` (no `-b`) → open it | *(new)* |
| a name matching nothing | a **"Create branch '…'"** row | `git worktree add <path> -b <name> [base]` → open it | `new_worktree` popup |

This absorbs the standalone `new_worktree` create popup and adds the missing ability to
spin up a worktree from a **pre-existing branch** (today `createWorktree` always passes
`-b`, so existing branch names just error — see `Worktree.swift:85`).

The look and feel must stay the **existing searchbar** (`CommandPaletteView`), not a new
bespoke UI. The human asked for "that same searchbar thing."

## Background (current state on main)

- Picker overlay: `macos/Sources/Features/Command Palette/TerminalWorktreePicker.swift`
  (`TerminalWorktreePickerView`) → wraps the shared `CommandPaletteView`
  (`Features/Command Palette/CommandPalette.swift`). Options are `CommandOption`
  (title, subtitle, `sectionTitle`, `leadingColor`, `isDimmed`, `titleWeight`, `action`).
- Create popup: `TerminalNewWorktree.swift` (`new_worktree` action, `cmd+opt+n`) — **to be
  removed / absorbed** by this palette.
- Model: `Worktree.swift` — `createWorktree(branch:from:forCwd:)` unconditionally uses
  `-b`; `worktrees(forCwd:)` returns `[Worktree]` where each carries its `branch` name.
- VM: `WorktreeSidebarViewModel` — `createWorktree(branch:base:)`, `select(_:)`,
  `activeWorktreePaths`, `defaultBaseBranch`, `isLive(_:)`, `hasLoaded`, `refresh(cwd:)`.

## Scope

### 1. Model: list branches + open an existing branch (`Worktree.swift`)

- **List local branches.** Add `func localBranches(forCwd:) async -> [String]` running
  `git for-each-ref --format=%(refname:short) refs/heads` (fast, already-sorted). Reuse
  `repoRoot` + `runner.runGit` like the existing queries.
- **Open an existing branch as a worktree.** Either add a dedicated
  `func addWorktree(forExistingBranch branch:forCwd:) async -> Result<URL, WorktreeCreateError>`
  running `git worktree add <destination> <branch>` (**no `-b`, no base**), or thread an
  `existingBranch: Bool` through `createWorktree`. Prefer a **separate method** — the two
  intents (create-new vs check-out-existing) read clearly and share nothing but the
  destination path (`WorktreeSidebar.newWorktreePath(repoRoot:branch:)`).

### 2. VM: expose branches-without-a-worktree + dispatch (`WorktreeSidebarViewModel`)

- On `refresh`, also load `localBranches`. Compute **branches that have no worktree** =
  `localBranches` minus the set of branch names already present in `worktrees` (each
  `Worktree.branch`). Expose as a published `branchesWithoutWorktree: [String]`.
- Add callbacks/methods so the palette can act:
  - switch to an existing worktree (already `select(_:)` / `onSelect`),
  - **open** an existing branch (new: create the worktree for it, then select/switch),
  - **create** a new branch+worktree (existing `createWorktree`).
- Keep the create/​open error surfacing via `createError` (rendered inline, never an
  alert — M4 guide).

### 3. The palette: sections + a live-query "create" row

Rework `TerminalWorktreePickerView` (rename to something like `TerminalWorktreePalette`
if clearer) to build a **sectioned** option list from the VM:

- Section **"Worktrees"** — existing worktrees, active-first
  (`WorktreeSidebar.activeFirst`), `action` = switch. (This is today's behavior.)
- Section **"Branches"** — `branchesWithoutWorktree`, dimmed, `action` = open-existing.
- A trailing **"Create branch '<query>'…"** row, shown when the query is non-empty and
  doesn't exactly equal an existing worktree/branch name, `action` = create-new.

**The filtering gotcha (important):** `CommandPaletteView.filteredOptions`
(`CommandPalette.swift:88`) filters `options` by the typed query (title/subtitle match).
A synthetic "Create '<query>'" row built from static options would be **filtered out**,
and the wrapper never sees the live query (it lives in `CommandPaletteView`'s internal
`rawQuery`). So you must give the shared palette a live-query hook. Recommended:

> Add an optional parameter to `CommandPaletteView`, e.g.
> `trailingOption: ((String) -> CommandOption?)?`, which — given the current query — can
> return one extra option that is appended **after** filtering (never filtered out) and
> re-rendered as the query changes. The worktree palette passes a closure that returns the
> "Create branch '<query>'" option (nil when the query is empty or exactly matches an
> existing worktree/branch). This keeps the exact searchbar look and centralizes query
> handling.

If touching the shared `CommandPaletteView` proves too invasive, the fallback is a
worktree-specific palette view that mirrors `CommandPaletteView`'s chrome but owns its own
query state — **flag this to the human before taking the fallback**, since it duplicates
UI.

### 4. Base ref for create-new

Keep v1 simple: create-new uses the default base (`viewModel.defaultBaseBranch ??` repo
HEAD), same as today's default. **Do not** add a second inline field to the searchbar
(there's no room and it breaks the single-bar feel). A base override is a follow-up (could
be `name from base` query syntax later) — note it as out of scope, don't build it.

### 5. Keybind unification

One palette, one entry point. Recommended:

- The unified palette **is** the enhanced `worktree_picker` action. Bind it to `cmd+opt+n`
  in `Config.zig` (reuse the chord users just learned from `new_worktree`).
- **Remove** the now-redundant `new_worktree` action and `TerminalNewWorktree.swift`
  (absorbed). That means deleting `new_worktree` from every layer it was added to — run
  `grep -rn new_worktree src/ include/ macos/Sources` and remove each entry, plus the
  Zig parse test and the Config.zig default, plus the iOS `membershipExceptions` entry in
  `macos/Ghostty.xcodeproj/project.pbxproj`, plus `showNewWorktree` /
  `newWorktreeIsShowing` wiring.

Confirm the final chord with the human if unsure — this is the one user-facing choice.
Leave `close_worktree_session` / `remove_worktree` untouched (separate concern).

## Out of scope

- Base-ref override in the create flow (note above).
- Remote branches — local branches only for v1 (`refs/heads`).
- Branch *deletion* — unrelated.
- GTK/Linux apprt.

## Verify

- `zig build` (full macOS app) compiles; artifact reports `feat-wt-unified-palette`.
- Open the palette (⌘⌥N): typing part of a live worktree shows it under **Worktrees** and
  Enter switches; typing an existing branch with no worktree shows it under **Branches**
  and Enter creates+opens its worktree; typing a brand-new name shows **"Create branch
  '…'"** and Enter creates+opens with a new branch.
- The create row reflects the live query as you type and is never filtered away.
- Errors (e.g. invalid name, dirty state) render inline in the palette, not as an alert.
- `new_worktree` is gone (no dangling references); README updated to describe the single
  palette instead of the separate picker + create popup.
- Zig parse tests updated (removed `new_worktree` test; the palette action still parses).

## Handoff / docs

Update `README.md`'s "Worktree Sidebar" section: replace the separate "worktree picker"
and "new worktree popup" descriptions with the one unified palette (switch / open existing
branch / create new), and fix the keybind table. The `close_worktree_session` /
`remove_worktree` rows stay as-is.
