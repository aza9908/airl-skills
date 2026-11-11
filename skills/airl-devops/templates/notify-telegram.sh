#!/usr/bin/env bash
# notify-telegram.sh "текст" — отправить оповещение в Telegram.
# Шаблон навыка airl-devops. Кладётся на сервер в /usr/local/bin/notify-telegram.
#
# Токен бота и чат — в /etc/airl/alert.env (владелец root, права 600), значения
# вписывает человек сам, в чат и в git они не попадают:
#   TELEGRAM_BOT_TOKEN=<токен от @BotFather>
#   TELEGRAM_CHAT_ID=<id чата дежурных>
#
# Токен передаётся curl через стандартный ввод, а не в командной строке:
# так его не видно в списке процессов.

set -euo pipefail

CONF="${AIRL_ALERT_ENV:-/etc/airl/alert.env}"
[ -r "$CONF" ] || { echo "Нет файла $CONF или нет прав на чтение" >&2; exit 2; }
TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$CONF" | cut -d= -f2- | tr -d '"'"'"' \r')
CHAT=$(grep -E '^TELEGRAM_CHAT_ID=' "$CONF" | cut -d= -f2- | tr -d '"'"'"' \r')
[ -n "$TOKEN" ] && [ -n "$CHAT" ] || { echo "В $CONF нет TELEGRAM_BOT_TOKEN или TELEGRAM_CHAT_ID" >&2; exit 2; }

TEXT="[$(hostname -s)] ${1:-проверка оповещения}"

printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TOKEN" \
  | curl -fsS -m 15 --retry 3 --retry-delay 5 -K - \
      --data-urlencode "chat_id=$CHAT" \
      --data-urlencode "text=$TEXT" \
      -o /dev/null
