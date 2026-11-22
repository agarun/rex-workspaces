local layout = require("rex-workspaces.lib.layout")

local M = {}

M.LABEL = "Workspaces"
M.EDIT_LABEL = "Edit workspaces"
M.BIN = "rex-workspaces"
M.INSTALL_URL = "https://raw.githubusercontent.com/agarun/rex-workspaces/main/install.sh"

local LAUNCH = ([[
local_bin=$1; client=$2; shift 2
[ -n "$client" ] && export REX_CLIENT="$client"
home_bin="${REX_WORKSPACES_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/rex-workspaces}/bin/rex-workspaces"
for bin in "$local_bin" "$home_bin"; do
  [ -x "$bin" ] && exec "$bin" "$@"
done
command -v rex-workspaces >/dev/null && exec rex-workspaces "$@"
printf 'rex-workspaces is not installed on this host.\nInstall it here with:\n'
printf '  curl -fsSL @URL@ | sh\n\nPress Enter to close.'
read -r _
]]):gsub("@URL@", M.INSTALL_URL)

function M.new(api, L, settings)
  local ui = {}
  local found

  function ui.bin()
    if found ~= nil then
      return found or nil
    end
    local candidates = {
      settings.module_dir .. "/bin/" .. M.BIN,
      settings.module_dir .. "/target/release/" .. M.BIN,
    }
    if settings.ui.bin then
      table.insert(candidates, 1, settings.ui.bin)
    end
    for _, candidate in ipairs(candidates) do
      if api.exists(candidate) then
        found = candidate
        return found
      end
    end
    local r = api.sh("command -v " .. M.BIN, { timeout = 5 })
    found = r.ok and (r.stdout or ""):match("[^\n]+") or false
    return found or nil
  end

  local function window_size(sid, block_id, view)
    local size = block_id and api.term_size(sid, block_id)
    if not (size and size.columns and size.rows) then
      return nil
    end
    local w, h = layout.block_share(view or api.view(sid), block_id)
    if not w or w <= 0 or h <= 0 then
      return nil
    end
    return size.columns / w, size.rows / h
  end

  local function bounds(ctx, rows, view)
    if settings.ui.bounds then
      return settings.ui.bounds
    end
    view = view or api.view(ctx.session_id)
    local tiled = ctx.block_id and layout.tiled_block(view, ctx.block_id)
    local cols, lines = window_size(ctx.session_id, tiled, view)
    if cols == nil then
      return layout.DEFAULT_UI_BOUNDS
    end
    return layout.fit(cols, lines, rows)
  end

  function ui.float(ctx, label, command, cwd, at)
    local block = L.block({
      flavor = layout.SHELL,
      label = label,
      options = { shell = "none", command = command, cwd = cwd },
    })
    return api.new_layer(ctx.session_id, nil, block, at, true)
  end

  function ui.open_layer(sid, view)
    for _, w in ipairs((view or api.view(sid)).windows or {}) do
      for _, layer in ipairs(w.layers or {}) do
        local b = (layer.blocks or {})[1]
        if layer.kind == "floating" and b and b.label == M.LABEL then
          return layer.layer_id, layer.bounds or {}
        end
      end
    end
    return nil
  end

  function ui.show(ctx, args, cwd, rows, view)
    local bin = ui.bin()
    if bin == nil or ctx.session_id == nil then
      return false
    end
    view = view or api.view(ctx.session_id)
    local layer = ui.open_layer(ctx.session_id, view)
    if layer then
      api.close_layer(ctx.session_id, layer)
    end
    local command = { "/bin/sh", "-c", LAUNCH, "sh", bin, api.calling_app(ctx) or "" }
    for _, a in ipairs(args or {}) do
      command[#command + 1] = a
    end
    local sub = (args or {})[1]
    if sub == "edit" or sub == "new" or sub == "capture" then
      rows = layout.EDIT_ROWS
    end
    ui.float(ctx, M.LABEL, command, cwd or settings.home, bounds(ctx, rows or 0, view))
    return true
  end

  function ui.resize(ctx, rows)
    if settings.ui.bounds or ctx.session_id == nil then
      return
    end
    local view = api.view(ctx.session_id)
    local layer, current = ui.open_layer(ctx.session_id, view)
    if layer == nil then
      return
    end
    local tiled = layout.tiled_block(view, layer)
    local cols, lines = window_size(ctx.session_id, tiled, view)
    if cols == nil then
      return
    end
    local want = layout.fit(cols, lines, rows)
    for i = 1, 4 do
      if math.abs((current[i] or 0) - want[i]) > 1e-6 then
        api.resize_layer(ctx.session_id, layer, want)
        return { resized = true }
      end
    end
  end

  function ui.toggle(ctx, cwd, rows)
    local view = ctx.session_id and api.view(ctx.session_id) or nil
    if view then
      local layer = ui.open_layer(ctx.session_id, view)
      if layer then
        api.close_layer(ctx.session_id, layer)
        return
      end
    end
    if type(cwd) == "function" then
      cwd = cwd()
    end
    if type(rows) == "function" then
      rows = rows()
    end
    if not ui.show(ctx, {}, cwd, rows, view) then
      api.open_palette(ctx)
    end
  end

  function ui.edit_file(ctx, file)
    local command = { "/bin/sh", "-c", '"${EDITOR:-vi}" "$1" && rex config reload', "sh", file }
    ui.float(ctx, M.EDIT_LABEL, command, settings.confdir, { 0.15, 0.1, 0.7, 0.7 })
  end

  return ui
end

return M
