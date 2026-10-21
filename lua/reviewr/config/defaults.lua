local M = {}

M.defaults = {
  name = "reviewr",
  debug = false,
  log_level = "info", -- debug|info|warn|error
  log_file = nil, -- nil => stdpath('log')/reviewr.log when debug
  baseline_trigger = "auto", -- auto|open|agent|first_comment|manual
  focus_agent = true, -- bring the agent's terminal forward after sending
  refresh_on_agent = true, -- reload the review when a watched agent finishes
  send_mode = "queue", -- queue|submit
  private_ref_prefix = "refs/reviewr",
  git = {
    timeout_ms = 20000,
  },
  keymaps = true, -- false to skip, or a table of key overrides
  adapters = { "neovim-terminal", "tmux", "rex", "wezterm", "filesystem-inbox" },
  -- programs that count as agents, matched by executable name
  agents = { "claude", "codex", "opencode", "aider", "goose", "cline", "pi" },
}

return M
