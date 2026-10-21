---
name: reviewr-nvim
description: Open a reviewr.nvim code review in Neovim for the user — a branch, two refs, staged or uncommitted changes — beside the agent's terminal, drive a review that is already open, and act on the review comments the plugin pastes back. Use when the user asks to review, diff or look over changes in Neovim, to "open the reviewer", or to compare branches, and when a message arrives wrapped in @@REVIEW_BEGIN / @@REVIEW_END.
---

# reviewr.nvim

reviewr.nvim opens a review in a Neovim tab: the base on the left, the change on
the right, and every changed file in a panel along the bottom. The user comments
on lines; `s` pastes all comments into a running agent's input as one envelope.
You open reviews for the user and act on what comes back. The user does the
reviewing.

## Check it is installed

```sh
nvim --headless -c 'lua io.stdout:write(tostring(pcall(require, "reviewr")) .. "\n")' +qa
```

`false` means it isn't installed: offer the install in this repository's
`INSTALL.md` (https://github.com/paul-enz/reviewr.nvim) instead of improvising.

## Pick what to review

| The user wants | Neovim command |
|---|---|
| everything on the current branch, committed or not, against the default branch (the usual "review my branch") | `ReviewrScope branch` |
| the working tree against `main` | `ReviewrOpen main` |
| `feature` against `main` | `ReviewrOpen main feature` |
| uncommitted changes | `ReviewrOpen` |
| one commit | `ReviewrScope commit <sha>` |
| what is staged | `ReviewrScope staged` |
| what you (or another agent) changed in your last turn | `ReviewrScope turn` |

In Rex the plugin watches the agents it can see: when one starts working, it
snapshots the turn baseline, and when it stops, the open review reloads. So
after you finish addressing a review, `ReviewrScope turn` in the user's open
review shows exactly your changes; suggest it rather than a branch diff.

`ReviewrOpen {base} {head}` diffs `head` against its merge base with `base`, the
way a pull request does, so commits that landed on `base` later don't show.
Working-tree reviews (no head ref: `branch`, `uncommitted`, `turn`, `ReviewrOpen main`) include uncommitted edits to tracked files and new files once they are `git add`ed (untracked files never appear); a review with two refs compares commits only.
Resolve the user's words to real refs first (`git branch -a`,
`git rev-parse --verify <ref>`), and ask when a name matches nothing or several
things. "No changes found" with an empty Neovim means the pair has no diff;
say so rather than retrying.

## Open it beside you

Run Neovim in the repository's directory, so the plugin finds the repo.

In Rex (`REX_SESSION` is set), split to the right of your own terminal:

```sh
rex split -s "$REX_SESSION" -b "$REX_BLOCK" --split=right --ratio 60 -c "$repo" -- \
  nvim -c 'ReviewrOpen main feature'
```

Save the block ID it prints (`--json`, `.block_ids[0]`). With the Rex
integration installed, the user toggles a review with cmd+r: it opens
`ReviewrScope branch` beside the focused terminal, hides it (the block is
detached but keeps running, comments and all), and shows it again. Pressed in an
agent's terminal, cmd+r pairs the review with that agent (block label
`review:<agent block>`, `vim.g.reviewr_agent` inside Neovim): `s` sends to it
and the turn view follows only its turns. Unpaired reviews are labelled
`review`. Before opening one, look for a `review` block of
the same repository in `rex api call session.list_blocks '{"session_id": "'"$REX_SESSION"'"}'`:
if it is detached, show it with `session.move_block` beside your terminal
rather than opening a second review.

In tmux: `tmux split-window -h -c "$repo" "nvim -c 'ReviewrOpen main feature'"`.
Elsewhere, give the user the command to run.

Check that it opened: capture the pane (`rex capture -s "$REX_SESSION" -b "$block" --trim`)
and look for `changed files (N)`.

## Drive a review that is already open

Find the Neovim pane (in Rex, `rex block ls` and the block's `process` method
shows `nvim` in the foreground) and type an Ex command into it; the open review
tab switches in place and keeps its comments:

```sh
rex send-key -s "$REX_SESSION" -b "$block" escape
rex send -s "$REX_SESSION" -b "$block" ':ReviewrOpen main other-branch'
rex send-key -s "$REX_SESSION" -b "$block" enter
```

Never close the review (`q`, `:q`, `:qa`, closing the pane): comments are kept
only in memory and closing drops the user's unsent ones. Don't press the review
keys (`c`, `d`, `s`, …) for the user unless asked; they comment, delete and send
in the user's name.

## Act on a review

A review arrives in your input as:

```
@@REVIEW_BEGIN v1
source: reviewr.nvim
repo: /abs/path
...
---
### path/to/file.lua:42-48 (right)
comment text

### other.lua:7-7 (left)
comment text
@@REVIEW_END
```

Each `###` heading is one comment: the file relative to `repo`, the line range,
and the side. `right` lines number the change (the head or working tree);
`left` lines number the base, so read `git show <base>:<file>` to see what they
point at. Address every comment, or say why one shouldn't be acted on.
