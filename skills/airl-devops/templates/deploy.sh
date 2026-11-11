#!/usr/bin/env bash
# deploy.sh — выкладка одной среды (staging или production) с миграциями и откатом.
# Шаблон навыка airl-devops, продакшен-версия скрипта из references/server-setup.md (часть 7).
#
# Лежит в папке среды: /srv/<проект>-staging/deploy.sh, /srv/<проект>-prod/deploy.sh.
# Запускается ключом выкладки с ограничением command=..., получает одну метку образа:
#   ./deploy.sh <полный хеш коммита>
#
# Что делает:
#   1. не даёт запустить две выкладки одновременно;
#   2. скачивает образ новой версии;
#   3. если в compose есть служба migrate (профиль tools): свежая копия базы (./backup.sh),
#      затем миграции из нового образа — только «expand», совместимые со старым кодом;
#   4. перезапускает только приложение и ждёт /healthz;
#   5. не ответил — возвращает предыдущую метку (база остаётся расширенной — старый код с ней работает);
#   6. пишет каждую выкладку в deploy.log.
#
# Файл .env рядом: APP_TAG, APP_PORT, HEALTH_PATH (по умолчанию /healthz),
# APP_SERVICE (по умолчанию app; в хабе — id сервиса), COMPOSE_PROJECT_NAME.

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

NEW_TAG="${1:-}"
[[ "$NEW_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Нужна метка образа" >&2; exit 2; }

exec 9>.deploy.lock
flock -n 9 || { echo "Уже идёт другая выкладка этой среды" >&2; exit 3; }

env_value() { grep -E "^$1=" .env | tail -n 1 | cut -d= -f2- || true; }

grep -q '^APP_TAG=' .env || echo 'APP_TAG=' >> .env
OLD_TAG=$(env_value APP_TAG)
PORT=$(env_value APP_PORT)
HEALTH=$(env_value HEALTH_PATH)
HEALTH="${HEALTH:-/healthz}"
SERVICE=$(env_value APP_SERVICE)
SERVICE="${SERVICE:-app}"
[ -n "$PORT" ] || { echo "В .env нет APP_PORT" >&2; exit 2; }

log() { printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$NEW_TAG" "$1" "${2:-}" >> deploy.log; }
set_tag() { sed -i "s/^APP_TAG=.*/APP_TAG=$1/" .env; }

rollback() {
  local reason="$1"
  if [ -n "$OLD_TAG" ] && [ "$OLD_TAG" != "$NEW_TAG" ]; then
    echo "$reason — откат на $OLD_TAG" >&2
    set_tag "$OLD_TAG"
    docker compose up -d --no-deps "$SERVICE" || true
    log "rollback" "$reason; вернули $OLD_TAG"
  else
    echo "$reason — предыдущей версии нет, смотрите: docker compose logs --tail 100 $SERVICE" >&2
    set_tag "$OLD_TAG"
    log "failed" "$reason"
  fi
  exit 1
}

log "start" "было $OLD_TAG"
set_tag "$NEW_TAG"
docker compose pull "$SERVICE" || rollback "образ $NEW_TAG не скачался"

if docker compose --profile tools config --services 2>/dev/null | grep -qx migrate; then
  if [ -x ./backup.sh ]; then
    ./backup.sh || rollback "копия базы перед миграцией не создалась"
  else
    echo "Нет ./backup.sh — миграции без свежей копии не запускаю" >&2
    rollback "нет backup.sh"
  fi
  docker compose --profile tools pull migrate || rollback "образ миграций не скачался"
  docker compose --profile tools run --rm migrate || rollback "миграции упали (смотрите вывод выше; база — в последней копии backups/)"
  log "migrated"
fi

docker compose up -d --no-deps "$SERVICE"

for _ in $(seq 1 12); do
  if curl -fsS -m 5 "http://127.0.0.1:$PORT$HEALTH" >/dev/null 2>&1; then
    if [ -n "$OLD_TAG" ] && [ "$OLD_TAG" != "$NEW_TAG" ]; then
      echo "$OLD_TAG" > .previous_tag
    fi
    log "ok"
    echo "Выложено: $NEW_TAG"
    exit 0
  fi
  sleep 5
done

rollback "новая версия не ответила на $HEALTH за минуту"
