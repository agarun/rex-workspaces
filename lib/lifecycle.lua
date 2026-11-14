local hooks = require("rex-workspaces.lib.hooks")
local layout = require("rex-workspaces.lib.layout")
local proc = require("rex-workspaces.lib.proc")
local servers = require("rex-workspaces.lib.servers")
local spec = require("rex-workspaces.lib.spec")

local M = {}

function M.find_session(api, name, sessions)
  for _, s in ipairs(sessions or api.sessions()) do
    if s.label == name then
      return s.session_id
    end
  end
  return nil
end

local function plan(api, sid, ws)
  local missing, idle, present = {}, {}, {}
  if sid == nil then
    for _, s in ipairs(ws.servers) do
      missing[#missing + 1] = s
    end
    return missing, idle, present
  end
  present = servers.find(api, sid, ws)
  for _, s in ipairs(ws.servers) do
    local b = present[s.label]
    if b == nil then
      missing[#missing + 1] = s
    elseif not proc.is_busy(api, sid, b.block_id) then
      idle[#idle + 1] = { server = s, block_id = b.block_id }
    end
  end
  return missing, idle, present
end

local function create(api, L, ws, missing)
  local windows = layout.windows(L, ws)
  if ws.servers_in == "tab" and #missing > 0 then
    windows[#windows + 1] = { window_label = spec.SERVERS_TAB, layout = layout.panes(L, missing, "right") }
    missing = {}
  end
  return api.create_session(ws.name, windows), missing
end

local function focus_tab(api, sid, name)
  for _, w in ipairs(api.view(sid).windows or {}) do
    if w.label == name then
      api.focus_window(sid, w.window_id)
      return
    end
  end
end

function M.start(api, L, ws, opts)
  opts = opts or {}
  local sid = M.find_session(api, ws.name)
  local missing, idle, present = plan(api, sid, ws)
  local created = sid == nil
  local starting = created or #missing > 0 or #idle > 0

  if starting then
    hooks.run(api, ws, "before_start")
  end
  if created then
    sid, missing = create(api, L, ws, missing)
  end
  servers.add(api, L, sid, ws, missing, present)
  for _, it in ipairs(idle) do
    api.write(sid, it.block_id, it.server.cmd .. "\n")
  end
  if created and ws.focus then
    focus_tab(api, sid, ws.focus)
  end
  if starting then
    hooks.run(api, ws, "after_start")
  end

  local switch = opts.select == true or (opts.select ~= false and ws.switch)
  local selected = switch and api.select(sid, opts.ctx) or false
  return { session_id = sid, created = created, started = starting, selected = selected }
end

function M.open(api, L, ws, opts)
  opts = opts or {}
  local sid = M.find_session(api, ws.name)
  if sid == nil then
    return M.start(api, L, ws, { ctx = opts.ctx, select = true })
  end
  return { session_id = sid, created = false, started = false, selected = api.select(sid, opts.ctx) }
end

function M.stop(api, ws)
  local sid = M.find_session(api, ws.name)
  if sid == nil then
    return { stopped = false }
  end
  hooks.run(api, ws, "before_stop")
  local blocks, forced = servers.interrupt(api, sid, ws)
  servers.close(api, sid, blocks)
  hooks.run(api, ws, "after_stop")
  return { stopped = true, session_id = sid, forced = forced }
end

function M.close(api, ws)
  local sid = M.find_session(api, ws.name)
  if sid == nil then
    return { stopped = false }
  end
  hooks.run(api, ws, "before_stop")
  local _, forced = servers.interrupt(api, sid, ws)
  api.destroy(sid)
  hooks.run(api, ws, "after_stop")
  return { stopped = true, session_id = sid, forced = forced }
end

function M.restart(api, L, ws, opts)
  M.stop(api, ws)
  return M.start(api, L, ws, opts)
end

function M.status(api, ws, sessions)
  local sid = M.find_session(api, ws.name, sessions)
  local list = servers.status(api, sid, ws)
  local up = 0
  for _, s in ipairs(list) do
    if s.up then
      up = up + 1
    end
  end
  return {
    name = ws.name,
    root = ws.root,
    key = ws.key,
    running = sid ~= nil,
    session_id = sid,
    servers = list,
    servers_up = up,
    tabs = #ws.tabs,
  }
end

function M.list(api, cfg)
  local sessions = api.sessions()
  local out = {}
  for _, ws in ipairs(cfg.list) do
    out[#out + 1] = M.status(api, ws, sessions)
  end
  return out
end

return M
