#!/bin/bash
# Установка навыков AIRL. Запуск: bash install.sh
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/skills"

mkdir -p "$DEST"
cp -R "$SRC/skills/." "$DEST/"

echo ""
echo "Готово. Установлены навыки: design, architecture, security"
echo "Папка: $DEST"
echo ""
echo "Осталось два шага:"
echo "  1. В VS Code нажмите Cmd+Shift+P, выберите Developer: Reload Window"
echo "  2. В панели Claude наберите /design"
echo ""
