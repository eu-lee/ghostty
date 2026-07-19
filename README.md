<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty &mdash; worktree fork
</h1>
  <p align="center">
    A personal fork of <a href="https://github.com/ghostty-org/ghostty">ghostty-org/ghostty</a>.
    <br />
    This README covers what the fork adds and how to build it. For upstream
    Ghostty &mdash; downloads, documentation, and the full feature set &mdash;
    see the <a href="https://ghostty.org">original project</a>.
  </p>
</p>

## What this fork adds

A macOS-native **git worktree sidebar**. Each window can list the worktrees of
the repository its terminal is in and switch the whole window between
per-worktree workspaces. Worktrees are resolved from the window's working
directory.

A *workspace* is the window's entire split layout — switching swaps every pane
at once, and the workspace you leave keeps running in the background: processes,
scrollback, and layout all survive, and switching back restores them exactly.

The sidebar header shows `root: <path>` — the directory the worktrees link to
(the main worktree), which stays fixed no matter which worktree you're on. The
**main worktree is pinned to the top**; the worktree the window is currently
switched to is marked with a leading `*`. Worktrees with a live session
("active") are grouped above the inactive ones, and any worktree whose session
has rung its bell shows a bell indicator on its row.

### Keybinds

All bindings below are macOS-only; the actions are no-ops elsewhere. Defaults
are compiled into this fork's build (see `src/config/Config.zig`); the cycle
actions ship unbound so you can bind them yourself.

| Action | Default bind | What it does |
| --- | --- | --- |
| `toggle_worktree_sidebar` | `cmd+shift+e` | Show or hide the worktree sidebar. |
| `worktree_picker` | `cmd+opt+n` | Open the worktree palette (press again, or `esc`, to close it). |
| `goto_worktree:next` | _(unbound)_ | Switch to the next active worktree. |
| `goto_worktree:previous` | _(unbound)_ | Switch to the previous active worktree. |
| `close_worktree_session` | `cmd+opt+c` | Tear down the selected worktree's live session, leaving the worktree on disk. |
| `remove_worktree` | `cmd+opt+backspace` | `git worktree remove` the selected worktree (branch left intact). |

To bind the unbound actions, add them to your Ghostty config, e.g.:

```ini
keybind = cmd+alt+right_bracket=goto_worktree:next
keybind = cmd+alt+left_bracket=goto_worktree:previous
```

### Using it

- **Open the sidebar** with `cmd+shift+e` or View → Worktree Sidebar.
- **Switch, open, or create** with the palette (`cmd+opt+n`, also reachable via
  View → Go to Worktree…). It's one search bar, sectioned:
  - **Worktrees** — live worktrees; choosing one switches to it.
  - **Branches** — local branches with no worktree; choosing one runs
    `git worktree add ../<repo>-worktrees/<branch> <branch>` and opens it.
  - **Create branch '<query>'** — shown when your query matches nothing; runs
    `git worktree add ../<repo>-worktrees/<branch> -b <branch> <base>` using the
    selected worktree's branch as the default base (or repository HEAD if none
    is selected).

  Worktrees live in a visible container directory next to the repository, one
  subdirectory per branch (slashes become dashes). Git errors show inline in
  the palette, never as alerts.
- **Close a session** with `close_worktree_session` (`cmd+opt+c`) or a row's
  right-click **Close Session**. This drops the worktree's live workspace and
  returns the row to inactive; the worktree stays on disk, and opening it again
  starts a fresh session.
- **Remove a worktree** with `remove_worktree` (`cmd+opt+backspace`) or a row's
  right-click **Remove Worktree…**, which runs `git worktree remove` for that
  checkout. The branch is left intact. If git refuses because the worktree is
  dirty, the sidebar shows the error inline and offers **Force remove**.

The keybind actions act on the sidebar's currently selected worktree, whether or
not the sidebar is showing. Removal is refused for the main worktree, and
closing a worktree with no live session is a no-op. The sidebar's collapsed
state and width are remembered for the app session (new windows inherit them);
persisting across restarts, and dirty / ahead-behind indicators, are non-goals
for v1. Creation and removal never delete branches.

## Building & running

Requires **Zig 0.15** and a full **Xcode** install (the Command Line Tools
alone aren't enough for the macOS app).

### Debug build (for hacking)

```sh
zig build
```

Produces `macos/build/Debug/Ghostty.app`. Add `-Demit-macos-app=false` to skip
the app bundle when you only need the core to compile. The debug app uses a
separate bundle id (`com.mitchellh.ghostty.debug`), so it runs happily
alongside a stable install.

### A real build to install

Use the **ReleaseLocal** configuration — optimized and ad-hoc code-signed, with
no notarization or auto-update (the right trade-off for a personal fork):

```sh
cd macos && ./build.nu --configuration ReleaseLocal
```

Produces `macos/build/ReleaseLocal/Ghostty.app`; drag it into `/Applications`.
Because it isn't notarized, Gatekeeper will complain on first launch — either
right-click → **Open** once, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Ghostty.app
```

There's no auto-update, so re-run the build after you pull. The full,
notarized `Release` pipeline (Developer ID signing + Sparkle appcast) is
upstream's distribution path and needs an Apple Developer account — out of
scope for this fork.

## Upstream

Everything not described above is upstream Ghostty. It's a fast, native,
feature-rich terminal emulator; for the full story, downloads, and
documentation see [ghostty.org](https://ghostty.org) and
[ghostty-org/ghostty](https://github.com/ghostty-org/ghostty).
