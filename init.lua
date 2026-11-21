local actions = require("rex-workspaces.lib.actions")
local keys = require("rex-workspaces.lib.keys")
local options = require("rex-workspaces.lib.options")
local path = require("rex-workspaces.lib.path")
local rex_api = require("rex-workspaces.lib.api")
local ui = require("rex-workspaces.lib.ui")

local M = {}

local MODULE_DIR = path.dirname((debug.getinfo(1, "S").source:gsub("^[@=]", "")))

local function list_dir(dir)
  local r = rex.exec({ "ls", "-1", dir }, { timeout = 5 })
  local names = {}
  for line in ((r and r.stdout) or ""):gmatch("[^\n]+") do
    names[#names + 1] = line
  end
  return names
end

function M.setup(opts)
  local settings, unknown = options.resolve(opts, MODULE_DIR, os.getenv("HOME") or "", list_dir)
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
