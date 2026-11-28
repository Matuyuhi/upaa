# The prompt for the fish resize test in core/src/term/Session.zig: a first line that fills the width ("left", dashes,
# "right"), as in tests/zsh/.zshrc, and "> " on the second line.
set -g fish_greeting
set -g fish_history ''
function fish_prompt
    printf 'left%sright\n> ' (string repeat -n (math $COLUMNS - 10) -)
end
