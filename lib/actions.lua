local config = require("rex-workspaces.lib.config")
local detect = require("rex-workspaces.lib.detect")
local layout = require("rex-workspaces.lib.layout")
local lifecycle = require("rex-workspaces.lib.lifecycle")
local path = require("rex-workspaces.lib.path")
local spec = require("rex-workspaces.lib.spec")
local store = require("rex-workspaces.lib.store")
local worktree = require("rex-workspaces.lib.worktree")

local M = {}

local CATEGORY = "Workspaces"

M.VERBS = { "open", "start", "stop", "close", "restart" }

local TITLES = {
  open = "Open %s",
  start = "Start %s",
  stop = "Stop %s Servers",
  close = "Close %s",
  restart = "Restart %s Servers",
}

local STOP_ALL = "Stop %s"

local DESCRIPTIONS = {
  open = "Switch to the workspace's session as it is. If it isn't open yet, start it.",
  start = "Open the workspace's session, or switch to it, and start any servers that aren't running.",
  stop = "Stop the servers, and the tab panes if the workspace says so. See the stop option.",
  close = "Stop the servers, then close the whole session.",
  restart = "Stop the servers, then start them again.",
}

function M.new(rex, api, ui, settings)
  local self = {}
  local L = rex.layout
  local files = {
    paths = settings.files,
    primary = settings.primary,
    home = settings.home,
    read = api.read,
    write = api.write_file,
    decode = rex.json.decode,
  }
  local fs = { find = api.find, read = api.read, exists = api.exists, decode = rex.json.decode }

  function self.load()
    return config.load(settings.files, api.read, rex.json.decode, settings.home)
  end

  local function get(name)
    local cfg, errs = self.load()
    local ws = cfg.by_name[name]
    if ws then
      return ws
    end
    local why = #errs > 0 and (": " .. table.concat(errs, "; ")) or ""
    error('no workspace named "' .. tostring(name) .. '"' .. why, 0)
  end

  local function placed(ws)
    return worktree.apply(api, ws, settings.home)
  end

  local verbs = {
    open = function(ws, ctx)
      return lifecycle.open(api, L, placed(ws), { ctx = ctx })
    end,
    start = function(ws, ctx, args)
      return lifecycle.start(api, L, placed(ws), { ctx = ctx, select = args and args.select })
    end,
    stop = function(ws)
      return lifecycle.stop(api, ws)
    end,
    close = function(ws)
      return lifecycle.close(api, ws)
    end,
    restart = function(ws, ctx, args)
      return lifecycle.restart(api, L, placed(ws), { ctx = ctx, select = args and args.select })
    end,
  }

  local function list_rows()
    local cfg = self.load()
    local most = 0
    for _, ws in ipairs(cfg.list) do
      most = math.max(most, #ws.servers)
    end
    return layout.list_rows(#cfg.list, most)
  end

  local function focused_dir(ctx)
    if ctx.block_id and ctx.session_id then
      return api.pwd(ctx.session_id, ctx.block_id)
    end
    return nil
  end

  local function list()
    local cfg, errs = self.load()
    local sessions = api.sessions()
    local out = {}
    for _, ws in ipairs(cfg.list) do
      local st = lifecycle.status(api, ws, sessions)
      st.spec = cfg.raw[ws.name]
      st.file = cfg.origin[ws.name]
      out[#out + 1] = st
    end
    return {
      workspaces = out,
      errors = errs,
      files = settings.files,
      primary = settings.primary,
      home = settings.home,
    }
  end

  local function add(ctx, args)
    local root = args.root and path.expand(args.root, settings.home) or focused_dir(ctx)
    if root == nil then
      error("no folder given and the focused pane has not reported one", 0)
    end
    local name = args.name or spec.default_name(path.basename(root), settings.home, self.load().raw)
    local raw = detect.starter(detect.scan(fs, root), name)
    raw.root = path.contract(root, settings.home)
    local saved = store.save(files, name, raw)
    if args.edit ~= false and ctx.session_id and not ui.show(ctx, { "edit", name }, nil, list_rows()) then
      ui.edit_file(ctx, saved.file)
    end
    return saved
  end

  local function define(def)
    def.category = CATEGORY
    rex.action(def)
  end

  function self.register()
    for _, verb in ipairs(M.VERBS) do
      define({
        name = "workspace_" .. verb,
        title = "Workspace: " .. TITLES[verb]:format("…"),
        description = DESCRIPTIONS[verb],
        args = { name = "string", select = "boolean?" },
        run = function(ctx, args)
          return verbs[verb](get(args.name), ctx, args)
        end,
      })
    end

    define({
      name = "workspace_ui",
      title = "Workspaces…",
      description = "Open the workspaces window. Without the ui installed, opens the command palette.",
      keywords = "workspace project start stop restart dashboard",
      run = function(ctx)
        ui.toggle(ctx, focused_dir(ctx), list_rows())
      end,
    })

    define({
      name = "workspace_ui_resize",
      title = "Workspace: Fit Window",
      description = "Resize the workspaces window for the list or the edit form. Used by the window.",
      args = { screen = "string" },
      run = function(ctx, args)
        return ui.resize(ctx, args.screen == "edit" and layout.EDIT_ROWS or list_rows())
      end,
    })

    define({
      name = "workspace_list",
      title = "Workspace: List",
      description = "Every workspace with its settings, whether it is open, and which servers are up.",
      run = list,
    })

    define({
      name = "workspace_add",
      title = "Workspace: Add This Folder",
      description = "Save the focused pane's folder as a workspace, with the dev servers it finds.",
      args = { name = "string?", root = "string?", edit = "boolean?" },
      run = add,
    })

    define({
      name = "workspace_edit",
      title = "Workspace: Edit…",
      description = "Edit a workspace in the workspaces window, or the workspaces file without it.",
      args = { name = "string?" },
      run = function(ctx, args)
        if ctx.session_id == nil then
          return { file = settings.primary }
        end
        local shown = ui.show(ctx, args.name and { "edit", args.name } or {}, nil, list_rows())
        if not shown then
          ui.edit_file(ctx, settings.primary)
        end
      end,
    })

    define({
      name = "workspace_edit_file",
      title = "Workspace: Open workspaces.json",
      description = "Open the workspaces file in $EDITOR; Rex reloads when you close it.",
      run = function(ctx)
        if ctx.session_id == nil then
          return { file = settings.primary }
        end
        ui.edit_file(ctx, settings.primary)
      end,
    })

    define({
      name = "workspace_save",
      title = "Workspace: Save",
      description = "Write one workspace to its file. Used by the workspaces window.",
      args = { name = "string", spec = "object", previous = "string?" },
      run = function(_, args)
        return store.save(files, args.name, args.spec, args.previous)
      end,
    })

    define({
      name = "workspace_remove",
      title = "Workspace: Remove",
      description = "Delete a workspace from its file. Its session, if open, stays open.",
      args = { name = "string" },
      run = function(_, args)
        return store.remove(files, args.name)
      end,
    })

    define({
      name = "workspace_detect",
      title = "Workspace: Detect Commands",
      description = "List the scripts, make targets and Procfile entries found in a folder.",
      args = { root = "string", name = "string?" },
      run = function(_, args)
        local root = path.expand(args.root, settings.home)
        local scan = detect.scan(fs, root)
        scan.starter = detect.starter(scan, args.name or path.basename(root))
        scan.starter.root = path.contract(root, settings.home)
        return scan
      end,
    })
  end

  function self.register_each(cfg)
    for _, ws in ipairs(cfg.list) do
      for _, verb in ipairs(M.VERBS) do
        local stops = #ws.servers > 0 or (verb == "stop" and spec.stops_panes(ws))
        if verb == "open" or verb == "start" or verb == "close" or stops then
          local name = ws.name
          local title = (verb == "stop" and spec.stops_panes(ws)) and STOP_ALL or TITLES[verb]
          define({
            name = "workspace_" .. verb .. "_" .. ws.slug,
            title = "Workspace: " .. title:format(name),
            description = DESCRIPTIONS[verb],
            keywords = "workspace project " .. name,
            run = function(ctx)
              return verbs[verb](get(name), ctx)
            end,
          })
        end
      end
    end
  end

  return self
end

return M
