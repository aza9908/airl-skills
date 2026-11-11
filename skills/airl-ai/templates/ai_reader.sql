-- Пользователь базы для ИИ-слоя: только чтение и только показатели.
-- Выполняет администратор хранилища (в хабе — команда AIRL). Пароль задаётся
-- переменной psql и в файл не пишется:
--
--   psql "$ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -v ai_pass="$AI_READER_PASSWORD" -f ai_reader.sql
--
-- Схемы с показателями перечисли ниже: metrics хаба и витрины, где лежат
-- представления m_<…> модулей. Таблицы с персональными данными сюда не входят.

CREATE ROLE ai_reader LOGIN PASSWORD :'ai_pass';
ALTER ROLE ai_reader SET default_transaction_read_only = on;
ALTER ROLE ai_reader SET statement_timeout = '10s';

-- Показатели хаба
GRANT USAGE ON SCHEMA metrics TO ai_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA metrics TO ai_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA metrics GRANT SELECT ON TABLES TO ai_reader;

-- Показатели модулей: только представления m_<…>, не таблицы модулей.
-- Повтори блок для каждой витрины (mart_roastqc, mart_finance, ...).
-- GRANT USAGE ON SCHEMA mart_roastqc TO ai_reader;
-- GRANT SELECT ON mart_roastqc.m_qc_reject_rate, mart_roastqc.m_qc_unchecked_overdue TO ai_reader;
-- GRANT SELECT ON mart_roastqc.airl_settings TO ai_reader;   -- пороги светофора модулей

-- База знаний (kb.py): чтение фрагментов.
CREATE SCHEMA IF NOT EXISTS ai;
GRANT USAGE ON SCHEMA ai TO ai_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA ai TO ai_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA ai GRANT SELECT ON TABLES TO ai_reader;
