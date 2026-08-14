# sourced by demo.tape so the tape never has to type shell metacharacters.
# `crew <args...>` routes to the canned-output script (no tmux/CCR/network).
crew(){ bash scripts/demo.sh "$@"; }
clear
