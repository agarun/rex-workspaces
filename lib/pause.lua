local state = require("rex-workspaces.lib.state")

local M = {}

function M.parse_ps(text)
  local procs = {}
  for line in text:gmatch("[^\n]+") do
    local pid, ppid, uid, stat = line:match("^%s*(%d+)%s+(%d+)%s+(%d+)%s+(%S+)")
    if pid then
      procs[#procs + 1] = { pid = tonumber(pid), ppid = tonumber(ppid), uid = tonumber(uid), stat = stat }
    end
  end
  return procs
end

function M.order(tops, procs, uid)
  local info, children = {}, {}
  for _, p in ipairs(procs) do
    info[p.pid] = p
    children[p.ppid] = children[p.ppid] or {}
    table.insert(children[p.ppid], p.pid)
  end
  local out, seen = {}, {}
  for _, top in ipairs(tops) do
    local queue, i = { top }, 1
    while queue[i] do
      local pid = queue[i]
      i = i + 1
      if not seen[pid] then
        seen[pid] = true
        if info[pid] and info[pid].uid == uid then
          out[#out + 1] = pid
        end
        for _, child in ipairs(children[pid] or {}) do
          queue[#queue + 1] = child
        end
      end
    end
  end
  return out
end

local function reversed(list)
  local out = {}
  for i = #list, 1, -1 do
    out[#out + 1] = list[i]
  end
  return out
end

local function file(dir, ws)
  return state.file(dir, "paused", ws)
end

function M.is_paused(api, dir, ws, sid)
  local rec = sid and state.read(api, file(dir, ws))
  local pid = rec and rec.session_id == sid and rec.pids and rec.pids[1]
  if not pid then
    return false
  end
  local first = M.parse_ps(api.ps({ pid }))[1]
  return first ~= nil and first.stat:sub(1, 1) == "T"
end

function M.run(api, dir, ws, sid, skip)
  local tops, uid, panes = {}, nil, 0
  for _, w in ipairs(api.view(sid).windows or {}) do
    for _, layer in ipairs(w.layers or {}) do
      for _, b in ipairs(layer.blocks or {}) do
        local ok, p = false, nil
        if not skip[b.label] then
          ok, p = pcall(api.process, sid, b.block_id)
        end
        if ok and p.child and p.child.pid then
          tops[#tops + 1] = p.child.pid
          uid = uid or (p.foreground and p.foreground.user_id)
          panes = panes + 1
        end
      end
    end
  end
  local pids = uid and M.order(tops, M.parse_ps(api.ps()), uid) or {}
  if #pids > 0 then
    state.write(api, file(dir, ws), { session_id = sid, pids = pids })
    api.signal("STOP", pids)
  end
  return { pids = pids, panes = panes }
end

function M.unpause(api, dir, ws, sid)
  local f = file(dir, ws)
  local rec = state.read(api, f)
  if rec == nil then
    return false
  end
  local mine = rec.session_id == sid
  if mine then
    api.signal("CONT", reversed(rec.pids))
  end
  api.remove(f)
  return mine
end

return M
