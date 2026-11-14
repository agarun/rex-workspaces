local M = {}

local function bind(rex, key, action, args)
  local ok, err = pcall(rex.bind, key, action, args)
  if not ok then
    rex.log("warn", "rex-workspaces: cannot bind " .. key .. ": " .. tostring(err))
  end
end

function M.apply(rex, settings, cfg)
  if settings.keys.open then
    bind(rex, settings.keys.open, "workspace_ui")
  end
  for _, ws in ipairs(cfg.list) do
    if ws.key then
      bind(rex, ws.key, "workspace_open", { name = ws.name })
    end
  end
end

return M
