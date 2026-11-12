#!/usr/bin/env bash
# Разворачивает хранилище демо-хаба с нуля: роли, слои raw → core → metrics,
# адаптеры и модули витрин, синтетические данные, тестовых пользователей хаба.
#
#   bash scripts/setup_db.sh            # всё, включая генерацию данных
#   bash scripts/setup_db.sh --reload   # только перегенерировать данные и пересчитать
#
# Нужны переменные (см. .env.example; файл .env создаётся сам и в git не попадает):
#   ADMIN_DATABASE_URL — администратор PostgreSQL (база postgres), только для установки;
#   DB_NAME, DB_HOST, DB_PORT — где создать хранилище; DEMO_PASSWORD — пароль демо-пользователей.
# Пароли пользователей базы генерируются при первом запуске и пишутся только в .env.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
export PGOPTIONS="-c client_min_messages=warning"

# shellcheck source=/dev/null
[ -f .env ] && set -a && . ./.env && set +a
: "${ADMIN_DATABASE_URL:?Задайте ADMIN_DATABASE_URL (см. .env.example)}"
DB_NAME=${DB_NAME:-airl_demo_hub}

gen() { python3 -c 'import secrets; print(secrets.token_urlsafe(24))'; }
ensure_secret() {
  local name=$1
  if [ -z "${!name:-}" ]; then
    local v; v=$(gen)
    printf '%s=%s\n' "$name" "$v" >> .env
    export "$name=$v"
  fi
}
touch .env && chmod 600 .env
for s in LOADER_DB_PASSWORD FIN_DB_PASSWORD SALES_DB_PASSWORD EDU_DB_PASSWORD HUB_DB_PASSWORD AI_DB_PASSWORD; do
  ensure_secret "$s"
done
if [ -z "${DEMO_PASSWORD:-}" ]; then
  echo "Нет DEMO_PASSWORD: задайте пароль демо-пользователей в .env (DEMO_PASSWORD=...) и запустите снова" >&2
  exit 2
fi

# Адрес базы хранилища для администратора: та же строка, другая база.
ADMIN_DB_URL=$(python3 - "$ADMIN_DATABASE_URL" "$DB_NAME" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1]); print(u.urlunsplit((p.scheme, p.netloc, '/' + sys.argv[2], p.query, p.fragment)))
PY
)
role_url() { # role_url <пользователь> <пароль>
  python3 - "$ADMIN_DB_URL" "$1" "$2" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1]); host = p.netloc.split('@')[-1]
print(u.urlunsplit((p.scheme, f"{sys.argv[2]}:{u.quote(sys.argv[3], safe='')}@{host}", p.path, p.query, '')))
PY
}
LOADER_URL=$(role_url airl_loader "$LOADER_DB_PASSWORD")
psqla() { psql "$ADMIN_DB_URL" -q -X -v ON_ERROR_STOP=1 "$@"; }

RELOAD=0; [ "${1:-}" = "--reload" ] && RELOAD=1

if [ $RELOAD -eq 0 ]; then
  echo "1/8 База $DB_NAME"
  psql "$ADMIN_DATABASE_URL" -q -X -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 \
    || psql "$ADMIN_DATABASE_URL" -q -X -c "CREATE DATABASE \"$DB_NAME\""

  echo "2/8 Роли и схемы"
  psqla -v dbname="$DB_NAME" -v loader_pass="$LOADER_DB_PASSWORD" -v fin_pass="$FIN_DB_PASSWORD" \
        -v sales_pass="$SALES_DB_PASSWORD" -v edu_pass="$EDU_DB_PASSWORD" -v hub_pass="$HUB_DB_PASSWORD" \
        -v ai_pass="$AI_DB_PASSWORD" -f dwh/sql/00_roles_schemas.sql
  echo "3/8 Слой core"
  psqla -f dwh/sql/01_core.sql
fi

echo "4/8 Синтетические данные 1С, банков, amoCRM, таблицы потоков"
python3 data/generate_1c.py --out data/out
LOADER_DATABASE_URL="$LOADER_URL" python3 dwh/load_raw.py --src data/out
echo "   core.load(): $(psql "$LOADER_URL" -X -tAc 'SELECT core.load()') строк"

if [ $RELOAD -eq 0 ]; then
  echo "5/8 Показатели (metrics) и адаптеры src_<…>"
  psqla <<SQL
SET ROLE metrics_owner;
\i dwh/sql/02_metrics.sql
RESET ROLE;
\i dwh/sql/03_adapters.sql
\i dwh/sql/04_grants.sql
SQL

  echo "6/8 Модули витрин (kit.sql + schema.sql из skills/airl-modules) под пользователями сервисов"
  psqla <<SQL
SET ROLE svc_finance;
SET search_path TO mart_finance;
\i dwh/modules/kit.sql
\i dwh/modules/pnl-cashflow.schema.sql
\i dwh/modules/receivables.schema.sql
\i dwh/modules/bank-reconciliation.schema.sql
RESET ROLE;
SET ROLE svc_sales;
SET search_path TO mart_sales;
\i dwh/modules/kit.sql
\i dwh/modules/plan-fact.schema.sql
RESET ROLE;
SET ROLE svc_edu;
SET search_path TO mart_edu;
\i dwh/modules/kit.sql
\i dwh/marts/edu_schema.sql
RESET ROLE;
SET ROLE svc_hub;
\i dwh/marts/hub_schema.sql
RESET ROLE;
SQL
  echo "7/8 Настройки модулей (ответы на вопросы MODULE.md, синтетика)"
  psqla -f dwh/marts/finance_config.sql >/dev/null
  psqla -f dwh/marts/sales_config.sql >/dev/null
  psqla -f dwh/sql/05_grants_ai.sql
else
  psqla -c "SET ROLE svc_finance; SET search_path TO mart_finance; SELECT pnl_rebuild('nightly'); SELECT bank_suggest('nightly');" >/dev/null
fi

echo "8/8 Тестовые пользователи хаба (пароль — из DEMO_PASSWORD, в git не попадает)"
HUB_DATABASE_URL=$(role_url svc_hub "$HUB_DB_PASSWORD") node services/hub/create_users.js

echo "Готово. Хранилище: $DB_NAME. Сервисы: bash scripts/dev_up.sh"
