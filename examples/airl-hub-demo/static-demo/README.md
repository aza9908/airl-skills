# Статическая демо-версия хаба (Netlify)

Опубликована: https://airl-hub-demo.netlify.app — экран руководителя на снимке **синтетических** данных.
Без входа, ролей, базы и сервисов отделов (это всё — в полной версии, `docker compose up`).

Как собрана (на запущенном стенде, `bash scripts/dev_up.sh`):
1. Под `ceo` сняты ответы `/auth/me`, `/hub/api/*` для периодов день/неделя/месяц/квартал → `data/*.json`
   (имя файла — путь с заменой не-латиницы на `_`).
2. Скопированы `services/hub/public` и `services/shared/static` (в `assets/`), убраны страница входа и service worker.
3. `static-mode.js` подменяет запросы к API на файлы из `data/`, `static-after.js` отключает SW и «Выйти»,
   сверху — плашка «демо, синтетические данные». `_redirects`: `/login` и `/finance|sales|edu/*` → `/`.
4. Публикация: Netlify, папка целиком, без сборки (`netlify.toml`).
