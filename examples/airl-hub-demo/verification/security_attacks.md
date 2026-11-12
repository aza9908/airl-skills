| Атака | Ожидали | Получили | Итог |
|---|---|---|---|
| /finance/api/overview без токена | 401 | 401 | ок |
| /sales/api/leads без токена | 401 | 401 | ок |
| /edu/api/overview без токена | 401 | 401 | ок |
| /hub/api/overview без токена | 401 | 401 | ок |
| /finance/api/hub/summary без токена | 401 | 401 | ок |
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
| staff_sales меняет план (действие head) | 403 | 403 | ок |
| ceo пишет в витрину финансов | 403 | 403 | ок |
| staff_sales: напоминание по чужой заявке (подмена id) | 404 | 404 | ок |
| staff_sales видит только свои заявки | все manager_id = 9001 | 26 строк, чужих: 0 | ок |
| staff_edu: поток другого куратора | 404 | 404 | ок |
| ceo видит имя физлица-должника | с маской | Б*** В*** | ок |
| в /api/hub/summary нет ПДн | только агрегаты | агрегаты | ок |
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
| svc_edu: имя слушателя (разрешённые колонки) | выполнилось | выполнилось | ок |

Атак: 41, не прошло (как и должно): 41, прошло: 0
