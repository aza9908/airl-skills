# HUB.md — как устроен хаб AIRL (демо)

`/airl-hub`, режим A (создать хаб) и B2 (приёмка сервисов). Делала «команда AIRL» (Claude) в песочнице.

## Части режима A
| Часть | Что сделано | Где |
|---|---|---|
| 1. Реестр | finance, sales, edu — статус `connected` | `hub/services.json` |
| 2. Вход | демо-издатель JWT RS256 (вместо Authentik), JWKS `/.well-known/jwks.json`, cookie `airl_session`, обновление токена оболочкой, 7 тестовых пользователей; «Контракт входа» в карте заполнен | `services/hub/server.js`, `COMPANY_MAP.md` §8 |
| 3. Оболочка | PWA в токенах карты, шапка-«таблетка», переключатель отделов (по `roles.view` и статусу), выход чистит кэши; service worker не трогает пути сервисов | `services/hub/public/` |
| 4. Экран руководителя | KPI с изменением к тем же дням прошлого периода, переключатель день/неделя/месяц/квартал, выручка (график), прогноз, ОПиУ, старение дебиторки, воронка, сигналы, плитки сервисов (опрос параллельно, 3 с, кэш 60 с на пользователя, «Нет данных от сервиса» серым), сводка ИИ | `services/hub/public/app.js` |
| 5. Маршруты | Caddyfile генерируется из реестра; локально — `scripts/dev-proxy.js` | `scripts/gen_caddy.js`, `proxy/Caddyfile` |
| 6. Журнал | вход, неудачный вход, выход, открытие сервиса, ошибки опроса, отказ | `hub.journal` |

Видимость: `ceo` — всё; `head_<отдел>` — экран только своего отдела и одна плитка; `staff_<отдел>` —
сразу в свой сервис (экран руководителя → 302). Подписи показателей — из `metrics.definitions` (= карта).

## Как добавить сервис
1. Отдел: `SPEC.md` + `airl.service.json` (`/airl-spec`), самопроверка
   `python3 skills/airl-hub/scripts/check_service.py --service services/<id>/airl.service.json --map COMPANY_MAP.md --files-only`.
2. Команда AIRL: строка в `hub/services.json` со статусом `ready`, `node scripts/gen_caddy.js`, перезагрузка Caddy.
3. Приёмка: `check_service.py … --registry hub/services.json --url <хаб>` с `AIRL_HUB_TOKEN` (ceo) → exit 0;
   ручные ворота 6, 7, 10–13 → `services/<id>/HUB_CHECK.md`.
4. Статус `connected`, отдельный коммит «hub: подключить <id> v<версия>».

## Как откатить
Подключение — `git revert` коммита реестра + `gen_caddy.js` + reload. Версию сервиса — `DEVOPS.md`, «Откат».

## Кто отвечает
Команда AIRL — оболочка, реестр, прокси, хранилище. Отделы — свои сервисы и витрины.
