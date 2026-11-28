# The prompt for the bash resize test in core/src/term/Session.zig: one line that fills the width but the last column
# ("left", dashes, "right"), set from PROMPT_COMMAND as themes do. bash redraws only a prompt's last line, so a prompt
# of one line is the one bash 5.2 leaves behind when the width changes.
unset HISTFILE
_test_theme() {
  local dashes
  printf -v dashes '%*s' $((COLUMNS - 10)) ''
  PS1="left${dashes// /-}right"
}
PROMPT_COMMAND=_test_theme
