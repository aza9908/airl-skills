#!/usr/bin/env bash
# Полная проверка демо-хаба на работающем стенде (после setup_db.sh и dev_up.sh / docker compose up).
# Результаты — в verification/*.txt (без паролей и токенов).
#   bash scripts/verify.sh [http://127.0.0.1:8080]
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
SKILLS=${SKILLS_DIR:-$ROOT/../../skills}
URL=${1:-http://127.0.0.1:8080}
set -a && . ./.env && set +a
DB_NAME=${DB_NAME:-airl_demo_hub}
OUT=verification; mkdir -p $OUT
url_for() {
  python3 - "$ADMIN_DATABASE_URL" "$1" "${2:-}" "${3:-}" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1]); host = p.netloc.split('@')[-1]
user = f"{sys.argv[3]}:{u.quote(sys.argv[4], safe='')}@" if sys.argv[3] else p.netloc.split('@')[0] + '@'
print(u.urlunsplit((p.scheme, user + host, '/' + sys.argv[2], p.query, '')))
PY
}
ADMIN_DB_URL=$(url_for "$DB_NAME")
export FIN_DB_URL=$(url_for "$DB_NAME" svc_finance "$FIN_DB_PASSWORD") SALES_DB_URL=$(url_for "$DB_NAME" svc_sales "$SALES_DB_PASSWORD") \
       EDU_DB_URL=$(url_for "$DB_NAME" svc_edu "$EDU_DB_PASSWORD") HUB_DB_URL=$(url_for "$DB_NAME" svc_hub "$HUB_DB_PASSWORD") \
       AI_DB_URL=$(url_for "$DB_NAME" ai_reader "$AI_DB_PASSWORD")
rc=0

echo "== 1. Приёмка сервисов в хаб: check_service.py (ворота 1–5, 8, 9)"
AIRL_HUB_TOKEN=$(curl -s -i -H 'Content-Type: application/json' -d "{\"login\":\"ceo\",\"password\":\"$DEMO_PASSWORD\"}" "$URL/auth/login" \
  | sed -n 's/^[Ss]et-[Cc]ookie: airl_session=\([^;]*\).*/\1/p')
export AIRL_HUB_TOKEN
: > $OUT/check_service.txt
for s in finance sales edu; do
  python3 "$SKILLS/airl-hub/scripts/check_service.py" --service services/$s/airl.service.json --map COMPANY_MAP.md \
    --registry hub/services.json --url "$URL" >> $OUT/check_service.txt 2>&1
  code=$?; echo "  $s: код выхода $code"; echo "exit=$code" >> $OUT/check_service.txt; [ $code -eq 0 ] || rc=1
done

echo "== 2. Модули на чистой тестовой базе: test_modules.sh (отдельная база airl_demo_modtest)"
psql "$ADMIN_DATABASE_URL" -qXc "DROP DATABASE IF EXISTS airl_demo_modtest" -c "CREATE DATABASE airl_demo_modtest" >/dev/null 2>&1
DATABASE_URL=$(url_for airl_demo_modtest) bash "$SKILLS/airl-modules/scripts/test_modules.sh" pnl-cashflow receivables bank-reconciliation plan-fact > $OUT/test_modules.txt 2>&1
code=$?; echo "  код выхода $code"; [ $code -eq 0 ] || rc=1
psql "$ADMIN_DATABASE_URL" -qXc "DROP DATABASE IF EXISTS airl_demo_modtest" >/dev/null

echo "== 3. Сверка «одни цифры»: модули витрин = metrics"
psql "$ADMIN_DB_URL" -X -f tests/reconcile.sql > $OUT/reconcile.txt 2>&1
cat $OUT/reconcile.txt | sed 's/^/  /'
if awk -F'|' 'NF>=4 && $3 ~ /^ *[0-9]+ *$/ && $3+0 > 0 {bad=1} END {exit !bad}' $OUT/reconcile.txt; then echo "  есть расхождения"; rc=1; else echo "  расхождений нет"; fi

echo "== 4. Атаки безопасности"
node tests/security_attacks.js "$URL" > $OUT/security_attacks.md 2>&1; code=$?
tail -1 $OUT/security_attacks.md | sed 's/^/  /'; [ $code -eq 0 ] || rc=1

echo "== 5. Сквозной тест Playwright: роли, KPI = SQL, скриншоты"
ADMIN_DB_URL="$ADMIN_DB_URL" node tests/smoke.playwright.js "$URL" > $OUT/smoke.txt 2>&1; code=$?
tail -3 $OUT/smoke.txt | sed 's/^/  /'; [ $code -eq 0 ] || rc=1

echo "Итог: $([ $rc -eq 0 ] && echo 'всё зелёное' || echo 'есть красное — см. verification/')"
exit $rc
