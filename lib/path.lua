local M = {}

function M.expand(path, home)
  if type(path) ~= "string" then
    return path
  end
  if path == "~" then
    return home
  end
  return (path:gsub("^~/", home .. "/"))
end

function M.contract(path, home)
  if type(path) ~= "string" or home == "" then
    return path
  end
  if path == home then
    return "~"
  end
  local prefix = home .. "/"
  if path:sub(1, #prefix) == prefix then
    return "~/" .. path:sub(#prefix + 1)
  end
  return path
end

function M.join(dir, path)
  if path == nil or path == "" or path == "." then
    return dir
  end
  if path:sub(1, 1) == "/" or dir == nil then
    return path
  end
  return (dir:gsub("/+$", "")) .. "/" .. path
end

function M.relative(path, root)
  if path == root then
    return ""
  end
  local prefix = (root:gsub("/+$", "")) .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

function M.dirname(path)
  return (path:gsub("/[^/]*$", ""))
end

function M.basename(path)
  return path:match("([^/]+)/*$")
end

function M.shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

return M
