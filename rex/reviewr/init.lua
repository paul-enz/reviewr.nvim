-- Rex integration for reviewr.nvim: a key that opens a review of the focused
-- terminal's repository in a split to its right.
local M = {}

local TERMINAL = "com.superlogical.terminal"

M.config = {
  key = "cmd+r",
  -- run in the new Neovim; the branch scope diffs the current branch against
  -- its merge base with the default branch (origin/HEAD, else main or master)
  command = "ReviewrScope branch",
  nvim = "nvim",
  -- the share of the row the focused terminal keeps
  ratio = 0.4,
}

local function cwd_of(session_id, block_id)
  local ok, proc = pcall(rex.call, "block.method",
    { session_id = session_id, block_id = block_id, method = "process" })
  local fg = ok and type(proc) == "table" and proc.foreground or nil
  return fg and fg.cwd or ""
end

function M.open(ctx)
  local session_id = ctx.session_id or rex.session_id
  local block_id = ctx.block_id or rex.block_id
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
        label = "review",
        options = {
          command = { M.config.nvim, "-c", M.config.command },
          cwd = cwd_of(session_id, block_id),
        },
      },
    },
  })
end

function M.setup(opts)
  for k, v in pairs(opts or {}) do M.config[k] = v end
  rex.action({
    name = "reviewr_open",
    title = "Review this branch",
    run = function(ctx) return M.open(ctx or {}) end,
  })
  if M.config.key then
    rex.bind(M.config.key, function(ctx)
      M.open(ctx or {})
      return true
    end)
  end
end

return M
