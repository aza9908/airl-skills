#!/usr/bin/env bash
# Выкладка демо-хаба AIRL на чистый сервер Ubuntu 22.04/24.04 одной командой.
# Запуск на сервере (под root или через sudo):
#   curl -fsSL https://raw.githubusercontent.com/aza9908/airl-skills/main/examples/airl-hub-demo/scripts/deploy_server.sh | sudo bash -s -- hub-demo.airl.kz
# Перед запуском: DNS-запись A для домена указывает на IP сервера, порты 80 и 443 открыты.
# Повторный запуск безопасен: обновит код и перезапустит контейнеры, пароли из .env сохранит.
set -euo pipefail

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
  echo "Укажите домен: bash deploy_server.sh hub-demo.airl.kz" >&2
  exit 2
fi
DIR=/srv/airl-skills
APP="$DIR/examples/airl-hub-demo"

echo "== 1. Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null

echo "== 2. Код (без git: архив ветки main)"
TMP=$(mktemp -d)
curl -fsSL -o "$TMP/main.zip" https://github.com/aza9908/airl-skills/archive/refs/heads/main.zip
command -v unzip >/dev/null 2>&1 || apt-get install -y -qq unzip >/dev/null
unzip -q "$TMP/main.zip" -d "$TMP"
mkdir -p "$DIR"
# .env и ключи переживают обновление: копируем код поверх, не удаляя их
cp -a "$TMP/airl-skills-main/." "$DIR/"
rm -rf "$TMP"

echo "== 3. Настройки (.env)"
cd "$APP"
[ -f .env ] || bash scripts/init_env.sh
set_env() { # set_env KEY VALUE — заменить или добавить строку в .env
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}
set_env HUB_SITE "$DOMAIN"
set_env PROXY_PORT 80
set_env COOKIE_SECURE 1
# Пароли пользователей базы новых отделов (HR, маркетинг) для .env, созданного до их появления
for v in HR MKT; do
  grep -q "^${v}_DB_PASSWORD=." .env || echo "${v}_DB_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))' 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)" >> .env
done
chmod 600 .env

echo "== 4. Запуск"
docker compose up -d --build

echo "== 5. Проверка"
for _ in $(seq 1 60); do
  if curl -fsS -m 5 "https://$DOMAIN/healthz" >/dev/null 2>&1; then
    echo "Готово: https://$DOMAIN/login"
    echo "Логины: ceo, head_finance, head_sales, head_marketing, head_edu, head_hr, staff_sales. Пароль: строка DEMO_PASSWORD в $APP/.env"
    exit 0
  fi
  sleep 5
done
echo "Сайт не ответил за 5 минут. Проверьте DNS домена и откройте порты 80/443; логи: cd $APP && docker compose logs --tail=50 caddy hub" >&2
exit 1
