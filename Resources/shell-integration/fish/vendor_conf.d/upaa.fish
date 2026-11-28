# upaa puts its directory first in XDG_DATA_DIRS, so fish loads this file before the user's own config, as in Ghostty's
# fish integration. It puts XDG_DATA_DIRS back, and in an interactive shell marks the prompt for the terminal with
# OSC 133: A where the prompt starts, C where the command's output starts. With the marks, libghostty-vt clears the
# prompt when the width changes instead of rewrapping it, so fish redraws it in place (issue #69). fish 4 marks the
# prompt itself, but A also has to say redraw=1 for the C API, as for zsh.

if set -q UPAA_XDG_DATA_DIRS
    set -gx XDG_DATA_DIRS $UPAA_XDG_DATA_DIRS
    set -e UPAA_XDG_DATA_DIRS
else
    set -e XDG_DATA_DIRS
end

status is-interactive; or exit

function __upaa_prompt --on-event fish_prompt
    # Tells upaa how many jobs the shell has, running or stopped, with its own OSC 7385 (#62), so it asks before
    # closing the pane would end them. A job disowned with disown is not one.
    printf '\e]7385;jobs=%s\a\e]133;A;redraw=1\a' (count (jobs --group 2>/dev/null))
end

function __upaa_output --on-event fish_preexec
    printf '\e]133;C\a'
end
