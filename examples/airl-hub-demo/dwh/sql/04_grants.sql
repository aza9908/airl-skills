-- Права после установки всех слоёв. Чтение core выдаётся по списку data.reads
-- из airl.service.json каждого сервиса, а не на всю схему.
-- Повторный запуск безопасен.

-- Показатели — всем читателям.
GRANT SELECT ON ALL TABLES IN SCHEMA metrics TO svc_finance, svc_sales, svc_edu, svc_hr, svc_marketing, svc_hub, ai_reader;

-- Финансы: адаптеры модулей + core по data.reads.
GRANT SELECT ON mart_finance.src_pnl_entries, mart_finance.src_pnl_cash, mart_finance.src_receivables_docs,
              mart_finance.src_rcv_clients, mart_finance.src_bank_statement_lines, mart_finance.src_bank_open_items
      TO svc_finance;
GRANT SELECT ON core.sales_docs, core.clients, core.cash_accounts TO svc_finance;

-- Продажи: адаптер plan-fact + заявки и менеджеры. Карточку клиента не читает.
GRANT SELECT ON mart_sales.src_pf_facts TO svc_sales;
GRANT SELECT ON core.leads, core.managers TO svc_sales;

-- Обучение: потоки и слушатели; из карточки клиента — только id, вид и имя (без ИИН, телефона, e-mail).
GRANT SELECT ON core.cohorts, core.enrollments TO svc_edu;
GRANT SELECT (client_id, kind, name) ON core.clients TO svc_edu;


-- HR: только адаптер онбординга (ФИО для экрана HR); вакансии, ФОТ и отсутствия — агрегаты из metrics.
-- Таблиц core (ФИО, ЗУП) сервис не читает.
GRANT SELECT ON mart_hr.src_onb_employees TO svc_hr;

-- Маркетинг: всё из metrics (расход, кампании, каналы). core и витрины других отделов — нет.
