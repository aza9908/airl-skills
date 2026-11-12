#!/usr/bin/env bash
# Создаёт .env со случайными паролями для docker compose (если его ещё нет). Значения не печатаются,
# кроме подсказки, где взять пароль демо-пользователей.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f .env ] && grep -q '^DEMO_PASSWORD=.' .env; then echo ".env уже есть — не трогаю"; exit 0; fi
gen() { python3 -c 'import secrets; print(secrets.token_urlsafe(24))' 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }
umask 077
{
  echo "ADMIN_DB_PASSWORD=$(gen)"
  echo "DB_NAME=airl_demo_hub"
  echo "DEMO_PASSWORD=$(gen | head -c 16)"
  for v in LOADER FIN SALES EDU HR MKT HUB AI; do echo "${v}_DB_PASSWORD=$(gen)"; done
  echo "AIRL_ISSUER=https://hub.airl.kz"
  echo "AIRL_AUDIENCE=airl-hub"
  echo "PROXY_PORT=8080"
} > .env
echo ".env создан (права 600). Пароль демо-пользователей — строка DEMO_PASSWORD в .env"
