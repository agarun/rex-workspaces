local path = require("rex-workspaces.lib.path")
local proc = require("rex-workspaces.lib.proc")
local spec = require("rex-workspaces.lib.spec")
local state = require("rex-workspaces.lib.state")
local store = require("rex-workspaces.lib.store")

local M = {}

-- codex and opencode keep conversations in a shared background server, so a pane's
-- conversation is only known from the resume command they print when they quit.
local AGENTS = {
  claude = { continue = "--continue", exact = "--resume %s" },
  codex = { continue = "resume --last", exact = "resume %s", printed = "codex resume ([%w%-]+)" },
  opencode = { continue = "--continue", exact = "--session %s", printed = "opencode %-s (%S+)" },
}

local RESUMING = {
  ["-c"] = true,
  ["--continue"] = true,
  ["-r"] = true,
  ["--resume"] = true,
  ["-s"] = true,
  ["--session"] = true,
}

local LAYOUT = { "root", "servers_in", "servers", "focus", "tabs" }

local function agent_of(cmd)
  local program, rest = (cmd or ""):match("^(%S+)(.*)$")
  local name = program and path.basename(program)
  if AGENTS[name] == nil then
    return nil
  end
  local first = rest:match("^%s+(%S+)")
  if first and not first:match("^%-") then
    return nil
  end
  for word in rest:gmatch("%S+") do
    if RESUMING[word] then
      return nil
    end
  end
  return name, program, rest
end

function M.resume_cmd(cmd, id)
  local name, program, rest = agent_of(cmd)
  if name == nil then
    return cmd
  end
  local how = id and AGENTS[name].exact:format(id) or AGENTS[name].continue
  return program .. " " .. how .. rest
end

local function quit(api, sid, block_id)
  for _ = 1, 3 do
    if not proc.is_busy(api, sid, block_id) then
      return
    end
    api.write(sid, block_id, "\3")
    local waited = 0
    while waited < 1 and proc.is_busy(api, sid, block_id) do
      api.sleep(proc.POLL)
      waited = waited + proc.POLL
    end
  end
end

local function last_match(text, pattern)
  local found
  for id in (text or ""):gmatch(pattern) do
    found = id
  end
  return found
end

function M.conversation(api, sid, block_id, cmd, claude_dir)
  local name = agent_of(cmd)
  if name == "claude" then
    local pid = proc.pid(api, sid, block_id)
    local doc = pid and api.read(claude_dir .. "/sessions/" .. pid .. ".json")
    return doc and doc:match('"sessionId"%s*:%s*"([%w%-]+)"')
  elseif name then
    quit(api, sid, block_id)
    return last_match(api.text(sid, block_id), AGENTS[name].printed)
  end
  return nil
end

local function file(dir, ws)
  return state.file(dir, "snoozed", ws)
end

function M.exists(api, dir, ws)
  return api.exists(file(dir, ws))
end

function M.read(api, dir, ws)
  return state.read(api, file(dir, ws))
end

function M.discard(api, dir, ws)
  api.remove(file(dir, ws))
end

function M.snapshot(api, sid, draft, claude_dir)
  local screens, n = {}, 0
  for _, t in ipairs(draft.spec.tabs) do
    spec.each_pane(t.panes, function(p)
      n = n + 1
      local block_id = draft.blocks[n]
      if p.cmd == nil then
        screens[tostring(n)] = api.screen(sid, block_id)
      else
        p.cmd = M.resume_cmd(p.cmd, M.conversation(api, sid, block_id, p.cmd, claude_dir))
      end
    end)
  end
  for _, s in ipairs(draft.spec.servers) do
    s.cmd = M.resume_cmd(s.cmd)
  end
  return { spec = store.prune(draft.spec), screens = screens }
end

function M.write(api, dir, ws, snap)
  state.write(api, file(dir, ws), snap)
end

function M.workspace(raw, snap, name, home)
  local merged = {}
  for k, v in pairs(raw or {}) do
    merged[k] = v
  end
  for _, k in ipairs(LAYOUT) do
    merged[k] = snap.spec[k]
  end
  local ws, errs = spec.normalize(name, merged, home)
  if #errs > 0 then
    error(table.concat(errs, "\n"), 0)
  end
  return ws
end

function M.place_screens(api, dir, ws, snap)
  local n = 0
  for _, t in ipairs(ws.tabs) do
    spec.each_pane(t.panes, function(p)
      n = n + 1
      local text = snap.screens and snap.screens[tostring(n)]
      if text and text ~= "" then
        local f = dir .. "/screens/" .. ws.slug .. "-" .. n .. ".vt"
        api.mkdir(path.dirname(f))
        api.write_file(f, text)
        p.replay = f
      end
    end)
  end
end

return M
