#!/bin/sh
# tmux integration for reviewr.nvim: a key that shows a review beside the
# current pane and hides it again. Load it from tmux.conf:
#   run-shell '<plugin>/tmux/reviewr.tmux'
#
# Options, set before the run-shell line:
#   @reviewr-key       prefix key (default R)
#   @reviewr-user-key  user-keys slot for the cmd+r sequence (default 9)
#   @reviewr-command   what the review pane runs
#   @reviewr-size      the review pane's share of the row (default 60%)
dir=$(cd "$(dirname "$0")" && pwd)

key=$(tmux show -gqv @reviewr-key)
slot=$(tmux show -gqv @reviewr-user-key)

# A terminal sends this sequence for a key tmux can't see, such as cmd+r on
# macOS (see the README for Ghostty, kitty, WezTerm and iTerm2).
tmux set -s "user-keys[${slot:-9}]" "$(printf '\033[9001~')"
tmux bind-key -n "User${slot:-9}" run-shell -b "sh '$dir/toggle.sh' '#{pane_id}'"
tmux bind-key "${key:-R}" run-shell -b "sh '$dir/toggle.sh' '#{pane_id}'"
