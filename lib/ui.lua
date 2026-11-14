local layout = require("rex-workspaces.lib.layout")

local M = {}

M.LABEL = "Workspaces"
M.EDIT_LABEL = "Edit workspaces"
M.BIN = "rex-workspaces"
M.INSTALL_URL = "https://raw.githubusercontent.com/agarun/rex-workspaces/main/install.sh"

local LAUNCH = ([[
local_bin=$1; shift
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

  local function window_size(sid, block_id)
    local size = block_id and api.term_size(sid, block_id)
    if not (size and size.columns and size.rows) then
      return nil
    end
    local w, h = layout.block_share(api.view(sid), block_id)
    if not w or w <= 0 or h <= 0 then
      return nil
    end
    return size.columns / w, size.rows / h
  end

  local function bounds(ctx, rows)
    if settings.ui.bounds then
      return settings.ui.bounds
    end
    local cols, lines = window_size(ctx.session_id, ctx.block_id)
    if cols == nil then
      return layout.DEFAULT_UI_BOUNDS
    end
    return layout.fit(cols, lines, rows)
  end

  function ui.float(ctx, label, command, cwd, at)
    local block = L.block({
      flavor = layout.SHELL,
      label = label,
      options = { command = command, cwd = cwd },
    })
    return api.new_layer(ctx.session_id, nil, block, at, true)
  end

  function ui.open_layer(sid)
    for _, w in ipairs(api.view(sid).windows or {}) do
      for _, layer in ipairs(w.layers or {}) do
        local b = (layer.blocks or {})[1]
        if layer.kind == "floating" and b and b.label == M.LABEL then
          return layer.layer_id, layer.bounds or {}
        end
      end
    end
    return nil
  end

  function ui.show(ctx, args, cwd, rows)
    local bin = ui.bin()
    if bin == nil or ctx.session_id == nil then
      return false
    end
    local layer = ui.open_layer(ctx.session_id)
    if layer then
      api.close_layer(ctx.session_id, layer)
    end
    local command = { "sh", "-c", LAUNCH, "sh", bin }
    for _, a in ipairs(args or {}) do
      command[#command + 1] = a
    end
    local sub = (args or {})[1]
    if sub == "edit" or sub == "new" or sub == "capture" then
      rows = layout.EDIT_ROWS
    end
    ui.float(ctx, M.LABEL, command, cwd or settings.home, bounds(ctx, rows or 0))
    return true
  end

  function ui.resize(ctx, rows)
    if settings.ui.bounds or ctx.session_id == nil then
      return
    end
    local layer, current = ui.open_layer(ctx.session_id)
    if layer == nil then
      return
    end
    local tiled = layout.tiled_block(api.view(ctx.session_id), layer)
    local cols, lines = window_size(ctx.session_id, tiled)
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
    if ctx.session_id then
      local layer = ui.open_layer(ctx.session_id)
      if layer then
        api.close_layer(ctx.session_id, layer)
        return
      end
    end
    if not ui.show(ctx, {}, cwd, rows) then
      api.open_palette(ctx)
    end
  end

  function ui.edit_file(ctx, file)
    local command = { "sh", "-c", '"${EDITOR:-vi}" "$1" && rex config reload', "sh", file }
    ui.float(ctx, M.EDIT_LABEL, command, settings.confdir, { 0.15, 0.1, 0.7, 0.7 })
  end

  return ui
end

return M
