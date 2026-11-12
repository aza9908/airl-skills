#!/usr/bin/env bash
# Запуск демо-хаба без Docker (песочница, ноутбук): оболочка хаба, пять сервисов отделов и
# локальный прокси вместо Caddy. Хранилище должно быть развёрнуто: bash scripts/setup_db.sh
#
#   bash scripts/dev_up.sh     # запустить (логи — .run/*.log)
#   bash scripts/dev_down.sh   # остановить
# Открыть: http://127.0.0.1:8080/login
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
set -a && . ./.env && set +a
DB_NAME=${DB_NAME:-airl_demo_hub}
mkdir -p .run

url_for() { # url_for <роль> <пароль>
  python3 - "$ADMIN_DATABASE_URL" "$DB_NAME" "$1" "$2" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1]); host = p.netloc.split('@')[-1]
print(u.urlunsplit((p.scheme, f"{sys.argv[3]}:{u.quote(sys.argv[4], safe='')}@{host}", '/' + sys.argv[2], p.query, '')))
PY
}

[ -d services/node_modules ] || (cd services && npm ci --omit=dev --no-audit --no-fund)

start() { # start <имя> <команда...>
  local name=$1; shift
  if [ -f ".run/$name.pid" ] && kill -0 "$(cat ".run/$name.pid")" 2>/dev/null; then echo "  $name уже работает"; return; fi
  nohup "$@" > ".run/$name.log" 2>&1 &
  echo $! > ".run/$name.pid"
  echo "  $name запущен (pid $!)"
}

export APP_VERSION=${APP_VERSION:-1.0.0} AIRL_JWKS_URL=http://127.0.0.1:3000/.well-known/jwks.json
DATABASE_URL=$(url_for svc_hub "$HUB_DB_PASSWORD") UPSTREAM_FINANCE=127.0.0.1:3001 UPSTREAM_SALES=127.0.0.1:3002 \
  UPSTREAM_EDU=127.0.0.1:3003 UPSTREAM_HR=127.0.0.1:3004 UPSTREAM_MARKETING=127.0.0.1:3005 \
  PORT=3000 start hub node services/hub/server.js
sleep 1
DATABASE_URL=$(url_for svc_finance "$FIN_DB_PASSWORD") PORT=3001 start finance node services/finance/server.js
DATABASE_URL=$(url_for svc_sales "$SALES_DB_PASSWORD") PORT=3002 start sales node services/sales/server.js
DATABASE_URL=$(url_for svc_edu "$EDU_DB_PASSWORD") PORT=3003 start edu node services/edu/server.js
DATABASE_URL=$(url_for svc_hr "$HR_DB_PASSWORD") PORT=3004 start hr node services/hr/server.js
DATABASE_URL=$(url_for svc_marketing "$MKT_DB_PASSWORD") PORT=3005 start marketing node services/marketing/server.js
start proxy node scripts/dev-proxy.js

for i in $(seq 1 30); do
  ok=0
  for p in /healthz /finance/healthz /sales/healthz /edu/healthz /hr/healthz /marketing/healthz; do
    curl -fsS "http://127.0.0.1:8080$p" >/dev/null 2>&1 && ok=$((ok+1))
  done
  [ $ok -eq 6 ] && break
  sleep 1
done
echo "Живы: $ok из 6. Откройте http://127.0.0.1:8080/login (логины — README.md, пароль — DEMO_PASSWORD из .env)"
