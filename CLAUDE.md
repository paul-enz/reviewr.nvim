# reviewr.nvim

Neovim review tab (base | change | changed-files panel) whose comments go to a
coding agent; `rex/reviewr/init.lua` is the Rex half (cmd+r). The maintainer
uses Rex, not herdr. Keep the decisions below unless the maintainer changes
them.

## Settled decisions

**What a review shows**
- Diffs cover git-tracked files only: commits, edits to tracked files, and new
  files once `git add`ed. Untracked files never appear.
- Working-tree diffs compare against a snapshot built in a temporary copy of the
  index with `git add -u`. Never touch the real index, worktree or user refs;
  the plugin's only git writes are private `refs/reviewr/*` refs.
- `branch` = the working tree (commits and uncommitted tracked edits) against
  its merge base with the default branch (`origin/HEAD`, else main/master) or
  the base picked with `gb`. Two refs (`:ReviewrOpen a b`) compare commits only.
- `commit` shows one commit against its parent (empty tree for a root commit).
- With nothing to review the tab still opens, says so, and keeps its keys;
  outside a git repository it doesn't open.
- A comment records what its side showed (`working tree`, `index` or a commit
  id) and shows only in views of that content.
- The agent gets plain text: "Code review comments from my editor:", numbered
  items (`file:range`, up to three quoted lines from the content commented on,
  `Comment:`), then "Make the requested changes and answer any questions.
  Reply per item." No markers, metadata, sides or version tags.
- Every export carries every comment; a successful one marks them sent. Close
  asks only while some are unsent (new, or edited since).

**Agents**
- An agent is recognised by the processes on its terminal (Rex `process`, `ps -t`),
  never by substring or by Neovim's own pane. Pastes are bracketed; the default
  never presses Enter (`send_mode = "queue"`).
- cmd+r in an agent's Rex pane pairs the review with it (label
  `review:<agent block>`, `vim.g.reviewr_agent`): `s` sends straight to it, `S`
  always offers the picker, its turn baseline is its own (`turn-<agent block>`),
  and only its turns move or refresh it.
- A turn starts when the agent goes from idle to working/blocked (snapshot the
  baseline) and ends when it leaves both (reload the review).
- Assume one git worktree per agent. Agents sharing a working copy see each
  other's edits in their turn views; that is accepted, don't engineer around it.
- With several agents and no pairing, show the picker, likeliest first.

**Rex**
- cmd+r toggles: in a review it hides it (`session.detach_block`, Neovim keeps
  running with its comments), in an agent's pane it shows/hides that agent's
  review, elsewhere one unpaired review per repo per window.
- Neovims started by cmd+r carry `vim.g.reviewr_standalone`; closing the review
  quits them so the pane closes.
- The Rex module is loaded from Neovim's managed copy with a `pcall`-guarded
  `dofile` (same pattern as vim-rex-navigator). Never an unguarded `require` or
  `dofile` in Rex's `init.lua`: a Lua error there drops every later binding.
  Rex doesn't watch files; `rex config reload` after the module changes.
- Copies also go out as OSC 52 inside Rex or over SSH.

**tmux**
- `tmux/reviewr.tmux` binds `prefix R` and user key `ESC [9001~` (what a
  terminal sends for cmd+r) to `tmux/toggle.sh`, loaded from Neovim's managed
  copy behind an `if-shell` guard. Reviews are panes carrying `@reviewr`
  (their repository); hidden ones wait in the background session `reviewr`.
  One review per window; unpaired.

**UI**
- Prompts and pickers are small boxes (`ui.confirm`, `ui.pick`): selection
  highlighted, j/k or arrows, Enter, Esc. Never `vim.ui.select`, `vim.ui.input`
  or numbered lists. Close asks once, Yes preselected.
- Keys follow herdr-reviewr unless they would take a Vim motion: `u` `b` `t`
  switch views; pickers are `gc` (commit) and `gb` (base), not `g`/`G`.
- The hint lives in the change pane's winbar (lualine owns statuslines). The two
  diff panes stay equal width. Marks that must show over diff colours go in the
  gutter (sign / number highlight), since diff highlighting hides line highlights.

## Working on this repo

- Test: `nvim --headless -u NONE -l tests/run.lua`. Add a spec with each
  behaviour change: spec behaviour and crash classes, not implementation details.
- Also check UI changes live in Rex under the maintainer's full config: some
  failures only show there (closing a tab of diff windows whose buffers wipe
  segfaulted Neovim 0.12; hence `diffoff!` before `tabclose`). Use a separate
  Rex tab, close what you open, and don't touch the maintainer's panes or
  reviews that hold comments.
- Keep `README.md`, `doc/reviewr.txt`, `INSTALL.md` (written for agents) and
  `skills/reviewr-nvim/SKILL.md` in step with behaviour. Refresh the README
  screenshots when the UI they show changes.
- Land every change as: branch, PR, rebase-merge yourself, delete the branch,
  then `nvim --headless "+Lazy! update reviewr.nvim" +qa` (bumps
  `~/.config/nvim/lazy-lock.json`) and `rex config reload` if `rex/` changed.
  Open reviews keep old code until reopened.
- Commits use the configured git identity, end-state messages, no
  Claude attribution. User-facing copy (descriptions, prompts) has no em dashes.

## Screenshots and the demo GIF

Captured from a live review, not mocked: a demo repo with a feature branch,
Neovim started with `-u` a minimal init (this plugin, gruvbox, `laststatus=0`,
`showtabline=0`, statusline drawn as a `─` rule, soft `Diff*` and `SignColumn`
highlights), in a hidden Rex tab resized to 150×36. Export each state with
`rex block call <block> format '{"format":"html"}'`, wrap `.content` in a page
(Menlo 13px/17px, body background = Normal bg) and render with headless Chrome
at `--force-device-scale-factor=2`.

`assets/demo.gif` is recorded the same way, from Claude Code in a throwaway
copy of the demo repo: a recorder saves both blocks' HTML about three times a
second while a script triggers the Rex key handler for Claude's block
(`rex do` running the module's `toggle`), comments with `c` and `:w`, sends
with `s` and submits with Enter. Each frame lays Claude's pane (60 columns) and
the review (100) side by side, headless Chrome renders it, and ffmpeg joins
the frames at their recorded timings. Run the review Neovim with
`focus_agent = false`, so sending doesn't bring the hidden tab forward.
