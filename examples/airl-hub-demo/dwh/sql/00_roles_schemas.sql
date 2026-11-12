-- Пользователи базы и схемы хранилища хаба AIRL (демо).
-- Выполняет администратор хранилища (команда AIRL). Пароли передаются переменными
-- psql из окружения и в файлы не пишутся:
--   psql "$ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -v loader_pass=... -v fin_pass=... \
--        -v sales_pass=... -v edu_pass=... -v hr_pass=... -v mkt_pass=... -v hub_pass=... -v ai_pass=... \
--        -f 00_roles_schemas.sql
-- Повторный запуск безопасен: роли создаются, если их нет, пароли обновляются.

SELECT format('CREATE ROLE %I LOGIN', r)
FROM unnest(ARRAY['airl_loader', 'svc_finance', 'svc_sales', 'svc_edu', 'svc_hr', 'svc_marketing', 'svc_hub', 'ai_reader']) r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
-- Владелец показателей: без входа, читает core, владеет схемой metrics.
SELECT 'CREATE ROLE metrics_owner NOLOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metrics_owner') \gexec

ALTER ROLE airl_loader PASSWORD :'loader_pass';
ALTER ROLE svc_finance PASSWORD :'fin_pass';
ALTER ROLE svc_sales   PASSWORD :'sales_pass';
ALTER ROLE svc_edu     PASSWORD :'edu_pass';
ALTER ROLE svc_hr      PASSWORD :'hr_pass';
ALTER ROLE svc_marketing PASSWORD :'mkt_pass';
ALTER ROLE svc_hub     PASSWORD :'hub_pass';
ALTER ROLE ai_reader   PASSWORD :'ai_pass';
ALTER ROLE ai_reader SET default_transaction_read_only = on;
ALTER ROLE ai_reader SET statement_timeout = '10s';
ALTER ROLE svc_hub SET statement_timeout = '10s';

-- Никто, кроме владельца, не создаёт объекты в public.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"dbname" TO airl_loader, svc_finance, svc_sales, svc_edu, svc_hr, svc_marketing, svc_hub, ai_reader;

CREATE SCHEMA IF NOT EXISTS raw_1c;
CREATE SCHEMA IF NOT EXISTS raw_bank;
CREATE SCHEMA IF NOT EXISTS raw_amocrm;
CREATE SCHEMA IF NOT EXISTS raw_sheets;
CREATE SCHEMA IF NOT EXISTS raw_ads;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS metrics;
CREATE SCHEMA IF NOT EXISTS mart_finance;
CREATE SCHEMA IF NOT EXISTS mart_sales;
CREATE SCHEMA IF NOT EXISTS mart_edu;
CREATE SCHEMA IF NOT EXISTS mart_hr;
CREATE SCHEMA IF NOT EXISTS mart_marketing;
CREATE SCHEMA IF NOT EXISTS hub;

-- Сырой слой: пишет и создаёт таблицы только загрузка.
GRANT USAGE, CREATE ON SCHEMA raw_1c, raw_bank, raw_amocrm, raw_sheets, raw_ads TO airl_loader;
-- Общие данные: таблицы создаёт администратор (миграции), наполняет загрузка.
GRANT USAGE ON SCHEMA core TO airl_loader;
GRANT USAGE ON SCHEMA core TO metrics_owner;
GRANT USAGE, CREATE ON SCHEMA metrics TO metrics_owner;

-- Витрины: каждый сервис — владелец объектов только своей витрины.
GRANT USAGE, CREATE ON SCHEMA mart_finance TO svc_finance;
GRANT USAGE, CREATE ON SCHEMA mart_sales   TO svc_sales;
GRANT USAGE, CREATE ON SCHEMA mart_edu     TO svc_edu;
GRANT USAGE, CREATE ON SCHEMA mart_hr      TO svc_hr;
GRANT USAGE, CREATE ON SCHEMA mart_marketing TO svc_marketing;
GRANT USAGE, CREATE ON SCHEMA hub          TO svc_hub;

-- Показатели читают все сервисы, хаб и ИИ-слой; core — только по списку (05_grants.sql).
GRANT USAGE ON SCHEMA metrics TO svc_finance, svc_sales, svc_edu, svc_hr, svc_marketing, svc_hub, ai_reader;
GRANT USAGE ON SCHEMA core TO svc_finance, svc_sales, svc_edu;
-- svc_hr и svc_marketing core не читают: только metrics и адаптеры своей витрины (src_<…>).
