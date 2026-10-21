-- reviewr.ui: review tab, diff windows, changed-files panel, signs, extmarks, floats
local M = {}

local state = {
  ns = nil,
  panel_win = nil,
  panel_buf = nil,
  diff = {},
}

M.config = {
  panel_width = 60,
  panel_height = 20,
  border = "rounded",
}

local function ensure_ns()
  if not state.ns then
    state.ns = vim.api.nvim_create_namespace("reviewr")
  end
  return state.ns
end

local function valid_win(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

local function highlights()
  for name, link in pairs({
    ReviewrCommentSign = "DiagnosticInfo",
    ReviewrCommentText = "Comment",
    ReviewrPanelBorder = "FloatBorder",
    ReviewrRange = "Visual",
    ReviewrRangeSign = "DiagnosticInfo",
    ReviewrButton = "PmenuSel",
    ReviewrAdded = "Added",
    ReviewrRemoved = "Removed",
  }) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  ensure_ns()
  highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("reviewr_highlights", { clear = true }),
    callback = highlights,
  })
  -- a review often opens before its terminal reaches full size, and Neovim
  -- would hand all the new width to the right pane
  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("reviewr_resize", { clear = true }),
    callback = function() M.equalize() end,
  })
end

-- ---------- review tab ----------

function M.is_open()
  return state.diff.tab ~= nil and vim.api.nvim_tabpage_is_valid(state.diff.tab)
    and valid_win(state.diff.left_win) and valid_win(state.diff.right_win)
end

-- A tab of its own, so the review never rearranges the user's windows.
function M.open_tab()
  vim.cmd("tabnew")
  local placeholder = vim.api.nvim_get_current_buf()
  vim.bo[placeholder].bufhidden = "wipe"
  local left_win = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit")
  local right_win = vim.api.nvim_get_current_win()
  state.diff = { tab = vim.api.nvim_get_current_tabpage(), left_win = left_win, right_win = right_win }
  return state.diff
end

-- Splits the width of the two diff panes evenly.
function M.equalize()
  if not M.is_open() then return end
  local d = state.diff
  local total = vim.api.nvim_win_get_width(d.left_win) + vim.api.nvim_win_get_width(d.right_win)
  vim.api.nvim_win_set_width(d.left_win, math.floor(total / 2))
end

function M.focus_tab()
  if M.is_open() then vim.api.nvim_set_current_tabpage(state.diff.tab) end
end

function M.show_file(left_buf, right_buf, file)
  local d = state.diff
  -- the hint lives in the winbar: statusline plugins such as lualine own the footer
  local bars = { "  base  ", "%!v:lua.require('reviewr.ui').winbar()" }
  for i, pair in ipairs({ { d.left_win, left_buf }, { d.right_win, right_buf } }) do
    vim.api.nvim_win_call(pair[1], function()
      vim.api.nvim_win_set_buf(pair[1], pair[2])
      vim.cmd("diffthis")
    end)
    vim.wo[pair[1]].winbar = bars[i]
    -- with 'cursorline' on, Neovim underlines the cursor line across diff
    -- colours; the line number alone marks it
    vim.wo[pair[1]].cursorlineopt = "number"
  end
  d.left_buf, d.right_buf, d.file = left_buf, right_buf, file
  return d
end

function M.panes()
  return state.diff
end

-- The diff window that is not the current one: where the comment box opens.
function M.alternate_win()
  local d = state.diff
  if vim.api.nvim_get_current_win() == d.right_win and valid_win(d.left_win) then
    return d.left_win
  end
  if valid_win(d.right_win) then return d.right_win end
  return d.left_win
end

function M.close_diff()
  local tab = state.diff.tab
  state.diff = {}
  if not (tab and vim.api.nvim_tabpage_is_valid(tab)) then return end
  -- wiping buffers still in diff mode as the tab closes can crash Neovim
  vim.api.nvim_set_current_tabpage(tab)
  vim.cmd("diffoff!")
  if #vim.api.nvim_list_tabpages() == 1 then vim.cmd("tabnew") end
  vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tab))
end

