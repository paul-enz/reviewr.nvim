-- reviewr.keymaps — buffer-local defaults, remappable
local M = {}

M.defaults = {
  comment = "c",   -- comment on the current line or visual selection
  send    = "s",   -- send every comment to the running agent
  copy    = "y",   -- copy every comment to the clipboard
  panel   = "l",   -- list comments
  help    = "?",   -- show every key
  quit    = "q",   -- close the review
  next    = "]c",  -- next change
  prev    = "[c",  -- previous change
}

-- What each key does, in the order the footer and the help screen show them.
-- The footer shows the first entry of each pair; `?` shows all of them.
M.legend = {
  { "c",  "comment on this line" },
  { "s",  "send comments to the agent" },
  { "y",  "copy comments" },
  { "l",  "list comments" },
  { "]c", "next change" },
  { "[c", "previous change" },
  { "?",  "all keys" },
  { "q",  "close" },
}

local function bind(bufnr, lhs, rhs, opts)
  opts = vim.tbl_extend("force", { buffer = bufnr, silent = true, noremap = true }, opts or {})
  vim.keymap.set(opts.mode or "n", lhs, rhs, opts)
end

local function comment_here()
  local reviewr = require("reviewr")
  local ui = require("reviewr.ui")
  local mode = vim.fn.mode()
  local startl, endl = vim.fn.line("."), vim.fn.line(".")
  if mode == "v" or mode == "V" then
    startl, endl = vim.fn.line("v"), vim.fn.line(".")
    if startl > endl then startl, endl = endl, startl end
  end
  vim.ui.input({ prompt = "comment: " }, function(body)
    if not body or body == "" then return end
    local c = reviewr.add_comment({ body = body, start = startl, ["end"] = endl, bufnr = vim.api.nvim_get_current_buf() })
    if c then
      ui.place_sign(0, startl, "comment")
      ui.set_extmark(0, startl, "💬  " .. body)
      ui.refresh_status()
      vim.notify("reviewr: comment on " .. c.file .. ":" .. startl, vim.log.levels.INFO)
    end
  end)
end

local function export(target)
  local reviewr = require("reviewr")
  local ok, res = reviewr.export(target)
  local verb = target == "send" and "sent" or "copied"
  vim.notify(ok and ("reviewr: " .. verb .. " " .. tostring(res)) or ("reviewr: " .. tostring(res)),
    ok and vim.log.levels.INFO or vim.log.levels.WARN)
end

function M.apply(bufnr, overrides)
  bufnr = bufnr or 0
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local keys = vim.tbl_extend("force", M.defaults, overrides or {})
  local ui = require("reviewr.ui")
  local bindings = {
    { keys.comment, comment_here, { "n", "v" } },
    { keys.send,    function() export("send") end },
    { keys.copy,    function() export("clipboard") end },
    { keys.panel,   function() ui.toggle_panel() end },
    { keys.help,    function() ui.toggle_help(M.legend) end },
    { keys.quit,    function() ui.close_diff() end },
    { keys.next,    function() vim.cmd("normal! ]c") end },
    { keys.prev,    function() vim.cmd("normal! [c") end },
  }
  for _, b in ipairs(bindings) do
    for _, mode in ipairs(b[3] or { "n" }) do
      pcall(bind, bufnr, b[1], b[2], { mode = mode })
    end
  end
  return keys
end

function M.set_defaults(tbl)
  M.defaults = vim.tbl_extend("force", M.defaults, tbl or {})
end

M.setup = M.apply
M.bind = M.apply
return M
