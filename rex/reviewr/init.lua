-- Rex integration for reviewr.nvim: a key that shows a review of the focused
-- terminal's repository in a split to its right, and hides it again.
local M = {}

local TERMINAL = "com.superlogical.terminal"

M.config = {
  key = "cmd+r",
  -- run in the new Neovim; the branch scope diffs the working tree, commits
  -- and uncommitted edits alike, against its merge base with the default
  -- branch (origin/HEAD, else main or master)
  command = "ReviewrScope branch",
  nvim = "nvim",
  -- the share of the row the focused terminal keeps
  ratio = 0.4,
}

local LABEL = "review"

local function cwd_of(session_id, block_id)
  local ok, proc = pcall(rex.call, "block.method",
    { session_id = session_id, block_id = block_id, method = "process" })
  local fg = ok and type(proc) == "table" and proc.foreground or nil
  return fg and fg.cwd or ""
end

local function repo_of(cwd)
  if cwd == "" then return "" end
  local out, _, code = rex.exec({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  local top = code == 0 and out and out:match("[^\n]+")
  return top or cwd
end

-- The review panes of the session: blocks this module opened, which keep the
-- label it gave them.
local function reviews(session_id)
  local ok, res = pcall(rex.call, "session.list_blocks", { session_id = session_id })
  local out = {}
  for _, b in ipairs(ok and res.blocks or {}) do
    if b.label == LABEL then out[#out + 1] = b end
  end
  return out
end

local function open_new(session_id, block_id, cwd)
  return rex.call("session.new_split", {
    session_id = session_id,
    anchor_id = block_id,
    direction = "horizontal",
    side = "after",
    ratio = M.config.ratio,
    focus = true,
    layout = {
      block = {
        flavor = TERMINAL .. ".shell",
        label = LABEL,
        options = { command = { M.config.nvim, "-c", M.config.command }, cwd = cwd },
      },
    },
  })
end

-- Hides the review shown in this window, keeping it running with its
-- comments; else brings back the hidden review of this repository; else opens
-- a new one, in a split right of the focused terminal.
function M.toggle(ctx)
  local session_id = ctx.session_id or rex.session_id
  local block_id = ctx.block_id or rex.block_id
  local all = reviews(session_id)
  local window
  for _, b in ipairs(rex.call("session.list_blocks", { session_id = session_id }).blocks or {}) do
    if b.block_id == block_id then window = b.window_id end
  end
  for _, b in ipairs(all) do
    if b.placement == "placed" and b.window_id == window then
      return rex.call("session.detach_block", { session_id = session_id, block_id = b.block_id })
    end
  end
  local cwd = cwd_of(session_id, block_id)
  local repo = repo_of(cwd)
  for _, b in ipairs(all) do
    if b.placement ~= "placed" and repo_of(cwd_of(session_id, b.block_id)) == repo then
      local res = rex.call("session.move_block", {
        session_id = session_id,
        block_id = b.block_id,
        anchor_block_id = block_id,
        direction = "horizontal",
        side = "after",
        ratio = M.config.ratio,
      })
      rex.call("session.focus_block", { session_id = session_id, block_id = b.block_id })
      return res
    end
  end
  return open_new(session_id, block_id, cwd)
end

M.open = M.toggle

function M.setup(opts)
  for k, v in pairs(opts or {}) do M.config[k] = v end
  rex.action({
    name = "reviewr_open",
    title = "Show or hide the review",
    run = function(ctx) return M.toggle(ctx or {}) end,
  })
  if M.config.key then
    rex.bind(M.config.key, function(ctx)
      M.toggle(ctx or {})
      return true
    end)
  end
end

return M
