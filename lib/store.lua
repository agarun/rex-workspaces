local config = require("rex-workspaces.lib.config")
local json = require("rex-workspaces.lib.json")
local spec = require("rex-workspaces.lib.spec")

local M = {}

local function is_array(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n > 0 and n == #t
end

local function prune(v)
  if v == "" then
    return nil
  end
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  if is_array(v) then
    for _, x in ipairs(v) do
      out[#out + 1] = prune(x)
    end
  else
    for k, x in pairs(v) do
      out[k] = prune(x)
    end
  end
  if next(out) == nil then
    return nil
  end
  return out
end

M.prune = prune

local function read_doc(store, file)
  local text = store.read(file)
  if text == nil or not text:match("%S") then
    return { workspaces = {} }
  end
  local doc, err = store.decode(text)
  if type(doc) ~= "table" then
    error(file .. ": " .. tostring(err), 0)
  end
  doc.workspaces = doc.workspaces or {}
  return doc
end

local function load(store)
  return config.load(store.paths, store.read, store.decode, store.home)
end

local function check_name(cfg, name, previous)
  local renaming = previous ~= nil and previous ~= name
  if (previous == nil or renaming) and cfg.raw[name] ~= nil then
    error('a workspace named "' .. name .. '" already exists', 0)
  end
  local slug = spec.slug(name)
  for _, ws in ipairs(cfg.list) do
    if ws.name ~= name and ws.name ~= previous and ws.slug == slug then
      error('"' .. name .. '" clashes with "' .. ws.name .. '"', 0)
    end
  end
end

function M.save(store, name, raw, previous)
  local cleaned = prune(raw) or {}
  local _, errs = spec.normalize(name, cleaned, store.home)
  if #errs > 0 then
    error(table.concat(errs, "\n"), 0)
  end
  local cfg = load(store)
  check_name(cfg, name, previous)
  local file = cfg.origin[previous or name] or store.primary
  local doc = read_doc(store, file)
  if previous ~= nil then
    doc.workspaces[previous] = nil
  end
  doc.workspaces[name] = cleaned
  store.write(file, json.encode(doc))
  return { name = name, file = file }
end

function M.remove(store, name)
  local file = load(store).origin[name]
  if file == nil then
    error('no workspace named "' .. tostring(name) .. '"', 0)
  end
  local doc = read_doc(store, file)
  doc.workspaces[name] = nil
  store.write(file, json.encode(doc))
  return { name = name, file = file }
end

return M
