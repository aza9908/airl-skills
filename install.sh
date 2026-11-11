#!/bin/bash
# Установка навыков AIRL. Запуск: bash install.sh
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/skills"

mkdir -p "$DEST"
cp -R "$SRC/skills/." "$DEST/"
find "$DEST" -path "*/airl-*/scripts/*" -type f -exec chmod +x {} + 2>/dev/null || true

NAMES=$(ls "$SRC/skills" | tr '\n' ' ')

echo ""
echo "Готово. Установлены навыки: $NAMES"
echo "Папка: $DEST"
echo ""
echo "Осталось два шага:"
echo "  1. В VS Code нажмите Cmd+Shift+P, выберите Developer: Reload Window"
echo "  2. В панели Claude наберите /airl-spec"
echo ""
