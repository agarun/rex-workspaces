# rex-workspaces

rex-workspaces starts, stops and restarts your projects in [Rex](https://www.superlogical.com/rex).

A workspace is a saved definition of a Rex session. It has a folder, tabs, dev servers, and
commands to run before and after start and stop.

## Requirements

- Rex, with the `rex` command on your `PATH`. See the
  [Rex installation guide](https://www.superlogical.com/rex/docs/installation).
- macOS or Linux, arm64 or x86_64.
- To build from source: `git` and Rust (`cargo`).

## Install

### With Homebrew

```sh
brew install agarun/tap/rex-workspaces
rex-workspaces install
```

### With the install script

```sh
curl -fsSL https://raw.githubusercontent.com/agarun/rex-workspaces/main/install.sh | sh
```

The script downloads the latest release for your machine to `~/.config/rex/rex-workspaces`.
If there is no release for your machine, the script clones the repository and builds it
with `cargo`. Then the script runs `rex-workspaces install`.

### From source

```sh
git clone https://github.com/agarun/rex-workspaces
cd rex-workspaces
make install
```

### What `rex-workspaces install` does

1. Links the Lua module to `~/.config/rex/rex-workspaces`.
2. Adds `require("rex-workspaces").setup{}` to `~/.config/rex/init.lua`.
3. Creates `~/.config/rex/workspaces.json` with a `my-project` example.
4. Reloads the Rex config.

You can run it again safely.

### Turn on Remote Control

1. In Rex, open **Settings** (<kbd>Cmd</kbd>+<kbd>,</kbd>).
2. Turn on **Remote Control**.

The workspaces window and `rex do` run outside the Rex app. They need Remote Control to
switch you to a workspace session. Without Remote Control, **Open** still creates the session
and starts its servers, but you must switch to it yourself (<kbd>Cmd</kbd>+<kbd>K</kbd>). The
command palette and shortcuts work without Remote Control.

### Remote hosts

Each Rex server reads its own config. Install rex-workspaces on each host where you want to
use it.

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

## Use

Press <kbd>Cmd</kbd>+<kbd>O</kbd> in Rex to open the workspaces window. Press it again to
close the window. The window uses the colors of your Rex theme.

```
╭ my-project ctrl+cmd+1 ─────────────────────────── 2 of 2 running ╮
│ ~/.config/rex/rex-workspaces/examples/my-project                  │
│                                                                   │
│ ● api  make dev                                                   │
│ ● web  npm run dev                                                │
╰───────────────────────────────────────────────────────────────────╯
╭ 2 ○ shop ─────────────────────────────────────────────── Stopped ╮
│ ~/Projects/shop                                                   │
╰───────────────────────────────────────────────────────────────────╯

 Open  enter    Stop  s    Restart  r    Close  c    Edit  e    New  n    Filter  /
```

- Select a workspace, then click a button or press its key.
- **New** creates a workspace for the current folder. It adds the dev servers it finds in
  `package.json`, `Makefile` and `Procfile`. Examine them, then save.
- **Edit** opens a form with all options, a folder picker, and the commands found in the
  folder.
- To set a **Shortcut** in the form, press <kbd>Enter</kbd>, then press the keys, for example
  <kbd>Ctrl</kbd>+<kbd>Cmd</kbd>+<kbd>1</kbd>. You can also type the shortcut. The window
  cannot record keys that Rex already uses, for example <kbd>Cmd</kbd>+<kbd>O</kbd>.

### Actions

| Action | Result |
| --- | --- |
| **Open** | Switches to the session. If the session does not exist, starts it. |
| **Start** | Opens the session and starts each server that is not running. |
| **Stop** | Sends Ctrl-C to each server pane, then closes the server panes. Other tabs stay open. |
| **Restart** | Stop, then start. |
| **Close** | Stops the servers, then closes the session. |

The same actions are in the command palette, for example `Workspace: Open my-project`.
They are also available on the command line:

```sh
rex do workspace_open name=my-project
rex do workspace_list
```

### Keys

| Keys | List | Edit form |
| --- | --- | --- |
| <kbd>↑</kbd> <kbd>↓</kbd> or <kbd>j</kbd> <kbd>k</kbd> | Select a workspace | Go to the next or previous field |
| <kbd>1</kbd> to <kbd>9</kbd> | Select a workspace by number | |
| <kbd>Tab</kbd> <kbd>←</kbd> <kbd>→</kbd> | Select a button. <kbd>Enter</kbd> pushes it. | Go to the next field |
| <kbd>/</kbd> or <kbd>f</kbd> | Filter by name. <kbd>Esc</kbd> clears the filter. | |
| <kbd>Enter</kbd> | Open | Toggle, or go to the next field |
| <kbd>s</kbd> | Stop the servers. If no server runs, start them. | |
| <kbd>r</kbd> <kbd>c</kbd> <kbd>e</kbd> <kbd>n</kbd> | Restart, Close, Edit, New | |
| <kbd>←</kbd> <kbd>→</kbd> <kbd>Home</kbd> <kbd>End</kbd> | | Move the cursor, or change a choice |
| <kbd>Ctrl</kbd>+<kbd>W</kbd> / <kbd>Ctrl</kbd>+<kbd>U</kbd> | | Delete a word / clear the field |
| <kbd>Ctrl</kbd>+<kbd>O</kbd> | | Select a folder |
| <kbd>Ctrl</kbd>+<kbd>X</kbd> | | Remove the server, tab or pane at the cursor |
| <kbd>Ctrl</kbd>+<kbd>S</kbd> / <kbd>Esc</kbd> | | Save / cancel |
| <kbd>q</kbd> or <kbd>Esc</kbd> | Close the window | |

## workspaces.json

The window writes this file. To edit it manually, run `Workspace: Open workspaces.json` from
the command palette. Editors that read `$schema` show a description of each field.

[`examples/workspaces.json`](examples/workspaces.json) uses all options.

| Field | Default | Description |
| --- | --- | --- |
| `root` | Home folder | Folder for all relative `cwd` values. `~` is permitted. |
| `key` | None | Shortcut that opens the workspace, for example `ctrl+cmd+1`. |
| `focus` | First tab | Tab to show when the session opens. |
| `switch` | `true` | Switch to the session after start. |
| `servers_in` | `"float"` | `"float"` puts servers in floating panes. `"tab"` puts them in a `servers` tab. |
| `stop_timeout` | `5` | Seconds to wait after Ctrl-C. Then the server pane closes. |
| `servers[]` | | `label`, `cmd`, `cwd`, `minimized` (default `true`), `bounds` `[x, y, w, h]`. |
| `tabs[]` | One shell | `name`, `split` (`"right"` or `"down"`), `panes[]` with `label`, `cwd`, `cmd`. |
| `hooks` | | `before_start`, `after_start`, `before_stop`, `after_stop`. Shell commands that run in `root`. Each has a 20 second limit. |

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

Rex-workspaces reads `files` in order. If two files have a workspace with the same name, the
later file wins. When you save a workspace, it goes back to the file it came from. The
default files are `workspaces.json` and `workspaces.local.json` in the same folder as
`init.lua`.

## Development

```sh
make build    # cargo build --release
make install  # build, then link this checkout into Rex
make test     # Rust, Lua (LuaJIT) and end-to-end tests on a temporary Rex server
make lint     # stylua, luacheck, rustfmt, clippy
```

To make a release, push a `v*` tag. The [release workflow](.github/workflows/release.yml)
builds archives for macOS and Linux (arm64 and x86_64). Each archive has the binary and the
Lua module. The workflow attaches the archives to the GitHub release. Then it writes
`Formula/rex-workspaces.rb` to the `agarun/homebrew-tap` repository with
[packaging/homebrew/formula.sh](packaging/homebrew/formula.sh). This step needs a
`HOMEBREW_TAP_TOKEN` secret: a fine-grained token with Contents read and write access on
the tap.

```
init.lua            setup{}: options, actions and keys
lib/options.lua     setup{} options and defaults
lib/actions.lua     all rex.action definitions
lib/keys.lua        shortcuts
lib/ui.lua          finds and opens the window
lib/config.lua      reads and merges workspaces files
lib/spec.lua        validates a workspace and adds defaults
lib/store.lua       saves and removes workspaces
lib/detect.lua      finds dev servers in a folder
lib/lifecycle.lua   start, stop, close, restart, status
lib/servers.lua     server panes: find, add, interrupt
lib/layout.lua      converts a workspace to Rex panes and splits
lib/hooks.lua, proc.lua, path.lua, json.lua
lib/api.lua         the only file that calls Rex
src/                the rex-workspaces binary (Rust, ratatui): the window and `install`.
                    It uses only `rex do` and `rex config` to talk to Rex.
install.sh          the install script
```
