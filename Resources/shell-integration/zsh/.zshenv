# upaa starts zsh with ZDOTDIR set to this directory, so zsh reads this file first. It puts the user's ZDOTDIR back
# (zsh then reads their .zprofile, .zshrc and .zlogin as usual), reads their .zshenv, and in an interactive shell
# loads upaa-integration.zsh.
#
# This file can be read with aliases on, so the builtins are quoted.
if [[ -n ${UPAA_ZDOTDIR+x} ]]; then
  'builtin' 'export' ZDOTDIR="$UPAA_ZDOTDIR"
  'builtin' 'unset' UPAA_ZDOTDIR
else
  'builtin' 'unset' ZDOTDIR
fi
{
  [[ ! -r ${ZDOTDIR:-$HOME}/.zshenv ]] || 'builtin' 'source' -- "${ZDOTDIR:-$HOME}/.zshenv"
} always {
  # ${(%):-%x} is this file; :A:h its directory.
  [[ ! -o interactive ]] || 'builtin' 'source' -- "${${(%):-%x}:A:h}/upaa-integration.zsh"
}
