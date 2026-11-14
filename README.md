# rex-workspaces


https://github.com/user-attachments/assets/78a10da3-f01a-4819-8c8f-9db29d1b3382


rex-workspaces manages your projects in [Rex](https://www.superlogical.com/rex): save and configure workspaces in any project so you can easily start and stop them.

A workspace is a saved definition of a Rex session. It configures the folders, tabs, panes, servers, and commands you want automatically opened or closed at the click of a button ⏺️

The default hotkey is <kbd>Cmd</kbd>+<kbd>O</kbd>, [but can be configured](#setup-options)

## Requirements

[Rex](https://www.superlogical.com/rex/docs/installation) ([Remote Control enabled](#turn-on-remote-control)) + macOS or Linux

## Install

Installation will update your Rex `init.lua` and download the latest release of rex-workspaces into `~/.config/rex/rex-workspaces`.

### Homebrew

```sh
brew trust agarun/tap
brew install agarun/tap/rex-workspaces
rex-workspaces install
```

or

### Install script

```sh
curl -fsSL https://raw.githubusercontent.com/agarun/rex-workspaces/main/install.sh | sh
```

### Building from source

To instead build from source:

```sh
git clone https://github.com/agarun/rex-workspaces
cd rex-workspaces
make install
```

### Installation

The install step will:

1. Link the Lua module to `~/.config/rex/rex-workspaces`.
2. Add `require("rex-workspaces").setup{}` to `~/.config/rex/init.lua`.
3. Create `~/.config/rex/workspaces.json` with a `my-project` example.
4. Reload the Rex config.

The Rust binary (`rex-workspaces`) is then downloaded and installed (from this repo), enabling the interface, or you can build it from source.

### Turn on Remote Control

For full support, the workspaces window and `rex do` need _Remote Control_ enabled to switch you to a workspace session.

1. In Rex, open **Settings** (<kbd>Cmd</kbd>+<kbd>,</kbd>).
2. Turn on **Remote Control**.

### Update

- Homebrew: `brew upgrade rex-workspaces`
- Install script: run the script again.
- Source: `git pull`, then `make install`.

### Uninstall

```sh
rex-workspaces uninstall
```

This removes the `require` line from `~/.config/rex/init.lua`, removes
`~/.config/rex/rex-workspaces`, and reloads Rex. It keeps `~/.config/rex/workspaces.json`.

If you used Homebrew, run `brew uninstall rex-workspaces` after this command.

### Remote hosts

Each Rex server reads its own config and runs its panes on its own machine, so install rex-workspaces on
each host where you want to use it. The workspaces window lists the workspaces of the host it opens on. If
that host does not have rex-workspaces, the pane shows the install command to run there.

When another host in `rex hosts` also has rex-workspaces, the window shows a host row above the buttons.
Press <kbd>h</kbd> to switch to the next host and manage its workspaces from the same window. On another
host, **Open** starts the workspace without switching to it, and **Save as new** is not available.

To use another host's workspaces from this machine, send the action to that host with `-S`:

```sh
rex -S desktop do workspace_list
rex -S desktop do workspace_start name=my-project select=false
```

Then switch to that session in Rex.

## How to use

Press <kbd>Cmd</kbd>+<kbd>O</kbd> in Rex to open or close the workspaces window. Press it again to
close the window.

- Select a workspace, then click a button or press its own hotkey.
- **New** creates a workspace for the current folder. It suggests the dev servers it finds in
  `package.json`, `Makefile` and `Procfile`. Examine them, then save. The name is the
  folder's name, or if not available it's just `untitled`.
- **Save as new** saves the session you are in as a new workspace. See
  [Save a session](#save-a-session).
- **Edit** opens a form with all options, a folder picker, and the commands found in the
  folder.
- To set a **Shortcut** in the form, press <kbd>Enter</kbd>, then press the keys, for example
  <kbd>Ctrl</kbd>+<kbd>Cmd</kbd>+<kbd>1</kbd>. You can also type the shortcut. The window
  cannot record keys that Rex already uses, for example <kbd>Cmd</kbd>+<kbd>O</kbd>.

All configuration is saved in a `workspaces.json` file on your machine.

### Actions

| Action      | Result                                                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------------------------- |
| **Open**    | Switches to the session. If the session does not exist, starts it.                                                  |
| **Start**   | Opens the session and starts each server that is not running.                                                       |
| **Stop**    | Stops the servers: Ctrl-C, then closes their panes. Can also stop tab panes. See [What Stop does](#what-stop-does). |
| **Restart** | Stops the servers only, then starts them. Tab panes are not touched.                                                |
| **Close**   | Sends Ctrl-C to the servers, then closes the whole session.                                                         |

These actions are also in the command palette, for example `Workspace: Open my-project`.

They are also available on the command line:

```sh
rex do workspace_open name=my-project
rex do workspace_list
```

### Keys

| Keys                                                             | List                                              | Edit form                                           |
| ---------------------------------------------------------------- | ------------------------------------------------- | --------------------------------------------------- |
| <kbd>↑</kbd> <kbd>↓</kbd> or <kbd>j</kbd> <kbd>k</kbd>           | Select a workspace                                | Go to the next or previous field                    |
| <kbd>Tab</kbd> <kbd>←</kbd> <kbd>→</kbd>                         | Select a button. <kbd>Enter</kbd> pushes it.      | Go to the next field                                |
| <kbd>/</kbd> or <kbd>f</kbd>                                     | Filter by name. <kbd>Esc</kbd> clears the filter. |                                                     |
| <kbd>Enter</kbd>                                                 | Open                                              | Toggle, or go to the next field                     |
| <kbd>s</kbd>                                                     | Stop. If no server runs, start them.              |                                                     |
| <kbd>r</kbd> <kbd>c</kbd> <kbd>e</kbd> <kbd>n</kbd> <kbd>w</kbd> | Restart, Close, Edit, New, Save as new            |                                                     |
| <kbd>h</kbd>                                                     | Switch host, when more than one has rex-workspaces |                                                     |
| <kbd>←</kbd> <kbd>→</kbd> <kbd>Home</kbd> <kbd>End</kbd>         |                                                   | Move the cursor, or change a choice                 |
| <kbd>Ctrl</kbd>+<kbd>W</kbd> / <kbd>Ctrl</kbd>+<kbd>U</kbd>      |                                                   | Delete a word / clear the field                     |
| <kbd>Ctrl</kbd>+<kbd>O</kbd>                                     |                                                   | Select a folder                                     |
| <kbd>Ctrl</kbd>+<kbd>D</kbd>                                     |                                                   | Duplicate as a new workspace                        |
| <kbd>Ctrl</kbd>+<kbd>X</kbd>                                     |                                                   | Remove the server, tab, group or pane at the cursor |
| <kbd>Ctrl</kbd>+<kbd>S</kbd> / <kbd>Esc</kbd>                    |                                                   | Save / cancel                                       |
| <kbd>q</kbd> or <kbd>Esc</kbd>                                   | Close the window                                  |                                                     |

### Save a session

Arrange tabs and panes in Rex, then press **Save as new** (<kbd>w</kbd>) in the workspaces
window, or run `Workspace: Save This Session…` from the command palette. The form opens with
the session's name. If the session has no name, or its name is your login name, the form uses
`untitled`. Change the name if you like, check the result, then save. The workspace
goes into the first workspaces file.

From the command line:

```sh
rex do workspace_capture session=my-session name=my-workspace
rex do workspace_capture session=my-session save=false   # just prints
```

There are some limitations with this approach due to what's available, so a lot will not be saved: commands that finished, a command that `ps` cannot read, or floating panes at a shell prompt

## workspaces.json

The window automatically writes this file. To edit it manually, run `Workspace: Open workspaces.json` from
the command palette. Editors that read `$schema` show a description of each field.

[`examples/workspaces.json`](examples/workspaces.json) uses all options.

| Field          | Default                            | Description                                                                                                                                                     |
| -------------- | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `root`         | Home folder                        | Folder for all relative `cwd` values. `~` is permitted.                                                                                                         |
| `key`          | None                               | Shortcut that opens the workspace, for example `ctrl+cmd+1`.                                                                                                    |
| `focus`        | First tab                          | Tab to show when the session opens.                                                                                                                             |
| `switch`       | `true`                             | Switch to the session after start.                                                                                                                              |
| `servers_in`   | `"float"`                          | `"float"` puts servers in floating panes. `"tab"` puts them in a `servers` tab.                                                                                 |
| `stop_timeout` | `5`                                | Seconds to wait after Ctrl-C, for servers and panes.                                                                                                            |
| `stop`         | Servers `"close"`, panes `"leave"` | What Stop does. `servers` and `panes`, each `"close"`, `"interrupt"` or `"leave"`. See [What Stop does](#what-stop-does).                                       |
| `servers[]`    |                                    | `label`, `cmd`, `cwd`, `minimized` (default `true`), `bounds` `[x, y, w, h]`, `stop`. See [Server panes](#server-panes).                                                                        |
| `tabs[]`       | One shell                          | `name`, `split` (`"right"`, `"down"` or `"grid"`), `panes[]` with `label`, `cwd`, `cmd`, `stop`. A pane can also be a group. See [Pane layouts](#pane-layouts). |
| `hooks`        |                                    | `before_start`, `after_start`, `before_stop`, `after_stop`. Shell commands that run in `root`. Each has a 20 second limit.                                      |

### What Stop does

`stop` sets what **Stop** does, for servers and for the panes in `tabs[]`:

| Value         | `servers`                                                   | `panes`                                                            |
| ------------- | ----------------------------------------------------------- | ------------------------------------------------------------------ |
| `"close"`     | Default. Ctrl-C, wait up to `stop_timeout`, close the pane. | Ctrl-C each busy pane, wait up to `stop_timeout`, close the panes. |
| `"interrupt"` | Ctrl-C only. The pane stays open at its shell prompt.       | Ctrl-C each busy pane. The panes stay open.                        |
| `"leave"`     | Nothing.                                                    | Default. Nothing.                                                  |

```json
"stop": { "servers": "interrupt", "panes": "interrupt" }
```

- Ctrl-C goes only to panes that run a program. A pane at its shell prompt is left alone,
  or closed with `"close"`.
- A server or a pane can have its own `stop` with the same values, for example
  `{ "label": "notes", "stop": "leave" }` for a pane that Stop must never touch. The edit
  form sets `stop` for the workspace and keeps the ones on servers and panes.
- Stop finds tab panes by the tab's name and the pane's label. Panes you add later, or
  rename, are left alone.
- Stop never closes the session's last pane, or the last pane of a tab that holds floating
  panes. It sends Ctrl-C to that pane instead and says so.
- **Restart** uses only `servers`. It never touches tab panes. With `"leave"`, Restart does
  nothing to the servers, then starts any that are missing or at their prompt.
- **Close** always ends the session.
- The `before_stop` and `after_stop` hooks run before and after all of it.
- With no servers, the window shows **Stop** for an open workspace whose panes Stop acts on.
  `rex do workspace_stop name=NAME` returns a `message` that says what was stopped.

### Server panes

With `servers_in: "float"`, each server opens in a floating pane. `minimized` (default `true`) starts it
tucked away. `bounds` is `[x, y, width, height]` as fractions of the window, from 0 to 1, for example
`[0.6, 0.32, 0.38, 0.3]`. Without `bounds`, servers stack down the right side. With `servers_in: "tab"`,
both are ignored.

In the edit window, **Minimized** and **Position** are set per server. Type Position as four numbers, for
example `0.6 0.32 0.38 0.3`, or leave it empty for the default. To find numbers, arrange the panes in Rex
and use **Save as new**.

### Pane layouts

`split` arranges a tab's panes:

- `"right"` (default): side by side.
- `"down"`: stacked.
- `"grid"`: rows of equal width, filled left to right. 4 panes make a 2x2 grid, 6 panes make 2
  rows of 3.

A 2x2 grid:

```json
{
  "name": "agents",
  "split": "grid",
  "panes": [
    { "label": "api", "cwd": "api" },
    { "label": "web", "cwd": "web" },
    { "label": "tests", "cwd": "api", "cmd": "make test" },
    { "label": "shell" }
  ]
}
```

For other layouts, put a group in `panes[]`. A group has only `split` and `panes[]`, and fills
one pane's place. A main pane with a stack of two on its right:

```json
{
  "name": "code",
  "split": "right",
  "panes": [
    { "label": "editor" },
    { "split": "down", "panes": [{ "label": "tests" }, { "label": "shell" }] }
  ]
}
```

Groups can hold groups. The edit form shows groups and lets you change their layout and add
panes. To make a new group, edit `workspaces.json`, or arrange the panes in Rex and
[save the session](#save-a-session).

## Worktrees

Servers can run in any folder you choose, and you can optionally set it to a specific worktree in the "Edit" page.

- Name the worktree by its branch, its folder name, or its path. Each item looks it up in its
  own repository with `git worktree list`.
- If the folder is a subfolder of its repository, the same subfolder of the worktree is used.
- Items without a worktree run in their folder as usual. Hooks run in `root`.
- The worktree must exist; a branch alone is not checked out. If it is not found, the workspace
  does not start. If the branch exists but has no worktree, the message gives the
  `git worktree add` command that makes one.
- When you select the workspace, each server shows its worktree, for example `⎇ feat-x`,
  unless it is `main`.

To keep the original and run a second copy on other branches, open it in the form, and press
**Duplicate** (<kbd>Ctrl</kbd>+<kbd>D</kbd>). The copy will have its own
name and session, so both can run at once, but note that servers that use a fixed port can conflict.

## Setup options

```lua
require("rex-workspaces").setup{
  files = { "~/dotfiles/workspaces.json", "~/dotfiles/workspaces.local.json" },
  keys = { open = "cmd+o" },   -- keys = false: no shortcut
  palette = true,              -- false: no palette entry for each workspace
  ui = {
    bin = "~/bin/rex-workspaces",    -- default: bin/ or target/release/ in the module, then PATH
    bounds = { 0.2, 0.1, 0.6, 0.7 }, -- default: centered, sized for your workspaces
  },
}
```

By default, workspaces are kept in `workspaces.json` in the same folder as `init.lua`.

To share workspaces across machines but keep some on one machine only, list more than one
file, as in the example above. Rex-workspaces reads `files` in order. If two files have a
workspace with the same name, the later file wins. When you save a workspace, it goes back to
the file it came from. New workspaces go to the first file.

## Development

```sh
make build    # cargo build --release
make install  # build, then link this checkout into Rex
make test     # Rust, Lua (LuaJIT) and end-to-end tests on a temporary Rex server
make lint     # stylua, luacheck, rustfmt, clippy
```

### Releasing

To make a release, push a `v*` tag. The [release workflow](.github/workflows/release.yml)
builds archives for macOS and Linux (arm64 and x86_64). Each archive has the binary and the
Lua module. The workflow attaches the archives to the GitHub release. Then it writes
`Formula/rex-workspaces.rb`.
