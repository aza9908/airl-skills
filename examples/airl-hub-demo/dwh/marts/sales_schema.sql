-- Витрина «Продажи» (mart_sales), свои таблицы рядом с модулем plan-fact. Ставится под svc_sales.
-- Воронку ведёт amoCRM (купленная система): статусы заявок сервис не меняет, только напоминания.
SET search_path TO mart_sales;

-- Кто из пользователей хаба — какой менеджер amoCRM (для «только свои заявки»).
CREATE TABLE IF NOT EXISTS sales_staff (
    login       text PRIMARY KEY,
    manager_id  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text NOT NULL
);

-- Напоминание «перезвонить» по заявке amoCRM: ссылка lead_id на core.leads, без копии данных.
CREATE TABLE IF NOT EXISTS lead_followups (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lead_id     text        NOT NULL,
    due_date    date        NOT NULL,
    comment     text        CHECK (comment IS NULL OR length(comment) <= 1000),
    status      text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'done', 'cancelled')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text        NOT NULL
);
CREATE INDEX IF NOT EXISTS lead_followups_lead ON lead_followups (lead_id, status);
DROP TRIGGER IF EXISTS lead_followups_touch ON lead_followups;
CREATE TRIGGER lead_followups_touch BEFORE UPDATE ON lead_followups FOR EACH ROW EXECUTE FUNCTION airl_touch();
