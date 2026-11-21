local actions = require("rex-workspaces.lib.actions")
local keys = require("rex-workspaces.lib.keys")
local options = require("rex-workspaces.lib.options")
local path = require("rex-workspaces.lib.path")
local rex_api = require("rex-workspaces.lib.api")
local ui = require("rex-workspaces.lib.ui")

local M = {}

local MODULE_DIR = path.dirname((debug.getinfo(1, "S").source:gsub("^[@=]", "")))

local function find_json(dir, depth)
  local argv =
    { "find", "-L", dir, "-mindepth", "1", "-maxdepth", tostring(depth or 32), "-type", "f", "-name", "*.json" }
  local r = rex.exec(argv, { timeout = 5 })
  local files = {}
  for line in ((r and r.stdout) or ""):gmatch("[^\n]+") do
    files[#files + 1] = line
  end
  table.sort(files)
  return files
end

function M.setup(opts)
  local settings, unknown = options.resolve(opts, MODULE_DIR, os.getenv("HOME") or "", find_json)
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
