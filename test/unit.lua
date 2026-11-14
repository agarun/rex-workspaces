table.insert(package.loaders, 2, function(name)
  local rel = name:match("^rex%-workspaces%.(.+)$")
  if rel == nil then
    return nil
  end
  local file = "./" .. rel:gsub("%.", "/") .. ".lua"
  local chunk, err = loadfile(file)
  if chunk == nil then
    return "\n\t" .. tostring(err)
  end
  return chunk
end)

local config = require("rex-workspaces.lib.config")
local detect = require("rex-workspaces.lib.detect")
local json = require("rex-workspaces.lib.json")
local layout = require("rex-workspaces.lib.layout")
local lifecycle = require("rex-workspaces.lib.lifecycle")
local options = require("rex-workspaces.lib.options")
local path = require("rex-workspaces.lib.path")
local proc = require("rex-workspaces.lib.proc")
local spec = require("rex-workspaces.lib.spec")
local store = require("rex-workspaces.lib.store")

local pass, fail = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

local function show(v)
  if type(v) == "table" then
    return (json.encode(v):gsub("%s+", " "))
  end
  return tostring(v)
end

local function eq(got, want, what)
  if show(got) ~= show(want) then
    error((what or "value") .. ": expected " .. show(want) .. ", got " .. show(got), 2)
  end
end

local function contains(list, needle)
  for _, s in ipairs(list) do
    if s:find(needle, 1, true) then
      return
    end
  end
  error("no message containing [" .. needle .. "] in " .. show(list), 2)
end

local HOME = "/home/u"

local function build(workspaces)
  return config.build({ { path = "f.json", doc = { workspaces = workspaces } } }, HOME)
end

test("path helpers", function()
  eq(path.expand("~/p", HOME), "/home/u/p")
  eq(path.expand("~", HOME), HOME)
  eq(path.expand("/abs", HOME), "/abs")
  eq(path.contract("/home/u/p", HOME), "~/p")
  eq(path.contract("/home/user2", HOME), "/home/user2")
  eq(path.join("/r", "web"), "/r/web")
  eq(path.join("/r/", "/abs"), "/abs")
  eq(path.join("/r", nil), "/r")
  eq(path.relative("/r/web/x", "/r"), "web/x")
  eq(path.relative("/r", "/r"), "")
  eq(path.basename("/a/b/"), "b")
end)

test("slug", function()
  eq(spec.slug("My App-2"), "my_app_2")
  eq(spec.slug("--x--"), "x")
end)

