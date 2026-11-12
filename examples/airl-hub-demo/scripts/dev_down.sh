#!/usr/bin/env bash
# Остановить локальный запуск (scripts/dev_up.sh).
cd "$(dirname "$0")/.." || exit 1
for f in .run/*.pid; do
  [ -f "$f" ] || continue
  kill "$(cat "$f")" 2>/dev/null && echo "остановлен $(basename "$f" .pid)"
  rm -f "$f"
done
