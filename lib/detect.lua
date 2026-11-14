local path = require("rex-workspaces.lib.path")

local M = {}

M.MANIFESTS =
  { "package.json", "Makefile", "Procfile", "compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml" }

local LONG_RUNNING = { dev = true, start = true, serve = true, watch = true, server = true, up = true, run = true }

local RUNNERS = {
  { lock = "pnpm-lock.yaml", run = "pnpm %s" },
  { lock = "yarn.lock", run = "yarn %s" },
  { lock = "bun.lock", run = "bun run %s" },
  { lock = "bun.lockb", run = "bun run %s" },
}

local function is_long_running(task)
  return LONG_RUNNING[task] == true or LONG_RUNNING[task:match("^(%w+)[:%-]") or ""] == true
end

local function runner(fs, dir, root)
  for _, r in ipairs(RUNNERS) do
    if fs.exists(dir .. "/" .. r.lock) or fs.exists(root .. "/" .. r.lock) then
      return r.run
    end
  end
  return "npm run %s"
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function package_scripts(fs, file, dir, root)
  local doc = fs.decode(fs.read(file) or "")
  local scripts = type(doc) == "table" and doc.scripts or nil
  if type(scripts) ~= "table" then
    return {}
  end
  local run = runner(fs, dir, root)
  local out = {}
  for _, name in ipairs(sorted_keys(scripts)) do
    out[#out + 1] = { task = name, cmd = run:format(name) }
  end
  return out
end

local function make_targets(fs, file)
  local out, seen = {}, {}
  for line in (fs.read(file) or ""):gmatch("[^\n]+") do
    local target = line:match("^([%w_][%w_.%-/]*)%s*:")
    local assignment = line:match("^[%w_][%w_.%-/]*%s*:=") or line:match("^[%w_][%w_.%-/]*%s*::=")
    if target and not assignment and not seen[target] then
      seen[target] = true
      out[#out + 1] = { task = target, cmd = "make " .. target }
    end
  end
  return out
end

local function procfile(fs, file)
  local out = {}
  for line in (fs.read(file) or ""):gmatch("[^\n]+") do
    local name, cmd = line:match("^([%w_%-]+):%s*(.-)%s*$")
    if name and cmd ~= "" then
      out[#out + 1] = { task = name, cmd = cmd, long_running = true }
    end
  end
  return out
end

local function label_for(rel, task)
  local folder = rel ~= "" and path.basename(rel) or nil
  if folder and (task == "dev" or task == "start") then
    return folder
  end
  if folder then
    return folder .. " " .. task
  end
  return task
end

local function add_tasks(commands, tasks, rel, source)
  for _, t in ipairs(tasks) do
    local long_running = t.long_running or is_long_running(t.task)
    commands[#commands + 1] = {
      label = label_for(rel, t.task),
      cwd = rel,
      cmd = t.cmd,
      source = source,
      server = long_running,
    }
  end
end

function M.scan(fs, root)
  local result = { root = root, commands = {}, hooks = {} }
  for _, file in ipairs(fs.find(root, M.MANIFESTS, 2)) do
    local dir = path.dirname(file)
    local rel = path.relative(dir, root)
    local name = path.basename(file)
    local source = rel ~= "" and (rel .. "/" .. name) or name
    if name == "package.json" then
      add_tasks(result.commands, package_scripts(fs, file, dir, root), rel, source)
    elseif name == "Makefile" then
      add_tasks(result.commands, make_targets(fs, file), rel, source)
    elseif name == "Procfile" then
      add_tasks(result.commands, procfile(fs, file), rel, source)
    elseif rel == "" then
      result.hooks.before_start = "docker compose up -d"
      result.hooks.after_stop = "docker compose down"
    end
  end
  return result
end

function M.starter(scan, name)
  local raw = { root = scan.root, servers = {}, tabs = { { name = "main", panes = { { label = name } } } } }
  local seen = {}
  for _, c in ipairs(scan.commands) do
    if c.server and not seen[c.label] then
      seen[c.label] = true
      raw.servers[#raw.servers + 1] = { label = c.label, cwd = c.cwd, cmd = c.cmd }
    end
  end
  if next(scan.hooks) then
    raw.hooks = scan.hooks
  end
  return raw
end

return M
