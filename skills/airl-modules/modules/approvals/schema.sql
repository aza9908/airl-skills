-- Модуль «Согласование заявок» (approvals). Требует kit/kit.sql в той же схеме
-- и представления src_appr_departments, src_appr_counterparties (адаптер или demo_src.sql).
-- Сумма «в валюте учёта» (amount_base) — в валюте настройки currency (по умолчанию KZT).

-- Статьи расходов (виды расхода).
CREATE TABLE IF NOT EXISTS appr_categories (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code              text        NOT NULL UNIQUE,
    title             text        NOT NULL,
    budget_controlled boolean     NOT NULL DEFAULT true,   -- есть ли бюджет по статье
    requires_document boolean     NOT NULL DEFAULT true,   -- нужен ли счёт/договор во вложении
    active            boolean     NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        text        NOT NULL,
    updated_at        timestamptz,
    updated_by        text
);

-- Правила маршрута: какое правило подходит заявке — то, у которого меньше priority.
-- Пустое поле (NULL) значит «любое». Сумма: min_amount включительно, max_amount — не включая.
CREATE TABLE IF NOT EXISTS appr_rules (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         text          NOT NULL UNIQUE,
    title        text          NOT NULL,
    priority     int           NOT NULL DEFAULT 100,
    request_type text          CHECK (request_type IN ('payment', 'expense', 'purchase', 'unplanned_purchase')),
    dept_id      text,
    category     text          REFERENCES appr_categories (code),
    min_amount   numeric(18,2) NOT NULL DEFAULT 0,
    max_amount   numeric(18,2),
    active       boolean       NOT NULL DEFAULT true,
    created_at   timestamptz   NOT NULL DEFAULT now(),
    created_by   text          NOT NULL,
    updated_at   timestamptz,
    updated_by   text,
    CHECK (min_amount >= 0 AND (max_amount IS NULL OR max_amount > min_amount))
);

-- Шаги маршрута: упорядоченный список ролей согласующих.
-- Роль dept_head — руководитель подразделения заявки (src_appr_departments.head_user_id).
CREATE TABLE IF NOT EXISTS appr_rule_steps (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_id       bigint      NOT NULL REFERENCES appr_rules (id),
    step_no       int         NOT NULL CHECK (step_no > 0),
    approver_role text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text        NOT NULL,
    updated_at    timestamptz,
    updated_by    text,
    UNIQUE (rule_id, step_no)
);

-- Бюджет: подразделение × статья × месяц, в валюте учёта.
CREATE TABLE IF NOT EXISTS appr_budgets (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dept_id     text          NOT NULL,
    category    text          NOT NULL REFERENCES appr_categories (code),
    month       date          NOT NULL CHECK (extract(day FROM month) = 1),
    amount      numeric(18,2) NOT NULL CHECK (amount >= 0),
    currency    char(3)       NOT NULL,
    note        text,
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    UNIQUE (dept_id, category, month)
);