-- ---------- changed-files panel ----------
-- A list of every changed file along the bottom, the way octo.nvim shows one
-- during a review. <CR> opens the file under the cursor.
local files_panel = { win = nil, buf = nil, files = {} }

function M.files_panel()
  return files_panel
end

function M.render_files_panel()
  local buf = files_panel.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local store = require("reviewr.store")
  local function at(b) return b and vim.api.nvim_buf_is_valid(b) and vim.b[b].reviewr_at or nil end
  local left_at, right_at = at(state.diff.left_buf), at(state.diff.right_buf)
  -- each row: marker, status, path, then +added -deleted the way octo.nvim
  -- shows them, then the comment count
  local current, lines, marks = nil, {}, {}
  for i, f in ipairs(files_panel.files) do
    local here = f.path == state.diff.file
    if here then current = i end
    local n = #store.shown(f.path, "left", left_at) + #store.shown(f.path, "right", right_at)
    local line = string.format("%s %s  %s", here and "▶" or " ", f.status, f.path)
    if f.added then
      local plus, minus = "+" .. f.added, "-" .. f.deleted
      table.insert(marks, { i - 1, #line + 2, #line + 2 + #plus, "ReviewrAdded" })
      table.insert(marks, { i - 1, #line + 3 + #plus, #line + 3 + #plus + #minus, "ReviewrRemoved" })
      line = line .. "  " .. plus .. " " .. minus
    end
    lines[i] = line .. (n > 0 and ("  💬 " .. n) or "")
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ensure_ns(), 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ensure_ns(), m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  if valid_win(files_panel.win) then
    vim.wo[files_panel.win].winbar = string.format("  changed files (%d)  ", #files_panel.files)
    if current then pcall(vim.api.nvim_win_set_cursor, files_panel.win, { current, 0 }) end
  end
end

function M.open_files_panel(files)
  files_panel.files = files or files_panel.files
  if not valid_win(files_panel.win) then
    local origin = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "reviewr-files"
    -- the rows, plus the title bar
    local height = require("reviewr.config").get().files_panel_height + 1
    vim.api.nvim_win_call(state.diff.left_win, function() vim.cmd("botright " .. height .. "split") end)
    local win = vim.fn.win_getid(vim.fn.winnr("$"), vim.api.nvim_tabpage_get_number(state.diff.tab))
    vim.api.nvim_win_set_buf(win, buf)
    for opt, val in pairs({ diff = false, scrollbind = false, cursorbind = false, foldenable = false,
      foldcolumn = "0", winfixheight = true, cursorline = true, number = false,
      relativenumber = false, signcolumn = "no", wrap = false }) do
      vim.wo[win][opt] = val
    end
    files_panel.win, files_panel.buf = win, buf
    local function map(lhs, fn)
      vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
    end
    map("<CR>", function()
      local f = files_panel.files[vim.fn.line(".")]
      if not f then return end
      require("reviewr").open_file(f.path)
      if valid_win(state.diff.right_win) then vim.api.nvim_set_current_win(state.diff.right_win) end
    end)
    map("q", function() require("reviewr.keymaps").quit() end)
    if valid_win(origin) then vim.api.nvim_set_current_win(origin) end
    M.equalize()
  end
  M.render_files_panel()
end

-- ---------- range highlight while commenting ----------

function M.mark_range(bufnr, startl, endl)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local last = vim.api.nvim_buf_line_count(bufnr)
  -- marked in the gutter: diff highlighting would hide a line highlight
  for line = startl, math.min(endl, last) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ensure_ns(), line - 1, 0, {
      sign_text = "▌", sign_hl_group = "ReviewrRangeSign", number_hl_group = "ReviewrRange", priority = 50,
    })
  end
end

function M.clear_range(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then M.redraw(bufnr) end
end

-- ---------- comments in the diff ----------

function M.redraw(bufnr)
  if bufnr == nil then
    for _, b in ipairs({ state.diff.left_buf, state.diff.right_buf }) do
      if b then M.redraw(b) end
    end
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ensure_ns(), 0, -1)
  local file, side = vim.b[bufnr].reviewr_file, vim.b[bufnr].reviewr_side
  if file then
    local last = vim.api.nvim_buf_line_count(bufnr)
    for _, c in ipairs(require("reviewr.store").shown(file, side, vim.b[bufnr].reviewr_at)) do
      local row = math.min(c.start, last) - 1
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ensure_ns(), row, 0, {
        sign_text = "💬",
        sign_hl_group = "ReviewrCommentSign",
        virt_lines = vim.tbl_map(function(l) return { { "  " .. l, "ReviewrCommentText" } } end,
          vim.split(c.body or "", "\n", { plain = true })),
        -- Neovim draws nothing above the first line, so that one goes below
        virt_lines_above = row > 0,
      })
    end
  end
  M.render_files_panel()
  pcall(vim.cmd, "redrawstatus!")
end

-- The comment under the cursor, if the cursor sits inside its range.
function M.comment_at_cursor()
  local file = vim.b.reviewr_file
  if not file then return nil end
  local lnum = vim.fn.line(".")
  for _, c in ipairs(require("reviewr.store").shown(file, vim.b.reviewr_side, vim.b.reviewr_at)) do
    if lnum >= c.start and lnum <= c["end"] then return c end
  end
  return nil
end

-- ---------- comment list ----------

function M.toggle_panel()
  if valid_win(state.panel_win) then
    vim.api.nvim_win_close(state.panel_win, true)
    state.panel_win, state.panel_buf = nil, nil
    return false
  end
  local lines = {}
  for _, c in ipairs(require("reviewr.store").ordered()) do
    lines[#lines + 1] = string.format(" %s:%d (%s)", c.file, c.start, c.side)
    lines[#lines + 1] = "   └ " .. (c.body or ""):gsub("\n", " ")
  end
  if #lines == 0 then lines[1] = "   (no comments)" end
  state.panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(state.panel_buf, 0, -1, false, lines)
  vim.bo[state.panel_buf].modifiable = false
  vim.bo[state.panel_buf].bufhidden = "wipe"
  local width = math.min(M.config.panel_width, vim.o.columns - 4)
  state.panel_win = vim.api.nvim_open_win(state.panel_buf, true, {
    relative = "editor",
    width = width,
    height = math.min(M.config.panel_height, #lines),
    col = vim.o.columns - width - 2,
    row = 1,
    style = "minimal",
    border = M.config.border,
    title = " comments ",
    title_pos = "center",
  })
  vim.wo[state.panel_win].winhl = "Normal:Normal,FloatBorder:ReviewrPanelBorder"
  for _, key in ipairs({ "l", "q", "<esc>" }) do
    vim.keymap.set("n", key, M.toggle_panel, { buffer = state.panel_buf, silent = true, nowait = true })
  end
  return true
end

-- ---------- confirm ----------

-- A small yes/no box. Yes starts highlighted, so <CR> confirms; <Right> or
-- <Tab> moves to No and <Left> back, <CR> takes the highlighted choice, and
-- <Esc> cancels. y and n answer directly.
function M.confirm(title, message, on_yes)
  local width = math.max(vim.fn.strwidth(message) + 4, 26)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 3,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - 5) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.wo[win].winhl = "Normal:Normal,FloatBorder:ReviewrPanelBorder"
  local buttons = { "  Yes  ", "  No  " }
  local gap = "   "
  local pad = math.floor((width - vim.fn.strwidth(buttons[1] .. gap .. buttons[2])) / 2)
  local selected = 1
  local function render()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      " " .. message, "", string.rep(" ", pad) .. buttons[1] .. gap .. buttons[2],
    })
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ensure_ns(), 0, -1)
    local start = pad + (selected == 1 and 0 or #buttons[1] + #gap)
    vim.api.nvim_buf_set_extmark(buf, ensure_ns(), 2, start, {
      end_col = start + #buttons[selected], hl_group = "ReviewrButton",
    })
    pcall(vim.api.nvim_win_set_cursor, win, { 3, start })
  end
  local function finish(yes)
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if yes then on_yes() end
  end
  local function map(keys, fn)
    for _, key in ipairs(keys) do
      vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
    end
  end
  map({ "<CR>" }, function() finish(selected == 1) end)
  map({ "<Right>", "l", "<Tab>" }, function() selected = 2; render() end)
  map({ "<Left>", "h", "<S-Tab>" }, function() selected = 1; render() end)
  map({ "<Esc>", "q", "n" }, function() finish(false) end)
  map({ "y" }, function() finish(true) end)
  render()
  return win
end

-- ---------- pick ----------

-- A list in a box like the confirm box, taking vim.ui.select's arguments:
-- j/k or the arrows move, <CR> picks, <Esc> or q cancels (on_choice(nil)).
function M.pick(items, opts, on_choice)
  opts = opts or {}
  local format = opts.format_item or tostring
  local lines = vim.tbl_map(function(it) return " " .. format(it) .. " " end, items)
  local width = vim.fn.strwidth(opts.prompt or "") + 4
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strwidth(l)) end
  width = math.min(math.max(width, 30), vim.o.columns - 4)
  local height = math.max(1, math.min(#lines, 15, vim.o.lines - 6))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    style = "minimal",
    border = "rounded",
    title = opts.prompt and (" " .. opts.prompt .. " ") or nil,
    title_pos = "center",
  })
  vim.wo[win].winhl = "Normal:Normal,FloatBorder:ReviewrPanelBorder,CursorLine:ReviewrButton"
  vim.wo[win].cursorline = true
  local done = false
  local function finish(choice)
    if done then return end
    done = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    on_choice(choice)
  end
  local function map(keys, fn)
    for _, key in ipairs(keys) do
      vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
    end
  end
  map({ "<CR>" }, function() finish(items[vim.fn.line(".")]) end)
  map({ "<Esc>", "q" }, function() finish(nil) end)
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = function() finish(nil) end })
  return win
