-- Модуль «Клиенты под риском» (churn-risk). Требует kit/kit.sql в той же схеме
-- и представление src_churn_sales (адаптер или demo_src.sql).
-- Правило, а не ИИ: закупки клиента за последние N недель сравниваются с его же
-- средними закупками за предыдущие месяцы. Все пороги — в airl_settings.

-- Причины ухода / снижения (список настраивается под компанию).
CREATE TABLE IF NOT EXISTS churn_reasons (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text        NOT NULL UNIQUE,
    title       text        NOT NULL,
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text
);

-- Действия менеджера по клиенту под риском.
CREATE TABLE IF NOT EXISTS churn_actions (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id      text        NOT NULL,
    action_type    text        NOT NULL
                   CHECK (action_type IN ('call', 'visit', 'message', 'tasting', 'offer', 'other')),
    reason_code    text        REFERENCES churn_reasons (code),
    outcome        text        NOT NULL DEFAULT 'pending'
                   CHECK (outcome IN ('pending', 'not_reached', 'will_order', 'ordered', 'no_issue', 'lost')),
    comment        text,
    next_step      text,
    next_step_date date,
    status         text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     text        NOT NULL,
    updated_at     timestamptz,
    updated_by     text,
    CHECK (outcome <> 'lost' OR reason_code IS NOT NULL),
    CHECK (next_step_date IS NULL OR next_step IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS churn_actions_client_idx ON churn_actions (client_id, created_at);

-- «Отложить»: клиент скрыт из списка менеджера до даты (сезонность, ремонт, отпуск владельца).
CREATE TABLE IF NOT EXISTS churn_snoozes (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id    text        NOT NULL,
    snooze_until date        NOT NULL,
    reason_code  text        NOT NULL REFERENCES churn_reasons (code),
    comment      text,
    status       text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text        NOT NULL,
    updated_at   timestamptz,
    updated_by   text
);
CREATE INDEX IF NOT EXISTS churn_snoozes_client_idx ON churn_snoozes (client_id, snooze_until);

DROP TRIGGER IF EXISTS churn_reasons_touch ON churn_reasons;
CREATE TRIGGER churn_reasons_touch BEFORE UPDATE ON churn_reasons FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS churn_actions_touch ON churn_actions;
CREATE TRIGGER churn_actions_touch BEFORE UPDATE ON churn_actions FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS churn_snoozes_touch ON churn_snoozes;
CREATE TRIGGER churn_snoozes_touch BEFORE UPDATE ON churn_snoozes FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Классификация каждого клиента на сегодня.
--   new       первая покупка позже, чем new_days назад — сравнивать не с чем;
--   lost      нет покупок дольше lost_days;
--   silent    нет покупок дольше max(silence_days, двух обычных интервалов клиента между заказами);
--   declining закупки за recent_weeks (в пересчёте на месяц) ниже базы на drop_pct и больше,
--             если в базе не меньше min_orders заказов;
--   active    всё остальное.
-- База — средняя закупка в месяц за baseline_months месяцев до последних recent_weeks недель.
-- est_lost_monthly — ОЦЕНКА выпадающей выручки в месяц: база − текущий темп.
CREATE OR REPLACE VIEW v_churn_clients AS
WITH cfg AS (
    SELECT (airl_setting('churn-risk', 'recent_weeks', '4'))::text::int              AS recent_weeks,
           (airl_setting('churn-risk', 'baseline_months', '3'))::text::int           AS baseline_months,
           (airl_setting('churn-risk', 'drop_pct', '30'))::text::numeric             AS drop_pct,
           (airl_setting('churn-risk', 'min_orders', '3'))::text::int                AS min_orders,
           (airl_setting('churn-risk', 'silence_days', '30'))::text::int             AS silence_days,
           (airl_setting('churn-risk', 'lost_days', '90'))::text::int                AS lost_days,
           (airl_setting('churn-risk', 'new_days', '60'))::text::int                 AS new_days,
           (airl_setting('churn-risk', 'history_days', '365'))::text::int            AS history_days,
           (airl_setting('churn-risk', 'include_aggregators', 'false'))::text::boolean AS include_aggr
),
win AS (
    SELECT cfg.*,
           current_date - cfg.recent_weeks * 7 AS recent_start,
           (current_date - cfg.recent_weeks * 7 - make_interval(months => cfg.baseline_months))::date AS base_start
    FROM cfg
),
per AS (
    SELECT s.client_id,
           max(s.client_name) AS client_name,
           (array_agg(s.manager_id ORDER BY s.sale_date DESC))[1] AS manager_id,
           (array_agg(s.branch_id ORDER BY s.sale_date DESC))[1]  AS branch_id,
           count(DISTINCT s.point_id)::int AS points,
           min(s.sale_date) AS first_sale,
           max(s.sale_date) AS last_sale,
           COALESCE(sum(s.amount) FILTER (WHERE s.sale_date >= w.recent_start), 0) AS recent_rev,
           COALESCE(sum(s.amount) FILTER (WHERE s.sale_date >= w.base_start AND s.sale_date < w.recent_start), 0) AS base_rev,
           sum(s.gross_profit) FILTER (WHERE s.sale_date >= w.base_start AND s.sale_date < w.recent_start) AS base_gp,
           count(DISTINCT s.sale_date) FILTER (WHERE s.sale_date >= w.base_start AND s.sale_date < w.recent_start)::int AS base_orders,
           count(DISTINCT s.sale_date) FILTER (WHERE s.sale_date >= w.recent_start)::int AS recent_orders,
           count(DISTINCT s.sale_date) FILTER (WHERE s.sale_date >= w.base_start)::int AS window_orders,
           min(s.sale_date) FILTER (WHERE s.sale_date >= w.base_start) AS window_first
    FROM src_churn_sales s
    CROSS JOIN win w
    WHERE (w.include_aggr OR NOT COALESCE(s.is_aggregator, false))
      AND s.sale_date <= current_date
    GROUP BY s.client_id
),
calc AS (
    SELECT p.*, w.*,
           round(p.base_rev / w.baseline_months, 2) AS baseline_monthly,
           round(p.recent_rev * 30.44 / (w.recent_weeks * 7), 2) AS recent_monthly,
           round(p.base_gp / w.baseline_months, 2) AS baseline_gp_monthly,
           (p.last_sale - p.window_first)::numeric / NULLIF(p.window_orders - 1, 0) AS avg_gap_days,
           current_date - p.last_sale AS days_since_last
    FROM per p CROSS JOIN win w
    WHERE p.last_sale >= current_date - w.history_days
),
cls AS (
    SELECT c.*,
           greatest(c.silence_days, ceil(2 * COALESCE(c.avg_gap_days, 0)))::int AS silence_threshold,
           (CASE
               WHEN c.first_sale > current_date - c.new_days THEN 'new'
               WHEN c.days_since_last > c.lost_days THEN 'lost'
               WHEN c.days_since_last > greatest(c.silence_days, ceil(2 * COALESCE(c.avg_gap_days, 0))) THEN 'silent'
               WHEN c.base_orders >= c.min_orders
                    AND c.recent_monthly < c.baseline_monthly * (1 - c.drop_pct / 100) THEN 'declining'
               ELSE 'active' END)::text AS risk_status
    FROM calc c
)
SELECT c.client_id, c.client_name, c.manager_id, c.branch_id, c.points,
       c.risk_status,
       c.first_sale, c.last_sale, c.days_since_last, c.silence_threshold,
       round(c.avg_gap_days, 1) AS avg_gap_days,
       c.base_orders, c.recent_orders,
       c.baseline_monthly::numeric(18,2) AS baseline_monthly,
       c.recent_monthly::numeric(18,2) AS recent_monthly,
       round(100.0 * (c.recent_monthly - c.baseline_monthly) / NULLIF(c.baseline_monthly, 0), 1) AS change_pct,
       c.baseline_gp_monthly::numeric(18,2) AS baseline_gp_monthly,
       (CASE WHEN c.risk_status IN ('declining', 'silent', 'lost')
             THEN greatest(c.baseline_monthly - c.recent_monthly, 0) ELSE 0 END)::numeric(18,2) AS est_lost_monthly,
       (c.risk_status IN ('declining', 'silent')) AS at_risk,
       sn.snooze_until, sn.reason_code AS snooze_reason,
       (sn.snooze_until IS NOT NULL) AS snoozed,
       la.created_at AS last_action_at, la.action_type AS last_action_type, la.outcome AS last_action_outcome,
       la.reason_code AS last_reason_code, la.next_step, la.next_step_date,
       (la.next_step_date < current_date AND la.outcome IN ('pending', 'not_reached', 'will_order')) AS next_step_overdue
FROM cls c
LEFT JOIN LATERAL (
    SELECT z.snooze_until, z.reason_code FROM churn_snoozes z
    WHERE z.client_id = c.client_id AND z.status = 'active' AND z.snooze_until >= current_date
    ORDER BY z.snooze_until DESC LIMIT 1
) sn ON true
LEFT JOIN LATERAL (
    SELECT a.created_at, a.action_type, a.outcome, a.reason_code, a.next_step, a.next_step_date FROM churn_actions a
    WHERE a.client_id = c.client_id AND a.status = 'active'
    ORDER BY a.created_at DESC, a.id DESC LIMIT 1
) la ON true;

-- Экран «Мои клиенты под риском». Фильтр «только свои» — на сервере: manager_id = пользователь.
-- Отложенные скрыты до даты; новые и активные сюда не попадают.
CREATE OR REPLACE VIEW v_churn_manager_list AS
SELECT client_id, client_name, manager_id, branch_id, risk_status, last_sale, days_since_last,
       baseline_monthly, recent_monthly, change_pct, est_lost_monthly,
       last_action_at, last_action_type, last_action_outcome, next_step, next_step_date, next_step_overdue,
       (last_action_at IS NULL OR last_action_at < now() - interval '14 days') AS needs_contact
FROM v_churn_clients
WHERE risk_status IN ('declining', 'silent', 'lost')
  AND NOT snoozed
  AND COALESCE(last_action_outcome, 'pending') <> 'lost';

-- Экран руководителя: по менеджерам.
CREATE OR REPLACE VIEW v_churn_head AS
SELECT COALESCE(manager_id, 'unassigned') AS manager_id,
       count(*)::int AS clients,
       (count(*) FILTER (WHERE risk_status = 'active'))::int    AS active,
       (count(*) FILTER (WHERE risk_status = 'new'))::int       AS new_clients,
       (count(*) FILTER (WHERE risk_status = 'declining'))::int AS declining,
       (count(*) FILTER (WHERE risk_status = 'silent'))::int    AS silent,
       (count(*) FILTER (WHERE risk_status = 'lost'))::int      AS lost,
       COALESCE(sum(est_lost_monthly) FILTER (WHERE at_risk), 0)::numeric(18,2) AS at_risk_revenue,
       (count(*) FILTER (WHERE at_risk AND last_action_at >= now() - interval '7 days'))::int AS contacted_7d,
       (count(*) FILTER (WHERE at_risk AND NOT snoozed
                         AND (last_action_at IS NULL OR last_action_at < now() - interval '14 days')))::int AS no_contact_14d,
       (count(*) FILTER (WHERE next_step_overdue))::int AS next_steps_overdue
FROM v_churn_clients
GROUP BY 1;

-- Журнал действий.
CREATE OR REPLACE VIEW v_churn_actions AS
SELECT a.id, a.client_id, c.client_name, c.manager_id, c.risk_status, a.action_type,
       a.reason_code, r.title AS reason, a.outcome, a.comment, a.next_step, a.next_step_date,
       a.status, a.created_at, a.created_by
FROM churn_actions a
LEFT JOIN churn_reasons r ON r.code = a.reason_code
LEFT JOIN v_churn_clients c ON c.client_id = a.client_id;

-- Показатель: число клиентов под риском (снижают закупки или замолчали) на сегодня.
-- Цвет — по доле от клиентской базы (active + declining + silent).
CREATE OR REPLACE VIEW m_client_churn_risk AS
WITH s AS (
    SELECT count(*) FILTER (WHERE at_risk) AS n,
           count(*) FILTER (WHERE risk_status IN ('active', 'declining', 'silent')) AS base
    FROM v_churn_clients
)
SELECT 'client_churn_risk'::text AS metric_id,
       to_char(current_date, 'YYYY-MM-DD') AS period,
       s.n::numeric AS value,
       'клиентов'::text AS unit,
       airl_traffic(round(100.0 * s.n / NULLIF(s.base, 0), 1),
           (airl_setting('churn-risk', 'risk_share_warn', '10'))::text::numeric,
           (airl_setting('churn-risk', 'risk_share_bad', '20'))::text::numeric,
           false) AS status
FROM s;

-- Показатель: оценка выручки в месяц, которую можем потерять (клиенты под риском).
-- Цвет — по доле от базовой выручки в месяц всей клиентской базы.
CREATE OR REPLACE VIEW m_at_risk_revenue AS
WITH s AS (
    SELECT COALESCE(sum(est_lost_monthly) FILTER (WHERE at_risk), 0)::numeric(18,2) AS v,
           sum(baseline_monthly) FILTER (WHERE risk_status IN ('active', 'declining', 'silent')) AS base
    FROM v_churn_clients
)
SELECT 'at_risk_revenue'::text AS metric_id,
       to_char(current_date, 'YYYY-MM-DD') AS period,
       s.v AS value,
       (airl_setting('churn-risk', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}')::text AS unit,
       airl_traffic(round(100.0 * s.v / NULLIF(s.base, 0), 1),
           (airl_setting('churn-risk', 'revenue_share_warn', '5'))::text::numeric,
           (airl_setting('churn-risk', 'revenue_share_bad', '10'))::text::numeric,
           false) AS status
FROM s;

-- Очередь уведомлений: клиент стал «под риском» (раз в месяц на клиента и статус),
-- просрочен следующий шаг. Повторный вызов не создаёт дублей (dedup_key).
CREATE OR REPLACE FUNCTION churn_queue_notifications() RETURNS int LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_channel text := airl_setting('churn-risk', 'channel', '"telegram"') #>> '{}';
    v_n int; v_total int := 0;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'churn-risk:' || l.risk_status || ':' || l.client_id || '.' || to_char(current_date, 'YYYY-MM') || ':' || l.manager_id,
           'churn-risk', v_channel, l.manager_id,
           'Клиент ' || l.client_name || CASE l.risk_status WHEN 'declining' THEN ' снизил закупки на '
                || abs(round(l.change_pct)) || '%' ELSE ' не покупает ' || l.days_since_last || ' дн' END
           || '. Оценка потерь: ' || round(l.est_lost_monthly) || ' в месяц'
    FROM v_churn_manager_list l
    WHERE l.risk_status IN ('declining', 'silent') AND l.manager_id IS NOT NULL
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;

    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'churn-risk:next_step:' || a.id || ':' || a.created_by, 'churn-risk', v_channel, a.created_by,
           'Просрочен шаг по клиенту ' || COALESCE(c.client_name, a.client_id) || ': ' || a.next_step
    FROM churn_actions a
    LEFT JOIN v_churn_clients c ON c.client_id = a.client_id
    WHERE a.status = 'active' AND a.next_step_date < current_date
      AND a.outcome IN ('pending', 'not_reached', 'will_order')
      AND NOT EXISTS (SELECT 1 FROM churn_actions b
                      WHERE b.client_id = a.client_id AND b.status = 'active' AND b.created_at > a.created_at)
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    RETURN v_total;
END $$;
