local path = require("rex-workspaces.lib.path")

local M = {}

M.DEFAULT_TAB = "main"
M.SERVERS_TAB = "servers"
M.DEFAULT_STOP_TIMEOUT = 5
M.HOOKS = { "before_start", "after_start", "before_stop", "after_stop" }

local SERVERS_IN = { float = true, tab = true }
local SPLITS = { right = true, down = true, grid = true }
local STOPS = { close = true, interrupt = true, leave = true }
local STOP_HELP = 'must be "close", "interrupt" or "leave"'
M.STOP_DEFAULT = { servers = "close", panes = "leave" }
local SPLIT_HELP = 'must be "right", "down" or "grid"'

M.UNTITLED = "untitled"

function M.default_name(name, home, taken)
  local login = home and home:match("([^/]+)/*$")
  if name ~= nil and name ~= "" and name ~= login then
    return name
  end
  local pick, n = M.UNTITLED, 2
  while taken and taken[pick] ~= nil do
    pick = M.UNTITLED .. " " .. n
    n = n + 1
  end
  return pick
end

function M.slug(name)
  return (name:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

local function is_array(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n == #t
end

local function report(errs, where, message)
  errs[#errs + 1] = where .. ": " .. message
end

local function typed(errs, where, value, kind)
  if value == nil or type(value) == kind then
    return value
  end
  report(errs, where, "must be a " .. kind)
  return nil
end

local function list(errs, where, value)
  if value == nil then
    return {}
  end
  if not is_array(value) then
    report(errs, where, "must be a list")
    return {}
  end
  return value
end

local function valid_bounds(b)
  if not is_array(b) or #b ~= 4 then
    return false
  end
  for _, n in ipairs(b) do
    if type(n) ~= "number" or n < 0 or n > 1 then
      return false
    end
  end
  return true
end

local function stop_value(errs, where, value)
  if value == nil or STOPS[value] then
    return value
  end
  report(errs, where, STOP_HELP)
  return nil
end

local function stop_of(raw, where, errs)
  local out = { servers = M.STOP_DEFAULT.servers, panes = M.STOP_DEFAULT.panes }
  if raw == nil then
    return out
  end
  if type(raw) ~= "table" or (is_array(raw) and #raw > 0) then
    report(errs, where, "must be an object")
    return out
  end
  for key in pairs(raw) do
    if out[key] == nil then
      report(errs, where .. "." .. tostring(key), 'unknown key; use "servers" or "panes"')
    end
  end
  out.servers = stop_value(errs, where .. ".servers", raw.servers) or out.servers
  out.panes = stop_value(errs, where .. ".panes", raw.panes) or out.panes
  return out
end

local function pane(raw, where, base, home, errs)
  if type(raw) ~= "table" then
    report(errs, where, "must be an object")
    return nil
  end
  if type(raw.label) ~= "string" or raw.label == "" then
    report(errs, where, "label is required")
    return nil
  end
  local cwd = typed(errs, where .. ".cwd", raw.cwd, "string")
  local wt = typed(errs, where .. ".worktree", raw.worktree, "string")
  return {
    label = raw.label,
    cmd = typed(errs, where .. ".cmd", raw.cmd, "string"),
    cwd = path.join(base, path.expand(cwd, home)),
    stop = stop_value(errs, where .. ".stop", raw.stop),
    worktree = wt ~= "" and wt or nil,
  }
end

local function server(raw, where, base, home, errs)
  local p = pane(raw, where, base, home, errs)
  if p == nil then
    return nil
  end
  if p.cmd == nil then
    report(errs, where, "cmd is required")
  end
  p.minimized = typed(errs, where .. ".minimized", raw.minimized, "boolean") ~= false
  if raw.bounds ~= nil then
    if valid_bounds(raw.bounds) then
      p.bounds = raw.bounds
    else
      report(errs, where .. ".bounds", "must be [x, y, width, height], each from 0 to 1")
    end
  end
  return p
end

local function servers(raw, where, base, home, errs)
  local out, seen = {}, {}
  for i, s in ipairs(list(errs, where, raw)) do
    local at = where .. "[" .. i .. "]"
    local p = server(s, at, base, home, errs)
    if p then
      if seen[p.label] then
        report(errs, at, 'duplicate server label "' .. p.label .. '"')
      end
      seen[p.label] = true
      out[#out + 1] = p
    end
  end
  return out
end

local function split_of(raw, where, errs)
  local split = raw.split or "right"
  if not SPLITS[split] then
    report(errs, where .. ".split", SPLIT_HELP)
    return "right"
  end
  return split
end

local node

local function children(raw, where, base, home, errs)
  local out = {}
  for j, p in ipairs(list(errs, where .. ".panes", raw.panes)) do
    out[#out + 1] = node(p, where .. ".panes[" .. j .. "]", base, home, errs)
  end
  return out
end

node = function(raw, where, base, home, errs)
  if type(raw) ~= "table" or raw.panes == nil then
    return pane(raw, where, base, home, errs)
  end
  if raw.label ~= nil or raw.cmd ~= nil or raw.cwd ~= nil or raw.stop ~= nil or raw.worktree ~= nil then
    report(errs, where, "a group has only split and panes; put label, cwd, cmd, stop and worktree on its panes")
  end
  local g = { split = split_of(raw, where, errs), panes = children(raw, where, base, home, errs) }
  if #g.panes == 0 then
    report(errs, where .. ".panes", "needs at least one pane")
    return nil
  end
  return g
end

local function tab(raw, i, where, base, home, errs)
  if type(raw) ~= "table" then
    report(errs, where, "must be an object")
    return nil
  end
  local t = {
    name = typed(errs, where .. ".name", raw.name, "string") or ("tab " .. i),
    split = split_of(raw, where, errs),
    panes = children(raw, where, base, home, errs),
  }
  if #t.panes == 0 then
    t.panes[1] = { label = t.name, cwd = base }
  end
  return t
end

local function tabs(raw, where, ws, home, errs)
  local out = {}
  for i, t in ipairs(list(errs, where, raw)) do
    out[#out + 1] = tab(t, i, where .. "[" .. i .. "]", ws.dir, home, errs)
  end
  if #out == 0 then
    out[1] = { name = M.DEFAULT_TAB, split = "right", panes = { { label = ws.name, cwd = ws.dir } } }
  end
  return out
end

local function hooks(raw, where, errs)
  local out = {}
  if raw == nil then
    return out
  end
  if type(raw) ~= "table" or (is_array(raw) and #raw > 0) then
    report(errs, where, "must be an object")
    return out
  end
  for _, name in ipairs(M.HOOKS) do
    out[name] = typed(errs, where .. "." .. name, raw[name], "string")
  end
  return out
end

local function has_tab(ws, name)
  for _, t in ipairs(ws.tabs) do
    if t.name == name then
      return true
    end
  end
  return false
end

function M.each_pane(nodes, fn)
  for _, n in ipairs(nodes) do
    if n.panes then
      M.each_pane(n.panes, fn)
    else
      fn(n)
    end
  end
end

function M.stops_panes(ws)
  local any = false
  for _, t in ipairs(ws.tabs) do
    M.each_pane(t.panes, function(p)
      any = any or (p.stop or ws.stop.panes) ~= "leave"
    end)
  end
  return any
end

function M.normalize(name, raw, home)
  if type(raw) ~= "table" or (is_array(raw) and #raw > 0) then
    return nil, { name .. ": must be an object" }
  end
  local errs = {}
  local root = typed(errs, name .. ".root", path.expand(raw.root, home), "string")
  local ws = {
    name = name,
    slug = M.slug(name),
    root = root,
    dir = root or home,
    key = typed(errs, name .. ".key", raw.key, "string"),
    focus = typed(errs, name .. ".focus", raw.focus, "string"),
    switch = typed(errs, name .. ".switch", raw.switch, "boolean") ~= false,
    servers_in = raw.servers_in or "float",
    stop_timeout = raw.stop_timeout or M.DEFAULT_STOP_TIMEOUT,
  }
  if ws.slug == "" then
    report(errs, name, "name needs at least one letter or digit")
  end
  if not SERVERS_IN[ws.servers_in] then
    report(errs, name .. ".servers_in", 'must be "float" or "tab"')
    ws.servers_in = "float"
  end
  if type(ws.stop_timeout) ~= "number" or ws.stop_timeout < 0 then
    report(errs, name .. ".stop_timeout", "must be a number of seconds")
    ws.stop_timeout = M.DEFAULT_STOP_TIMEOUT
  end
  ws.servers = servers(raw.servers, name .. ".servers", ws.dir, home, errs)
  ws.tabs = tabs(raw.tabs, name .. ".tabs", ws, home, errs)
  ws.hooks = hooks(raw.hooks, name .. ".hooks", errs)
  ws.stop = stop_of(raw.stop, name .. ".stop", errs)
  if ws.focus and not has_tab(ws, ws.focus) then
    report(errs, name .. ".focus", 'no tab named "' .. ws.focus .. '"')
    ws.focus = nil
  end
  return ws, errs
end

return M
