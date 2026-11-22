local M = {}

local TERMINAL = "com.superlogical.terminal"

local function decode_file_url(url)
  local without_host = url:gsub("^file://[^/]*", "")
  return (without_host:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

function M.new(rex)
  local api = {}

  local function call(method, args)
    local r, err = rex.call(method, args or {})
    if r == nil and err ~= nil then
      error(method .. ": " .. tostring(err), 0)
    end
    return r or {}
  end

  local function terminal(sid, block_id, method, args)
    return call(TERMINAL .. "." .. method, { session_id = sid, block_id = block_id, args = args or {} })
  end

  local function attach(sid)
    call("session.attach", { session_id = sid })
  end

  function api.sessions()
    return call("session.list").sessions or {}
  end

  function api.create_session(label, windows)
    return call("session.create", { label = label, initial_windows = windows }).session_id
  end

  function api.view(sid)
    attach(sid)
    return call("session.view", { session_id = sid })
  end

  function api.new_window(sid, label, layout)
    return call("session.new_window", { session_id = sid, window_label = label, layout = layout, focus = false })
  end

  function api.new_split(sid, anchor_id, layout)
    return call("session.new_split", {
      session_id = sid,
      anchor_id = anchor_id,
      direction = "horizontal",
      side = "after",
      layout = layout,
      focus = false,
    })
  end

  function api.new_layer(sid, window_id, layout, bounds, focus)
    attach(sid)
    return call("session.new_layer", {
      session_id = sid,
      window_id = window_id,
      layout = layout,
      bounds = bounds,
      focus = focus or false,
    })
  end

  function api.minimize(sid, layer_id)
    call("session.set_layer_state", { session_id = sid, layer_id = layer_id, state = "minimized" })
  end

  function api.focus_window(sid, window_id)
    call("session.focus_window", { session_id = sid, window_id = window_id })
  end

  function api.process(sid, block_id)
    return terminal(sid, block_id, "process")
  end

  function api.screen(sid, block_id)
    local ok, r = pcall(terminal, sid, block_id, "format", { format = "vt" })
    return ok and r.content or nil
  end

  function api.text(sid, block_id)
    local ok, r = pcall(terminal, sid, block_id, "format", { format = "text" })
    return ok and r.content or nil
  end

  function api.term_size(sid, block_id)
    local ok, r = pcall(terminal, sid, block_id, "size")
    return ok and r or nil
  end

  function api.write(sid, block_id, data)
    terminal(sid, block_id, "write", { data = data })
  end

  function api.pwd(sid, block_id)
    local ok, r = pcall(terminal, sid, block_id, "pwd")
    local url = ok and r.pwd or nil
    if url == nil or url == "" then
      return nil
    end
    return decode_file_url(url)
  end

  function api.close_block(sid, block_id)
    call("block.close", { session_id = sid, block_id = block_id })
  end

  function api.resize_layer(sid, layer_id, bounds)
    call("session.resize_layer", { session_id = sid, layer_id = layer_id, bounds = bounds })
  end

  function api.close_layer(sid, layer_id)
    call("session.close_layer", { session_id = sid, layer_id = layer_id })
  end

  function api.destroy(sid)
    call("session.destroy", { session_id = sid })
  end

  local function has_app(ctx)
    if ctx and (ctx.origin == "key" or ctx.origin == "palette") then
      return true
    end
    local r = rex.call("client.list", {})
    for _, c in ipairs((r and r.clients) or {}) do
      if c.info and c.info.kind == "app" then
        return true
      end
    end
    return false
  end

  function api.calling_app(ctx)
    if not (ctx and ctx.client_id) then
      return nil
    end
    if ctx.origin == "key" or ctx.origin == "palette" then
      return ctx.client_id
    end
    local r = rex.call("client.list", { kinds = { "app" } })
    for _, c in ipairs((r and r.clients) or {}) do
      if c.client_id == ctx.client_id then
        return c.client_id
      end
    end
    return nil
  end

  function api.select(sid, ctx)
    if not has_app(ctx) then
      return false
    end
    return (pcall(rex.client.queue, "session.select", { session_id = sid }))
  end

  function api.open_palette(ctx)
    if not has_app(ctx) then
      return false
    end
    return (pcall(rex.client.queue, "client.palette.toggle"))
  end

  function api.sh(script, opts)
    local shell = os.getenv("SHELL") or "/bin/sh"
    local r, err = rex.exec({ shell, "-lc", script }, opts or {})
    if r == nil then
      error(err, 0)
    end
    return r
  end

  function api.sleep(seconds)
    rex.exec({ "sleep", tostring(seconds) })
  end

  function api.read(path)
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local text = f:read("*a")
    f:close()
    return text
  end

  function api.exists(path)
    local f = io.open(path, "r")
    if f then
      f:close()
    end
    return f ~= nil
  end

  local function any_name(argv, names)
    argv[#argv + 1] = "("
    for i, name in ipairs(names) do
      if i > 1 then
        argv[#argv + 1] = "-o"
      end
      argv[#argv + 1] = "-name"
      argv[#argv + 1] = name
    end
    argv[#argv + 1] = ")"
  end

  local PRUNED = { "node_modules", ".git", "target", "dist", "build", ".venv", "vendor" }

  function api.find(root, names, depth)
    local argv = { "find", root, "-mindepth", "1", "-maxdepth", tostring(depth) }
    any_name(argv, PRUNED)
    argv[#argv + 1] = "-prune"
    argv[#argv + 1] = "-o"
    any_name(argv, names)
    argv[#argv + 1] = "-print"
    local r = rex.exec(argv, { timeout = 10 })
    local files = {}
    for line in ((r and r.stdout) or ""):gmatch("[^\n]+") do
      files[#files + 1] = line
    end
    table.sort(files)
    return files
  end

  local function resolve(path)
    local r = rex.exec({ "realpath", path }, { timeout = 5 })
    local real = r and r.ok and (r.stdout or ""):match("^[^\n]+")
    return real or path
  end

  api.realpath = resolve

  function api.worktrees(root)
    local script = "git rev-parse --show-toplevel --show-prefix && git worktree list --porcelain"
    local r = rex.exec({ "sh", "-c", script }, { cwd = root, timeout = 5 })
    return r and r.ok and r.stdout or nil
  end

  function api.has_branch(dir, branch)
    local r = rex.exec(
      { "git", "-C", dir, "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch },
      { timeout = 5 }
    )
    return r ~= nil and r.ok == true
  end

  function api.args(pid)
    local r = rex.exec({ "ps", "-o", "args=", "-p", tostring(pid) }, { timeout = 5 })
    local line = r and r.ok and (r.stdout or ""):match("^%s*([^\n]-)%s*\n?$")
    return (line and line ~= "") and line or nil
  end

  function api.ps(pids)
    local argv = { "ps", "-o", "pid=", "-o", "ppid=", "-o", "uid=", "-o", "stat=" }
    if pids then
      argv[#argv + 1] = "-p"
      argv[#argv + 1] = table.concat(pids, ",")
    else
      argv[#argv + 1] = "-A"
    end
    local r = rex.exec(argv, { timeout = 5 })
    return r and r.stdout or ""
  end

  function api.decode(text)
    return rex.json.decode(text)
  end

  function api.signal(sig, pids)
    if #pids == 0 then
      return
    end
    local argv = { "kill", "-" .. sig }
    for _, pid in ipairs(pids) do
      argv[#argv + 1] = tostring(pid)
    end
    rex.exec(argv, { timeout = 5 })
  end

  function api.mkdir(dir)
    rex.exec({ "mkdir", "-p", dir }, { timeout = 5 })
  end

  function api.remove(path)
    os.remove(path)
  end

  function api.write_file(path, text)
    path = resolve(path)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then
      error(err, 0)
    end
    f:write(text)
    f:close()
    local ok, rename_err = os.rename(tmp, path)
    if not ok then
      error(rename_err, 0)
    end
  end

  return api
end

return M
