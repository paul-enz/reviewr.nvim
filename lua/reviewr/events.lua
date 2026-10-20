local log = require("reviewr.log")

local M = {}
local listeners = {}

local function autocmd_name(event)
  return "Reviewr" .. event
end

function M.emit(event, data)
  data = data or {}
  log.debug("emit " .. event)
  vim.api.nvim_exec_autocmds("User", {
    pattern = autocmd_name(event),
    data = data,
  })
  for _, cb in ipairs(listeners[event] or {}) do
    local ok, err = pcall(cb, data)
    if not ok then log.error(err) end
  end
end

function M.on(event, cb)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], cb)
  return function()
    M.off(event, cb)
  end
end

function M.off(event, cb)
  local arr = listeners[event]
  if not arr then return end
  for i = #arr, 1, -1 do
    if arr[i] == cb then table.remove(arr, i) end
  end
end

return M
