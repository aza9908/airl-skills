| Атака | Ожидали | Получили | Итог |
|---|---|---|---|
| /finance/api/overview без токена | 401 | 401 | ок |
| /sales/api/leads без токена | 401 | 401 | ок |
| /edu/api/overview без токена | 401 | 401 | ок |
| /hr/api/onboarding без токена | 401 | 401 | ок |
| /marketing/api/campaigns без токена | 401 | 401 | ок |
| /hub/api/overview без токена | 401 | 401 | ок |
| /finance/api/hub/summary без токена | 401 | 401 | ок |
| /hr/api/hub/summary без токена | 401 | 401 | ок |
| /marketing/api/hub/summary без токена | 401 | 401 | ок |
| /hub/api/hr без токена | 401 | 401 | ок |
| /hub/api/marketing без токена | 401 | 401 | ок |
| staff_sales поменял role на ceo в токене | 401 | 401 | ок |
| токен подписан чужим ключом | 401 | 401 | ок |
| просроченный токен | 401 | 401 | ок |
| токен с чужой аудиторией (aud) | 401 | 401 | ок |
| токен alg=none | 401 | 401 | ок |
| /finance/healthz без токена (открыт, без данных) | 200, только status/version | 200, поля: status,service,version,map_version | ок |
| staff_sales → /finance/api/overview | 403 | 403 | ок |
| staff_sales → /finance/api/hub/summary | 403 | 403 | ок |
| staff_sales → /hub/api/overview | 403 | 403 | ок |
| staff_sales → /edu/api/overview | 403 | 403 | ок |
| head_finance → /sales/api/overview | 403 | 403 | ок |
| head_finance → /hub/api/funnel | 403 | 403 | ок |
| head_finance → /hub/api/pnl | 200 | 200 | ок |
| head_finance → /hub/api/digest | 403 | 403 | ок |
| staff_finance → /finance/api/hub/summary | 403 | 403 | ок |
| staff_edu → /finance/api/debtors | 403 | 403 | ок |
| ceo → /edu/api/overview | 200 | 200 | ок |
| head_sales → /hub/api/series?metric=cash_balance | 403 | 403 | ок |
| staff_sales → /hr/api/overview | 403 | 403 | ок |
| staff_sales → /marketing/api/overview | 403 | 403 | ок |
| staff_hr → /marketing/api/overview | 403 | 403 | ок |
| staff_marketing → /hr/api/onboarding | 403 | 403 | ок |
| head_marketing → /hr/api/vacancies | 403 | 403 | ок |
| head_hr → /marketing/api/budget | 403 | 403 | ок |
| head_hr → /hub/api/marketing | 403 | 403 | ок |
| head_marketing → /hub/api/hr | 403 | 403 | ок |
| head_hr → /hub/api/pnl | 403 | 403 | ок |
| head_marketing → /hub/api/series?metric=payroll_fund | 403 | 403 | ок |
| head_hr → /hub/api/series?metric=payroll_fund | 200 | 200 | ок |
| staff_hr → /hr/api/payroll | 403 | 403 | ок |
| staff_hr → /hr/api/hub/summary | 403 | 403 | ок |
| staff_marketing → /marketing/api/hub/summary | 403 | 403 | ок |
| staff_hr → /hub/api/overview | 403 | 403 | ок |
| ceo → /hr/api/payroll | 200 | 200 | ок |
| ceo → /marketing/api/overview | 200 | 200 | ок |
| head_hr → /hub/api/hr | 200 | 200 | ок |
| head_marketing → /hub/api/marketing | 200 | 200 | ок |
| staff_sales меняет план (действие head) | 403 | 403 | ок |
| ceo пишет в витрину финансов | 403 | 403 | ок |
| ceo отмечает пункт онбординга (пишет в mart_hr) | 403 | 403 | ок |
| head_marketing отмечает пункт онбординга | 403 | 403 | ок |
| staff_marketing меняет бюджет (действие head) | 403 | 403 | ок |
| head_hr меняет бюджет маркетинга | 403 | 403 | ок |
| staff_sales: напоминание по чужой заявке (подмена id) | 404 | 404 | ок |
| staff_sales видит только свои заявки | все manager_id = 9001 | 26 строк, чужих: 0 | ок |
| staff_edu: поток другого куратора | 404 | 404 | ок |
| staff_hr: онбординг чужого отдела (подмена id) | 404 | 404 | ок |
| staff_hr: «Готово» по пункту чужого отдела (подмена id) | 404 | 404 | ок |
| staff_hr видит только свои отделы | нет «Разработка», «Финансы» | 6 строк, чужих: 0 | ок |
| staff_marketing: заметка к кампании чужого канала (подмена id) | 404 | 404 | ок |
| ceo видит имя физлица-должника | с маской | Б*** В*** | ок |
| в /api/hub/summary нет ПДн | только агрегаты | агрегаты | ок |
| ceo видит имена новых сотрудников | с маской (их видит только HR) | Ш*** М*** | ок |
| HR: полных ФИО и окладов нет ни в одном ответе | нет | нет | ок |
| ФОТ по отделам: нет отдела меньше 3 человек | малые отделы объединены | Разработка:9; Малые отделы (до 3 человек):6; Обучение:9; Продажи:7; Финансы:3 | ок |
| маркетинг: нет контактов (телефон, e-mail, имя) | только агрегаты | агрегаты | ок |
| заголовки безопасности | content-security-policy, x-content-type-options, strict-transport-security, referrer-policy | 4 из 4 | ок |
| cookie входа | HttpOnly; Secure; SameSite=Lax | airl_session=…; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=3600 | ок |
| sales: INSERT INTO mart_finance.rcv_actions (client_id, kind, resul | нет прав | нет прав | ок |
| sales: SELECT name FROM core.clients LIMIT 1 | нет прав | нет прав | ок |
| edu: SELECT phone FROM core.clients LIMIT 1 | нет прав | нет прав | ок |
| fin: INSERT INTO core.sales_docs (doc_id) VALUES ('x') | нет прав | нет прав | ок |
| hub: SELECT * FROM core.leads LIMIT 1 | нет прав | нет прав | ок |
| fin: SELECT * FROM mart_sales.pf_plans LIMIT 1 | нет прав | нет прав | ок |
| edu: CREATE TABLE mart_finance.x (id int) | нет прав | нет прав | ок |
| ai: SELECT * FROM mart_finance.rcv_actions LIMIT 1 | нет прав | нет прав | ок |
| hr: INSERT INTO mart_marketing.mkt_budgets (month, channel, amou | нет прав | нет прав | ок |
| mkt: UPDATE mart_hr.onb_tasks SET status = 'done', done_at = now( | нет прав | нет прав | ок |
| mkt: SELECT full_name FROM core.employee_names LIMIT 1 | нет прав | нет прав | ок |
| hr: SELECT full_name FROM core.employee_names LIMIT 1 | нет прав | нет прав | ок |
| hr: SELECT * FROM raw_1c.zup_nachisleniya LIMIT 1 | нет прав | нет прав | ок |
| hr: SELECT name FROM core.clients LIMIT 1 | нет прав | нет прав | ок |
| mkt: SELECT * FROM core.leads LIMIT 1 | нет прав | нет прав | ок |
| fin: SELECT * FROM mart_hr.src_onb_employees LIMIT 1 | нет прав | нет прав | ок |
| hub: SELECT * FROM core.payroll_monthly LIMIT 1 | нет прав | нет прав | ок |
| ai: SELECT * FROM mart_hr.onb_tasks LIMIT 1 | нет прав | нет прав | ок |
| sales: CREATE TABLE mart_marketing.x (id int) | нет прав | нет прав | ок |
| svc_edu: имя слушателя (разрешённые колонки) | выполнилось | выполнилось | ок |

Атак: 89, не прошло (как и должно): 89, прошло: 0
