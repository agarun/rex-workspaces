local layout = require("rex-workspaces.lib.layout")
local proc = require("rex-workspaces.lib.proc")
local spec = require("rex-workspaces.lib.spec")

local M = {}

M.POLL = 0.25

local function holds_servers(ws, window, layer)
  if layer.kind == "floating" then
    return ws.servers_in == "float"
  end
  return ws.servers_in == "tab" and window.label == spec.SERVERS_TAB
end

function M.find(api, sid, ws)
  local wanted = {}
  for _, s in ipairs(ws.servers) do
    wanted[s.label] = true
  end
  local found = {}
  for _, w in ipairs(api.view(sid).windows or {}) do
    for _, layer in ipairs(w.layers or {}) do
      if holds_servers(ws, w, layer) then
        local blocks = layer.blocks or {}
        local own_layer = layer.kind == "floating" and #blocks == 1
        for _, b in ipairs(blocks) do
          if wanted[b.label] and not found[b.label] then
            found[b.label] = {
              block_id = b.block_id,
              layer_id = own_layer and layer.layer_id or nil,
              window_id = w.window_id,
            }
          end
        end
      end
    end
  end
  return found
end

local function index_of(list, item)
  for i, x in ipairs(list) do
    if x == item then
      return i
    end
  end
  return 1
end

local function first_window(api, sid)
  local windows = api.view(sid).windows or {}
  return windows[1] and windows[1].window_id
end

local function add_floating(api, L, sid, ws, missing)
  local window_id = first_window(api, sid)
  for _, s in ipairs(missing) do
    local bounds = s.bounds or layout.float_bounds(index_of(ws.servers, s), #ws.servers)
    local layer = api.new_layer(sid, window_id, layout.block(L, s), bounds)
    if s.minimized and layer.layer_id then
      api.minimize(sid, layer.layer_id)
    end
  end
end

local function add_tiled(api, L, sid, missing, present)
  local anchor
  for _, b in pairs(present) do
    anchor = b.block_id
  end
  if anchor == nil then
    api.new_window(sid, spec.SERVERS_TAB, layout.panes(L, missing, "right"))
    return
  end
  for _, s in ipairs(missing) do
    local r = api.new_split(sid, anchor, layout.block(L, s))
    anchor = (r.block_ids and r.block_ids[1]) or anchor
  end
end

function M.add(api, L, sid, ws, missing, present)
  if #missing == 0 then
    return
  end
  if ws.servers_in == "float" then
    add_floating(api, L, sid, ws, missing)
  else
    add_tiled(api, L, sid, missing, present)
  end
end

function M.interrupt(api, sid, ws)
  local blocks = M.find(api, sid, ws)
  local busy = {}
  for label, b in pairs(blocks) do
    if proc.is_busy(api, sid, b.block_id) then
      api.write(sid, b.block_id, "\3")
      busy[label] = b
    end
  end
  local waited = 0
  while next(busy) ~= nil and waited < ws.stop_timeout do
    api.sleep(M.POLL)
    waited = waited + M.POLL
    for label, b in pairs(busy) do
      if not proc.is_busy(api, sid, b.block_id) then
        busy[label] = nil
      end
    end
  end
  local forced = {}
  for label in pairs(busy) do
    forced[#forced + 1] = label
  end
  table.sort(forced)
  return blocks, forced
end

function M.close(api, sid, blocks)
  for _, b in pairs(blocks) do
    if b.layer_id then
      api.close_layer(sid, b.layer_id)
    else
      api.close_block(sid, b.block_id)
    end
  end
end

function M.status(api, sid, ws)
  local blocks = sid and M.find(api, sid, ws) or {}
  local out = {}
  for i, s in ipairs(ws.servers) do
    local b = blocks[s.label]
    out[i] = {
      label = s.label,
      cmd = s.cmd,
      open = b ~= nil,
      up = b ~= nil and proc.is_busy(api, sid, b.block_id),
    }
  end
  return out
end

return M
