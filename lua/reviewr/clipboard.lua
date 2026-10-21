-- reviewr.clipboard: copy to the user's clipboard, even when Neovim runs on
-- another machine: in Rex or over SSH the text also goes out as OSC 52, which
-- the terminal (Rex forwards it to the app) puts on the local clipboard.
local M = {}

function M.copy(text)
  pcall(vim.fn.setreg, "+", text)
  vim.fn.setreg('"', text)
  if vim.env.REX_SESSION or vim.env.SSH_TTY or vim.fn.has("clipboard") == 0 then
    pcall(function()
      require("vim.ui.clipboard.osc52").copy("+")(vim.split(text, "\n", { plain = true }))
    end)
  end
end

return M
