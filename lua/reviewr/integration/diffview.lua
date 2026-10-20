-- reviewr.integration.diffview — optional adapter stub respecting availability
local M = {}

function M.available()
  local ok = pcall(require, "diffview")
  return ok
end

function M.setup(opts)
  if not M.available() then
    return false, "diffview.nvim not available"
  end
  -- stub: wire adapter hooks without forcing dependency
  M._opts = opts or {}
  return true
end

function M.open(left, right, opts)
  if not M.available() then
    return false, "diffview.nvim not available"
  end
  -- stub implementation: fall back to reviewr ui diff
  local ok, ui = pcall(require, "reviewr.ui")
  if ok then return ui.open_diff(left, right, opts) end
  return false, "ui module unavailable"
end

function M.close()
  if not M.available() then return false, "diffview.nvim not available" end
  local ok, ui = pcall(require, "reviewr.ui")
  if ok then ui.close_diff() end
  return true
end

M.is_available = M.available
return M
