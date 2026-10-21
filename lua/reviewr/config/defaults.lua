local M = {}

M.defaults = {
  name = "reviewr",
  debug = false,
  log_level = "info", -- debug|info|warn|error
  log_file = nil, -- nil => stdpath('log')/reviewr.log when debug
  baseline_trigger = "open", -- open|first_comment|manual
  send_mode = "queue", -- queue|submit
  private_ref_prefix = "refs/reviewr",
  git = {
    timeout_ms = 20000,
    use_plenary = true,
  },
  keymaps = true, -- false to skip, or a table of key overrides
  adapters = { "neovim-terminal", "tmux", "rex", "wezterm", "filesystem-inbox" },
}

return M
