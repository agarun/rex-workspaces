local M = {}

M.TIMEOUT = 20

function M.run(api, ws, name)
  local script = ws.hooks[name]
  if script == nil then
    return
  end
  local r = api.sh(script, { cwd = ws.dir, timeout = M.TIMEOUT })
  if r.ok then
    return
  end
  local why = r.timed_out and ("timed out after " .. M.TIMEOUT .. "s") or ("exited " .. tostring(r.code))
  local detail = (r.stderr ~= "" and r.stderr) or r.stdout or ""
  error(ws.name .. " " .. name .. " hook " .. why .. (detail ~= "" and (": " .. detail) or ""), 0)
end

return M
