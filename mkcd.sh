#!/usr/bin/env bash
mkdir "$@"
cd "${@: -1}" || exit

if [ -r /proc/$$/exe ]; then
  exec "$(readlink /proc/$$/exe)"
elif command -v lsof >/dev/null 2>&1; then
  exec "$(lsof -p $$ -Fn | awk 'NR>1 && /^n\//{print substr($0,2); exit}')"
else
  exec "$SHELL"
fi
