-- Схема оболочки хаба (hub): тестовые пользователи демо-входа и журнал хаба.
-- Владелец — svc_hub. Пароли хранятся только хешем scrypt; задаются при первом
-- запуске из переменной окружения DEMO_PASSWORD (scripts/create_users.js) и в git не попадают.
SET search_path TO hub;

CREATE TABLE IF NOT EXISTS users (
    login         text PRIMARY KEY CHECK (login ~ '^[a-z][a-z0-9_]{2,40}$'),
    display_name  text        NOT NULL,
    role          text        NOT NULL CHECK (role ~ '^(ceo|(head|staff)_[a-z]+)$'),
    department    text,
    password_hash text        NOT NULL,
    disabled      boolean     NOT NULL DEFAULT false,
    failed_logins int         NOT NULL DEFAULT 0,
    locked_until  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- Журнал хаба: вход, открытие сервиса, ошибки опроса. Без ПДн, кроме логина.
CREATE TABLE IF NOT EXISTS journal (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at      timestamptz NOT NULL DEFAULT now(),
    login   text,
    event   text        NOT NULL CHECK (event IN ('login', 'login_failed', 'logout', 'open_service', 'summary_error', 'denied')),
    detail  text
);
CREATE INDEX IF NOT EXISTS journal_at ON journal (at);
