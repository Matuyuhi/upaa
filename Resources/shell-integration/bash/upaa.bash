# upaa starts a bash login shell in POSIX mode with ENV set to this file, so bash reads this file alone at startup, as
# in Ghostty's bash integration. It leaves POSIX mode, puts the user's ENV back, and reads the files a login shell reads.
# Then it marks the prompt for the terminal with OSC 133: A where the prompt starts, B where the typed command starts,
# C where the command's output starts. With the marks, libghostty-vt clears the prompt when the width changes instead
# of rewrapping it, so readline redraws it in place (issue #69). bash redraws only the last line of a prompt, so A says
# redraw=last, and the C API needs it said, as for zsh.

if [[ -n ${UPAA_ENV+x} ]]; then
  builtin export ENV="$UPAA_ENV"
  builtin unset UPAA_ENV
else
  builtin unset ENV
fi
builtin set +o posix
# POSIX mode turns this on, and set +o posix leaves it on.
builtin shopt -u inherit_errexit 2>/dev/null
# In POSIX mode, bash 5.2 and later keep the history in ~/.sh_history, unless the user set HISTFILE themselves.
if [[ $HISTFILE == "$HOME/.sh_history" && $(builtin declare -p HISTFILE) != "declare -x"* ]]; then
  HISTFILE=$HOME/.bash_history
fi

[[ ! -r /etc/profile ]] || builtin source /etc/profile
for _upaa_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  if [[ -r $_upaa_file ]]; then
    builtin source "$_upaa_file"
    break
  fi
done
builtin unset _upaa_file

# PS0, where C goes, came in bash 4.4.
(( BASH_VERSINFO[0] > 4 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4 )) || builtin return 0

_upaa_prompt() {
  builtin local status=$?
  # Tells upaa how many jobs the shell has, running or stopped, with its own OSC 7385 (#62), so it asks before closing
  # the pane would end them. A job disowned with disown is not one.
  builtin local pids newlines jobs=0
  pids=$(builtin jobs -pr; builtin jobs -ps)
  newlines=${pids//[!$'\n']/}
  [[ -z $pids ]] || jobs=$(( ${#newlines} + 1 ))
  builtin printf '\e]7385;jobs=%s\a\e]133;A;redraw=last\a' "$jobs"
  # Mark PS1 as it is now: the unmarked one from last time, or what a theme just set. The marks in PS1 use P, not A,
  # since readline writes them again each time it redraws, and A would move to a fresh line. Each line after the
  # first is marked too, since bash does not redraw it.
  [[ $PS1 != "$_upaa_marked_ps1" ]] || PS1=$_upaa_ps1
  _upaa_ps1=$PS1
  builtin local newline='\n' next='\n\[\e]133;P;k=s\a\]'
  PS1='\[\e]133;P;k=i\a\]'${PS1//"$newline"/"$next"}'\[\e]133;B\a\]'
  _upaa_marked_ps1=$PS1
  [[ $PS0 == *'\e]133;C\a'* ]] || PS0+='\e]133;C\a'
  builtin return "$status"
}

# Last, after the user's own commands, as themes set PS1 in theirs. 2>/dev/null keeps a bash started inside this one,
# which may take an exported PROMPT_COMMAND without the function, from complaining at each prompt.
if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
  PROMPT_COMMAND+=('_upaa_prompt 2>/dev/null')
else
  PROMPT_COMMAND=${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}'_upaa_prompt 2>/dev/null'
fi
