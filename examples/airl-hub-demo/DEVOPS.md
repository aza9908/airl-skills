# DEVOPS.md — выкладка хаба AIRL (демо)

НЕИЗВЕСТНО: сервер и домен хаба (доступа к серверу airl.kz нет) · НЕИЗВЕСТНО: кто поддерживает хаб после курса.
Ниже — что проверено в песочнице и как это перенести на сервер (`/airl-devops`, режим хаба).

## Где работает сейчас
| Где | Как | Проверено |
|---|---|---|
| песочница без Docker | `scripts/setup_db.sh` + `scripts/dev_up.sh` (Node + локальный прокси `scripts/dev-proxy.js` вместо Caddy) | да: verify.sh зелёный |
| песочница, Docker | образы `hub/finance/sales/edu` из `Dockerfile`, `db` — `postgres:16-alpine`, `docker compose up` | да: 4 контейнера healthy, `check_service.py` exit 0 ×3 (`verification/check_service_compose.txt`) |
| песочница, Docker: Caddy и контейнер `setup` | — | **нет**: Docker Hub вернул 429 на `caddy:2.8-alpine`; зеркало Alpine закрыто прокси песочницы (403) — хранилище в стеке ставилось с хоста |
| боевой сервер в РК | — | **нет** |

## Восемь вопросов (ответы по умолчанию)
| Вопрос | Ответ |
|---|---|
| Где работает | VPS в РК (Алматы), Ubuntu 24.04, Docker; договор — на ТОО AIRL |
| Кто следит | команда AIRL; после курса — НЕИЗВЕСТНО |
| Бюджет | ~30–40 тыс. ₸/мес (VPS 4 vCPU / 8 ГБ + копии в другом ДЦ РК) |
| Домен | `hub.<домен AIRL>` — Caddy выпускает сертификат сам (`HUB_SITE`) |
| Выкладка | GitHub Actions: проверки (`ci/ci.yml`) → образ с меткой версии → `deploy.sh` сервиса |
| Staging | второй проект Compose на том же сервере с тестовой копией хранилища |
| Оповещения | `/healthz` каждую минуту → Telegram (`skills/airl-devops/templates/notify-telegram.sh`) |
| Копии | `pg_dump` ночью, 14 дней на сервере + копия в другом ДЦ РК, проверка восстановления раз в месяц |

## Раскладка на сервере (режим хаба)
```
/srv/proxy/          Caddy, proxy/Caddyfile (генерирует scripts/gen_caddy.js из hub/services.json)
/srv/hub/dwh/        db (сеть dwh, без портов), cron: загрузка raw → core в 05:30, pg_dump в 03:00
/srv/hub/hub/        оболочка (сети web, dwh), ключ JWT — том hub_keys
/srv/hub/finance/    сервис отдела — свой проект Compose, свой .env (600), пользователь deploy_finance
/srv/hub/sales/      …
/srv/hub/edu/        …
```
В демо всё в одном `docker-compose.yml` — так проще запустить; разнести по папкам — первая задача на сервере.

## Команды
Запуск (сервер или ноутбук с Docker):
```bash
bash scripts/init_env.sh                # .env со случайными паролями (600), в git не попадает
docker compose up -d --build            # db → setup (хранилище, модули, синтетика, пользователи) → сервисы → caddy
docker compose ps                       # все healthy
curl -fsS http://127.0.0.1:3001/finance/healthz
```
Выкладка одного сервиса (соседи не перезапускаются):
```bash
FINANCE_TAG=1.0.1 docker compose up -d --no-deps finance
curl -fsS http://127.0.0.1:3001/finance/healthz   # version = 1.0.1
```
**Откат одной командой** (ворота 12):
```bash
FINANCE_TAG=1.0.0 docker compose up -d --no-deps finance
```
Откат выполнен 2026-11-12 11:52 UTC в песочнице: 1.0.0 → 1.0.1 → 1.0.0, `/finance/healthz` вернул
`version: 1.0.0`, контейнеры hub/sales/edu/db не перезапускались (`verification/rollback_rehearsal.txt`).

Перезагрузка маршрутов после изменения реестра:
```bash
node scripts/gen_caddy.js
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```
Ночной пересчёт (cron на сервере): `bash scripts/setup_db.sh --reload && bash ai/run_digest.sh`.

## Выкладка на сервер одной командой

Нужен чистый сервер Ubuntu 22.04/24.04 (2 vCPU, 4 ГБ RAM, 30 ГБ диска; для настоящих данных — в РК),
DNS-запись A домена (например `hub-demo.airl.kz`) на IP сервера и открытые порты 80 и 443. На сервере:

```bash
curl -fsSL https://raw.githubusercontent.com/aza9908/airl-skills/main/examples/airl-hub-demo/scripts/deploy_server.sh | sudo bash -s -- hub-demo.airl.kz
```

Скрипт ставит Docker, скачивает код, создаёт `.env` со случайными паролями (повторный запуск их сохраняет),
включает домен и HTTPS (сертификат выпускает Caddy) и ждёт, пока `https://<домен>/healthz` ответит.
Пароль демо-пользователей — строка `DEMO_PASSWORD` в `/srv/airl-skills/examples/airl-hub-demo/.env`.

## Памятка начинающему
| Порт | Что | Снаружи |
|---|---|---|
| 80/443 | Caddy | да |
| 3000–3003 | hub, finance, sales, edu | только `127.0.0.1` |
| 5432 | PostgreSQL | нет (только сеть `dwh`) |

Безопасно: `docker compose ps`, `docker compose logs --tail 50 finance`, `curl …/healthz`.
С осторожностью: `docker compose up -d --no-deps <сервис>`, `caddy reload`.
Опасно, только с копией и «да»: `docker compose down -v` (удаляет базу!), `DROP`, `setup_db.sh` на боевой базе
(генератор перезапишет `raw_*` синтетикой — на боевом сервере генератор отключить, загрузка из 1С).

## Сборка образов за корпоративным прокси
Если прокси подменяет сертификаты (как в песочнице), передайте его сборке:
`docker build --secret id=ca,src=<ca.crt> --build-arg SERVICE=finance .` — без секрета сборка обычная.
