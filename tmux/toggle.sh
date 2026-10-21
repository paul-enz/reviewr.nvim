#!/bin/sh
# Shows or hides the review beside a pane. Pressed in a review, hides it.
# Pressed elsewhere: hides the review in this window, else brings back the
# hidden review of the pane's repository, else opens one. Hidden reviews keep
# running, comments and all, in the background session "reviewr".
pane=$1
hidden=reviewr

command=$(tmux show -gqv @reviewr-command)
command=${command:-"nvim -c 'lua vim.g.reviewr_standalone = true' -c 'ReviewrScope branch'"}
size=$(tmux show -gqv @reviewr-size)
size=${size:-60%}

path=$(tmux display -p -t "$pane" '#{pane_current_path}')
repo=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$path")
window=$(tmux display -p -t "$pane" '#{window_id}')

# reviews are panes carrying @reviewr, the repository they review
reviews() {
  tmux list-panes "$@" -F '#{pane_id}	#{@reviewr}' 2>/dev/null | awk -F '\t' '$2 != ""'
}

hide() {
  if ! tmux has-session -t "=$hidden" 2>/dev/null; then
    tmux new-session -d -s "$hidden" -n hold 'tail -f /dev/null'
  fi
  tmux break-pane -d -s "$1" -t "=$hidden:"
}

if [ -n "$(tmux show -pqv -t "$pane" @reviewr)" ]; then
  hide "$pane"
  exit 0
fi

placed=$(reviews -t "$window" | head -n 1 | cut -f 1)
if [ -n "$placed" ]; then
  hide "$placed"
  exit 0
fi

parked=$(reviews -s -t "=$hidden" | awk -F '\t' -v repo="$repo" '$2 == repo { print $1; exit }')
if [ -n "$parked" ]; then
  tmux join-pane -h -l "$size" -s "$parked" -t "$pane"
  tmux select-pane -t "$parked"
  exit 0
fi

new=$(tmux split-window -h -l "$size" -c "$path" -t "$pane" -P -F '#{pane_id}' "$command")
tmux set -p -t "$new" @reviewr "$repo"
# closing the review quits its Neovim; the pane goes with it
tmux set -p -t "$new" remain-on-exit off
