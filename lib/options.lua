local path = require("rex-workspaces.lib.path")

local M = {}

M.DEFAULT_KEY = "cmd+o"

local KNOWN = { files = true, keys = true, palette = true, ui = true }

local function unknown(opts)
  local names = {}
  for k in pairs(opts) do
    if not KNOWN[k] then
      names[#names + 1] = tostring(k)
    end
  end
  table.sort(names)
  return names
end

local function keys(raw)
  if raw == false then
    return { open = false }
  end
  raw = raw or {}
  local open = raw.open
  if open == nil then
    open = M.DEFAULT_KEY
  end
  return { open = open }
end

function M.resolve(opts, module_dir, home)
  opts = opts or {}
  local confdir = path.dirname(module_dir)
  local defaults = { confdir .. "/workspaces.json" }
  local files = {}
  for i, f in ipairs(opts.files or defaults) do
    files[i] = path.expand(f, home)
  end
  local ui = opts.ui or {}
  local settings = {
    home = home,
    module_dir = module_dir,
    confdir = confdir,
    files = files,
    primary = files[1],
    keys = keys(opts.keys),
    palette = opts.palette ~= false,
    ui = {
      bin = ui.bin and path.expand(ui.bin, home) or nil,
      bounds = ui.bounds,
    },
  }
  return settings, unknown(opts)
end

return M
