#!/usr/bin/env bash
# server-checks.sh — проверки сервера раз в 5–10 минут с оповещением в Telegram.
# Шаблон навыка airl-devops: оповещения уровня 1–2 без Prometheus.
# Внешнюю проверку адреса (сервер упал целиком) делает Uptime Kuma или аналог
# на ДРУГОМ сервере — этот скрипт про то, что видно изнутри.
#
# Установка (на сервере):
#   sudo install -m 755 notify-telegram.sh /usr/local/bin/notify-telegram
#   sudo install -m 755 server-checks.sh /usr/local/bin/airl-server-checks
#   crontab -e  →  */10 * * * * /usr/local/bin/airl-server-checks >> /var/log/airl-checks.log 2>&1
#
# Настройки — переменными окружения в строке cron или по умолчанию:
#   DISK_LIMIT=80            процент заполнения диска для оповещения
#   BACKUP_GLOB="/srv/*/backups/db_*.dump"   где искать копии
#   BACKUP_MAX_AGE_H=26      копия старше — оповещение
#   REPEAT_H=6               одно и то же оповещение не чаще, чем раз в столько часов

set -uo pipefail

DISK_LIMIT="${DISK_LIMIT:-80}"
BACKUP_GLOB="${BACKUP_GLOB:-/srv/*/backups/db_*.dump}"
BACKUP_MAX_AGE_H="${BACKUP_MAX_AGE_H:-26}"
REPEAT_H="${REPEAT_H:-6}"
NOTIFY="${NOTIFY:-/usr/local/bin/notify-telegram}"
STATE="${STATE_DIR:-/var/tmp/airl-checks}"
mkdir -p "$STATE"

problems=0

# alert <ключ> <текст> — отправить, если это оповещение не уходило последние REPEAT_H часов
alert() {
  local key="$1" text="$2" stamp="$STATE/$1"
  problems=$((problems + 1))
  if [ -f "$stamp" ] && [ -n "$(find "$stamp" -mmin -$((REPEAT_H * 60)) 2>/dev/null)" ]; then
    return 0
  fi
  echo "$(date -Is) ALERT $key: $text"
  "$NOTIFY" "$text" && touch "$stamp"
}

# resolved <ключ> <текст> — сообщить, что проблема ушла
resolved() {
  local key="$1" stamp="$STATE/$1"
  if [ -f "$stamp" ]; then
    rm -f "$stamp"
    "$NOTIFY" "Исправлено: $2" || true
  fi
}

# Диск
while read -r use mount; do
  pct="${use%\%}"
  key="disk_$(printf '%s' "$mount" | tr '/' '_')"
  if [ "$pct" -ge "$DISK_LIMIT" ]; then
    alert "$key" "Диск $mount заполнен на $pct%. Что делать: references/runbooks.md, «Диск заполнен»"
  else
    resolved "$key" "диск $mount — $pct%"
  fi
done < <(df -P -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk 'NR > 1 {print $5, $6}')

# Контейнеры: перезапускаются по кругу или нездоровы
if command -v docker >/dev/null 2>&1; then
  bad=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null; \
        docker ps -a --filter status=restarting --format '{{.Names}}' 2>/dev/null)
  bad=$(printf '%s\n' "$bad" | sort -u | tr '\n' ' ' | sed 's/ *$//')
  if [ -n "$bad" ]; then
    alert "containers" "Контейнеры нездоровы или перезапускаются: $bad. Смотреть: docker logs --tail 100 <имя>"
  else
    resolved "containers" "все контейнеры в порядке"
  fi
fi

# Свежесть резервной копии
# shellcheck disable=SC2086,SC2012 # шаблон пути должен раскрыться; имена копий — без пробелов
latest=$(ls -1t $BACKUP_GLOB 2>/dev/null | head -n 1)
if [ -z "$latest" ]; then
  alert "backup" "Не найдено ни одной резервной копии по шаблону $BACKUP_GLOB"
elif [ -n "$(find "$latest" -mmin +$((BACKUP_MAX_AGE_H * 60)) 2>/dev/null)" ]; then
  alert "backup" "Последняя копия базы старше $BACKUP_MAX_AGE_H ч: $latest. Проверьте cron и backups/backup.log"
elif [ ! -s "$latest" ]; then
  alert "backup" "Последняя копия базы пустая: $latest"
else
  resolved "backup" "свежая копия есть"
fi

# Память: свободно меньше 5% вместе с подкачкой
avail=$(awk '/^MemAvailable:/ {a=$2} /^MemTotal:/ {t=$2} END {print int(a*100/t)}' /proc/meminfo)
if [ "$avail" -lt 5 ]; then
  alert "memory" "Свободной памяти $avail%: процессы могут падать. Смотреть: docker stats --no-stream"
else
  resolved "memory" "память в норме ($avail% свободно)"
fi

exit $((problems > 0 ? 1 : 0))
