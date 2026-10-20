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
  vim.cmd("diffthis")
  local left_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local right_win = vim.api.nvim_get_current_win()
  if left_buf then vim.api.nvim_win_set_buf(left_win, left_buf) end
  if right_buf then vim.api.nvim_win_set_buf(right_win, right_buf) end
  vim.cmd("diffthis")
  state.diff = { left_win = left_win, right_win = right_win, left_buf = left_buf, right_buf = right_buf }
  return state.diff
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
  return vim.api.nvim_buf_set_extmark(bufnr, ns, (line or 1) - 1, 0, vim.tbl_extend("force", {
    virt_text = { { text or "", "ReviewrCommentText" } },
    virt_text_pos = opts.pos or "eol",
    hl_group = opts.hl,
    priority = opts.priority or 10,
  }, opts.extra or {}))
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

function M.set_statusline(str)
  vim.o.statusline = str or "%!v:lua.require('reviewr.ui').statusline()"
end

function M.statusline()
  local n = 0
  local ok, store = pcall(require, "reviewr.store")
  if ok and type(store) == "table" and store.count then
    n = store.count() or 0
  end
  return " reviewr │ " .. n .. " comments "
end

-- aliases for common / expected names
M.toggle = M.toggle_panel
M.toggle_review_panel = M.toggle_panel
M.float_panel = M.toggle_panel
return M
