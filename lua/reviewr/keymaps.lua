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
  uncommitted = "u", -- review uncommitted changes
  branch  = "b",   -- review the branch against its base
  turn    = "t",   -- review the agent's last turn
  commit  = "gc",  -- pick a commit and review it
  base    = "gb",  -- pick the base branch for the branch view
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
  { "u",  "view: uncommitted" },
  { "b",  "view: branch" },
  { "t",  "view: last turn" },
  { "gc", "view: pick a commit" },
  { "gb", "pick the base branch" },
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
  local at, source = vim.b.reviewr_at, vim.b.reviewr_source
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

  -- :w saves and closes the box; <esc>, :q! or :wq close it. Leaving runs once,
  -- when the box closes, so :wq's quit closes the box and not the diff pane
  -- focus returned to.
  local body, done
  local function leave()
    if done then return end
    done = true
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
      local reviewr = require("reviewr")
      if body and body ~= "" then
        if existing then
          reviewr.edit_comment(existing.id, body)
        else
          reviewr.add_comment({ file = file, side = side, at = at, source = source, body = body,
            start = startl, ["end"] = endl })
        end
      end
      ui.redraw(origin_buf)
    end)
  end
  local function close()
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(box) then vim.api.nvim_win_close(box, true) end
  end
  vim.keymap.set("n", "<esc>", close, { buffer = buf, silent = true, nowait = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
      -- after this write: :wq goes on to quit the box itself
      vim.schedule(close)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(box), once = true, callback = leave })
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
  local n = #require("reviewr.store").unsent()
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
    { keys.uncommitted, function() require("reviewr").set_scope("uncommitted") end },
    { keys.branch,  function() require("reviewr").set_scope("branch") end },
    { keys.turn,    function() require("reviewr").set_scope("turn") end },
    { keys.commit,  function() require("reviewr").pick_commit() end },
    { keys.base,    function() require("reviewr").pick_base() end },
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
