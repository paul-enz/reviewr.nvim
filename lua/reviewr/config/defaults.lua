local M = {}

M.defaults = {
  name = "reviewr",
  debug = false,
  log_level = "info", -- debug|info|warn|error
  log_file = nil, -- nil => stdpath('log')/reviewr.log when debug
  baseline_trigger = "open", -- open|first_comment|manual|bufwrite
  ephemeral = true,
  private_ref_prefix = "refs/reviewr",
  comment = {
    context_lines = 3,
  },
  git = {
    timeout_ms = 20000,
    use_plenary = true,
  },
  keymaps = true,
  adapters = { "neovim-terminal", "filesystem-inbox", "generic-clipboard" },
}

return M
