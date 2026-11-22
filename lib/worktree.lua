local path = require("rex-workspaces.lib.path")
local spec = require("rex-workspaces.lib.spec")

local M = {}

-- Input is `git rev-parse --show-toplevel --show-prefix` followed by
-- `git worktree list --porcelain`, run in the item's folder.
function M.parse(text)
  local lines = {}
  for line in (text or ""):gmatch("([^\n]*)\n?") do
    lines[#lines + 1] = line
  end
  local top, prefix = lines[1], (lines[2] or ""):gsub("/+$", "")
  if top == nil or top == "" then
    return {}
  end
  local out, cur = {}, nil
  for i = 3, #lines do
    local key, value = lines[i]:match("^(%S+) ?(.*)$")
    if key == "worktree" then
      cur = { path = value }
      out[#out + 1] = cur
    elseif cur and key == "branch" then
      cur.branch = value:gsub("^refs/heads/", "")
    elseif cur and (key == "bare" or key == "prunable") then
      cur.skip = true
    end
  end
  local list = {}
  for _, wt in ipairs(out) do
    if not wt.skip then
      list[#list + 1] = {
        label = wt.branch or path.basename(wt.path),
        branch = wt.branch,
        path = wt.path,
        root = path.join(wt.path, prefix),
        current = wt.path == top,
      }
    end
  end
  return list
end

local function find(api, list, wanted, home)
  for _, wt in ipairs(list) do
    if wt.label == wanted or path.basename(wt.path) == wanted then
      return wt
    end
  end
  local expanded = path.expand(wanted, home)
  if expanded:sub(1, 1) ~= "/" then
    return nil
  end
  local real = api.realpath(expanded)
  for _, wt in ipairs(list) do
    if wt.path == real then
      return wt
    end
  end
  return nil
end

local function copy(t)
  if type(t) ~= "table" then
    return t
  end
  local out = {}
  for k, v in pairs(t) do
    out[k] = copy(v)
  end
  return out
end

local function each_item(ws, fn)
  for _, s in ipairs(ws.servers) do
    fn(s)
  end
  for _, t in ipairs(ws.tabs) do
    spec.each_pane(t.panes, fn)
  end
end

function M.uses(ws)
  local any = false
  each_item(ws, function(it)
    any = any or it.worktree ~= nil
  end)
  return any
end

function M.missing(api, list, it, name)
  local where = it.label .. " in " .. name
  local main = list[1]
  if main == nil then
    return where .. ": " .. it.cwd .. " is not in a git repository"
  end
  if not api.has_branch(main.path, it.worktree) then
    return 'no worktree "' .. it.worktree .. '" for ' .. where
  end
  local dir = main.path .. "." .. it.worktree:gsub("/", "-")
  return where
    .. ': branch "'
    .. it.worktree
    .. '" has no worktree. Create one with: git -C '
    .. path.shell_quote(main.path)
    .. " worktree add "
    .. path.shell_quote(dir)
    .. " "
    .. path.shell_quote(it.worktree)
end

function M.apply(api, ws, home)
  if not M.uses(ws) then
    return ws
  end
  local inst, cache = copy(ws), {}
  each_item(inst, function(it)
    if it.worktree == nil then
      return
    end
    cache[it.cwd] = cache[it.cwd] or M.parse(api.worktrees(it.cwd))
    local wt = find(api, cache[it.cwd], it.worktree, home)
    if wt == nil then
      error(M.missing(api, cache[it.cwd], it, ws.name), 0)
    end
    it.cwd = wt.root
  end)
  return inst
end

return M
