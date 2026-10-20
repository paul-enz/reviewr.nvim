local M = {}

function M.hash_lines(lines)
  lines = lines or {}
  local text = table.concat(lines, "\n")
  if vim.fn.exists("*sha256") == 1 then
    return vim.fn.sha256(text)
  end
  -- fallback checksum
  local h = 0
  for i = 1, #text do h = (h * 31 + string.byte(text, i)) % 2147483647 end
  return tostring(h)
end

function M.make(file, side, start, finish, lines)
  return {
    file = file,
    side = side or "right",
    start = start,
    ["end"] = finish,
    hunk_hash = M.hash_lines(lines),
  }
end

function M.namespace()
  return vim.api.nvim_create_namespace("reviewr")
end

function M.place(bufnr, anchor, ns)
  ns = ns or M.namespace()
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return nil end
  local s = (anchor.start or 1) - 1
  local e = (anchor["end"] or anchor.start or 1) - 1
  if s < 0 then s = 0 end
  if e < s then e = s end
  local last = vim.api.nvim_buf_line_count(bufnr) - 1
  if s > last then return nil end
  if e > last then e = last end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, s, 0, {
    end_row = e,
    hl_group = "DiffChange",
    priority = 100,
  })
  if not ok then return nil end
  return id
end

function M.reconcile(comments, exists_fn)
  for _, c in ipairs(comments or {}) do
    local ok = (exists_fn and exists_fn(c)) or false
    c.orphaned = not ok
  end
  return comments
end

function M.orphan(comment)
  if comment then comment.orphaned = true end
  return comment
end

return M
