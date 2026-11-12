# Безопасность сервиса «Финансы» — отдел Финансы

**Дата**: 2026-11-12 · **Коммит**: 9eaf06cd48 · **map_version**: 1.0 · **Проверял**: airl-cybersecurity
**Можно подключать к хабу**: да — атаки на вход, роли, IDOR и права базы не прошли, «СРОЧНО» нет.

Общая проверка хаба и находки (ВАЖНО/ПОЗЖЕ) — `../../SECURITY.md`; полный вывод атак — `../../verification/security_attacks.md`.

## Чек-лист недели 3
- [x] Вход только через хаб, токен проверяется на сервере (`shared/lib/auth.js`), роль — из токена
- [x] Роли по матрице карты, запрет по умолчанию (`shared/lib/service.js`: без явного списка — только `roles.view`)
- [x] Пишет только в `mart_finance` — права пользователя `svc_finance` в базе
- [x] Ключи — `.env` вне репозитория; `public_paths` пуст
- [x] ПДн замаскированы на сервере, в `/finance/api/hub/summary` только агрегаты
- [ ] Данные в РК — после сервера (см. общий SECURITY.md)

## Проверки действием
| Атака | Ожидали | Получили | Итог |
|---|---|---|---|
| API без токена / с подменённой ролью / чужим ключом | 401 | 401 | ок |
| staff_sales → /finance/api/overview, /finance/api/hub/summary | 403 | 403 | ок |
| staff_finance → /finance/api/hub/summary (сводка только ceo и head_finance) | 403 | 403 | ок |
| ceo пишет действие по долгу (запись в витрину) | 403 | 403 | ок |
| имя физлица-должника под ceo | маска | «Б*** В***» | ок |
| svc_sales: INSERT в mart_finance.rcv_actions | нет прав | нет прав | ок |
| svc_edu: CREATE TABLE в mart_finance | нет прав | нет прав | ок |
| svc_finance: INSERT в core.sales_docs; SELECT mart_sales.pf_plans | нет прав | нет прав | ок |
