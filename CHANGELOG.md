# Changelog

## 0.3.1

### Added

- `folders` setup option to list workspace folders alongside or instead of `files`.

### Changed

- Cache the detected terminal theme in `~/.cache/rex-workspaces/theme.json` and refresh it on close so the Workspaces window draws immediately on open.
- Reduce redundant Rex RPC calls and skip spawning a login shell when opening, closing, or resizing the Workspaces window.

## 0.3.0

### Added

- **Save & Close** (`Ctrl+S`) saves the session and closes it, so its memory and ports are freed. **Open** rebuilds it, even after a restart. Idle shells show their old output, and `claude`, `codex` and `opencode` panes resume their own conversation. **Forget saved** throws it away.
- `workspace_save_close` and `workspace_pause` actions, and Save & Close and Pause entries in the command palette. Pause stops every process in the session where it is until you **Open** it. Saved sessions and paused processes are recorded in `~/.local/state/rex-workspaces`, or `$XDG_STATE_HOME/rex-workspaces`.
- Panes and groups take a `size`, their share of the width or height. **Save new** and **Save & Close** record the sizes you dragged.
- **Use current layout** (`Ctrl+L`) in the edit form copies a running workspace's tabs, panes and sizes from its session.
- Workspaces are read from every `.json` file under a `workspaces` folder next to `init.lua`, including subfolders up to 8 levels deep. A `files` entry that is a folder is read the same way. Files and folders whose names start with `.` are skipped.
- The Workspaces window lists running workspaces first and selects the workspace of the session you are in.
- `workspace_open` takes `select=false` to open a workspace without switching to it.

### Changed

- The Workspaces window shows only the buttons that apply to the selected workspace. **New**, **Save new** and **Filter** are on a line above them.
- **Start**, **Stop** and **Restart** each show only when they apply, so a workspace with one server down shows all three. **Open** starts the servers of a workspace that is not running.
- **Save as new** is now **Save new**.
- Keys in the window: `s` starts servers, `x` stops them, `r` restarts them, `Ctrl+S` saves and closes, `c` closes the session. In 0.2, `s` toggled between Start and Stop.

### Fixed

- `workspaces.local.json` and other `workspaces.*.json` files next to `init.lua` are read by default, as documented. Before, only `workspaces.json` was.
- **Open** in the Workspaces window switches to the session when more than one Rex app is connected, instead of failing with "no client is targeted".
- The Workspaces window no longer crashes when it is small, or when it is opened from a minimized or floating pane.
