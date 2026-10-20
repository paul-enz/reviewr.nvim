local M = {}

local sessions = {}

local function key(tabpage)
  return tabpage or vim.api.nvim_get_current_tabpage()
end

function M.create(tabpage, data)
  tabpage = key(tabpage)
  sessions[tabpage] = vim.tbl_extend("force", {
    tabpage = tabpage,
    scope = nil,
    buffers = {},
    comments_loaded = false,
  }, data or {})
  return sessions[tabpage]
end

function M.get(tabpage)
  return sessions[key(tabpage)]
end

function M.ensure(tabpage)
  tabpage = key(tabpage)
  if not sessions[tabpage] then M.create(tabpage) end
  return sessions[tabpage]
end

function M.update(tabpage, patch)
  local s = M.ensure(tabpage)
  for k, v in pairs(patch or {}) do s[k] = v end
  return s
end

function M.remove(tabpage)
  sessions[key(tabpage)] = nil
end

function M.all()
  return sessions
end

function M.clear()
  sessions = {}
end

return M