-- Заявки.
CREATE TABLE IF NOT EXISTS appr_requests (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_no        text          NOT NULL UNIQUE,
    request_type      text          NOT NULL
                      CHECK (request_type IN ('payment', 'expense', 'purchase', 'unplanned_purchase')),
    dept_id           text          NOT NULL,
    category          text          NOT NULL REFERENCES appr_categories (code),
    counterparty_id   text,                      -- ключ в src_appr_counterparties; NULL — новый контрагент
    counterparty_name text,                      -- как написал заявитель (для нового контрагента)
    purpose           text          NOT NULL,
    doc_ref           text,                      -- номер счёта, заказа или договора
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    currency          char(3)       NOT NULL,
    amount_base       numeric(18,2) NOT NULL CHECK (amount_base > 0),  -- в валюте учёта
    budget_month      date          NOT NULL CHECK (extract(day FROM budget_month) = 1),
    need_by           date,
    status            text          NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft', 'on_approval', 'approved', 'rejected', 'returned', 'paid', 'cancelled')),
    rule_id           bigint        REFERENCES appr_rules (id),   -- правило фиксируется при отправке
    current_round     int           NOT NULL DEFAULT 0,          -- номер круга согласования
    submitted_at      timestamptz,                               -- первая отправка, не переписывается
    decided_at        timestamptz,                               -- итоговое решение
    paid_at           timestamptz,
    payment_ref       text,
    cancel_reason     text,
    created_at        timestamptz   NOT NULL DEFAULT now(),
    created_by        text          NOT NULL,
    updated_at        timestamptz,
    updated_by        text,
    CHECK (counterparty_id IS NOT NULL OR counterparty_name IS NOT NULL),
    CHECK (status IN ('draft', 'cancelled') OR submitted_at IS NOT NULL),
    CHECK (status NOT IN ('approved', 'rejected', 'paid') OR decided_at IS NOT NULL),
    CHECK (status <> 'paid' OR paid_at IS NOT NULL),
    CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS appr_requests_budget_idx ON appr_requests (dept_id, category, budget_month);
CREATE INDEX IF NOT EXISTS appr_requests_status_idx ON appr_requests (status);

-- Решения по шагам. Каждый круг (после возврата на доработку) — новые строки.
CREATE TABLE IF NOT EXISTS appr_steps (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id    bigint      NOT NULL REFERENCES appr_requests (id),
    round         int         NOT NULL CHECK (round > 0),
    step_no       int         NOT NULL CHECK (step_no > 0),
    approver_role text        NOT NULL,
    decision      text        NOT NULL DEFAULT 'pending'
                  CHECK (decision IN ('pending', 'approved', 'rejected', 'returned', 'skipped')),
    decided_at    timestamptz,
    decided_by    text,
    comment       text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text        NOT NULL,
    updated_at    timestamptz,
    updated_by    text,
    UNIQUE (request_id, round, step_no),
    CHECK (decision IN ('pending', 'skipped') OR (decided_at IS NOT NULL AND decided_by IS NOT NULL)),
    CHECK (decision NOT IN ('rejected', 'returned') OR comment IS NOT NULL)
);

DROP TRIGGER IF EXISTS appr_categories_touch ON appr_categories;
CREATE TRIGGER appr_categories_touch BEFORE UPDATE ON appr_categories FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS appr_rules_touch ON appr_rules;
CREATE TRIGGER appr_rules_touch BEFORE UPDATE ON appr_rules FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS appr_rule_steps_touch ON appr_rule_steps;
CREATE TRIGGER appr_rule_steps_touch BEFORE UPDATE ON appr_rule_steps FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS appr_budgets_touch ON appr_budgets;
CREATE TRIGGER appr_budgets_touch BEFORE UPDATE ON appr_budgets FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS appr_requests_touch ON appr_requests;
CREATE TRIGGER appr_requests_touch BEFORE UPDATE ON appr_requests FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS appr_steps_touch ON appr_steps;
CREATE TRIGGER appr_steps_touch BEFORE UPDATE ON appr_steps FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Разрешённые переходы статуса заявки (схема в MODULE.md) и запись в журнал.
CREATE OR REPLACE FUNCTION appr_requests_status_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF (OLD.status, NEW.status) NOT IN (
            ('draft', 'on_approval'), ('draft', 'cancelled'),
            ('on_approval', 'approved'), ('on_approval', 'rejected'),
            ('on_approval', 'returned'), ('on_approval', 'cancelled'),
            ('returned', 'on_approval'), ('returned', 'cancelled'),
            ('approved', 'paid'), ('approved', 'cancelled')) THEN
            RAISE EXCEPTION 'approvals: переход % → % не разрешён (заявка %)', OLD.status, NEW.status, OLD.request_no;
        END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
        VALUES (COALESCE(NEW.updated_by, 'system'), 'approvals', 'request', NEW.request_no, 'status',
                OLD.status, NEW.status, NEW.cancel_reason);
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS appr_requests_status ON appr_requests;
CREATE TRIGGER appr_requests_status BEFORE UPDATE OF status ON appr_requests
    FOR EACH ROW EXECUTE FUNCTION appr_requests_status_guard();

-- Какое правило подходит заявке сейчас (для черновика — «кто будет согласовывать»).
CREATE OR REPLACE VIEW v_appr_route AS
SELECT r.id AS request_id, r.request_no, m.rule_id, m.rule_code, m.rule_title
FROM appr_requests r
LEFT JOIN LATERAL (
    SELECT ru.id AS rule_id, ru.code AS rule_code, ru.title AS rule_title
    FROM appr_rules ru
    WHERE ru.active
      AND (ru.request_type IS NULL OR ru.request_type = r.request_type)
      AND (ru.dept_id IS NULL OR ru.dept_id = r.dept_id)
      AND (ru.category IS NULL OR ru.category = r.category)
      AND r.amount_base >= ru.min_amount
      AND (ru.max_amount IS NULL OR r.amount_base < ru.max_amount)
    ORDER BY ru.priority, ru.id
    LIMIT 1
) m ON true;

-- Использование бюджета: подразделение × статья × месяц.
CREATE OR REPLACE VIEW v_appr_budget AS
WITH used AS (
    SELECT dept_id, category, budget_month,
           COALESCE(sum(amount_base) FILTER (WHERE status = 'on_approval'), 0) AS pending,
           COALESCE(sum(amount_base) FILTER (WHERE status = 'approved'), 0)    AS approved,
           COALESCE(sum(amount_base) FILTER (WHERE status = 'paid'), 0)        AS paid
    FROM appr_requests
    GROUP BY dept_id, category, budget_month
)
SELECT b.id AS budget_id, b.dept_id, d.dept_name, b.category, c.title AS category_title,
       b.month, to_char(b.month, 'YYYY-MM') AS period,
       b.amount AS budget, b.currency,
       COALESCE(u.pending, 0)::numeric(18,2)  AS pending,
       COALESCE(u.approved, 0)::numeric(18,2) AS approved,
       COALESCE(u.paid, 0)::numeric(18,2)     AS paid,
       (b.amount - COALESCE(u.approved, 0) - COALESCE(u.paid, 0))::numeric(18,2) AS remaining,
       (b.amount - COALESCE(u.approved, 0) - COALESCE(u.paid, 0) - COALESCE(u.pending, 0))::numeric(18,2) AS remaining_after_pending,
       round(100.0 * (COALESCE(u.approved, 0) + COALESCE(u.paid, 0)) / NULLIF(b.amount, 0), 1) AS used_pct,
       (COALESCE(u.approved, 0) + COALESCE(u.paid, 0)) > b.amount AS overrun
FROM appr_budgets b
LEFT JOIN used u ON u.dept_id = b.dept_id AND u.category = b.category AND u.budget_month = b.month
LEFT JOIN src_appr_departments d ON d.dept_id = b.dept_id
LEFT JOIN appr_categories c ON c.code = b.category;

-- Реестр заявок с отметками об отклонениях (нестандартных операциях).
CREATE OR REPLACE VIEW v_appr_requests AS
WITH base AS (
    SELECT r.*,
           d.dept_name, d.head_user_id,
           c.title AS category_title, c.budget_controlled, c.requires_document,
           cp.counterparty_name AS src_counterparty_name, cp.counterparty_type, cp.first_deal_date,
           b.budget, b.approved AS budget_approved, b.paid AS budget_paid, b.remaining AS budget_remaining,
           b.remaining_after_pending AS budget_remaining_after_pending,
           EXISTS (SELECT 1 FROM airl_attachments a
                   WHERE a.module = 'approvals' AND a.entity = 'request' AND a.entity_id = r.request_no) AS has_document
    FROM appr_requests r
    LEFT JOIN src_appr_departments d     ON d.dept_id = r.dept_id
    LEFT JOIN appr_categories c     ON c.code = r.category
    LEFT JOIN src_appr_counterparties cp ON cp.counterparty_id = r.counterparty_id
    LEFT JOIN v_appr_budget b       ON b.dept_id = r.dept_id AND b.category = r.category AND b.month = r.budget_month
),
flagged AS (
    SELECT base.*,
           -- заявка не помещается в бюджет вместе с уже одобренными и оплаченными
           (budget IS NOT NULL AND
            budget_approved + budget_paid
              - CASE WHEN status IN ('approved', 'paid') THEN amount_base ELSE 0 END
              + amount_base > budget) AS flag_over_budget,
           (budget IS NULL AND COALESCE(budget_controlled, true)) AS flag_no_budget,
           (NOT has_document AND COALESCE(requires_document, true)) AS flag_no_document,
           (src_counterparty_name IS NULL
            OR first_deal_date IS NULL
            OR first_deal_date > current_date - (airl_setting('approvals', 'new_counterparty_days', '90'))::text::int) AS flag_new_counterparty,
           (amount_base >= (airl_setting('approvals', 'large_amount', '5000000'))::text::numeric) AS flag_large_amount
    FROM base
)
SELECT id, request_no, request_type, dept_id, dept_name, category, category_title,
       counterparty_id, COALESCE(src_counterparty_name, counterparty_name) AS counterparty_name, counterparty_type,
       purpose, doc_ref, amount, currency, amount_base, budget_month, need_by,
       status, rule_id, current_round, submitted_at, decided_at, paid_at, payment_ref, cancel_reason,
       created_at, created_by, updated_at, updated_by,
       budget, budget_remaining, budget_remaining_after_pending, has_document,
       flag_over_budget, flag_no_budget, flag_no_document, flag_new_counterparty, flag_large_amount,
       array_remove(ARRAY[
           CASE WHEN flag_over_budget      THEN 'over_budget'      END,
           CASE WHEN flag_no_budget        THEN 'no_budget'        END,
           CASE WHEN flag_no_document      THEN 'no_document'      END,
           CASE WHEN flag_new_counterparty THEN 'new_counterparty' END,
           CASE WHEN flag_large_amount     THEN 'large_amount'     END], NULL)::text[] AS flags,
       round(extract(epoch FROM (COALESCE(decided_at, now()) - submitted_at)) / 3600, 1) AS cycle_hours
FROM flagged;

-- Экран «Мне на согласование»: текущий шаг каждой заявки на согласовании.
-- Фильтр «только мои» — на сервере: approver_user_id = пользователь
-- или approver_role входит в роли пользователя.
CREATE OR REPLACE VIEW v_appr_inbox AS
SELECT s.id AS step_id, s.request_id, r.request_no, s.round, s.step_no, s.approver_role,
       CASE WHEN s.approver_role = 'dept_head' THEN d.head_user_id END AS approver_user_id,
       (SELECT count(*) FROM appr_steps x WHERE x.request_id = s.request_id AND x.round = s.round)::int AS steps_total,
       r.request_type, r.dept_id, r.dept_name, r.category, r.category_title,
       r.counterparty_name, r.purpose, r.doc_ref, r.amount, r.currency, r.amount_base, r.need_by,
       r.created_by AS requester, r.submitted_at,
       COALESCE(prev.decided_at, r.submitted_at) AS waiting_since,
       round(extract(epoch FROM now() - COALESCE(prev.decided_at, r.submitted_at)) / 3600, 1) AS waiting_hours,
       r.budget, r.budget_remaining, r.budget_remaining_after_pending, r.flags
FROM appr_steps s
JOIN v_appr_requests r ON r.id = s.request_id AND r.status = 'on_approval' AND r.current_round = s.round
LEFT JOIN src_appr_departments d ON d.dept_id = r.dept_id
LEFT JOIN LATERAL (
    SELECT max(p.decided_at) AS decided_at FROM appr_steps p
    WHERE p.request_id = s.request_id AND p.round = s.round AND p.step_no < s.step_no
) prev ON true
WHERE s.decision = 'pending'
  AND NOT EXISTS (SELECT 1 FROM appr_steps e
                  WHERE e.request_id = s.request_id AND e.round = s.round
                    AND e.step_no < s.step_no AND e.decision <> 'approved');

-- История решений по заявке (лента на карточке заявки).
CREATE OR REPLACE VIEW v_appr_decisions AS
SELECT s.id AS step_id, r.request_no, s.round, s.step_no, s.approver_role,
       s.decision, s.decided_at, s.decided_by, s.comment
FROM appr_steps s
JOIN appr_requests r ON r.id = s.request_id;

-- Экран «Отклонения»: заявки с нестандартными признаками, кроме черновиков и отменённых.
CREATE OR REPLACE VIEW v_appr_deviations AS
SELECT id, request_no, request_type, dept_id, dept_name, category_title, counterparty_name,
       amount, currency, amount_base, budget_month, status, created_by, submitted_at,
       budget, budget_remaining, flags, cardinality(flags) AS flag_count
FROM v_appr_requests
WHERE status NOT IN ('draft', 'cancelled')
  AND cardinality(flags) > 0;

-- Показатель: медиана часов от первой отправки до итогового решения, по месяцу решения.
CREATE OR REPLACE VIEW m_approval_cycle_hours AS
WITH c AS (
    SELECT date_trunc('month', decided_at) AS m,
           round((percentile_cont(0.5) WITHIN GROUP (
               ORDER BY extract(epoch FROM decided_at - submitted_at) / 3600))::numeric, 1) AS v
    FROM appr_requests
    WHERE decided_at IS NOT NULL AND submitted_at IS NOT NULL
    GROUP BY date_trunc('month', decided_at)
)
SELECT 'approval_cycle_hours'::text AS metric_id,
       to_char(m, 'YYYY-MM') AS period,
       v AS value,
       'ч'::text AS unit,
       airl_traffic(v,
           (airl_setting('approvals', 'cycle_warn_hours', '24'))::text::numeric,
           (airl_setting('approvals', 'cycle_bad_hours', '72'))::text::numeric,
           false) AS status
FROM c;

-- Показатель: строки бюджета (подразделение × статья), где одобрено и оплачено больше бюджета.
CREATE OR REPLACE VIEW m_budget_overrun_count AS
SELECT 'budget_overrun_count'::text AS metric_id,
       period,
       (count(*) FILTER (WHERE overrun))::numeric AS value,
       'шт'::text AS unit,
       airl_traffic(count(*) FILTER (WHERE overrun), 1, 3, false) AS status
FROM v_appr_budget
GROUP BY period;

-- Отправка заявки на согласование (из черновика или после возврата):
-- фиксирует правило, создаёт шаги нового круга. Права проверяет сервер до вызова.
CREATE OR REPLACE FUNCTION appr_submit(p_request_id bigint, p_actor text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_req   appr_requests%ROWTYPE;
    v_rule  bigint;
    v_round int;
    v_steps int;
BEGIN
    SELECT * INTO v_req FROM appr_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'approvals: заявка % не найдена', p_request_id; END IF;
    IF v_req.status NOT IN ('draft', 'returned') THEN
        RAISE EXCEPTION 'approvals: отправить можно только черновик или возвращённую заявку (сейчас %)', v_req.status;
    END IF;
    SELECT rule_id INTO v_rule FROM v_appr_route WHERE request_id = p_request_id;
    IF v_rule IS NULL THEN RAISE EXCEPTION 'approvals: нет правила маршрута для заявки %', v_req.request_no; END IF;
    v_round := v_req.current_round + 1;
    INSERT INTO appr_steps (request_id, round, step_no, approver_role, created_by)
    SELECT p_request_id, v_round, rs.step_no, rs.approver_role, p_actor
    FROM appr_rule_steps rs WHERE rs.rule_id = v_rule ORDER BY rs.step_no;
    GET DIAGNOSTICS v_steps = ROW_COUNT;
    IF v_steps = 0 THEN RAISE EXCEPTION 'approvals: у правила % нет шагов', v_rule; END IF;
    UPDATE appr_requests
       SET status = 'on_approval', rule_id = v_rule, current_round = v_round,
           submitted_at = COALESCE(submitted_at, now()), updated_by = p_actor
     WHERE id = p_request_id;
    RETURN v_round;
END $$;

-- Решение по текущему шагу: approved | rejected | returned. Роль согласующего
-- проверяет сервер; функция не даёт автору согласовать свою же заявку.
CREATE OR REPLACE FUNCTION appr_decide(p_step_id bigint, p_decision text, p_actor text, p_comment text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_step appr_steps%ROWTYPE;
    v_req  appr_requests%ROWTYPE;
BEGIN
    IF p_decision NOT IN ('approved', 'rejected', 'returned') THEN
        RAISE EXCEPTION 'approvals: решение должно быть approved, rejected или returned';
    END IF;
    SELECT * INTO v_step FROM appr_steps WHERE id = p_step_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'approvals: шаг % не найден', p_step_id; END IF;
    IF NOT EXISTS (SELECT 1 FROM v_appr_inbox WHERE step_id = p_step_id) THEN
        RAISE EXCEPTION 'approvals: шаг % сейчас не ждёт решения', p_step_id;
    END IF;
    SELECT * INTO v_req FROM appr_requests WHERE id = v_step.request_id FOR UPDATE;
    IF v_req.created_by = p_actor THEN
        RAISE EXCEPTION 'approvals: автор не может согласовать свою заявку %', v_req.request_no;
    END IF;
    UPDATE appr_steps SET decision = p_decision, decided_at = now(), decided_by = p_actor,
                          comment = p_comment, updated_by = p_actor
     WHERE id = p_step_id;
    INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment, details)
    VALUES (p_actor, 'approvals', 'step', p_step_id::text, 'status', 'pending', p_decision, p_comment,
            jsonb_build_object('request_no', v_req.request_no, 'round', v_step.round, 'step_no', v_step.step_no));
    IF p_decision IN ('rejected', 'returned') THEN
        UPDATE appr_steps SET decision = 'skipped', updated_by = p_actor
         WHERE request_id = v_step.request_id AND round = v_step.round AND decision = 'pending';
        UPDATE appr_requests SET status = p_decision,
               decided_at = CASE WHEN p_decision = 'rejected' THEN now() ELSE decided_at END,
               updated_by = p_actor
         WHERE id = v_step.request_id;
        RETURN p_decision;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM appr_steps WHERE request_id = v_step.request_id
                     AND round = v_step.round AND decision = 'pending') THEN
        UPDATE appr_requests SET status = 'approved', decided_at = now(), updated_by = p_actor
         WHERE id = v_step.request_id;
        RETURN 'approved';
    END IF;
    RETURN 'on_approval';
END $$;

-- Очередь уведомлений: новый шаг, напоминание о зависшем шаге, итог заявителю.
-- Повторный вызов не создаёт дублей (dedup_key). Получатель — пользователь или 'role:<роль>'.
CREATE OR REPLACE FUNCTION appr_queue_notifications() RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_channel text := airl_setting('approvals', 'channel', '"telegram"') #>> '{}';
    v_remind  int  := (airl_setting('approvals', 'remind_hours', '24'))::text::int;
    v_n int; v_total int := 0;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'approvals:step:' || i.step_id || ':' || rcp, 'approvals', v_channel, rcp,
           'Заявка ' || i.request_no || ' ждёт вашего решения: ' || i.purpose || ', '
           || to_char(i.amount, 'FM999G999G999G990D00') || ' ' || i.currency
    FROM v_appr_inbox i, LATERAL (SELECT COALESCE(i.approver_user_id, 'role:' || i.approver_role) AS rcp) x
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;

    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'approvals:remind:' || i.step_id || ':' || rcp, 'approvals', v_channel, rcp,
           'Напоминание: заявка ' || i.request_no || ' ждёт решения ' || floor(i.waiting_hours) || ' ч'
    FROM v_appr_inbox i, LATERAL (SELECT COALESCE(i.approver_user_id, 'role:' || i.approver_role) AS rcp) x
    WHERE i.waiting_hours >= v_remind
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;

    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'approvals:' || r.status || ':' || r.request_no || '.' || r.current_round || ':' || r.created_by,
           'approvals', v_channel, r.created_by,
           'Заявка ' || r.request_no || ': ' || CASE r.status WHEN 'approved' THEN 'согласована'
                WHEN 'rejected' THEN 'отклонена' ELSE 'возвращена на доработку' END
    FROM appr_requests r
    WHERE r.status IN ('approved', 'rejected', 'returned')
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    RETURN v_total;
END $$;
