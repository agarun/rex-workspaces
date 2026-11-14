local M = {}

M.SHELL = "com.superlogical.terminal.shell"
M.DEFAULT_UI_BOUNDS = { 0.2, 0.15, 0.6, 0.7 }

function M.block(L, p)
  return L.block({
    flavor = M.SHELL,
    label = p.label,
    options = { cwd = p.cwd, initial_input = p.cmd and (p.cmd .. "\n") or nil },
  })
end

function M.grid_rows(n)
  local cols = math.ceil(math.sqrt(n))
  local rows = {}
  for first = 1, n, cols do
    rows[#rows + 1] = math.min(cols, n - first + 1)
  end
  return rows
end

local function chain(pair, items, from, to)
  if from == to then
    return items[from]
  end
  return pair(1 / (to - from + 1), items[from], chain(pair, items, from + 1, to))
end

function M.panes(L, panes, split)
  local built = {}
  for i, p in ipairs(panes) do
    built[i] = p.panes and M.panes(L, p.panes, p.split) or M.block(L, p)
  end
  if split ~= "grid" then
    return chain(split == "down" and L.vertical or L.horizontal, built, 1, #built)
  end
  local rows, first = {}, 1
  for i, count in ipairs(M.grid_rows(#built)) do
    rows[i] = chain(L.horizontal, built, first, first + count - 1)
    first = first + count
  end
  return chain(L.vertical, rows, 1, #rows)
end

function M.float_bounds(i, n)
  local gap = 0.02
  local h = math.min(0.25, (0.9 - gap * (n - 1)) / n)
  return { 0.6, 0.05 + (i - 1) * (h + gap), 0.38, h }
end

local function find_rect(node, block_id)
  if node == nil then
    return nil
  end
  if node.block_id == block_id then
    return node.rect
  end
  local split = node.split
  if split then
    return find_rect(split.before, block_id) or find_rect(split.after, block_id)
  end
  return nil
end

local function first_block(node)
  if node == nil or node.block_id then
    return node and node.block_id
  end
  local split = node.split
  return split and (first_block(split.before) or first_block(split.after))
end

function M.tiled_block(view, layer_id)
  for _, w in ipairs(view.windows or {}) do
    local tiled, has = nil, false
    for _, layer in ipairs(w.layers or {}) do
      if layer.kind == "tiled" then
        tiled = first_block(layer.layout)
      elseif layer.layer_id == layer_id then
        has = true
      end
    end
    if has then
      return tiled
    end
  end
  return nil
end

function M.block_share(view, block_id)
  for _, w in ipairs(view.windows or {}) do
    for _, layer in ipairs(w.layers or {}) do
      local rect = find_rect(layer.layout, block_id)
      if rect then
        local b = layer.bounds or { 0, 0, 1, 1 }
        return b[3] * rect[3], b[4] * rect[4]
      end
    end
  end
  return nil
end

M.UI = { min_rows = 10, cols = 96, chrome_rows = 3, max_w = 0.9, max_h = 0.85, min_w = 0.5 }

M.EDIT_ROWS = 34

local function height(win_rows, rows)
  local u = M.UI
  return math.min(u.max_h, (math.max(rows, u.min_rows) + u.chrome_rows) / win_rows)
end

function M.fit(win_cols, win_rows, rows)
  local u = M.UI
  local h = height(win_rows, rows)
  local tallest = math.max(h, height(win_rows, M.EDIT_ROWS))
  local w = math.min(u.max_w, math.max(u.min_w, u.cols / win_cols))
  return { (1 - w) / 2, (1 - tallest) / 2, w, h }
end

function M.list_rows(count, most_servers)
  local servers = most_servers > 0 and most_servers + 1 or 0
  return math.max(count, 1) * 3 + servers + 5
end

function M.windows(L, ws)
  local windows = {}
  for _, tab in ipairs(ws.tabs) do
    windows[#windows + 1] = { window_label = tab.name, layout = M.panes(L, tab.panes, tab.split) }
  end
  return windows
end

return M
