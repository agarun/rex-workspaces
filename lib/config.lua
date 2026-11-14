local spec = require("rex-workspaces.lib.spec")

local M = {}

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function collect(sources, errs)
  local raw, origin = {}, {}
  for _, source in ipairs(sources) do
    local found = type(source.doc) == "table" and source.doc.workspaces or nil
    if type(found) ~= "table" then
      errs[#errs + 1] = source.path .. ': needs a top-level "workspaces" object'
      found = {}
    end
    for name, ws in pairs(found) do
      raw[name] = ws
      origin[name] = source.path
    end
  end
  return raw, origin
end

function M.build(sources, home)
  local errs = {}
  local raw, origin = collect(sources, errs)
  local cfg = { list = {}, by_name = {}, raw = raw, origin = origin }
  local by_slug = {}
  for _, name in ipairs(sorted_keys(raw)) do
    local ws, problems = spec.normalize(name, raw[name], home)
    for _, e in ipairs(problems) do
      errs[#errs + 1] = e
    end
    if ws and by_slug[ws.slug] then
      errs[#errs + 1] = name .. ': clashes with "' .. by_slug[ws.slug].name .. '" (same action name)'
    elseif ws then
      cfg.list[#cfg.list + 1] = ws
      cfg.by_name[name] = ws
      by_slug[ws.slug] = ws
    end
  end
  return cfg, errs
end

function M.read(paths, read, decode)
  local sources, errs = {}, {}
  for _, path in ipairs(paths) do
    local text = read(path)
    if text ~= nil and text:match("%S") then
      local doc, err = decode(text)
      if doc == nil then
        errs[#errs + 1] = path .. ": " .. tostring(err)
      else
        sources[#sources + 1] = { path = path, doc = doc }
      end
    end
  end
  return sources, errs
end

function M.load(paths, read, decode, home)
  local sources, errs = M.read(paths, read, decode)
  local cfg, problems = M.build(sources, home)
  for _, e in ipairs(problems) do
    errs[#errs + 1] = e
  end
  return cfg, errs
end

return M
