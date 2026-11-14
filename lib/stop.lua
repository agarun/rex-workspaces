local proc = require("rex-workspaces.lib.proc")
local servers = require("rex-workspaces.lib.servers")
local spec = require("rex-workspaces.lib.spec")

local M = {}

function M.panes(view, ws, skip)
  local by_name = {}
  for _, w in ipairs(view.windows or {}) do
    if w.label and by_name[w.label] == nil then
      by_name[w.label] = w
    end
  end
  local out = {}
  for _, t in ipairs(ws.tabs) do
    local w = by_name[t.name]
    local free = {}
    for _, layer in ipairs(w and w.layers or {}) do
      if layer.kind ~= "floating" then
        for _, b in ipairs(layer.blocks or {}) do
          if b.label and not skip[b.block_id] then
            free[b.label] = free[b.label] or {}
            table.insert(free[b.label], b.block_id)
          end
        end
      end
    end
    spec.each_pane(t.panes, function(p)
      local ids = free[p.label]
      if ids and #ids > 0 then
        out[#out + 1] = {
          kind = "pane",
          label = p.label,
          block_id = table.remove(ids, 1),
          how = p.stop or ws.stop.panes,
        }
      end
    end)
  end
  return out
end

local function better(a, b)
  return a == nil or (a.kind ~= "pane" and b.kind == "pane")
end

function M.protect(view, targets)
  local closing = {}
  for _, t in ipairs(targets) do
    if t.how == "close" then
      closing[t.block_id] = t
    end
  end
  local kept = {}
  local function keep(t)
    t.how = "interrupt"
    closing[t.block_id] = nil
    kept[#kept + 1] = t.label
  end
  local tiled_total, fallback = 0, nil
  for _, w in ipairs(view.windows or {}) do
    local tiled, floating, first = 0, 0, nil
    for _, layer in ipairs(w.layers or {}) do
      local float = layer.kind == "floating"
      for _, b in ipairs(layer.blocks or {}) do
        local t = closing[b.block_id]
        if t == nil then
          tiled = tiled + (float and 0 or 1)
          floating = floating + (float and 1 or 0)
        elseif not float and better(first, t) then
          first = t
        end
      end
    end
    if tiled == 0 and first and floating > 0 then
      keep(first)
      tiled = 1
    end
    tiled_total = tiled_total + tiled
    if first and better(fallback, first) then
      fallback = first
    end
  end
  if tiled_total == 0 and fallback then
    keep(fallback)
  end
  return kept
end

function M.plan(api, sid, ws, opts)
  local found = servers.find(api, sid, ws)
  local targets, server_ids = {}, {}
  for _, s in ipairs(ws.servers) do
    local b = found[s.label]
    if b then
      server_ids[b.block_id] = true
      local how = s.stop or ws.stop.servers
      if how ~= "leave" then
        targets[#targets + 1] =
          { kind = "server", label = s.label, block_id = b.block_id, layer_id = b.layer_id, how = how }
      end
    end
  end
  local view = api.view(sid)
  if opts.panes then
    for _, p in ipairs(M.panes(view, ws, server_ids)) do
      if p.how ~= "leave" then
        targets[#targets + 1] = p
      end
    end
  end
  return targets, M.protect(view, targets)
end

function M.run(api, sid, ws, opts)
  local targets, kept = M.plan(api, sid, ws, opts)
  local sent, busy = proc.interrupt(api, sid, targets, ws.stop_timeout)
  local r = { closed = {}, interrupted = {}, forced = {}, kept = kept }
  for _, t in ipairs(targets) do
    if t.how == "close" then
      if t.layer_id then
        api.close_layer(sid, t.layer_id)
      else
        api.close_block(sid, t.block_id)
      end
      r.closed[#r.closed + 1] = t
    elseif sent[t] then
      r.interrupted[#r.interrupted + 1] = t
    end
    if busy[t] then
      r.forced[#r.forced + 1] = t
    end
  end
  return r
end

local function count(list, kind)
  local n = 0
  for _, t in ipairs(list) do
    n = n + (t.kind == kind and 1 or 0)
  end
  if n == 0 then
    return nil
  end
  return n .. " " .. kind .. (n == 1 and "" or "s")
end

local function labels(list, closed)
  local out = {}
  for _, t in ipairs(list) do
    if (t.how == "close") == closed then
      out[#out + 1] = t.label
    end
  end
  return #out > 0 and table.concat(out, ", ") or nil
end

function M.message(name, r, timeout)
  local done = {}
  for _, part in ipairs({
    { "closed", count(r.closed, "server") },
    { "interrupted", count(r.interrupted, "server") },
    { "closed", count(r.closed, "pane") },
    { "interrupted", count(r.interrupted, "pane") },
  }) do
    if part[2] then
      done[#done + 1] = part[1] .. " " .. part[2]
    end
  end
  local out = {
    #done > 0 and ("Stopped " .. name .. ": " .. table.concat(done, ", ") .. ".")
      or ("Nothing to stop in " .. name .. "."),
  }
  local after = "after " .. timeout .. "s"
  local forced_closed, still = labels(r.forced, true), labels(r.forced, false)
  if forced_closed then
    out[#out + 1] = "Closed " .. after .. " without stopping: " .. forced_closed .. "."
  end
  if still then
    out[#out + 1] = "Still running " .. after .. ": " .. still .. "."
  end
  if #r.kept > 0 then
    out[#out + 1] = "Kept " .. table.concat(r.kept, ", ") .. " open so the session is not left empty."
  end
  return table.concat(out, " ")
end

return M
