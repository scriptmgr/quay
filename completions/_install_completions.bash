#!/usr/bin/env bash
# Bash completion for install.sh

_install() {
  local cur prev
  local SHORTOPTS="-h -v"
  local LONGOPTS="--help --version --color --debug --remove"
  local COLOR_VALUES="auto yes no"

  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"

  # Complete --color= with values
  if [[ "$cur" == --color=* ]]; then
    local prefix="${cur#--color=}"
    COMPREPLY=($(compgen -W "$COLOR_VALUES" -- "$prefix"))
    return 0
  fi

  # Handle long options
  if [[ "$cur" == --* ]]; then
    COMPREPLY=($(compgen -W "$LONGOPTS" -- "$cur"))
    return 0
  fi

  # Handle short options
  if [[ "$cur" == -* ]]; then
    COMPREPLY=($(compgen -W "$SHORTOPTS" -- "$cur"))
    return 0
  fi

  return 0
}

complete -F _install install install.sh
