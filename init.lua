local actions = require("rex-workspaces.lib.actions")
local keys = require("rex-workspaces.lib.keys")
local options = require("rex-workspaces.lib.options")
local path = require("rex-workspaces.lib.path")
local rex_api = require("rex-workspaces.lib.api")
local ui = require("rex-workspaces.lib.ui")

local M = {}

local MODULE_DIR = path.dirname((debug.getinfo(1, "S").source:gsub("^[@=]", "")))

local FIND_JSON = [[
[ -d "$1" ] || exit 3
exec find -L "$1" -mindepth 1 -maxdepth "$2" -name '.*' -prune -o -type f -name '*.json' -print
]]

local function find_json(dir, depth)
  local r = rex.exec({ "sh", "-c", FIND_JSON, "sh", dir, tostring(depth or 8) }, { timeout = 5 })
  if r == nil or r.code == 3 then
    return nil
  end
  local files = {}
  for line in (r.stdout or ""):gmatch("[^\n]+") do
    files[#files + 1] = line
  end
  table.sort(files)
  return files
end

function M.setup(opts)
  local home, state_home = os.getenv("HOME") or "", os.getenv("XDG_STATE_HOME")
  local settings, unknown = options.resolve(opts, MODULE_DIR, home, find_json, state_home)
  if #unknown > 0 then
    rex.log("warn", "rex-workspaces: unknown setup options: " .. table.concat(unknown, ", "))
  end

  local api = rex_api.new(rex)
  local registry = actions.new(rex, api, ui.new(api, rex.layout, settings), settings)
  registry.register()

  local cfg, errs = registry.load()
  for _, e in ipairs(errs) do
    rex.log("warn", "rex-workspaces: " .. e)
  end
  if settings.palette then
    registry.register_each(cfg)
  end
  keys.apply(rex, settings, cfg)
end

return M
