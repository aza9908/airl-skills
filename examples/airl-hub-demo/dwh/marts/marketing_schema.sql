-- Витрина отдела «Маркетинг» (mart_marketing): бюджет рекламы по каналам и месяцам, заметки к кампаниям.
-- Каркас kit.sql ставится раньше. Ставится под svc_marketing. Повторный запуск безопасен.
-- Расход, заявки и окупаемость — только из metrics (формулы карты), здесь не пересчитываются.
-- Модуль leads не ставим: воронка живёт в amoCRM (корзина «купить», раздел 10 карты), формулы CPL/CAC/ROMI
-- и экран «Кампании» взяты из него в раздел 4 карты.
SET search_path TO mart_marketing;

-- Бюджет канала на месяц. Изменение — новая версия, старая остаётся в истории (archived).
CREATE TABLE IF NOT EXISTS mkt_budgets (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    month       date          NOT NULL CHECK (extract(day FROM month) = 1),
    channel     text          NOT NULL CHECK (channel IN ('instagram', 'site', 'telegram', 'meta_form', 'event', 'referral')),
    amount      numeric(18,2) NOT NULL CHECK (amount >= 0),
    comment     text          CHECK (comment IS NULL OR length(comment) <= 500),
    status      text          NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL,
    updated_at  timestamptz   NOT NULL DEFAULT now(),
    updated_by  text          NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS mkt_budgets_active ON mkt_budgets (month, channel) WHERE status = 'active';
DROP TRIGGER IF EXISTS mkt_budgets_touch ON mkt_budgets;
CREATE TRIGGER mkt_budgets_touch BEFORE UPDATE ON mkt_budgets FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Заметка маркетолога к кампании (что поменяли в объявлении, почему остановили). Ссылка campaign_id = utm_campaign.
CREATE TABLE IF NOT EXISTS mkt_campaign_notes (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_id text        NOT NULL,
    note        text        NOT NULL CHECK (length(note) BETWEEN 1 AND 1000),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL
);
CREATE INDEX IF NOT EXISTS mkt_campaign_notes_c ON mkt_campaign_notes (campaign_id, created_at);

-- «Свои записи» маркетолога: каналы, которые он ведёт (руководитель маркетинга — все).
CREATE TABLE IF NOT EXISTS mkt_staff_channels (
    login       text PRIMARY KEY,
    channels    text[] NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text NOT NULL
);

-- План-факт бюджета текущего и прошлых месяцев: факт — metrics.ad_spend_daily, прогноз — по темпу (оценка;
-- для разовых мероприятий — не меньше бюджета).
CREATE OR REPLACE VIEW v_mkt_budget AS
WITH a AS (SELECT metrics.as_of() AS at),
f AS (SELECT date_trunc('month', day)::date AS month, channel, sum(value) AS fact
      FROM metrics.ad_spend_daily, a WHERE day <= a.at GROUP BY 1, 2)
SELECT b.month, b.channel, metrics.channel_title(b.channel) AS channel_title, b.amount AS budget,
       COALESCE(f.fact, 0) AS fact,
       CASE WHEN b.month <> date_trunc('month', a.at)::date THEN COALESCE(f.fact, 0)
            -- мероприятие оплачивается разово: темп не экстраполируем, прогноз — не меньше бюджета
            WHEN b.channel = 'event' THEN greatest(COALESCE(f.fact, 0), b.amount)
            ELSE round(COALESCE(f.fact, 0) / extract(day FROM a.at) * extract(day FROM (b.month + interval '1 month - 1 day')), 0) END AS forecast,
       b.comment, b.updated_by, b.updated_at
FROM mkt_budgets b CROSS JOIN a
LEFT JOIN f ON f.month = b.month AND f.channel = b.channel
WHERE b.status = 'active';

-- Показатель витрины: исполнение рекламного бюджета текущего месяца по прогнозу (для предупреждений хаба).
CREATE OR REPLACE VIEW m_mkt_budget_usage AS
SELECT 'mkt_budget_usage'::text AS metric_id, to_char(month, 'YYYY-MM') AS period,
       round(100 * sum(forecast) / NULLIF(sum(budget), 0), 1) AS value, '%'::text AS unit,
       airl_traffic(round(100 * sum(forecast) / NULLIF(sum(budget), 0), 1),
                    (airl_setting('marketing', 'budget_warn_pct', '110'))::text::numeric,
                    (airl_setting('marketing', 'budget_bad_pct', '125'))::text::numeric, false) AS status
FROM v_mkt_budget
WHERE month = date_trunc('month', metrics.as_of())::date
GROUP BY month;