end

-- ---------- help ----------
local help_state = { win = nil, buf = nil }

function M.toggle_help(legend)
  if valid_win(help_state.win) then
    vim.api.nvim_win_close(help_state.win, true)
    help_state.win, help_state.buf = nil, nil
    return false
  end
  legend = legend or require("reviewr.keymaps").legend
  local lines = { " reviewr: keys", "" }
  local width = 28
  for _, row in ipairs(legend) do
    local key = " " .. row[1] .. string.rep(" ", math.max(1, 5 - vim.fn.strwidth(row[1])))
    lines[#lines + 1] = key .. row[2]
    width = math.max(width, vim.fn.strwidth(lines[#lines]) + 2)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = " press ? or q to close"
  help_state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(help_state.buf, 0, -1, false, lines)
  vim.bo[help_state.buf].modifiable = false
  vim.bo[help_state.buf].bufhidden = "wipe"
  help_state.win = vim.api.nvim_open_win(help_state.buf, true, {
    relative = "editor",
    width = width,
    height = #lines,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2)),
    style = "minimal",
    border = "rounded",
    title = " ? ",
    title_pos = "center",
  })
  vim.wo[help_state.win].winhl = "Normal:Normal,FloatBorder:ReviewrPanelBorder"
  for _, key in ipairs({ "?", "q", "<esc>" }) do
    vim.keymap.set("n", key, function() M.toggle_help() end,
      { buffer = help_state.buf, silent = true, nowait = true })
  end
  return true
end

-- ---------- hint bar ----------

-- The bar says the next useful step, the way herdr-reviewr's footer does.
function M.hint(count)
  if (count or 0) == 0 then
    return "c  comment on this line    ?  all keys"
  end
  return "s  send to agent    y  copy    ?  all keys"
end

function M.winbar()
  local n = require("reviewr.store").count()
  local s = require("reviewr.scope").get()
  local agent = require("reviewr").paired()
  local name = s and (s.label or s.name)
  local left = "  change " .. (name and ("│ " .. name .. " ") or "")
    .. "│ " .. n .. (n == 1 and " comment" or " comments")
    .. (agent and ("  → " .. agent.name) or "")
  local right = M.hint(#require("reviewr.store").unsent()) .. " "
  local width = vim.api.nvim_win_get_width(vim.g.statusline_winid or 0)
  local gap = width - vim.fn.strwidth(left) - vim.fn.strwidth(right)
  if gap < 2 then return left end
  return left .. string.rep(" ", gap) .. right
end

return M
