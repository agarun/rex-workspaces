local path = require("rex-workspaces.lib.path")
local spec = require("rex-workspaces.lib.spec")
local state = require("rex-workspaces.lib.state")
local store = require("rex-workspaces.lib.store")

local M = {}

local RESUME = {
  claude = "--continue",
  codex = "resume --last",
  opencode = "--continue",
}

local RESUMING = {
  ["-c"] = true,
  ["--continue"] = true,
  ["-r"] = true,
  ["--resume"] = true,
  ["-s"] = true,
  ["--session"] = true,
}

local LAYOUT = { "root", "servers_in", "servers", "focus", "tabs" }

function M.resume_cmd(cmd)
  local program, rest = (cmd or ""):match("^(%S+)(.*)$")
  local how = program and RESUME[path.basename(program)]
  if how == nil then
    return cmd
  end
  local first = rest:match("^%s+(%S+)")
  if first and not first:match("^%-") then
    return cmd
  end
  for word in rest:gmatch("%S+") do
    if RESUMING[word] then
      return cmd
    end
  end
  return program .. " " .. how .. rest
end

local function file(dir, ws)
  return state.file(dir, "snoozed", ws)
end

function M.exists(api, dir, ws)
  return api.exists(file(dir, ws))
end

function M.read(api, dir, ws)
  return state.read(api, file(dir, ws))
end

function M.discard(api, dir, ws)
  api.remove(file(dir, ws))
end

function M.snapshot(api, sid, draft)
  local screens, n = {}, 0
  for _, t in ipairs(draft.spec.tabs) do
    spec.each_pane(t.panes, function(p)
      n = n + 1
      p.cmd = M.resume_cmd(p.cmd)
      if p.cmd == nil then
        screens[tostring(n)] = api.screen(sid, draft.blocks[n])
      end
    end)
  end
  for _, s in ipairs(draft.spec.servers) do
    s.cmd = M.resume_cmd(s.cmd)
  end
  return { spec = store.prune(draft.spec), screens = screens }
end

function M.write(api, dir, ws, snap)
  state.write(api, file(dir, ws), snap)
end

function M.workspace(raw, snap, name, home)
  local merged = {}
  for k, v in pairs(raw or {}) do
    merged[k] = v
  end
  for _, k in ipairs(LAYOUT) do
    merged[k] = snap.spec[k]
  end
  local ws, errs = spec.normalize(name, merged, home)
  if #errs > 0 then
    error(table.concat(errs, "\n"), 0)
  end
  return ws
end

function M.place_screens(api, dir, ws, snap)
  local n = 0
  for _, t in ipairs(ws.tabs) do
    spec.each_pane(t.panes, function(p)
      n = n + 1
      local text = snap.screens and snap.screens[tostring(n)]
      if text and text ~= "" then
        local f = dir .. "/screens/" .. ws.slug .. "-" .. n .. ".vt"
        api.mkdir(path.dirname(f))
        api.write_file(f, text)
        p.replay = f
      end
    end)
  end
end

return M
