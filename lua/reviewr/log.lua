local config = require("reviewr.config")

local M = {}
local function level_ok(level)
  return config.level_value(level) >= config.level_value(config.get().log_level)
end

local function file_path()
  local c = config.get()
  if c.log_file then return c.log_file end
  if not c.debug then return nil end
  return vim.fn.stdpath("log") .. "/" .. (c.name or "reviewr") .. ".log"
end

local function write(level, msg)
  if not level_ok(level) then return end
  msg = string.format("[%s][%s] %s", os.date("%Y-%m-%dT%H:%M:%S"), level:upper(), tostring(msg))
  local fp = file_path()
  if fp then
    local f = io.open(fp, "a")
    if f then f:write(msg .. "\n"); f:close() end
  end
  if level == "error" or level == "warn" then
    vim.notify(msg, level == "error" and vim.log.levels.ERROR or vim.log.levels.WARN)
  elseif config.get().debug then
    vim.notify(msg, vim.log.levels.INFO)
  end
end

function M.debug(m) write("debug", m) end
function M.info(m) write("info", m) end
function M.warn(m) write("warn", m) end
function M.error(m) write("error", m) end

return M
