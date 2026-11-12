# Безопасность сервиса «Маркетинг» — отдел Маркетинг

**Дата**: 2026-11-12 · **Коммит**: 6fffb32 · **map_version**: 1.1 · **Проверял**: airl-cybersecurity
**Можно подключать к хабу**: да — атаки на вход, роли, подмену id и права базы не прошли, ПДн в сервисе нет, «СРОЧНО» нет.

Общая проверка хаба и находки (ВАЖНО/ПОЗЖЕ) — `../../SECURITY.md`; полный вывод атак — `../../verification/security_attacks.md`.

## Чек-лист недели 3
- [x] Вход только через хаб, токен проверяется на сервере (`shared/lib/auth.js`), роль — из токена
- [x] Роли по матрице карты, запрет по умолчанию: бюджет — только `head_marketing`; заметки — свои каналы у `staff_marketing`
- [x] Пишет только в `mart_marketing` — права `svc_marketing` в базе; `core` не читает (только `metrics`)
- [x] Ключи — `.env` вне репозитория; `public_paths` пуст; ключей рекламных кабинетов в демо нет (в бою — `/airl-connect`, `.env` сервера)
- [x] ПДн нет: заявки — количеством, без телефонов, e-mail и имён (проверено запросом)
- [ ] Данные в РК — после сервера (см. общий SECURITY.md)

## Проверки действием
| Атака | Ожидали | Получили | Итог |
|---|---|---|---|
| `/marketing/api/campaigns`, `/marketing/api/hub/summary`, `/hub/api/marketing` без токена | 401 | 401 | ок |
| staff_sales, staff_hr, head_hr → API маркетинга | 403 | 403 | ок |
| staff_marketing → `/marketing/api/hub/summary` | 403 | 403 | ок |
| staff_marketing, head_hr → «Изменить бюджет» | 403 | 403 | ок |
| staff_marketing: заметка к кампании канала «Сайт и Google» (подмена id) | 404 | 404 | ок |
| контакты в ответах маркетинга | нет | нет | ок |
| svc_marketing: `core.leads`, `core.employee_names`; UPDATE `mart_hr.onb_tasks` | нет прав | нет прав | ок |
| svc_sales: CREATE TABLE в `mart_marketing` | нет прав | нет прав | ок |
