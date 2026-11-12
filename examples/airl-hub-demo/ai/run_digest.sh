#!/usr/bin/env bash
# Утренняя сводка руководителю (/airl-ai): skills/airl-ai/scripts/digest.py под пользователем ai_reader.
# Есть ключ модели и SDK anthropic — пишет модель, каждое число сверяется с фактами.
# Нет ключа (как в этом демо) — шаблонная сводка без ИИ, и это написано в поле how.
# Результат — ai/out/digest.json, его показывает экран руководителя.
set -euo pipefail
cd "$(dirname "$0")/.."
SKILLS=${SKILLS_DIR:-../../skills}
DB_NAME=${DB_NAME:-airl_demo_hub}
if [ -z "${AI_READER_DATABASE_URL:-}" ]; then
  AIP=$(grep '^AI_DB_PASSWORD=' .env | cut -d= -f2-)
  ADMIN=$(grep '^ADMIN_DATABASE_URL=' .env | cut -d= -f2- | tr -d "'")
  AI_READER_DATABASE_URL=$(python3 - "$ADMIN" "$DB_NAME" "$AIP" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1]); host = p.netloc.split('@')[-1]
print(u.urlunsplit((p.scheme, f"ai_reader:{u.quote(sys.argv[3], safe='')}@{host}", '/' + sys.argv[2], p.query, '')))
PY
)
  export AI_READER_DATABASE_URL
fi
mkdir -p ai/out
mode=--dry-run
if [ -n "${ANTHROPIC_API_KEY:-}" ] && python3 -c 'import anthropic' 2>/dev/null; then mode=""; fi
python3 "$SKILLS/airl-ai/scripts/digest.py" --config ai/digest.json $mode > ai/out/digest.txt 2> ai/out/digest.err
python3 - <<'PY'
import json, datetime
text = open('ai/out/digest.txt', encoding='utf-8').read().strip()
err = open('ai/out/digest.err', encoding='utf-8').read()
how = next((l.split('способ:', 1)[1].strip() for l in err.splitlines() if 'способ:' in l), 'неизвестно')
if 'без модели' in how:
    how = 'сводка без ИИ: ключа модели нет, шаблон из тех же фактов'
json.dump({'text': text, 'how': how, 'date': datetime.date.today().isoformat()}, open('ai/out/digest.json', 'w', encoding='utf-8'), ensure_ascii=False)
print('сводка:', how)
PY
