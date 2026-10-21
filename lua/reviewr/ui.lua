-- reviewr.ui — diff buffers, windows, signs, extmarks, floating review panel
local M = {}

local state = {
  ns = nil,
  panel_win = nil,
  panel_buf = nil,
  diff = {},
}

local defaults = {
  panel_width = 60,
  panel_height = 20,
  border = "rounded",
  signs = {
    comment  = { text = "💬", texthl = "ReviewrCommentSign", priority = 10 },
    pending  = { text = "●",  texthl = "ReviewrPendingSign",  priority = 9  },
    resolved = { text = "✓",  texthl = "ReviewrResolvedSign", priority = 8  },
  },
}

M.config = vim.deepcopy(defaults)

local function ensure_ns()
  if not state.ns then
    state.ns = vim.api.nvim_create_namespace("reviewr")
  end
  return state.ns
end

local function hl(name, opts)
  vim.api.nvim_set_hl(0, name, opts)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  ensure_ns()
  hl("ReviewrCommentSign",  { fg = "#7aa2f7", bold = true })
  hl("ReviewrPendingSign",  { fg = "#e0af68", bold = true })
  hl("ReviewrResolvedSign", { fg = "#9ece6a", bold = true })
  hl("ReviewrPanelTitle",   { fg = "#bb9af7", bold = true })
  hl("ReviewrPanelBorder",  { fg = "#414868" })
  hl("ReviewrCommentText",  { fg = "#c0caf5" })
  hl("ReviewrCommentFile",  { fg = "#7dcfff", bold = true })
  for _, s in pairs(M.config.signs) do
    vim.fn.sign_define(s.text and ("Reviewr" .. s.text) or "ReviewrSign", {
      text = s.text, texthl = s.texthl,
    })
  end
end

-- ---------- diff buffers / windows ----------
function M.open_diff(left_buf, right_buf, opts)
  opts = opts or {}
  -- current window becomes the left (base) pane
  local left_win = vim.api.nvim_get_current_win()
  if left_buf then vim.api.nvim_win_set_buf(left_win, left_buf) end
  vim.cmd("diffthis")
  vim.cmd("rightbelow vsplit")
  local right_win = vim.api.nvim_get_current_win()
  if right_buf then vim.api.nvim_win_set_buf(right_win, right_buf) end
  vim.cmd("diffthis")
  -- titles
  pcall(function()
    vim.wo[left_win].winbar = "  base  "
    vim.wo[right_win].winbar = "  feature  "
  end)
  state.diff = { left_win = left_win, right_win = right_win, left_buf = left_buf, right_buf = right_buf, file = opts.file }
  return state.diff
end

function M.remember(diff)
  state.diff = diff or {}
end

function M.panes()
  return state.diff
end

-- The diff window that is not the current one: where the comment box opens,
-- the way octo.nvim opens its thread buffer in the alternate pane.
function M.alternate_win()
  local d = state.diff
  local cur = vim.api.nvim_get_current_win()
  if cur == d.right_win and d.left_win and vim.api.nvim_win_is_valid(d.left_win) then
    return d.left_win
  end
  if d.right_win and vim.api.nvim_win_is_valid(d.right_win) and cur ~= d.right_win then
    return d.right_win
  end
  return d.left_win
end

