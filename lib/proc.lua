local M = {}

M.POLL = 0.25

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

local function read(api, sid, block_id)
  local ok, p = pcall(api.process, sid, block_id)
  if not ok or p == nil or p.foreground == nil then
    return nil
  end
  local chain = { p.foreground }
  for _, a in ipairs(p.ancestors or {}) do
    chain[#chain + 1] = a
  end
  local depth = p.child and p.child.pid and shell_depth(chain, p.child)
  return p, chain, depth
end

local function busy(p, depth)
  if p == nil then
    return false
  end
  if depth then
    return depth > 1
  end
  local name = (p.foreground.name or ""):gsub("^%-", "")
  return not SHELLS[name]
end

function M.is_busy(api, sid, block_id)
  local p, _, depth = read(api, sid, block_id)
  return busy(p, depth)
end

function M.interrupt(api, sid, items, timeout)
  local waiting, sent = {}, {}
  for _, it in ipairs(items) do
    if M.is_busy(api, sid, it.block_id) then
      api.write(sid, it.block_id, "\3")
      waiting[it] = true
      sent[it] = true
    end
  end
  local waited = 0
  while next(waiting) ~= nil and waited < timeout do
    api.sleep(M.POLL)
    waited = waited + M.POLL
    for it in pairs(waiting) do
      if not M.is_busy(api, sid, it.block_id) then
        waiting[it] = nil
      end
    end
  end
  return sent, waiting
end

return M
