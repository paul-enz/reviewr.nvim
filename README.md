# reviewr.nvim

A multiplexer-agnostic Neovim plugin that brings [herdr-reviewr](https://github.com/persiyanov/herdr-reviewr)-style code review to Neovim: open a diff of two branches, comment on lines or ranges, and send the whole review to a running coding agent (Claude Code, Codex, OpenCode, Aider, …) — entirely from inside Neovim.

![reviewr.nvim reviewing a branch. Captured from a live Neovim session: the feature pane carries two line comments, each on its own line above the change, and the footer says the next step.](assets/screenshot.png)

![Every key, behind `?`.](assets/keys.png)

![Adding a comment. `c` on a line, or a visual selection, opens a buffer in the other pane. `:w` saves it, `<esc>` cancels.](assets/comment.png)

## Features

- Four diff scopes: uncommitted, staged, branch, commits, plus a private-ref **last turn** baseline
- Unified/split native Vim diff (`:diffthis`, `]c`/`[c`, folds)
- Line comments on a line or range, anchored by identity (file, side, start, end) — never row index
- In-memory comment store by design (ephemeral; close loses unsent comments)
- All-or-none export: clipboard, agent send, or filesystem inbox
- Mux-agnostic send: Neovim `:terminal` → tmux / WezTerm / Kitty → process-tree scan → clipboard/inbox fallback
- Private `refs/reviewr/*` baselines only; never mutates worktree/index/branches
- Configurable keymaps, events (`User Reviewr…`), leveled logging
- Runs from the shell: `nvim -d …` or `:ReviewrOpen`

## Requirements

- Neovim ≥ 0.9
- git
- Optional: `plenary.nvim` for async jobs

## Install (lazy.nvim)

```lua
{
  "paul-enz/reviewr.nvim",
  config = function()
    require("reviewr").setup({})
  end,
}
```

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
| `:ReviewrOpen {base} {head} [scope]` | open diff + review session |
| `:ReviewrScope {scope}` | switch scope (uncommitted/staged/branch/commits) |
| `:ReviewrComment` | add comment on selection |
| `:ReviewrTurn` | mark a new turn baseline |
| `:ReviewrExport {clipboard\|send\|inbox}` | export all comments (all-or-none) |
| `:ReviewrClear` | clear comments |

## Keys

The footer always shows the next step. `?` lists every key.

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
| `r` | refresh the diff |
| `?` | all keys |
| `q` | close; asks first when comments are unsent |

All buffer-local and remappable via `require("reviewr.keymaps").set_defaults()`.

## Agent send protocol

Sends a stable envelope:

```
@@REVIEW_BEGIN v1
id: <nonce>
source: reviewr.nvim
repo: /abs/path
file: path/relative
range: 42-88
created: ISO8601
format: markdown
---
<body>
@@REVIEW_END
```

Default delivery is **queue** (pasted into the agent input, no Enter); set `send_mode = "submit"` to also submit. Filesystem inbox writes the same envelope to `<repo>/.reviewr/inbox/`.

## Configuration

```lua
require("reviewr").setup({
  baseline_trigger = "open",   -- open | first_comment | manual | bufwrite
  log_level = "info",
  send_mode = "queue",         -- queue | submit
  private_ref_prefix = "refs/reviewr",
  keymaps = true,
})
```

## Testing

```sh
nvim --headless -u NONE -c 'set rtp+=/path/reviewr.nvim' -c 'lua require("reviewr").setup({})' -c 'q'
```

## License

MIT
