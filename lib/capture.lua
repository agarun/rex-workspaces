local layout = require("rex-workspaces.lib.layout")
local path = require("rex-workspaces.lib.path")
local proc = require("rex-workspaces.lib.proc")
local servers = require("rex-workspaces.lib.servers")
local spec = require("rex-workspaces.lib.spec")

local M = {}

function M.tree(node, leaf)
  if node == nil then
    return nil
  end
  if node.block_id then
    return leaf(node.block_id)
  end
  local s = node.split
  if s == nil then
    return nil
  end
  local dir = s.direction == "vertical" and "down" or "right"
  local out = {}
  for _, child in ipairs({ s.before, s.after }) do
    local n = M.tree(child, leaf)
    if n and n.panes and n.split == dir then
      for _, x in ipairs(n.panes) do
        out[#out + 1] = x
      end
    elseif n then
      out[#out + 1] = n
    end
  end
  if #out <= 1 then
    return out[1]
  end
  return { split = dir, panes = out }
end

local function row_cells(row)
  if row.panes == nil then
    return { row }
  end
  if row.split ~= "right" then
    return nil
  end
  for _, x in ipairs(row.panes) do
    if x.panes then
      return nil
    end
  end
  return row.panes
end

function M.grids(node)
  if node == nil or node.panes == nil then
    return node
  end
  for i, x in ipairs(node.panes) do
    node.panes[i] = M.grids(x)
  end
  if node.split ~= "down" then
    return node
  end
  local cells, sizes = {}, {}
  for i, row in ipairs(node.panes) do
    local items = row_cells(row)
    if items == nil then
      return node
    end
    for _, x in ipairs(items) do
      cells[#cells + 1] = x
    end
    sizes[i] = #items
  end
  if table.concat(sizes, ",") ~= table.concat(layout.grid_rows(#cells), ",") then
    return node
  end
  return { split = "grid", panes = cells }
end

local function each_leaf(nodes, fn)
  for _, n in ipairs(nodes) do
    if n.panes then
      each_leaf(n.panes, fn)
    else
      fn(n)
    end
  end
end

local function relative(cwd, roots, home)
  if cwd == nil then
    return nil
  end
  for _, root in ipairs(roots) do
    local rel = path.relative(cwd, root)
    if rel == "" then
      return nil
    end
    if rel ~= cwd then
      return rel
    end
  end
  return path.contract(cwd, home)
end

local function plural(n, one, many)
  return n == 1 and one or many:format(n)
end

local function known_servers(api, sid, ws, raw)
  local by_block, specs = {}, {}
  if ws == nil then
    return by_block, specs
  end
  local found = servers.find(api, sid, ws)
  for _, s in ipairs((raw and raw.servers) or {}) do
    local b = type(s) == "table" and found[s.label]
    if b then
      by_block[b.block_id] = true
      specs[#specs + 1] = s
    end
  end
  return by_block, specs
end

local function known_cmds(ws)
  local cmds = {}
  if ws then
    for _, t in ipairs(ws.tabs) do
      each_leaf(t.panes, function(p)
        cmds[p.label] = cmds[p.label] or p.cmd
      end)
    end
  end
  return cmds
end

local function unique(label, taken)
  local pick, n = label, 2
  while taken[pick] do
    pick = label .. " " .. n
    n = n + 1
  end
  taken[pick] = true
  return pick
end

function M.session(api, sid, opts)
  local view = api.view(sid)
  local name = spec.default_name(view.label or opts.label, opts.home, opts.taken)
  local ws = opts.ws
  local server_blocks, server_specs = known_servers(api, sid, ws, opts.raw)
  local cmds = known_cmds(ws)
  local skip = opts.skip or {}
  local blocks, unreadable, ran, skipped = {}, 0, 0, {}
  local server_labels, floats = {}, {}
  for _, s in ipairs(server_specs) do
    server_labels[s.label] = true
  end

  for _, w in ipairs(view.windows or {}) do
    for _, layer in ipairs(w.layers or {}) do
      for _, b in ipairs(layer.blocks or {}) do
        blocks[b.block_id] = b
      end
    end
  end

  local function running(block_id)
    local cmd, busy = proc.command(api, sid, block_id)
    if cmd then
      ran = ran + 1
    elseif busy then
      unreadable = unreadable + 1
    end
    return cmd
  end

  local function cwd_of(block_id)
    return api.pwd(sid, block_id) or proc.cwd(api, sid, block_id)
  end

  local function leaf(block_id)
    if server_blocks[block_id] then
      return nil
    end
    local b = blocks[block_id] or {}
    local label = (b.label and b.label ~= "") and b.label or "shell"
    return { label = label, cmd = cmds[label] or running(block_id), cwd = cwd_of(block_id) }
  end

  local function float(layer, b)
    local cmd = running(b.block_id)
    if cmd == nil then
      skipped[#skipped + 1] = b.label or "pane"
      return
    end
    local s = { label = unique(b.label or "server", server_labels), cmd = cmd, cwd = cwd_of(b.block_id) }
    if layer.state ~= "minimized" then
      s.minimized = false
    end
    if #layer.blocks == 1 then
      s.bounds = layer.bounds
    end
    floats[#floats + 1] = s
  end

  local tabs, focus = {}, nil
  for _, w in ipairs(view.windows or {}) do
    local tiled
    for _, layer in ipairs(w.layers or {}) do
      if layer.kind == "floating" then
        for _, b in ipairs(layer.blocks or {}) do
          if not server_blocks[b.block_id] and not skip[b.label] then
            float(layer, b)
          end
        end
      elseif tiled == nil then
        tiled = layer
      end
    end
    local node = tiled and M.grids(M.tree(tiled.layout, leaf))
    if node then
      tabs[#tabs + 1] = {
        name = w.label,
        split = node.panes and node.split or nil,
        panes = node.panes or { node },
      }
      if w.window_id == view.active_window_id and #tabs > 1 then
        focus = w.label
      end
    end
  end

  local root = opts.root
  if root == nil then
    each_leaf(tabs[1] and tabs[1].panes or {}, function(p)
      root = root or p.cwd
    end)
  end
  root = root or opts.home
  local roots = { root, api.realpath(root) }
  for _, t in ipairs(tabs) do
    each_leaf(t.panes, function(p)
      p.cwd = relative(p.cwd, roots, opts.home)
    end)
  end
  for _, s in ipairs(floats) do
    s.cwd = relative(s.cwd, roots, opts.home)
    server_specs[#server_specs + 1] = s
  end

  local notes = {}
  if ran > 0 then
    notes[#notes + 1] = "Running commands were saved. They run again when the workspace starts."
  end
  if unreadable > 0 then
    notes[#notes + 1] = plural(
      unreadable,
      "1 pane runs a command that could not be read, so it opens as a shell.",
      "%d panes run commands that could not be read, so they open as shells."
    )
  end
  if #skipped > 0 then
    notes[#notes + 1] = "Skipped floating "
      .. (#skipped == 1 and "pane" or "panes")
      .. " with no running command: "
      .. table.concat(skipped, ", ")
      .. "."
  end
  if opts.taken and opts.taken[name] then
    notes[#notes + 1] = 'A workspace named "' .. name .. '" exists. Rename this one to save it.'
  end

  return {
    name = name,
    session_id = sid,
    notes = notes,
    spec = {
      root = path.contract(root, opts.home),
      servers_in = ws and ws.servers_in ~= "float" and ws.servers_in or nil,
      servers = server_specs,
      focus = focus,
      tabs = tabs,
    },
  }
end

return M
