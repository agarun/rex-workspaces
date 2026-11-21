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

local function default_files(confdir, list)
  local files = { confdir .. "/workspaces.json" }
  local extra = {}
  for _, name in ipairs(list and list(confdir) or {}) do
    if name:match("^workspaces%..+%.json$") then
      extra[#extra + 1] = name
    end
  end
  table.sort(extra)
  for _, name in ipairs(extra) do
    files[#files + 1] = confdir .. "/" .. name
  end
  return files
end

function M.resolve(opts, module_dir, home, list, state_home)
  opts = opts or {}
  if state_home == nil or state_home == "" then
    state_home = home .. "/.local/state"
  end
  local confdir = path.dirname(module_dir)
  local defaults = opts.files or default_files(confdir, list)
  local files = {}
  for i, f in ipairs(defaults) do
    files[i] = path.expand(f, home)
  end
  local ui = opts.ui or {}
  local settings = {
    home = home,
    module_dir = module_dir,
    confdir = confdir,
    files = files,
    primary = files[1],
    state = state_home .. "/rex-workspaces",
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
