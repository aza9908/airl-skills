-- Модуль «Дебиторка» (receivables). Требует kit/kit.sql в той же схеме
-- и представления src_rcv_clients, src_receivables_docs (адаптер или demo_src.sql).
-- Сумма показателей — только в основной валюте (настройка currency, по умолчанию KZT).

-- Действия по взысканию: звонки, письма, встречи, остановка отгрузок.
CREATE TABLE IF NOT EXISTS rcv_actions (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id         text        NOT NULL,
    doc_no            text,                     -- если действие по конкретному документу
    kind              text        NOT NULL
                      CHECK (kind IN ('call', 'message', 'meeting', 'letter', 'claim', 'stop_shipments')),
    result            text        NOT NULL
                      CHECK (result IN ('reached', 'not_reached', 'promised', 'disputed', 'refused', 'other')),
    comment           text,
    next_contact_date date,
    status            text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        text        NOT NULL,
    updated_at        timestamptz,
    updated_by        text,
    CHECK (result NOT IN ('disputed', 'refused', 'other') OR comment IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS rcv_actions_client_idx ON rcv_actions (client_id, created_at);

-- Обещания оплатить. Выполнено или нет — считает v_rcv_promises по оплатам в источнике.
CREATE TABLE IF NOT EXISTS rcv_promises (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id          text          NOT NULL,
    action_id          bigint        REFERENCES rcv_actions (id),
    promised_date      date          NOT NULL,
    promised_amount    numeric(18,2) NOT NULL CHECK (promised_amount > 0),
    currency           char(3)       NOT NULL,
    balance_at_promise numeric(18,2),           -- долг клиента в момент обещания (заполняется сам)
    status             text          NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled')),
    comment            text,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    created_by         text          NOT NULL,
    updated_at         timestamptz,
    updated_by         text,
    CHECK (status <> 'cancelled' OR comment IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS rcv_promises_client_idx ON rcv_promises (client_id, promised_date);

DROP TRIGGER IF EXISTS rcv_actions_touch ON rcv_actions;
CREATE TRIGGER rcv_actions_touch BEFORE UPDATE ON rcv_actions FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS rcv_promises_touch ON rcv_promises;
CREATE TRIGGER rcv_promises_touch BEFORE UPDATE ON rcv_promises FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Долг клиента в момент обещания: остаток по документам, выписанным не позже даты обещания.
CREATE OR REPLACE FUNCTION rcv_promises_fill() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.balance_at_promise IS NULL THEN
        SELECT COALESCE(sum(d.amount - d.paid_amount), 0) INTO NEW.balance_at_promise
        FROM src_receivables_docs d
        WHERE d.client_id = NEW.client_id AND d.currency = NEW.currency
          AND d.doc_date <= NEW.created_at::date;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS rcv_promises_fill ON rcv_promises;
CREATE TRIGGER rcv_promises_fill BEFORE INSERT ON rcv_promises FOR EACH ROW EXECUTE FUNCTION rcv_promises_fill();

-- Открытые документы: остаток, срок оплаты, дни просрочки, корзина возраста долга.
-- Срок: из документа; если его нет — дата документа + отсрочка клиента (если разрешено
-- настройкой use_contract_terms); если нет и её — корзина no_terms (в список качества данных).
CREATE OR REPLACE VIEW v_rcv_docs AS
SELECT d.doc_no, d.doc_date, d.client_id,
       COALESCE(c.client_name, d.client_name) AS client_name,
       COALESCE(d.manager_id, c.manager_id) AS manager_id,
       d.branch_id, d.currency,
       d.amount, d.paid_amount,
       (d.amount - d.paid_amount)::numeric(18,2) AS balance,
       COALESCE(c.is_aggregator, false) AS is_aggregator,
       (c.client_id IS NULL) AS unknown_client,
       d.due_date,
       e.due AS effective_due_date,
       (CASE WHEN d.due_date IS NOT NULL THEN 'document'
             WHEN e.due IS NOT NULL THEN 'contract'
             ELSE 'none' END)::text AS due_source,
       CASE WHEN e.due IS NOT NULL THEN greatest(current_date - e.due, 0) END AS days_overdue,
       (CASE WHEN d.amount - d.paid_amount < 0 THEN 'credit'
             WHEN e.due IS NULL THEN 'no_terms'
             WHEN current_date <= e.due THEN 'current'
             WHEN current_date - e.due <= 30 THEN '1-30'
             WHEN current_date - e.due <= 60 THEN '31-60'
             WHEN current_date - e.due <= 90 THEN '61-90'
             ELSE '90+' END)::text AS bucket,
       (d.currency = (airl_setting('receivables', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}')) AS in_main_currency
FROM src_receivables_docs d
LEFT JOIN src_rcv_clients c ON c.client_id = d.client_id
CROSS JOIN LATERAL (
    SELECT COALESCE(d.due_date,
                    CASE WHEN (airl_setting('receivables', 'use_contract_terms', 'true'))::text::boolean
                         THEN d.doc_date + c.payment_terms_days END) AS due
) e
WHERE d.amount - d.paid_amount <> 0;

-- Обещания с итогом: выполнено (kept), ждём (waiting), нарушено (broken), отменено.
-- Оплачено с момента обещания = долг тогда − долг сейчас по тем же документам.
CREATE OR REPLACE VIEW v_rcv_promises AS
WITH p AS (
    SELECT p.*,
           p.balance_at_promise
             - (SELECT COALESCE(sum(d.amount - d.paid_amount), 0)
                  FROM src_receivables_docs d
                 WHERE d.client_id = p.client_id AND d.currency = p.currency
                   AND d.doc_date <= p.created_at::date) AS paid_since
    FROM rcv_promises p
),
o AS (
    SELECT p.*,
           (CASE WHEN p.status = 'cancelled' THEN 'cancelled'
                 WHEN p.paid_since >= p.promised_amount
                      * (1 - (airl_setting('receivables', 'promise_tolerance_pct', '5'))::text::numeric / 100)
                      THEN 'kept'
                 WHEN p.promised_date < current_date THEN 'broken'
                 ELSE 'waiting' END)::text AS outcome
    FROM p
)
SELECT o.id AS promise_id, o.client_id, c.client_name, c.manager_id, o.action_id,
       o.promised_date, o.promised_amount, o.currency, o.balance_at_promise,
       o.paid_since::numeric(18,2) AS paid_since,
       o.status, o.comment, o.created_at, o.created_by, o.outcome,
       CASE WHEN o.outcome = 'broken' THEN current_date - o.promised_date END AS days_late
FROM o
LEFT JOIN src_rcv_clients c ON c.client_id = o.client_id;

-- Экран «Дебиторка по клиентам»: возраст долга, лимит, последнее действие, обещание.
-- Только основная валюта; документы в других валютах — в v_rcv_data_quality.
CREATE OR REPLACE VIEW v_rcv_aging AS
WITH agg AS (
    SELECT client_id, max(client_name) AS client_name, max(manager_id) AS manager_id,
           bool_or(is_aggregator) AS is_aggregator,
           COALESCE(sum(balance) FILTER (WHERE balance > 0), 0)::numeric(18,2)            AS open_total,
           COALESCE(sum(balance), 0)::numeric(18,2)                                         AS net_balance,
           COALESCE(sum(balance) FILTER (WHERE bucket = 'current'), 0)::numeric(18,2)     AS not_due,
           COALESCE(sum(balance) FILTER (WHERE bucket = '1-30'), 0)::numeric(18,2)        AS overdue_1_30,
           COALESCE(sum(balance) FILTER (WHERE bucket = '31-60'), 0)::numeric(18,2)       AS overdue_31_60,
           COALESCE(sum(balance) FILTER (WHERE bucket = '61-90'), 0)::numeric(18,2)       AS overdue_61_90,
           COALESCE(sum(balance) FILTER (WHERE bucket = '90+'), 0)::numeric(18,2)         AS overdue_90_plus,
           COALESCE(sum(balance) FILTER (WHERE bucket IN ('1-30', '31-60', '61-90', '90+')), 0)::numeric(18,2) AS overdue,
           COALESCE(sum(balance) FILTER (WHERE bucket = 'no_terms'), 0)::numeric(18,2)    AS no_terms,
           COALESCE(-sum(balance) FILTER (WHERE bucket = 'credit'), 0)::numeric(18,2)     AS credit_balance,
           max(days_overdue) AS max_days_overdue
    FROM v_rcv_docs
    WHERE in_main_currency
    GROUP BY client_id
)
SELECT a.client_id, a.client_name, a.manager_id, a.is_aggregator,
       c.credit_limit, c.payment_terms_days,
       a.open_total, a.net_balance, a.not_due,
       a.overdue_1_30, a.overdue_31_60, a.overdue_61_90, a.overdue_90_plus, a.overdue,
       a.no_terms, a.credit_balance, a.max_days_overdue,
       round(100.0 * a.net_balance / NULLIF(c.credit_limit, 0), 1) AS limit_used_pct,
       (c.credit_limit IS NOT NULL AND a.net_balance > c.credit_limit) AS over_limit,
       la.created_at AS last_action_at, la.kind AS last_action_kind, la.result AS last_action_result,
       la.next_contact_date,
       pr.promised_date, pr.promised_amount, pr.outcome AS promise_outcome
FROM agg a
LEFT JOIN src_rcv_clients c ON c.client_id = a.client_id
LEFT JOIN LATERAL (
    SELECT x.created_at, x.kind, x.result, x.next_contact_date FROM rcv_actions x
    WHERE x.client_id = a.client_id AND x.status = 'active'
    ORDER BY x.created_at DESC, x.id DESC LIMIT 1
) la ON true
LEFT JOIN LATERAL (
    SELECT y.promised_date, y.promised_amount, y.outcome FROM v_rcv_promises y
    WHERE y.client_id = a.client_id AND y.outcome <> 'cancelled'
    ORDER BY y.created_at DESC, y.promise_id DESC LIMIT 1
) pr ON true;

-- Экран «По менеджерам». Агрегаторы (маркетплейсы) — отдельной строкой, не в сумме менеджера.
CREATE OR REPLACE VIEW v_rcv_by_manager AS
SELECT CASE WHEN a.is_aggregator THEN 'aggregators' ELSE COALESCE(a.manager_id, 'unassigned') END AS manager_id,
       count(*)::int AS clients,
       sum(a.open_total)::numeric(18,2) AS open_total,
       sum(a.overdue)::numeric(18,2) AS overdue,
       sum(a.overdue_90_plus)::numeric(18,2) AS overdue_90_plus,
       round(100.0 * sum(a.overdue) / NULLIF(sum(a.open_total), 0), 1) AS overdue_share_pct,
       (count(*) FILTER (WHERE a.over_limit))::int AS over_limit_clients,
       (count(*) FILTER (WHERE a.promise_outcome = 'broken'))::int AS broken_promises
FROM v_rcv_aging a
GROUP BY 1;

-- Экран «Качество данных»: что нельзя честно посчитать, пока не исправят в источнике.
CREATE OR REPLACE VIEW v_rcv_data_quality AS
SELECT 'no_terms'::text AS issue, 'danger'::text AS severity,
       'Нет срока оплаты ни в документе, ни в условиях клиента — просрочку посчитать нельзя'::text AS description,
       client_id, client_name, manager_id, doc_no, doc_date, balance, currency
FROM v_rcv_docs WHERE due_source = 'none' AND balance > 0
UNION ALL
SELECT 'terms_from_contract', 'info',
       'Срок оплаты не указан в документе, взят из отсрочки клиента',
       client_id, client_name, manager_id, doc_no, doc_date, balance, currency
FROM v_rcv_docs WHERE due_source = 'contract' AND balance > 0
UNION ALL
SELECT 'unknown_client', 'warning',
       'Клиента нет в справочнике: нет лимита, отсрочки и признака агрегатора',
       client_id, client_name, manager_id, doc_no, doc_date, balance, currency
FROM v_rcv_docs WHERE unknown_client
UNION ALL
SELECT 'overpaid', 'warning',
       'Оплачено больше суммы документа — проверьте разнесение оплаты',
       client_id, client_name, manager_id, doc_no, doc_date, balance, currency
FROM v_rcv_docs WHERE amount > 0 AND paid_amount > amount
UNION ALL
SELECT 'other_currency', 'info',
       'Документ не в основной валюте — не входит в показатели',
       client_id, client_name, manager_id, doc_no, doc_date, balance, currency
FROM v_rcv_docs WHERE NOT in_main_currency
UNION ALL
SELECT 'no_credit_limit', 'warning',
       'У клиента есть долг, но не задан кредитный лимит',
       a.client_id, a.client_name, a.manager_id, NULL::text, NULL::date, a.open_total, (airl_setting('receivables', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}')::char(3)
FROM v_rcv_aging a WHERE a.credit_limit IS NULL AND NOT a.is_aggregator AND a.open_total > 0;

-- Журнал действий по взысканию.
CREATE OR REPLACE VIEW v_rcv_actions AS
SELECT x.id, x.client_id, c.client_name, c.manager_id, x.doc_no, x.kind, x.result, x.comment,
       x.next_contact_date, (x.next_contact_date < current_date) AS next_contact_overdue,
       x.status, x.created_at, x.created_by
FROM rcv_actions x
LEFT JOIN src_rcv_clients c ON c.client_id = x.client_id;

-- Показатель: просроченная дебиторка на сегодня, основная валюта, без агрегаторов.
CREATE OR REPLACE VIEW m_receivables_overdue AS
WITH s AS (
    SELECT COALESCE(sum(balance) FILTER (WHERE bucket IN ('1-30', '31-60', '61-90', '90+')), 0)::numeric(18,2) AS v
    FROM v_rcv_docs
    WHERE in_main_currency
      AND (NOT is_aggregator OR (airl_setting('receivables', 'include_aggregators', 'false'))::text::boolean)
)
SELECT 'receivables_overdue'::text AS metric_id,
       to_char(current_date, 'YYYY-MM-DD') AS period,
       s.v AS value,
       (airl_setting('receivables', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}')::text AS unit,
       airl_traffic(s.v,
           (airl_setting('receivables', 'overdue_warn', '3000000'))::text::numeric,
           (airl_setting('receivables', 'overdue_bad', '10000000'))::text::numeric,
           false) AS status
FROM s;

-- Показатель: доля просроченной в открытой дебиторке (%), основная валюта, без агрегаторов.
CREATE OR REPLACE VIEW m_receivables_overdue_share AS
WITH s AS (
    SELECT round(100.0 * sum(balance) FILTER (WHERE bucket IN ('1-30', '31-60', '61-90', '90+'))
                 / NULLIF(sum(balance) FILTER (WHERE balance > 0), 0), 1) AS v
    FROM v_rcv_docs
    WHERE in_main_currency
      AND (NOT is_aggregator OR (airl_setting('receivables', 'include_aggregators', 'false'))::text::boolean)
)
SELECT 'receivables_overdue_share'::text AS metric_id,
       to_char(current_date, 'YYYY-MM-DD') AS period,
       COALESCE(s.v, 0) AS value,
       '%'::text AS unit,
       airl_traffic(COALESCE(s.v, 0),
           (airl_setting('receivables', 'share_warn', '20'))::text::numeric,
           (airl_setting('receivables', 'share_bad', '35'))::text::numeric,
           false) AS status
FROM s;

-- Очередь уведомлений: нарушенное обещание, превышение лимита, новый долг 90+.
-- Повторный вызов не создаёт дублей (dedup_key).
CREATE OR REPLACE FUNCTION rcv_queue_notifications() RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_channel text := airl_setting('receivables', 'channel', '"telegram"') #>> '{}';
    v_fin     text := airl_setting('receivables', 'finance_recipient', '"role:fin_director"') #>> '{}';
    v_n int; v_total int := 0;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'receivables:broken:' || p.promise_id || ':' || p.manager_id, 'receivables', v_channel, p.manager_id,
           'Клиент ' || p.client_name || ' не выполнил обещание оплатить '
           || p.promised_amount || ' ' || p.currency || ' до ' || to_char(p.promised_date, 'DD.MM.YYYY')
    FROM v_rcv_promises p
    WHERE p.outcome = 'broken' AND p.manager_id IS NOT NULL
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;

    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'receivables:over_limit:' || a.client_id || '.' || to_char(current_date, 'YYYY-MM') || ':' || r.rcp,
           'receivables', v_channel, r.rcp,
           'Клиент ' || a.client_name || ' превысил кредитный лимит: долг ' || a.net_balance
           || ' при лимите ' || a.credit_limit
    FROM v_rcv_aging a
    CROSS JOIN LATERAL (VALUES (a.manager_id), (v_fin)) AS r(rcp)
    WHERE a.over_limit AND NOT a.is_aggregator AND r.rcp IS NOT NULL
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;

    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'receivables:90plus:' || d.doc_no || ':' || v_fin, 'receivables', v_channel, v_fin,
           'Долг старше 90 дней: ' || d.client_name || ', документ ' || d.doc_no || ', остаток ' || d.balance || ' ' || d.currency
    FROM v_rcv_docs d
    WHERE d.bucket = '90+' AND NOT d.is_aggregator
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    RETURN v_total;
END $$;
