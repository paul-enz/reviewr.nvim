# reviewr.nvim

A multiplexer-agnostic Neovim plugin that brings [herdr-reviewr](https://github.com/persiyanov/herdr-reviewr)-style code review to Neovim: open a diff of two branches, comment on lines or ranges, and send the whole review to a running coding agent (Claude Code, Codex, OpenCode, Aider, …) — entirely from inside Neovim.

![reviewr.nvim reviewing a branch. Captured from a live Neovim session: the feature pane carries two line comments, each on its own line above the change, and the footer says the next step.](assets/screenshot.png)

![Every key, behind `?`.](assets/keys.png)

![Adding a comment. `c` opens a small box over the other pane, and the lines being commented are highlighted on the right. `:w` saves, `<esc>` cancels.](assets/comment.png)

## Features

- A review tab of its own: side-by-side native Vim diff (`]c`/`[c`, folds) over a **changed-files panel** along the bottom, like an octo.nvim review
- Scopes: uncommitted, staged, branch (against the merge base), and **turn** — what changed since the last turn baseline
- Line comments on a line or range, anchored by identity (file, side, start, end) — never row index
- In-memory comment store by design (ephemeral; close drops unsent comments)
- All-or-none export: clipboard, agent send, or filesystem inbox
- Mux-agnostic send to a running agent: Neovim `:terminal` → tmux → Rex → WezTerm → inbox → clipboard
- Private `refs/reviewr/*` baselines only; never mutates worktree/index/branches
- Configurable keymaps, events (`User Reviewr…`), leveled logging
- Runs from the shell: `nvim -d …` or `:ReviewrOpen`

## Requirements

- Neovim ≥ 0.10
- git
- Optional: `plenary.nvim` for async jobs

## Install

Point your coding agent at this repository and ask it to install reviewr.nvim. [INSTALL.md](INSTALL.md) is written for agents: it adds the plugin to Neovim, installs the agent skill (`skills/reviewr-nvim`) so the agent can open reviews for you and act on the comments, and sets up the Rex key binding when you use Rex.

By hand, with lazy.nvim:

```lua
{
  "paul-enz/reviewr.nvim",
  cmd = { "ReviewrOpen", "ReviewrScope", "ReviewrComment", "ReviewrTurn", "ReviewrExport", "ReviewrClear" },
  opts = {},
}
```

## Rex

`rex/reviewr` is a Rex config module. Linked into `~/.config/rex/reviewr` and enabled with `require("reviewr").setup()` in `~/.config/rex/init.lua`, it binds cmd+r: a review of the focused terminal's current branch, against the default branch, opens in a split to its right. `setup({ key = "...", command = "ReviewrOpen" })` changes the key or what is reviewed.

## Shell usage

```sh
# raw diff (no comment plumbing)
nvim -d <(git show HEAD:file.txt) <(git show feature:file.txt)

# integrated review session
nvim -c 'cd /path/repo' -c 'ReviewrOpen HEAD feature'
```

## Commands

| Command | Description |
|---|---|
| `:ReviewrOpen [base] [head] [label]` | open a review; no args reviews uncommitted changes, `{base} {head}` diffs head against its merge base with base |
| `:ReviewrScope {scope}` | switch scope: `uncommitted`, `staged`, `branch` (default branch...HEAD), `turn` |
| `:[range]ReviewrComment {text}` | comment on the current line or range |
| `:ReviewrTurn` | snapshot the working tree as the turn baseline |
| `:ReviewrExport {clipboard\|send\|inbox}` | export all comments (all-or-none) |
| `:ReviewrClear` | clear comments |

## Keys

The bar above the change pane always shows the next step. `?` lists every key.

| Key | Action |
|---|---|
| `c` | comment on the current line, or the visual selection |
| `e` | edit the comment under the cursor |
| `d` | delete the comment under the cursor |
| `n` / `N` | next / previous comment |
| `s` | send every comment to the running agent |
| `y` | copy every comment |
| `l` | list comments |
| `]c` / `[c` | next / previous change |
| `f` / `F` | next / previous changed file |
| `r` | reread the changes from git and the working tree |
| `?` | all keys |
| `q` | close; asks first when comments are unsent |

In the changed-files panel, `<CR>` opens the file under the cursor and `q` closes the review.

All buffer-local and remappable through the `keymaps` option or `require("reviewr.keymaps").set_defaults()`.

## Agents

`s` pastes the review into a running agent (`claude`, `codex`, `opencode`, `aider`, `goose`, `cline`, `pi`). It looks in:

1. Neovim `:terminal`s whose processes include an agent;
2. tmux panes in the repo running an agent (inside tmux);
3. Rex terminals running an agent: any terminal in Neovim's own Rex session, and terminals in other sessions working in the repo (inside Rex);
4. WezTerm panes in the repo running an agent (inside WezTerm).

With one agent found it sends straight away; with several, a picker lists them, the likeliest first, with each terminal's title. With none it writes the inbox file, and failing that copies to the clipboard. The `adapters` option limits which of these are tried.

## Agent send protocol

Sends a stable envelope:

```
@@REVIEW_BEGIN v1
id: <nonce>
source: reviewr.nvim
repo: /abs/path
file: path/relative        (only when every comment is on one file)
range: 42-88               (only for a single comment)
created: ISO8601
format: markdown
---
### path/relative:42-88 (right)
<comment>

@@REVIEW_END
```

Default delivery is **queue** (pasted into the agent input, no Enter); set `send_mode = "submit"` to also submit. Filesystem inbox writes the same envelope to `<repo>/.reviewr/inbox/`, which git ignores.

## Configuration

```lua
require("reviewr").setup({
  baseline_trigger = "open",   -- open | first_comment | manual
  log_level = "info",
  send_mode = "queue",         -- queue | submit
  private_ref_prefix = "refs/reviewr",
  keymaps = true,              -- false, or a table such as { send = "S" }
  adapters = { "neovim-terminal", "tmux", "rex", "wezterm", "filesystem-inbox" },
})
```

## Testing

```sh
nvim --headless -u NONE -l tests/run.lua
```

## License

MIT
