# Installing reviewr.nvim (for coding agents)

You are a coding agent asked to install reviewr.nvim for your user. Do every
step that applies, check each one, and report what you changed. Ask before
editing a config the user keeps under version control in a way they might not
expect, and never overwrite an existing file; add to it.

Repository: https://github.com/paul-enz/reviewr.nvim. Requirements: Neovim 0.10
or later, and git.

## 1. Add the plugin to Neovim

Find the user's plugin manager in their Neovim config (`nvim --headless -c
'lua io.stdout:write(vim.fn.stdpath("config") .. "\n")' +qa`).

With lazy.nvim, add a spec file next to their other plugin specs, matching their
style:

```lua
return {
  "paul-enz/reviewr.nvim",
  cmd = { "ReviewrOpen", "ReviewrScope", "ReviewrComment", "ReviewrTurn", "ReviewrExport", "ReviewrClear" },
  opts = {},
}
```

Then install it: `nvim --headless "+Lazy! install reviewr.nvim" +qa`.

With another manager, add `paul-enz/reviewr.nvim` the way that manager expects
and call `require("reviewr").setup({})` after it loads.

Check: `nvim --headless -c 'lua io.stdout:write(tostring(pcall(require, "reviewr")) .. "\n")' +qa`
prints `true`.

## 2. Install the agent skill

`skills/reviewr-nvim/SKILL.md` teaches agents to open reviews for the user and
act on the comments that come back. Link it into your own skills directory from
the installed plugin, so it updates with the plugin:

```sh
plugin=$(nvim --headless -c 'lua io.stdout:write(vim.fn.stdpath("data") .. "/lazy/reviewr.nvim\n")' +qa)
ln -s "$plugin/skills/reviewr-nvim" ~/.claude/skills/reviewr-nvim   # Claude Code
```

Other agents: link or copy the directory into wherever that agent loads skills
from. If the agent has no skills, add the file's contents to its instructions.

## 3. Rex integration (only if the user runs Rex)

Rex is in use when `rex` is on the PATH and `~/.config/rex/init.lua` exists.
The integration binds cmd+r to open a review of the focused terminal's branch
(against the default branch) in a split to its right.

```sh
ln -s "$plugin/rex/reviewr" ~/.config/rex/reviewr
```

Add to `~/.config/rex/init.lua`, after any existing `require` lines:

```lua
require("reviewr").setup()   -- or setup({ key = "ctrl+a>r" }) to pick another key
```

Check the key is free first (`rex keymap`), then `rex config check` and
`rex config reload`. `rex keymap` should list the key with source
`reviewr/init.lua`.

## 4. Verify

From the plugin directory: `nvim --headless -u NONE -l tests/run.lua` ends with
`0 failed`. Then open a review the way the skill describes, on any repository
with changes, and confirm the pane shows `changed files (N)`.
