local json = require("rex-workspaces.lib.json")
local path = require("rex-workspaces.lib.path")

local M = {}

function M.file(dir, kind, ws)
  return dir .. "/" .. kind .. "/" .. ws.slug .. ".json"
end

function M.read(api, file)
  local text = api.read(file)
  if text == nil or not text:match("%S") then
    return nil
  end
  local value = api.decode(text)
  return type(value) == "table" and value or nil
end

function M.write(api, file, value)
  api.mkdir(path.dirname(file))
  api.write_file(file, json.encode(value))
end

return M
