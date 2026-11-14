local M = {}

local ORDER = {
  "$schema",
  "workspaces",
  "root",
  "key",
  "focus",
  "switch",
  "servers_in",
  "stop_timeout",
  "servers",
  "tabs",
  "hooks",
  "name",
  "split",
  "label",
  "cwd",
  "cmd",
  "minimized",
  "bounds",
  "panes",
  "before_start",
  "after_start",
  "before_stop",
  "after_stop",
}

local RANK = {}
for i, key in ipairs(ORDER) do
  RANK[key] = i
end

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function quote(s)
  local escaped = s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. escaped .. '"'
end

local function is_array(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n > 0 and n == #t
end

local function by_rank(a, b)
  local ra, rb = RANK[a] or math.huge, RANK[b] or math.huge
  if ra ~= rb then
    return ra < rb
  end
  return tostring(a) < tostring(b)
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, by_rank)
  return keys
end

local function all_scalar(list)
  for _, v in ipairs(list) do
    if type(v) == "table" then
      return false
    end
  end
  return true
end

local encode

local function encode_array(list, indent)
  local inner = indent .. "  "
  local parts = {}
  for i, v in ipairs(list) do
    parts[i] = encode(v, inner)
  end
  if all_scalar(list) then
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  return "[\n" .. inner .. table.concat(parts, ",\n" .. inner) .. "\n" .. indent .. "]"
end

local function encode_object(t, indent)
  local inner = indent .. "  "
  local parts = {}
  for _, k in ipairs(sorted_keys(t)) do
    parts[#parts + 1] = quote(tostring(k)) .. ": " .. encode(t[k], inner)
  end
  if #parts == 0 then
    return "{}"
  end
  return "{\n" .. inner .. table.concat(parts, ",\n" .. inner) .. "\n" .. indent .. "}"
end

encode = function(v, indent)
  local kind = type(v)
  if kind == "string" then
    return quote(v)
  elseif kind == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format("%d", v)
    end
    return tostring(v)
  elseif kind == "boolean" then
    return tostring(v)
  elseif kind == "nil" then
    return "null"
  elseif kind == "table" then
    if is_array(v) then
      return encode_array(v, indent)
    end
    return encode_object(v, indent)
  end
  error("cannot encode a " .. kind, 0)
end

function M.encode(v)
  return encode(v, "") .. "\n"
end

return M
