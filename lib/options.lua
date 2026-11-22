local path = require("rex-workspaces.lib.path")

local M = {}

M.DEFAULT_KEY = "cmd+o"

local KNOWN = { files = true, folders = true, keys = true, palette = true, ui = true }

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

local function add_folder(files, dir, find)
  local found = find and find(dir)
  for _, f in ipairs(found or {}) do
    if not path.basename(f):match("^%.") then
      files[#files + 1] = f
    end
  end
  return found ~= nil
end

local function default_files(confdir, find)
  local files = { confdir .. "/workspaces.json" }
  for _, f in ipairs(find and find(confdir, 1) or {}) do
    if path.basename(f):match("^workspaces%..+%.json$") then
      files[#files + 1] = f
    end
  end
  add_folder(files, confdir .. "/workspaces", find)
  return files
end

local function expand(file_entries, folder_entries, home, find)
  local files, folders = {}, {}
  for _, entry in ipairs(file_entries or {}) do
    entry = path.expand(entry, home)
    if entry:match("%.json$") or not add_folder(files, entry, find) then
      files[#files + 1] = entry
    else
      folders[entry] = true
    end
  end
  for _, entry in ipairs(folder_entries or {}) do
    entry = path.expand(entry, home)
    add_folder(files, entry, find)
    folders[entry] = true
  end
  return files, folders
end

function M.resolve(opts, module_dir, home, find, state_home)
  opts = opts or {}
  if state_home == nil or state_home == "" then
    state_home = home .. "/.local/state"
  end
  local confdir = path.dirname(module_dir)
  local files, folders
  if opts.files or opts.folders then
    files, folders = expand(opts.files, opts.folders, home, find)
  else
    files, folders = default_files(confdir, find), {}
  end
  local first = path.expand((opts.files or {})[1] or (opts.folders or {})[1] or (confdir .. "/workspaces.json"), home)
  local ui = opts.ui or {}
  local settings = {
    home = home,
    module_dir = module_dir,
    confdir = confdir,
    files = files,
    primary = folders[first] and (first .. "/workspaces.json") or first,
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