test("defaults: one shell tab at the root", function()
  local cfg, errs = build({ app = { root = "~/app" } })
  eq(#errs, 0, "errors")
  local ws = cfg.by_name.app
  eq(ws.root, "/home/u/app")
  eq(ws.servers_in, "float")
  eq(ws.stop_timeout, 5)
  eq(ws.switch, true)
  eq(ws.tabs[1].name, "main")
  eq(ws.tabs[1].panes[1].cwd, "/home/u/app")
end)

test("no root falls back to home", function()
  local cfg = build({ app = { tabs = { { name = "t", panes = { { label = "p", cwd = "x" } } } } } })
  eq(cfg.by_name.app.dir, HOME)
  eq(cfg.by_name.app.tabs[1].panes[1].cwd, "/home/u/x")
end)

test("every option", function()
  local cfg, errs = build({
    app = {
      root = "/r",
      key = "ctrl+cmd+1",
      focus = "agents",
      switch = false,
      servers = {
        { label = "web", cwd = "web", cmd = "pnpm dev" },
        { label = "api", cmd = "make api", minimized = false, bounds = { 0.5, 0.1, 0.4, 0.3 } },
      },
      tabs = { { name = "agents", split = "down", panes = { { label = "a" }, { label = "b", cwd = "/elsewhere" } } } },
    },
  })
  eq(#errs, 0, "errors")
  local ws = cfg.by_name.app
  eq(ws.key, "ctrl+cmd+1")
  eq(ws.focus, "agents")
  eq(ws.switch, false)
  eq(ws.servers[1].cwd, "/r/web")
  eq(ws.servers[1].minimized, true)
  eq(ws.servers[2].minimized, false)
  eq(ws.servers[2].bounds, { 0.5, 0.1, 0.4, 0.3 })
  eq(ws.tabs[1].split, "down")
  eq(ws.tabs[1].panes[2].cwd, "/elsewhere")
end)

test("later files override earlier ones and remember where each came from", function()
  local cfg = config.build({
    { path = "a.json", doc = { workspaces = { a = { root = "/one" }, b = { root = "/b" } } } },
    { path = "b.json", doc = { workspaces = { a = { root = "/two" } } } },
  }, HOME)
  eq(cfg.by_name.a.root, "/two")
  eq(cfg.origin.a, "b.json")
  eq(cfg.origin.b, "a.json")
  eq(cfg.list[1].name, "a")
end)

test("a file without a workspaces object is reported", function()
  local cfg, errs = config.build({ { path = "x.json", doc = { app = {} } } }, HOME)
  eq(#cfg.list, 0)
  contains(errs, 'x.json: needs a top-level "workspaces" object')
end)

test("validation messages", function()
  local _, errs = build({
    bad = {
      servers_in = "side",
      stop_timeout = -1,
      focus = "nowhere",
      switch = "yes",
      servers = {
        { label = "s" },
        { cmd = "x" },
        { label = "d", cmd = "a" },
        { label = "d", cmd = "b", bounds = { 2, 0, 0, 0 } },
      },
      tabs = { { name = "t", split = "diagonal", panes = { { label = "p", cmd = 3 } } } },
      hooks = { before_start = 1 },
    },
    ["!!"] = {},
  })
  contains(errs, 'bad.servers_in: must be "float" or "tab"')
  contains(errs, "bad.stop_timeout")
  contains(errs, 'bad.focus: no tab named "nowhere"')
  contains(errs, "bad.switch: must be a boolean")
  contains(errs, "bad.servers[1]: cmd is required")
  contains(errs, "bad.servers[2]: label is required")
  contains(errs, 'duplicate server label "d"')
  contains(errs, "bad.servers[4].bounds")
  contains(errs, "bad.tabs[1].split")
  contains(errs, "bad.tabs[1].panes[1].cmd: must be a string")
  contains(errs, "bad.hooks.before_start: must be a string")
  contains(errs, "!!: name needs at least one letter or digit")
end)

test("slug clashes are reported", function()
  local cfg, errs = build({ ["my-app"] = {}, ["my app"] = {} })
  eq(#cfg.list, 1)
  contains(errs, "same action name")
end)

test("load skips missing and empty files, reports bad JSON", function()
  local files = { a = '{"workspaces":{"x":{}}}', b = "  \n", c = "{oops" }
  local read = function(p)
    return files[p]
  end
  local decode = function(t)
    if t:sub(1, 2) == "{o" then
      return nil, "bad json"
    end
    return { workspaces = { x = {} } }
  end
  local cfg, errs = config.load({ "a", "b", "c", "missing" }, read, decode, HOME)
  eq(#cfg.list, 1)
  eq(errs, { "c: bad json" })
end)

test("options: defaults, keys, unknown names", function()
  local s, unknown = options.resolve(nil, "/c/rex/rex-workspaces", HOME)
  eq(s.files, { "/c/rex/workspaces.json", "/c/rex/workspaces.local.json" })
  eq(s.keys.open, "cmd+o")
  eq(s.palette, true)
  eq(#unknown, 0)
  s = options.resolve({ keys = false }, "/m", HOME)
  eq(s.keys.open, false)
  s, unknown = options.resolve({ keys = { open = "shift+cmd+o" }, files = { "~/w.json" }, key = "x" }, "/m", HOME)
  eq(s.keys.open, "shift+cmd+o")
  eq(s.files, { "/home/u/w.json" })
  eq(unknown, { "key" })
end)

local L = {
  block = function(t)
    return { block = t }
  end,
  horizontal = function(r, a, b)
    return { h = r, a = a, b = b }
  end,
  vertical = function(r, a, b)
    return { v = r, a = a, b = b }
  end,
}

test("layout splits panes evenly", function()
  local tree = layout.panes(L, { { label = "a" }, { label = "b" }, { label = "c", cmd = "x" } }, "right")
  eq(tree.h, 1 / 3)
  eq(tree.b.h, 1 / 2)
  eq(tree.b.b.block.label, "c")
  eq(tree.b.b.block.options.initial_input, "x\n")
  eq(layout.panes(L, { { label = "a" }, { label = "b" } }, "down").v, 0.5)
end)

test("float bounds stay inside the window", function()
  for n = 1, 8 do
    local last = layout.float_bounds(n, n)
    if last[2] + last[4] > 0.96 then
      error(n .. " servers overflow: " .. show(last))
    end
  end
  eq(layout.float_bounds(1, 1), { 0.6, 0.05, 0.38, 0.25 })
end)

test("block share multiplies the layer bounds by the pane's rect", function()
  local view = {
    windows = {
      {
        layers = {
          {
            bounds = { 0, 0, 1, 1 },
            layout = {
              rect = { 0, 0, 1, 1 },
              split = {
                before = { rect = { 0, 0, 0.5, 1 }, block_id = "a" },
                after = { rect = { 0.5, 0, 0.5, 1 }, block_id = "b" },
              },
            },
          },
          { bounds = { 0.1, 0.1, 0.5, 0.4 }, layout = { rect = { 0, 0, 1, 1 }, block_id = "f" } },
        },
      },
    },
  }
  eq({ layout.block_share(view, "b") }, { 0.5, 1 })
  eq({ layout.block_share(view, "f") }, { 0.5, 0.4 })
  eq(layout.block_share(view, "nope"), nil)
  local with_float = {
    windows = {
      { layers = { { kind = "tiled", layout = { split = { before = { block_id = "t" } } } } } },
      {
        layers = {
          { kind = "tiled", layout = { block_id = "u" } },
          { kind = "floating", layer_id = "L" },
        },
      },
    },
  }
  eq(layout.tiled_block(with_float, "L"), "u")
  eq(layout.tiled_block(with_float, "nope"), nil)
end)

test("ui fit centers, grows with the list, and stays inside the window", function()
  eq(layout.list_rows(0, 0), 8)
  eq(layout.list_rows(2, 3), 15)
  local b = layout.fit(200, 50, 13)
  local edit = layout.fit(200, 50, layout.EDIT_ROWS)
  eq(edit[2] + edit[4] / 2, 0.5, "edit form is centered")
  eq(b[2], edit[2], "list shares the edit form's top edge")
  eq(b[1] + b[3] / 2, 0.5, "horizontal center")
  eq(b[4], (13 + layout.UI.chrome_rows) / 50)
  eq(layout.fit(200, 50, 2)[4], (layout.UI.min_rows + layout.UI.chrome_rows) / 50, "min rows")
  eq(layout.fit(200, 50, 500)[4], layout.UI.max_h, "max height")
  eq(layout.fit(80, 50, 10)[3], layout.UI.max_w, "narrow window")
end)

test("json orders keys and escapes", function()
  local out = json.encode({
    workspaces = { app = { tabs = {}, root = "~/a", servers = { { cmd = 'say "hi"\n', label = "s" } } } },
  })
  if out:find('"root"') >= out:find('"servers"') then
    error("root should come before servers:\n" .. out)
  end
  if not out:find('"label": "s",\n%s+"cmd": "say \\"hi\\"\\n"') then
    error("label/cmd order or escaping:\n" .. out)
  end
  eq(json.encode({ bounds = { 0.6, 0.05 } }), '{\n  "bounds": [0.6, 0.05]\n}\n')
end)

local function memory_store(files)
  local decode = function(text)
    local lua = text:gsub("%[", "{"):gsub("%]", "}"):gsub('"([^"]-)"%s*:', function(k)
      return '["' .. k .. '"]='
    end)
    local f = assert(loadstring("return " .. lua))
    local ok, v = pcall(f)
    if not ok then
      return nil, v
    end
    return v
  end
  return {
    paths = { "main.json", "local.json" },
    primary = "main.json",
    home = HOME,
    read = function(p)
      return files[p]
    end,
    write = function(p, text)
      files[p] = text
    end,
    decode = decode,
  }
end

local function lua_doc(t)
  return json.encode(t)
end

test("store saves, renames, prunes empties, refuses duplicates", function()
  local files = { ["main.json"] = lua_doc({ workspaces = { a = { root = "/a" } } }) }
  local s = memory_store(files)
  local r = store.save(s, "b", { root = "/b", servers = {}, hooks = { before_start = "" }, tabs = { { name = "t" } } })
  eq(r.file, "main.json")
  if files["main.json"]:find("servers") or files["main.json"]:find("hooks") then
    error("empty values should be dropped:\n" .. files["main.json"])
  end
  local ok, err = pcall(store.save, s, "a", { root = "/x" })
  eq(ok, false)
  if not tostring(err):find("already exists") then
    error(err)
  end
  store.save(s, "c", { root = "/c" }, "b")
  if files["main.json"]:find('"b"') or not files["main.json"]:find('"c"') then
    error("rename failed:\n" .. files["main.json"])
  end
  ok, err = pcall(store.save, s, "d", { servers = { { label = "x" } } })
  eq(ok, false)
  if not tostring(err):find("cmd is required") then
    error(err)
  end
end)

test("store writes back to the file a workspace came from", function()
  local files = {
    ["main.json"] = lua_doc({ workspaces = { a = { root = "/a" } } }),
    ["local.json"] = lua_doc({ workspaces = { secret = { root = "/s" } } }),
  }
  local s = memory_store(files)
  eq(store.save(s, "secret", { root = "/s2" }, "secret").file, "local.json")
  eq(store.remove(s, "a").file, "main.json")
  if files["main.json"]:find('"a"') then
    error("not removed")
  end
end)

local function fake_fs(tree)
  return {
    find = function(root)
      local out = {}
      for p in pairs(tree) do
        if p:sub(1, #root) == root and not p:find("lock") then
          out[#out + 1] = p
        end
      end
      table.sort(out)
      return out
    end,
    read = function(p)
      return tree[p]
    end,
    exists = function(p)
      return tree[p] ~= nil
    end,
    decode = function(text)
      if text:find("scripts") then
        return { scripts = { dev = "vite", build = "vite build", ["dev:docs"] = "x" } }
      end
      return nil
    end,
  }
end

test("detect finds scripts, make targets, Procfile, compose", function()
  local fs = fake_fs({
    ["/p/Makefile"] = "VAR := 1\n.PHONY: dev\ndev: deps\n\tgo run .\ntest:\n\tgo test\n",
    ["/p/web/package.json"] = '{"scripts":{}}',
    ["/p/web/pnpm-lock.yaml"] = "",
    ["/p/Procfile"] = "worker: bin/worker --queue x\n",
    ["/p/compose.yaml"] = "services: {}",
  })
  local scan = detect.scan(fs, "/p")
  local by = {}
  for _, c in ipairs(scan.commands) do
    by[c.cmd] = c
  end
  eq(by["make dev"].server, true)
  eq(by["make test"].server, false)
  eq(by["make VAR"], nil)
  eq(by["pnpm dev"].label, "web")
  eq(by["pnpm dev"].cwd, "web")
  eq(by["pnpm dev:docs"].server, true)
  eq(by["pnpm build"].label, "web build")
  eq(by["bin/worker --queue x"].label, "worker")
  eq(scan.hooks.before_start, "docker compose up -d")
  local starter = detect.starter(scan, "p")
  eq(#starter.servers, 4)
  eq(starter.tabs[1].panes[1].label, "p")
end)

local function fake(opts)
  opts = opts or {}
  local calls, sessions, busy = {}, {}, opts.busy or {}
  local api = {}
  local function log(...)
    calls[#calls + 1] = table.concat({ ... }, " ")
  end
  function api.sessions()
    return sessions
  end
  function api.create_session(label)
    sessions[#sessions + 1] = { label = label, session_id = "s1" }
    log("create", label)
    return "s1"
  end
  function api.view()
    return { windows = opts.windows or { { window_id = "w1", label = "main", layers = {} } } }
  end
  function api.new_layer(_, _, l)
    log("layer", l.block.label)
    return { layer_id = "L-" .. l.block.label }
  end
  function api.minimize(_, id)
    log("minimize", id)
  end
  function api.focus_window(_, id)
    log("focus", id)
  end
  function api.new_window(_, label)
    log("window", label)
  end
  function api.new_split(_, anchor, l)
    log("split", anchor, l.block.label)
    return {}
  end
  function api.process(_, b)
    local shell = { foreground = { name = "zsh", pid = 2 }, ancestors = { { pid = 1, name = "login" } } }
    shell.child = { pid = 1, name = "login" }
    if busy[b] then
      return {
        foreground = { name = "node", pid = 9 },
        ancestors = { { pid = 2, name = "zsh" }, { pid = 1, name = "login" } },
        child = { pid = 1, name = "login" },
      }
    end
    return shell
  end
  function api.write(_, b, data)
    log("write", b, data == "\3" and "^C" or data)
    if data == "\3" and not opts.stubborn then
      busy[b] = nil
    end
  end
  function api.sleep()
    log("sleep")
  end
  function api.close_layer(_, id)
    log("close_layer", id)
  end
  function api.close_block(_, id)
    log("close_block", id)
  end
  function api.destroy(sid)
    log("destroy", sid)
  end
  function api.select()
    log("select")
    return true
  end
  function api.sh(script)
    log("sh", script)
    return opts.hook_result or { ok = true }
  end
  return api, calls, sessions
end

local function ws_of(raw)
  local cfg, errs = build({ app = raw })
  if #errs > 0 then
    error(table.concat(errs, "; "))
  end
  return cfg.by_name.app
end

test("is_busy uses the process chain, not names", function()
  local api = fake({ busy = { b1 = true } })
  eq(proc.is_busy(api, "s", "b1"), true)
  eq(proc.is_busy(api, "s", "b2"), false)
  api.process = function()
    return {
      foreground = { name = "sh", pid = 3 },
      ancestors = { { pid = 2, name = "bash" } },
      child = { pid = 2, name = "bash" },
    }
  end
  eq(proc.is_busy(api, "s", "x"), true, "a shell script server on Linux")
end)

test("start creates the session, floats and minimizes servers, runs hooks, switches", function()
  local api, calls = fake()
  local ws = ws_of({
    servers = { { label = "web", cmd = "w" }, { label = "api", cmd = "a", minimized = false } },
    hooks = { before_start = "up", after_start = "ready" },
  })
  local r = lifecycle.start(api, L, ws)
  eq(r.created, true)
  eq(calls, { "sh up", "create app", "layer web", "minimize L-web", "layer api", "sh ready", "select" })
end)

test("focus picks the tab, switch=false stays put", function()
  local windows =
    { { window_id = "w1", label = "main", layers = {} }, { window_id = "w2", label = "logs", layers = {} } }
  local api, calls = fake({ windows = windows })
  lifecycle.start(api, L, ws_of({ focus = "logs", switch = false, tabs = { { name = "main" }, { name = "logs" } } }))
  eq(calls, { "create app", "focus w2" })
end)

test("a failing hook stops start before anything is created", function()
  local api, calls = fake({ hook_result = { ok = false, code = 1, stderr = "docker not running", stdout = "" } })
  local ok, err = pcall(lifecycle.start, api, L, ws_of({ hooks = { before_start = "docker compose up -d" } }))
  eq(ok, false)
  if not tostring(err):find("before_start hook exited 1: docker not running", 1, true) then
    error(err)
  end
  eq(calls, { "sh docker compose up -d" })
end)

test("start on a running workspace retypes idle servers only", function()
  local windows = {
    {
      window_id = "w1",
      label = "main",
      layers = {
        { kind = "floating", layer_id = "L1", blocks = { { block_id = "b1", label = "web" } } },
        { kind = "floating", layer_id = "L2", blocks = { { block_id = "b2", label = "api" } } },
      },
    },
  }
  local api, calls, sessions = fake({ windows = windows, busy = { b1 = true } })
  sessions[1] = { label = "app", session_id = "s1" }
  local r = lifecycle.start(api, L, ws_of({ servers = { { label = "web", cmd = "w" }, { label = "api", cmd = "a" } } }))
  eq(r.created, false)
  eq(calls, { "write b2 a\n", "select" })
end)

test("stop interrupts, waits, closes, and reports stubborn servers", function()
  local windows = {
    {
      window_id = "w1",
      label = "main",
      layers = { { kind = "floating", layer_id = "L1", blocks = { { block_id = "b1", label = "web" } } } },
    },
  }
  local api, calls, sessions = fake({ windows = windows, busy = { b1 = true }, stubborn = true })
  sessions[1] = { label = "app", session_id = "s1" }
  local r = lifecycle.stop(api, ws_of({ stop_timeout = 0.5, servers = { { label = "web", cmd = "w" } } }))
  eq(r.forced, { "web" })
  eq(calls, { "write b1 ^C", "sleep", "sleep", "close_layer L1" })
end)

test("stop on a stopped workspace does nothing", function()
  local api, calls = fake()
  eq(lifecycle.stop(api, ws_of({})).stopped, false)
  eq(#calls, 0)
end)

test("servers in a tab: new window, then splits beside survivors", function()
  local api, calls = fake()
  local ws = ws_of({ servers_in = "tab", servers = { { label = "a", cmd = "x" }, { label = "b", cmd = "y" } } })
  lifecycle.start(api, L, ws, { select = false })
  eq(calls, { "create app" })

  local windows = {
    {
      window_id = "w2",
      label = "servers",
      layers = { { kind = "tiled", blocks = { { block_id = "ba", label = "a" } } } },
    },
  }
  local api2, calls2, sessions2 = fake({ windows = windows, busy = { ba = true } })
  sessions2[1] = { label = "app", session_id = "s1" }
  lifecycle.start(api2, L, ws, { select = false })
  eq(calls2, { "split ba b" })
end)

test("status lists each server", function()
  local windows = {
    {
      window_id = "w1",
      label = "main",
      layers = { { kind = "floating", layer_id = "L1", blocks = { { block_id = "b1", label = "web" } } } },
    },
  }
  local api = fake({ windows = windows, busy = { b1 = true } })
  local ws = ws_of({ servers = { { label = "web", cmd = "w" }, { label = "api", cmd = "a" } } })
  local st = lifecycle.status(api, ws, { { label = "app", session_id = "s1" } })
  eq(st.running, true)
  eq(st.servers_up, 1)
  eq(st.servers[1].up, true)
  eq(st.servers[2].open, false)
end)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
