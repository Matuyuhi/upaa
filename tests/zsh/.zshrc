# The prompt for the resize test in core/src/term/Session.zig: a first line that fills the width, as powerlevel10k's
# does ("left", dashes, "right"), set from a precmd hook as themes do, and "> " on the second line.
unset HISTFILE
setopt prompt_subst
_test_theme() { PROMPT=$'left${(pl.$((COLUMNS-10))..-.)}right\n> ' }
precmd_functions+=(_test_theme)
