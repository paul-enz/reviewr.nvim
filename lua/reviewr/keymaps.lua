-- reviewr.keymaps — buffer-local defaults, remappable
local M = {}

M.defaults = {
  comment = "c",   -- comment on the current line or visual selection
  edit    = "e",   -- edit the comment under the cursor
  delete  = "d",   -- delete the comment under the cursor
  send    = "s",   -- send every comment to the running agent
  copy    = "y",   -- copy every comment to the clipboard
  panel   = "l",   -- list comments
  nextc   = "n",   -- next comment
  prevc   = "N",   -- previous comment
  nextf   = "f",   -- next changed file
  prevf   = "F",   -- previous changed file
  refresh = "r",   -- reload the diff
  help    = "?",   -- show every key
  quit    = "q",   -- close the review
  next    = "]c",  -- next change
  prev    = "[c",  -- previous change
}

-- What each key does, in the order the footer and the help screen show them.
M.legend = {
  { "c",  "comment on this line" },
  { "e",  "edit the comment here" },
  { "d",  "delete the comment here" },
  { "n",  "next comment" },
  { "N",  "previous comment" },
  { "s",  "send comments to the agent" },
  { "y",  "copy comments" },
  { "l",  "list comments" },
  { "]c", "next change" },
  { "[c", "previous change" },
  { "f",  "next file" },
  { "F",  "previous file" },
  { "r",  "refresh" },
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
  local startl, endl = vim.fn.line("."), vim.fn.line(".")
  if vim.fn.mode():find("[vV]") then
    startl, endl = vim.fn.line("v"), vim.fn.line(".")
    if startl > endl then startl, endl = endl, startl end
  end
  vim.ui.input({ prompt = "comment: " }, function(body)
    if not body or body == "" then return end
    if reviewr.add_comment({ body = body, start = startl, ["end"] = endl }) then
      ui.redraw()
    end
  end)
end

local function edit_here()
  local ui = require("reviewr.ui")
  local c = ui.comment_at_cursor()
  if not c then vim.notify("reviewr: no comment on this line", vim.log.levels.INFO); return end
  vim.ui.input({ prompt = "comment: ", default = c.body }, function(body)
    if not body or body == "" then return end
    require("reviewr").edit_comment(c.id, body)
    ui.redraw()
  end)
end

local function delete_here()
  local ui = require("reviewr.ui")
  local c = ui.comment_at_cursor()
  if not c then vim.notify("reviewr: no comment on this line", vim.log.levels.INFO); return end
  require("reviewr").delete_comment(c.id)
  ui.redraw()
end

local function quit()
  local store = require("reviewr.store")
  local n = store.count()
  local function close() require("reviewr.ui").close_diff() end
  if n == 0 then return close() end
  vim.ui.select({ "keep reviewing", "close and drop " .. n .. " unsent" },
    { prompt = n .. " unsent " .. (n == 1 and "comment" or "comments") },
    function(choice) if choice and choice:find("^close") then close() end end)
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
    { keys.edit,    edit_here },
    { keys.delete,  delete_here },
    { keys.send,    function() export("send") end },
    { keys.copy,    function() export("clipboard") end },
    { keys.panel,   function() ui.toggle_panel() end },
    { keys.nextc,   function() require("reviewr").jump_comment(1) end },
    { keys.prevc,   function() require("reviewr").jump_comment(-1) end },
    { keys.nextf,   function() local f = require("reviewr").jump_file(1); if f then vim.notify("reviewr: " .. f, vim.log.levels.INFO) end end },
    { keys.prevf,   function() local f = require("reviewr").jump_file(-1); if f then vim.notify("reviewr: " .. f, vim.log.levels.INFO) end end },
    { keys.refresh, function() vim.cmd("diffupdate") end },
    { keys.help,    function() ui.toggle_help(M.legend) end },
    { keys.quit,    quit },
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
