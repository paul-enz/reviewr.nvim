-- reviewr.keymaps — buffer-local defaults, remappable
local M = {}

M.defaults = {
  comment = "c",   -- comment on the current line or visual selection
  edit    = "e",   -- edit the comment under the cursor
  delete  = "d",   -- delete the comment under the cursor
  send    = "s",   -- send every comment to the running agent (the paired one, if any)
  pick    = "S",   -- send, choosing the agent
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
  { "S",  "send, choosing the agent" },
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
  local mode = opts.mode or "n"
  opts.mode = nil
  vim.keymap.set(mode, lhs, rhs, opts)
end

-- Opens the comment box for the current line or selection, or, given a
-- comment, for editing that comment.
local function open_comment_box(existing)
  local ui = require("reviewr.ui")
  local startl, endl = vim.fn.line("."), vim.fn.line(".")
  if existing then
    startl, endl = existing.start, existing["end"]
  elseif vim.fn.mode():find("[vV\22]") then
    startl, endl = vim.fn.line("v"), vim.fn.line(".")
    if startl > endl then startl, endl = endl, startl end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "nx", false)
  end
  local file = vim.b.reviewr_file
  local side = vim.b.reviewr_side
  local origin = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_get_current_buf()
  local alt = ui.alternate_win()
  if not file or not alt or not vim.api.nvim_win_is_valid(alt) then
    vim.notify("reviewr: open a review first", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local span = startl == endl and tostring(startl) or (startl .. "-" .. endl)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "acwrite"
  vim.api.nvim_buf_set_name(buf, "reviewr://comment/" .. buf)
  if existing then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(existing.body, "\n", { plain = true }))
    vim.bo[buf].modified = false
  end

  -- a small box over the other pane, level with the line being commented
  local pos = vim.api.nvim_win_get_position(alt)
  local width = math.max(20, math.min(48, vim.api.nvim_win_get_width(alt) - 2))
  local height = 6
  local box = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = pos[2],
    row = math.max(0, math.min(pos[1] + vim.fn.winline() - 1, vim.o.lines - height - 3)),
    style = "minimal",
    border = "rounded",
    title = " comment  " .. vim.fn.fnamemodify(file, ":t") .. ":" .. span .. " ",
    title_pos = "left",
    footer = " :w save    <esc> cancel ",
    footer_pos = "right",
  })
  vim.wo[box].winhl = "Normal:Normal,FloatBorder:ReviewrPanelBorder"
  if not existing then vim.cmd("startinsert") end

  ui.mark_range(origin_buf, startl, endl)

  local function finish(save)
    vim.cmd("stopinsert")
    local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    if vim.api.nvim_win_is_valid(box) then vim.api.nvim_win_close(box, true) end
    if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
    local reviewr = require("reviewr")
    if save and body ~= "" then
      if existing then
        reviewr.edit_comment(existing.id, body)
      else
        reviewr.add_comment({ file = file, side = side, body = body, start = startl, ["end"] = endl })
      end
    end
    ui.redraw(origin_buf)
  end
  vim.keymap.set("n", "<esc>", function() finish(false) end, { buffer = buf, silent = true, nowait = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      finish(true)
    end,
  })
end

M.open_comment_box = open_comment_box

local function edit_here()
  local c = require("reviewr.ui").comment_at_cursor()
  if not c then vim.notify("reviewr: no comment on this line", vim.log.levels.INFO); return end
  open_comment_box(c)
end

local function delete_here()
  local ui = require("reviewr.ui")
  local c = ui.comment_at_cursor()
  if not c then vim.notify("reviewr: no comment on this line", vim.log.levels.INFO); return end
  require("reviewr").delete_comment(c.id)
  ui.redraw()
end

function M.quit()
  local n = require("reviewr.store").count()
  local close = require("reviewr").close
  if n == 0 then return close() end
  require("reviewr.ui").confirm("Close review?",
    n .. " unsent " .. (n == 1 and "comment" or "comments") .. " will be lost.", close)
end

local function report(ok, res, dest)
  if not ok then
    vim.notify("reviewr: " .. tostring(res), vim.log.levels.WARN)
    return
  end
  local what = res .. (res == 1 and " comment" or " comments")
  local msg = dest == "clipboard" and ("copied " .. what)
    or (dest and dest:find("/") and ("wrote " .. what .. " to " .. dest))
    or ("sent " .. what .. " to " .. tostring(dest))
  vim.notify("reviewr: " .. msg, vim.log.levels.INFO)
end

local function export(target, opts)
  require("reviewr").export(target, report, opts)
end

local function jump_file(dir)
  local f = require("reviewr").jump_file(dir)
  if f then vim.notify("reviewr: " .. f, vim.log.levels.INFO) end
end

function M.apply(bufnr, overrides)
  bufnr = bufnr or 0
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local keys = vim.tbl_extend("force", M.defaults, overrides or {})
  local ui = require("reviewr.ui")
  local bindings = {
    { keys.comment, function() open_comment_box() end, { "n", "x" } },
    { keys.edit,    edit_here },
    { keys.delete,  delete_here },
    { keys.send,    function() export("send") end },
    { keys.pick,    function() export("send", { pick = true }) end },
    { keys.copy,    function() export("clipboard") end },
    { keys.panel,   function() ui.toggle_panel() end },
    { keys.nextc,   function() require("reviewr").jump_comment(1) end },
    { keys.prevc,   function() require("reviewr").jump_comment(-1) end },
    { keys.nextf,   function() jump_file(1) end },
    { keys.prevf,   function() jump_file(-1) end },
    { keys.refresh, function() require("reviewr").refresh() end },
    { keys.help,    function() ui.toggle_help(M.legend) end },
    { keys.quit,    M.quit },
    { keys.next,    function() vim.cmd("normal! ]c") end },
    { keys.prev,    function() vim.cmd("normal! [c") end },
  }
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      for _, mode in ipairs(b[3] or { "n" }) do
        bind(bufnr, b[1], b[2], { mode = mode })
      end
    end
  end
  return keys
end

function M.set_defaults(tbl)
  M.defaults = vim.tbl_extend("force", M.defaults, tbl or {})
end

return M
