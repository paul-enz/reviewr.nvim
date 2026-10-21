local log = require("reviewr.log")

local M = {}
local current = nil

local function normalize(scope)
  if type(scope) == "string" then scope = { name = scope } end
  scope = scope or {}
  if not scope.repo then scope.repo = nil end
  if not scope.name and scope.ref then scope.name = scope.ref end
  return scope
end

function M.set(scope)
  current = normalize(scope)
  log.info("scope set: " .. vim.inspect(current))
  return current
end

function M.get()
  return current
end

function M.clear()
  current = nil
end

function M.repo()
  if current then return current.repo end
  return nil
end

return M