function M.close_diff()
  for _, w in ipairs({ state.diff.left_win, state.diff.right_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  state.diff = {}
end

-- ---------- signs ----------
function M.place_sign(bufnr, lnum, name, priority)
  bufnr = bufnr or 0
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local sign_name = "Reviewr" .. (name or "comment")
  -- ensure defined
  pcall(vim.fn.sign_define, sign_name, { text = name == "pending" and "●" or (name == "resolved" and "✓" or "💬"), texthl = "Reviewr" .. (name or "comment"):gsub("^%l", string.upper) .. "Sign" })
  return vim.fn.sign_place(0, "reviewr", sign_name, bufnr, { lnum = lnum, priority = priority or 10 })
end

function M.clear_signs(bufnr)
  bufnr = bufnr or 0
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  vim.fn.sign_unplace("reviewr", { buffer = bufnr })
end

-- ---------- extmarks / comment gutter ----------
function M.set_extmark(bufnr, line, text, opts)
  bufnr = bufnr or 0
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  opts = opts or {}
  local ns = ensure_ns()
  local body = "  " .. (text or ""):gsub("^%s+", "")
  return vim.api.nvim_buf_set_extmark(bufnr, ns, math.max((line or 1) - 1, 0), 0, {
    virt_lines = { { { body, "ReviewrCommentText" } } },
    virt_lines_above = true,
    priority = opts.priority or 10,
  })
end

function M.clear_extmarks(bufnr)
  bufnr = bufnr or 0
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  vim.api.nvim_buf_clear_namespace(bufnr, ensure_ns(), 0, -1)
end

-- ---------- floating review panel ----------
function M.toggle_panel(items)
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_win_close(state.panel_win, true)
    state.panel_win = nil
    state.panel_buf = nil
    return false
  end
  state.panel_buf = vim.api.nvim_create_buf(false, true)
  local lines = { " reviewr — review panel ", " ────────────────────────────" }
  for _, it in ipairs(items or {}) do
    lines[#lines + 1] = string.format(" %s  %s:%d", it.status or "○", it.file or "?", it.line or 0)
    if it.body then
      lines[#lines + 1] = "   └ " .. tostring(it.body):gsub("\n", " ")
    end
  end
  if #lines == 2 then lines[#lines + 1] = "   (no comments)" end
  vim.api.nvim_buf_set_lines(state.panel_buf, 0, -1, false, lines)
  vim.bo[state.panel_buf].modifiable = false
  vim.bo[state.panel_buf].buftype = "nofile"
  local width = M.config.panel_width
  local height = math.min(M.config.panel_height, #lines)
  state.panel_win = vim.api.nvim_open_win(state.panel_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = vim.o.columns - width - 2,
    row = 1,
    style = "minimal",
    border = M.config.border,
    title = " reviewr ",
    title_pos = "center",
  })
  vim.wo[state.panel_win].winhl = "Normal:Normal,FloatBorder:ReviewrPanelBorder"
  return true
end

-- ---------- help ----------
local help_state = { win = nil, buf = nil }

function M.toggle_help(legend)
  if help_state.win and vim.api.nvim_win_is_valid(help_state.win) then
    vim.api.nvim_win_close(help_state.win, true)
    help_state.win, help_state.buf = nil, nil
    return false
  end
  legend = legend or require("reviewr.keymaps").legend
  local lines = { " reviewr — keys", "" }
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
  vim.bo[help_state.buf].buftype = "nofile"
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

function M.set_statusline(str)
  vim.o.statusline = str or "%!v:lua.require('reviewr.ui').statusline()"
end

-- The footer says the next useful step, the way herdr-reviewr's does.
function M.hint(count)
  if (count or 0) == 0 then
    return "c  comment on this line    ?  all keys"
  end
  return "s  send to agent    y  copy    ?  all keys"
end

function M.statusline()
  local n = 0
  local ok, store = pcall(require, "reviewr.store")
  local scope_ok, scope = pcall(require, "reviewr.scope")
  if ok and store.count then
    local q = {}
    if scope_ok and scope.get and scope.get() then q.scope = scope.get().name end
    n = store.count(q) or 0
  end
  local label = " reviewr "
  local s = scope_ok and scope.get and scope.get()
  if s and s.name then label = label .. "│ " .. s.name .. " " end
  local left = label .. "│ " .. n .. (n == 1 and " comment" or " comments")
  local right = M.hint(n)
  local width = math.floor(vim.o.columns / math.max(1, #vim.api.nvim_tabpage_list_wins(0)))
  local gap = math.max(2, width - vim.fn.strwidth(left) - vim.fn.strwidth(right))
  return left .. string.rep(" ", gap) .. right
end

function M.refresh_status()
  vim.o.statusline = "%!v:lua.require('reviewr.ui').statusline()"
  pcall(vim.cmd, "redrawstatus")
end

function M.redraw(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  M.clear_signs(bufnr)
  M.clear_extmarks(bufnr)
  local ok, store = pcall(require, "reviewr.store")
  if not ok then return end
  local name = vim.api.nvim_buf_get_name(bufnr)
  for _, c in ipairs(store.ordered()) do
    local mine = c.file and (name == "" or name:sub(-#c.file) == c.file)
    if mine and not c.orphaned then
      M.place_sign(bufnr, c.start, "comment")
      M.set_extmark(bufnr, c.start, "💬  " .. (c.body or ""))
    end
  end
  M.refresh_status()
end

-- The comment under the cursor, if the cursor sits on its line.
function M.comment_at_cursor()
  local ok, store = pcall(require, "reviewr.store")
  if not ok then return nil end
  local lnum = vim.fn.line(".")
  local name = vim.api.nvim_buf_get_name(0)
  for _, c in ipairs(store.ordered()) do
    if c.start == lnum and c.file and name:sub(-#c.file) == c.file then return c end
  end
  return nil
end

-- aliases for common / expected names
M.toggle = M.toggle_panel
M.toggle_review_panel = M.toggle_panel
M.float_panel = M.toggle_panel
return M
