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

local capture = require("rex-workspaces.lib.capture")
local config = require("rex-workspaces.lib.config")
local detect = require("rex-workspaces.lib.detect")
local freeze = require("rex-workspaces.lib.freeze")
local json = require("rex-workspaces.lib.json")
local layout = require("rex-workspaces.lib.layout")
local lifecycle = require("rex-workspaces.lib.lifecycle")
local options = require("rex-workspaces.lib.options")
local path = require("rex-workspaces.lib.path")
local proc = require("rex-workspaces.lib.proc")
local snooze = require("rex-workspaces.lib.snooze")
local spec = require("rex-workspaces.lib.spec")
local stop = require("rex-workspaces.lib.stop")
local store = require("rex-workspaces.lib.store")
local worktree = require("rex-workspaces.lib.worktree")

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

test("default names avoid the login name", function()
  eq(spec.default_name("shop", HOME, {}), "shop")
  eq(spec.default_name("u", HOME, {}), "untitled")
  eq(spec.default_name(nil, HOME, {}), "untitled")
  eq(spec.default_name("", HOME, { untitled = {}, ["untitled 2"] = {} }), "untitled 3")
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

test("grid and nested groups", function()
  local cfg, errs = build({
    app = {
      root = "/r",
      tabs = {
        { name = "g", split = "grid", panes = { { label = "a" }, { label = "b" }, { label = "c" }, { label = "d" } } },
        { name = "m", panes = { { label = "main" }, { split = "down", panes = { { label = "x", cwd = "web" } } } } },
      },
    },
  })
  eq(#errs, 0, "errors")
  local tabs = cfg.by_name.app.tabs
  eq(tabs[1].split, "grid")
  eq(tabs[2].panes[2].split, "down")
  eq(tabs[2].panes[2].panes[1].cwd, "/r/web")

  local _, bad = build({
    app = {
      tabs = {
        { panes = { { split = "grid", panes = {} }, { label = "l", panes = { { label = "p" } } } } },
        { panes = { { split = "sideways", panes = { { label = "p" } } }, { split = "down", panes = { {} } } } },
      },
    },
  })
  contains(bad, "app.tabs[1].panes[1].panes: needs at least one pane")
  contains(bad, "app.tabs[1].panes[2]: a group has only split and panes")
  contains(bad, 'app.tabs[2].panes[1].split: must be "right", "down" or "grid"')
  contains(bad, "app.tabs[2].panes[2].panes[1]: label is required")
end)

test("stop settings: defaults, overrides, errors", function()
  local cfg, errs = build({
    app = {
      stop = { panes = "interrupt" },
      servers = { { label = "s", cmd = "x", stop = "leave" } },
      tabs = { { panes = { { label = "p", stop = "close" }, { label = "q" } } } },
    },
  })
  eq(#errs, 0, "errors")
  local ws = cfg.by_name.app
  eq(ws.stop, { servers = "close", panes = "interrupt" })
  eq(ws.servers[1].stop, "leave")
  eq(ws.tabs[1].panes[1].stop, "close")
  eq(spec.stops_panes(ws), true)
  eq(build({ plain = {} }).by_name.plain.stop, { servers = "close", panes = "leave" })
  eq(spec.stops_panes(build({ plain = {} }).by_name.plain), false)

  local _, bad = build({
    app = {
      stop = { servers = "kill", pane = "close" },
      servers = { { label = "s", cmd = "x", stop = "pause" } },
      tabs = { { panes = { { label = "p", stop = 1 }, { stop = "close", panes = { { label = "g" } } } } } },
    },
    other = { stop = "close" },
  })
  contains(bad, 'app.stop.servers: must be "close", "interrupt" or "leave"')
  contains(bad, 'app.stop.pane: unknown key; use "servers" or "panes"')
  contains(bad, "app.servers[1].stop: must be")
  contains(bad, "app.tabs[1].panes[1].stop: must be")
  contains(bad, "app.tabs[1].panes[2]: a group has only split and panes")
  contains(bad, "other.stop: must be an object")
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

test("options: default files include workspaces.*.json, sorted", function()
  local list = function(dir)
    eq(dir, "/c/rex")
    return {
      "workspaces.work.json",
      "init.lua",
      "workspaces.json",
      "workspaces.local.json",
      "workspaces.json.tmp",
      "xworkspaces.json",
    }
  end
  local s = options.resolve(nil, "/c/rex/rex-workspaces", HOME, list)
  eq(s.files, { "/c/rex/workspaces.json", "/c/rex/workspaces.local.json", "/c/rex/workspaces.work.json" })
  eq(s.primary, "/c/rex/workspaces.json")
  local custom = options.resolve({ files = { "~/a.json" } }, "/c/rex/rex-workspaces", HOME, list)
  eq(#custom.files, 1)
end)

test("options: defaults, keys, unknown names", function()
  local s, unknown = options.resolve(nil, "/c/rex/rex-workspaces", HOME)
  eq(s.files, { "/c/rex/workspaces.json" })
  eq(s.state, "/home/u/.local/state/rex-workspaces")
  eq(options.resolve(nil, "/m", HOME, nil, "/xdg").state, "/xdg/rex-workspaces")
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

test("grid rows fill left to right, top to bottom", function()
  eq(layout.grid_rows(1), { 1 })
  eq(layout.grid_rows(3), { 2, 1 })
  eq(layout.grid_rows(4), { 2, 2 })
  eq(layout.grid_rows(5), { 3, 2 })
  eq(layout.grid_rows(9), { 3, 3, 3 })
  local function p(l)
    return { label = l }
  end
  local g = layout.panes(L, { p("a"), p("b"), p("c"), p("d") }, "grid")
  eq(g.v, 0.5)
  eq(g.a.h, 0.5)
  eq({ g.a.a.block.label, g.a.b.block.label, g.b.a.block.label, g.b.b.block.label }, { "a", "b", "c", "d" })
  local main = layout.panes(L, { p("m"), { split = "down", panes = { p("x"), p("y") } } }, "right")
  eq(main.h, 0.5)
  eq(main.b.v, 0.5)
  eq(main.b.b.block.label, "y")
  eq(layout.panes(L, { p("solo") }, "grid").block.label, "solo")
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
  eq(layout.list_rows(0, 0), 10)
  eq(layout.list_rows(2, 3), 17)
  local b = layout.fit(200, 50, 20)
  local edit = layout.fit(200, 50, layout.EDIT_ROWS)
  eq(edit[2] + edit[4] / 2, 0.5, "edit form is centered")
  eq(b[2] + b[4] / 2, 0.5, "list is centered")
  eq(b[1] + b[3] / 2, 0.5, "horizontal center")
  eq(b[4], (20 + layout.UI.chrome_rows) / 50)
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
  function api.realpath(p)
    return (p:gsub("^/r$", "/private/r"))
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

test("command reads a running program's arguments, not an idle shell's", function()
  local api = fake({ busy = { b1 = true } })
  local asked = {}
  api.args = function(pid)
    asked[#asked + 1] = pid
    return pid == 9 and "node server.js" or nil
  end
  eq({ proc.command(api, "s", "b1") }, { "node server.js", true })
  eq({ proc.command(api, "s", "b2") }, { nil, false })
  eq(asked, { 9 }, "idle shells are not looked up")
end)

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

local function stop_windows(extra)
  local windows = {
    {
      window_id = "w1",
      label = "agents",
      layers = {
        {
          kind = "tiled",
          blocks = {
            { block_id = "c1", label = "claude" },
            { block_id = "c2", label = "claude" },
            { block_id = "sh", label = "shell" },
          },
        },
        { kind = "floating", layer_id = "L1", blocks = { { block_id = "s1", label = "web" } } },
      },
    },
  }
  for _, w in ipairs(extra or {}) do
    windows[#windows + 1] = w
  end
  return windows
end

local function stop_ws(raw)
  raw.servers = raw.servers or { { label = "web", cmd = "pnpm dev" } }
  raw.tabs = raw.tabs
    or {
      { name = "agents", panes = { { label = "claude" }, { label = "claude" }, { label = "shell" } } },
    }
  return ws_of(raw)
end

local function stop_session(opts)
  local api, calls, sessions = fake(opts)
  sessions[1] = { label = "app", session_id = "s1" }
  return api, calls
end

test("stop: panes interrupt busy panes only and keep them", function()
  local api, calls = stop_session({ windows = stop_windows(), busy = { s1 = true, c1 = true, c2 = true } })
  local r = lifecycle.stop(api, stop_ws({ stop = { panes = "interrupt" } }))
  eq(calls, { "write s1 ^C", "write c1 ^C", "write c2 ^C", "sleep", "close_layer L1" })
  eq(r.interrupted, { "claude", "claude" })
  eq(r.closed, { "web" })
  eq(r.message, "Stopped app: closed 1 server, interrupted 2 panes.")
end)

test("stop: servers interrupt keeps the pane, overrides win, close closes idle panes", function()
  local api, calls = stop_session({ windows = stop_windows(), busy = { s1 = true, c1 = true } })
  local ws = stop_ws({
    stop = { servers = "interrupt", panes = "close" },
    tabs = {
      { name = "agents", panes = { { label = "claude", stop = "leave" }, { label = "claude" }, { label = "shell" } } },
    },
  })
  local r = lifecycle.stop(api, ws)
  eq(calls, { "write s1 ^C", "sleep", "close_block c2", "close_block sh" })
  eq(r.message, "Stopped app: interrupted 1 server, closed 2 panes.")
end)

test("stop: servers leave does nothing to them", function()
  local api, calls = stop_session({ windows = stop_windows(), busy = { s1 = true } })
  local r = lifecycle.stop(api, stop_ws({ stop = { servers = "leave" } }))
  eq(#calls, 0)
  eq(r.message, "Nothing to stop in app.")
end)

test("stop: closing never empties the session", function()
  local only = {
    {
      window_id = "w1",
      label = "agents",
      layers = {
        { kind = "tiled", blocks = { { block_id = "c1", label = "claude" }, { block_id = "c2", label = "claude" } } },
      },
    },
  }
  local api, calls = stop_session({ windows = only, busy = { c1 = true, c2 = true } })
  local ws = stop_ws({
    servers = {},
    stop = { panes = "close" },
    tabs = { { name = "agents", panes = { { label = "claude" }, { label = "claude" } } } },
  })
  local r = lifecycle.stop(api, ws)
  eq(calls, { "write c1 ^C", "write c2 ^C", "sleep", "close_block c2" })
  eq(r.kept, { "claude" })
  if not r.message:find("Kept claude open so the session is not left empty.", 1, true) then
    error(r.message)
  end
end)

test("stop: a window that holds floating servers keeps one tiled pane", function()
  local logs = {
    window_id = "w2",
    label = "logs",
    layers = { { kind = "tiled", blocks = { { block_id = "t1", label = "tail" } } } },
  }
  local api = stop_session({ windows = stop_windows({ logs }) })
  local ws = stop_ws({
    stop = { servers = "leave", panes = "close" },
    tabs = {
      { name = "agents", panes = { { label = "claude" }, { label = "claude" }, { label = "shell" } } },
      { name = "logs", panes = { { label = "tail", stop = "leave" } } },
    },
  })
  local targets, kept = stop.plan(api, "s1", ws, { panes = true })
  eq(kept, { "claude" })
  eq(#targets, 3)
  eq(targets[1].how, "interrupt")
end)

test("stop: forced timeouts are reported", function()
  local api = stop_session({ windows = stop_windows(), busy = { s1 = true, c1 = true }, stubborn = true })
  local r = lifecycle.stop(api, stop_ws({ stop_timeout = 0.25, stop = { panes = "interrupt" } }))
  eq(r.forced, { "claude", "web" })
  eq(
    r.message,
    "Stopped app: closed 1 server, interrupted 1 pane. Closed after 0.25s without stopping: web."
      .. " Still running after 0.25s: claude."
  )
end)

test("restart touches servers only", function()
  local api, calls = stop_session({ windows = stop_windows(), busy = { c1 = true, s1 = true } })
  lifecycle.restart(api, L, stop_ws({ stop = { panes = "close" } }), { select = false })
  eq(calls, { "write s1 ^C", "sleep", "close_layer L1", "write s1 pnpm dev\n" }, "c1 is never touched")
end)

local function leaf(id, x, y, w, h)
  return { block_id = id, rect = { x, y, w, h } }
end

local function split(dir, before, after)
  return { split = { direction = dir, before = before, after = after, ratio = 0.5 } }
end

local function labels(node)
  if node.panes == nil then
    return node.label
  end
  local out = {}
  for i, n in ipairs(node.panes) do
    out[i] = labels(n)
  end
  return { split = node.split, panes = out }
end

local function by_label(id)
  return { label = id }
end

test("capture reads splits back as panes, grids and groups", function()
  local grid = split("vertical", split("horizontal", leaf("a"), leaf("b")), split("horizontal", leaf("c"), leaf("d")))
  eq(labels(capture.grids(capture.tree(grid, by_label))), { split = "grid", panes = { "a", "b", "c", "d" } })
  local flat = split("horizontal", leaf("x"), split("horizontal", leaf("y"), leaf("z")))
  eq(labels(capture.grids(capture.tree(flat, by_label))), { split = "right", panes = { "x", "y", "z" } })
  local main = split("horizontal", leaf("m"), split("vertical", leaf("s1"), leaf("s2")))
  eq(
    labels(capture.grids(capture.tree(main, by_label))),
    { split = "right", panes = { "m", { split = "down", panes = { "s1", "s2" } } } }
  )
  local nine = split(
    "vertical",
    split("horizontal", leaf("1"), split("horizontal", leaf("2"), leaf("3"))),
    split(
      "vertical",
      split("horizontal", leaf("4"), split("horizontal", leaf("5"), leaf("6"))),
      split("horizontal", leaf("7"), split("horizontal", leaf("8"), leaf("9")))
    )
  )
  eq(#capture.grids(capture.tree(nine, by_label)).panes, 9)
  eq(capture.grids(capture.tree(nine, by_label)).split, "grid")
  local uneven = split("vertical", split("horizontal", leaf("a"), leaf("b")), leaf("c"))
  eq(capture.grids(capture.tree(uneven, by_label)).split, "grid", "2 over 1 is the 3-pane grid")
  local stacked = split("vertical", leaf("a"), leaf("b"))
  eq(capture.grids(capture.tree(stacked, by_label)).split, "down")
  local skipped = capture.tree(split("horizontal", leaf("a"), leaf("gone")), function(id)
    return id ~= "gone" and { label = id } or nil
  end)
  eq(skipped, { label = "a" })
end)

test("capture a session: tabs, folders, servers from its workspace, notes", function()
  local windows = {
    {
      window_id = "w1",
      label = "code",
      layers = {
        {
          kind = "tiled",
          blocks = { { block_id = "b1", label = "api" }, { block_id = "b2", label = "logs" } },
          layout = split("horizontal", leaf("b1"), leaf("b2")),
        },
        { kind = "floating", layer_id = "L1", blocks = { { block_id = "s1", label = "web" } } },
        {
          kind = "floating",
          layer_id = "L2",
          state = "minimized",
          bounds = { 0.5, 0.1, 0.4, 0.3 },
          blocks = { { block_id = "s2", label = "web" } },
        },
        { kind = "floating", layer_id = "L3", blocks = { { block_id = "u", label = "Workspaces" } } },
        { kind = "floating", layer_id = "L4", blocks = { { block_id = "s3", label = "idle" } } },
        { kind = "floating", layer_id = "L5", blocks = { { block_id = "s4", label = "top" } } },
      },
    },
    {
      window_id = "w2",
      label = "grid",
      layers = {
        {
          kind = "tiled",
          blocks = {
            { block_id = "g1", label = "a" },
            { block_id = "g2", label = "b" },
            { block_id = "g3", label = "c" },
            { block_id = "g4" },
          },
          layout = split(
            "vertical",
            split("horizontal", leaf("g1"), leaf("g2")),
            split("horizontal", leaf("g3"), leaf("g4"))
          ),
        },
      },
    },
  }
  local api = fake({ windows = windows, busy = { b2 = true } })
  api.view = function()
    return { label = "proj", active_window_id = "w2", windows = windows }
  end
  local cwds = { b1 = "/private/r/api", b2 = "/r", g1 = "/elsewhere", g2 = "/home/u/x" }
  api.pwd = function(_, b)
    return cwds[b]
  end
  local pids = { b2 = 9, g3 = 8, s2 = 7, s4 = 6 }
  local args = { [9] = "node server.js --port 3000", [7] = "tail -f log", [6] = "htop" }
  api.args = function(pid)
    return args[pid]
  end
  api.process = function(_, b)
    if pids[b] then
      return {
        foreground = { name = "node", pid = pids[b], cwd = "/r" },
        ancestors = { { pid = 2, name = "zsh", cwd = "/r" }, { pid = 1, name = "login" } },
        child = { pid = 1, name = "login" },
      }
    end
    return {
      foreground = { name = "zsh", pid = 2, cwd = "/r/sub" },
      ancestors = { { pid = 1, name = "login" } },
      child = { pid = 1, name = "login" },
    }
  end

  local ws = ws_of({ root = "/r", servers = { { label = "web", cmd = "pnpm dev" } } })
  local d = capture.session(api, "s1", {
    home = HOME,
    root = "/r",
    ws = ws,
    raw = { servers = { { label = "web", cmd = "pnpm dev", cwd = "web" } } },
    skip = { Workspaces = true },
    taken = { proj = {} },
  })
  eq(d.name, "proj")
  eq(d.spec.root, "/r")
  eq(d.spec.focus, "grid")
  eq(d.spec.servers, {
    { label = "web", cmd = "pnpm dev", cwd = "web" },
    { label = "web 2", cmd = "tail -f log", bounds = { 0.5, 0.1, 0.4, 0.3 } },
    { label = "top", cmd = "htop", minimized = false },
  })
  eq(d.spec.tabs[1], {
    name = "code",
    split = "right",
    panes = { { label = "api", cwd = "api" }, { label = "logs", cmd = "node server.js --port 3000" } },
  })
  eq(d.spec.tabs[2].split, "grid")
  eq(d.spec.tabs[2].panes[1].cwd, "/elsewhere")
  eq(d.spec.tabs[2].panes[2].cwd, "~/x")
  eq(d.spec.tabs[2].panes[2].cwd, "~/x")
  eq(d.spec.tabs[2].panes[3].cmd, nil, "ps could not read it")
  eq(d.spec.tabs[2].panes[4].cwd, "sub", "falls back to the shell's own folder")
  eq(d.spec.tabs[2].panes[4].label, "shell")
  contains(d.notes, "Running commands were saved. They run again when the workspace starts.")
  contains(d.notes, "1 pane runs a command that could not be read")
  contains(d.notes, "no running command: idle.")
  contains(d.notes, 'A workspace named "proj" exists')
  eq(d.blocks, { "b1", "b2", "g1", "g2", "g3", "g4" }, "one block per pane, in pane order")
  local cfg, errs = build({ copy = d.spec })
  eq(#errs, 0, "captured spec is valid")
  eq(cfg.by_name.copy.tabs[2].split, "grid")
end)

test("capture live prefers what runs now and keeps pane stop", function()
  local windows = {
    {
      window_id = "w1",
      label = "main",
      layers = {
        {
          kind = "tiled",
          blocks = { { block_id = "b1", label = "agent" }, { block_id = "b2", label = "tests" } },
          layout = split("horizontal", leaf("b1"), leaf("b2")),
        },
      },
    },
  }
  local api = fake({ windows = windows })
  api.view = function()
    return { label = "app", active_window_id = "w1", windows = windows }
  end
  api.pwd = function()
    return "/r"
  end
  api.args = function()
    return "opencode"
  end
  api.process = function(_, b)
    local fg = b == "b1" and { name = "opencode", pid = 9 } or { name = "zsh", pid = 2 }
    return { foreground = fg, ancestors = { { pid = 2, name = "zsh" } }, child = { pid = 2, name = "zsh" } }
  end
  local ws = ws_of({
    root = "/r",
    tabs = {
      {
        name = "main",
        panes = { { label = "agent", cmd = "vim", stop = "leave" }, { label = "tests", cmd = "make test" } },
      },
    },
  })
  local opts = { home = HOME, root = "/r", ws = ws }
  local saved = capture.session(api, "s1", opts).spec.tabs[1].panes
  eq(saved[1], { label = "agent", cmd = "vim", stop = "leave" })
  opts.live = true
  local live = capture.session(api, "s1", opts).spec.tabs[1].panes
  eq(live[1], { label = "agent", cmd = "opencode", stop = "leave" })
  eq(live[2], { label = "tests", cmd = "make test" }, "falls back to the workspace's command")
end)

test("freeze walks each pane's tree, parents first, own processes only", function()
  local procs = freeze.parse_ps(table.concat({
    "    1     0     0 Ss",
    "  100     1     0 Ss",
    "  101   100   501 S",
    "  102   101   501 S+",
    "  103   102   501 S+",
    "  104   101   501 S",
    "  200     1   501 Ss",
    "  201   200   501 R+",
    "  300   101     0 S",
    "garbage",
  }, "\n"))
  eq(#procs, 9)
  eq(procs[3], { pid = 101, ppid = 100, uid = 501, stat = "S" })
  eq(freeze.order({ 100, 200 }, procs, 501), { 101, 102, 104, 103, 200, 201 })
  eq(freeze.order({ 100, 101 }, procs, 501), { 101, 102, 104, 103 }, "each process once")
  eq(freeze.order({ 999 }, procs, 501), {})
end)

local function state_api(files)
  local signals = {}
  return {
    read = function(f)
      return files[f]
    end,
    exists = function(f)
      return files[f] ~= nil
    end,
    decode = function(text)
      return load("return " .. text)()
    end,
    write_file = function(f, text)
      files[f] = text
    end,
    remove = function(f)
      files[f] = nil
    end,
    mkdir = function() end,
    signal = function(sig, pids)
      signals[#signals + 1] = sig .. " " .. table.concat(pids, ",")
    end,
    ps = function(pids)
      return pids and (pids[1] .. " 1 501 T") or ""
    end,
  },
    signals
end

test("thaw wakes children before their shell, only for the same session", function()
  local files = { ["/st/frozen/app.json"] = '{ session_id = "s1", pids = { 101, 102, 103 } }' }
  local api, signals = state_api(files)
  local ws = { slug = "app" }
  eq(freeze.is_frozen(api, "/st", ws, "s1"), true)
  eq(freeze.is_frozen(api, "/st", ws, "s2"), false, "another session")
  eq(freeze.is_frozen(api, "/st", ws, nil), false, "not open")
  eq(freeze.thaw(api, "/st", ws, "s1"), true)
  eq(signals, { "CONT 103,102,101" })
  eq(files["/st/frozen/app.json"], nil, "forgets the freeze")
  files["/st/frozen/app.json"] = '{ session_id = "old", pids = { 5 } }'
  eq(freeze.thaw(api, "/st", ws, "s1"), false)
  eq(#signals, 1, "a stale freeze sends nothing")
  eq(files["/st/frozen/app.json"], nil, "and is dropped")
end)

test("snooze resumes agents where they left off", function()
  eq(snooze.resume_cmd("opencode"), "opencode --continue")
  eq(snooze.resume_cmd("/Users/me/.opencode/bin/opencode"), "/Users/me/.opencode/bin/opencode --continue")
  eq(snooze.resume_cmd("claude"), "claude --continue")
  eq(snooze.resume_cmd("claude --model opus"), "claude --continue --model opus")
  eq(snooze.resume_cmd("codex"), "codex resume --last")
  eq(snooze.resume_cmd("codex resume --last"), "codex resume --last", "already resuming")
  eq(snooze.resume_cmd("claude --continue"), "claude --continue")
  eq(snooze.resume_cmd("claude -r abc"), "claude -r abc")
  eq(snooze.resume_cmd("opencode run fix it"), "opencode run fix it", "a subcommand is left alone")
  eq(snooze.resume_cmd("npm run dev"), "npm run dev")
  eq(snooze.resume_cmd(nil), nil)
end)

test("snooze resumes each agent's own conversation", function()
  eq(snooze.resume_cmd("claude --model opus", "abc-1"), "claude --resume abc-1 --model opus")
  eq(snooze.resume_cmd("codex", "019f-2"), "codex resume 019f-2")
  eq(snooze.resume_cmd("opencode", "ses_3"), "opencode --session ses_3")
  eq(snooze.resume_cmd("npm run dev", "x"), "npm run dev")

  local running, writes = { b1 = true, b2 = true, b3 = true }, {}
  local api = {
    process = function(_, b)
      local pids = { b1 = 101, b2 = 102, b3 = 103 }
      return {
        foreground = running[b] and { pid = pids[b], name = "agent" } or { pid = 1, name = "zsh" },
        child = { pid = 1, name = "zsh" },
        ancestors = { { pid = 1, name = "zsh" } },
      }
    end,
    write = function(_, b, data)
      writes[#writes + 1] = b .. data
      if b == "b2" then
        running[b] = false
      end
    end,
    sleep = function() end,
    read = function(f)
      return f == "/c/sessions/101.json" and '{"pid":101,"sessionId":"aaaa-1111","cwd":"/r"}' or nil
    end,
    text = function(_, b)
      return b == "b2" and "To reconnect, run:\n  codex resume 019f-old\n  codex resume 019f-new\n" or ""
    end,
  }
  eq(snooze.conversation(api, "s", "b1", "claude", "/c"), "aaaa-1111")
  eq(#writes, 0, "claude is read from its session file, not quit")
  eq(snooze.conversation(api, "s", "b2", "codex", "/c"), "019f-new")
  eq(writes, { "b2\3" })
  eq(snooze.conversation(api, "s", "b3", "opencode", "/c"), nil, "nothing printed falls back")
  eq(#writes, 4, "gives up after three Ctrl-C")
  eq(snooze.conversation(api, "s", "b3", "claude --resume x", "/c"), nil, "already resuming")
end)

test("snooze saves idle shells' screens and resumes with the workspace's hooks", function()
  local api = {
    screen = function(_, b)
      return "screen of " .. b
    end,
  }
  local d = {
    blocks = { "b1", "b2", "b3" },
    spec = {
      root = "/r",
      servers = { { label = "web", cmd = "pnpm dev" } },
      tabs = {
        { name = "code", split = "right", panes = { { label = "sh" }, { label = "agent", cmd = "claude" } } },
        { name = "logs", panes = { { label = "tail", cwd = "" } } },
      },
    },
  }
  local snap = snooze.snapshot(api, "s1", d)
  eq(snap.screens, { ["1"] = "screen of b1", ["3"] = "screen of b3" })
  eq(snap.spec.tabs[1].panes[2].cmd, "claude --continue")
  eq(snap.spec.tabs[2].panes[1], { label = "tail" }, "empty values pruned")
  local raw = {
    root = "/r",
    focus = "main",
    hooks = { before_start = "echo hi" },
    servers = { { label = "web", cmd = "pnpm dev" }, { label = "db", cmd = "pg" } },
    tabs = { { name = "main" } },
  }
  local ws = snooze.workspace(raw, snap, "app", HOME)
  eq(ws.hooks.before_start, "echo hi")
  eq(ws.focus, nil)
  eq(#ws.servers, 1, "servers that were stopped stay stopped")
  eq(ws.tabs[1].name, "code")
  local files = {}
  local fs = state_api(files)
  snooze.place_screens(fs, "/st", ws, snap)
  eq(ws.tabs[1].panes[1].replay, "/st/screens/app-1.vt")
  eq(ws.tabs[1].panes[2].replay, nil)
  eq(files["/st/screens/app-3.vt"], "screen of b3")
  local block = layout.block(L, ws.tabs[1].panes[1]).block
  eq(block.options.shell, "none")
  eq(block.options.command, { "/bin/sh", "-c", layout.REPLAY, "sh", "/st/screens/app-1.vt" })
end)

test("capture without a workspace roots at the first pane", function()
  local windows = {
    {
      window_id = "w1",
      label = "main",
      layers = { { kind = "tiled", blocks = { { block_id = "b1", label = "sh" } }, layout = leaf("b1") } },
    },
  }
  local api = fake({ windows = windows })
  api.view = function()
    return { active_window_id = "w1", windows = windows }
  end
  api.pwd = function()
    return "/home/u/proj"
  end
  local d = capture.session(api, "s1", { home = HOME, label = "proj" })
  eq(d.name, "proj")
  eq(capture.session(api, "s1", { home = HOME, label = "u" }).name, "untitled", "login name")
  eq(capture.session(api, "s1", { home = HOME, label = "", taken = { untitled = {} } }).name, "untitled 2")
  eq(d.spec.root, "~/proj")
  eq(d.spec.tabs, { { name = "main", panes = { { label = "sh" } } } })
  eq(#d.notes, 0)
end)

local PORCELAIN = table.concat({
  "/repo",
  "web/",
  "worktree /repo",
  "HEAD abc",
  "branch refs/heads/main",
  "",
  "worktree /repo.feat",
  "HEAD abc",
  "branch refs/heads/feat/x",
  "",
  "worktree /repo.det",
  "HEAD abc",
  "detached",
  "",
  "worktree /gone",
  "HEAD abc",
  "branch refs/heads/old",
  "prunable gitdir file points to non-existent location",
  "",
}, "\n")

test("worktree parse keeps the subfolder, labels by branch or folder, skips prunable", function()
  local list = worktree.parse(PORCELAIN)
  eq(#list, 3)
  eq(list[1], { label = "main", branch = "main", path = "/repo", root = "/repo/web", current = true })
  eq(list[2].label, "feat/x")
  eq(list[2].root, "/repo.feat/web")
  eq(list[3].label, "repo.det")
  eq(list[3].branch, nil)
  eq(worktree.parse(nil), {})
  eq(worktree.parse("/repo\n\nworktree /repo\nbranch refs/heads/main\n")[1].root, "/repo")
end)

local function two_repos(picks)
  local raw = {
    root = "/home/u/proj",
    servers = {
      { label = "api", cwd = "/repo/web", cmd = "make", worktree = picks.api },
      { label = "web", cwd = "/other", cmd = "npm", worktree = picks.web },
      { label = "db", cmd = "docker" },
    },
    tabs = { { name = "main", panes = { { label = "sh", cwd = "/repo/web", worktree = picks.sh } } } },
  }
  local ws = build({ app = raw }).by_name.app
  local api = fake()
  api.worktrees = function(dir)
    if dir == "/other" then
      return "/other\n\nworktree /other\nbranch refs/heads/main\n\nworktree /other.fix\nbranch refs/heads/fix-y\n"
    end
    return PORCELAIN
  end
  return ws, api
end

test("worktree is set per server and pane", function()
  local _, errs = build({ app = { tabs = { { panes = { { split = "down", worktree = "x", panes = {} } } } } } })
  contains(errs, "put label, cwd, cmd, stop and worktree on its panes")
  local _, bad = build({ app = { servers = { { label = "a", cmd = "x", worktree = true } } } })
  contains(bad, "app.servers[1].worktree: must be a string")
  eq(build({ app = { servers = { { label = "a", cmd = "x", worktree = "" } } } }).by_name.app.servers[1].worktree, nil)
end)

test("each item starts in the worktree it names, in its own repository", function()
  local ws, api = two_repos({ api = "feat/x", web = "/other.fix", sh = "repo.det" })
  local placed = worktree.apply(api, ws, HOME)
  eq(placed.servers[1].cwd, "/repo.feat/web", "keeps the subfolder")
  eq(placed.servers[2].cwd, "/other.fix", "another repository, named by path")
  eq(placed.servers[3].cwd, "/home/u/proj", "items without a worktree stay")
  eq(placed.tabs[1].panes[1].cwd, "/repo.det/web", "named by folder")
  eq(ws.servers[1].cwd, "/repo/web", "the workspace is not changed")

  local plain, never = two_repos({})
  never.worktrees = function()
    error("git should not run")
  end
  eq(worktree.apply(never, plain, HOME), plain)

  local function fails(picks, branches)
    local bad, api2 = two_repos(picks)
    api2.has_branch = function(_, b)
      return branches[b] == true
    end
    local ok, err = pcall(worktree.apply, api2, bad, HOME)
    eq(ok, false)
    return err
  end
  eq(fails({ web = "feat/x" }, {}), 'no worktree "feat/x" for web in app')
  eq(
    fails({ web = "feat/x" }, { ["feat/x"] = true }),
    'web in app: branch "feat/x" has no worktree. Create one with: '
      .. "git -C '/other' worktree add '/other.feat-x' 'feat/x'"
  )
end)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
