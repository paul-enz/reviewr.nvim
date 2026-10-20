-- reviewr.keymaps — buffer-local defaults, remappable
local M = {}

M.defaults = {
  comment = "gc",
  reply   = "gr",
  resolve = "gx",
  export  = "ge",
  panel   = "gp",
  next    = "]c",
  prev    = "[c",
  diff    = "gd",
}

local function bind(bufnr, lhs, rhs, opts)
  opts = vim.tbl_extend("force", { buffer = bufnr, silent = true, noremap = true }, opts or {})
  vim.keymap.set(opts.mode or "n", lhs, rhs, opts)
end

function M.apply(bufnr, overrides)
  bufnr = bufnr or 0
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local keys = vim.tbl_extend("force", M.defaults, overrides or {})
  local ui = require("reviewr.ui")
  local exp = require("reviewr.export")
  local bindings = {
    { keys.comment, function() vim.notify("reviewr: add comment", vim.log.levels.INFO) end },
    { keys.reply,   function() vim.notify("reviewr: reply", vim.log.levels.INFO) end },
    { keys.resolve, function() vim.notify("reviewr: resolve", vim.log.levels.INFO) end },
    { keys.export, function()
      local store = require("reviewr.store")
      local scope = require("reviewr.scope")
      local s = scope.get() or {}
      local comments = store.list({ repo = s.repo, scope = s.name })
      local ok, res = exp.export_all(comments, { clipboard = true })
      vim.notify(ok and ("reviewr: exported " .. tostring(res or #comments)) or ("reviewr: " .. tostring(res)), ok and vim.log.levels.INFO or vim.log.levels.WARN)
    end },
    { keys.panel,   function() ui.toggle_panel({}) end },
    { keys.diff,    function() ui.open_diff() end },
  }
  for _, b in ipairs(bindings) do
    pcall(bind, bufnr, b[1], b[2])
  end
  return keys
end

function M.set_defaults(tbl)
  M.defaults = vim.tbl_extend("force", M.defaults, tbl or {})
end

M.setup = M.apply
M.bind = M.apply
return M
