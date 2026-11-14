local M = {}

local SHELLS = {
  bash = true,
  zsh = true,
  fish = true,
  sh = true,
  dash = true,
  ksh = true,
  tcsh = true,
  csh = true,
  nu = true,
  elvish = true,
  xonsh = true,
  pwsh = true,
  login = true,
}

local function shell_depth(chain, child)
  for i, proc in ipairs(chain) do
    if proc.pid == child.pid then
      return child.name == "login" and i - 1 or i
    end
  end
  return nil
end

function M.is_busy(api, sid, block_id)
  local ok, p = pcall(api.process, sid, block_id)
  if not ok or p == nil or p.foreground == nil then
    return false
  end
  local chain = { p.foreground }
  for _, a in ipairs(p.ancestors or {}) do
    chain[#chain + 1] = a
  end
  if p.child and p.child.pid then
    local depth = shell_depth(chain, p.child)
    if depth then
      return depth > 1
    end
  end
  local name = (p.foreground.name or ""):gsub("^%-", "")
  return not SHELLS[name]
end

return M
