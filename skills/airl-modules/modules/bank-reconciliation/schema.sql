-- Модуль «Сверка банковской выписки» (bank-reconciliation). Требует kit/kit.sql в той же
-- схеме и представления src_bank_statement_lines, src_bank_open_items (адаптер или demo_src.sql).
-- Модуль предлагает сопоставления строк выписки с документами и хранит решения людей.
-- Файлы выписок разбирает адаптер; запись оплат в 1С делает навык интеграций по выгрузке
-- v_bank_export_1c. Модуль сам ничего не проводит в учёте.

-- Валюта отчётов модуля: своя настройка или общая настройка схемы.
CREATE OR REPLACE FUNCTION bank_currency() RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    SELECT airl_setting('bank-reconciliation', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}'
$$;

-- БИН/ИИН/ИНН: только цифры (в выписках бывают пробелы и приставки «БИН»).
CREATE OR REPLACE FUNCTION bank_norm_tax(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
    SELECT NULLIF(regexp_replace(COALESCE(p, ''), '\D', '', 'g'), '')
$$;

-- Есть ли номер документа в назначении платежа.
-- Цифровая часть номера (от 3 цифр, ведущие нули не важны) ищется как отдельное число:
-- «СФ-1187» находится в «оплата по сч.1187 от …», но не в «11870».
-- Номер с буквами («GCT-2026-07») ищется без пробелов и знаков: «GCT202607».
CREATE OR REPLACE FUNCTION bank_doc_in_text(p_doc text, p_text text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
    WITH n AS (
        SELECT ltrim(regexp_replace(COALESCE(p_doc, ''), '\D', '', 'g'), '0')        AS digits,
               upper(regexp_replace(COALESCE(p_doc, ''), '[^[:alnum:]]', '', 'g'))   AS alnum,
               upper(regexp_replace(COALESCE(p_text, ''), '[^[:alnum:]]', '', 'g'))  AS text_alnum
    )
    SELECT p_doc IS NOT NULL AND p_text IS NOT NULL AND (
           (length(digits) >= 3 AND p_text ~ ('(^|\D)0*' || digits || '(\D|$)'))
        OR (length(alnum) >= 5 AND alnum ~ '\D' AND position(alnum IN text_alnum) > 0))
    FROM n
$$;

-- Сопоставление: строка выписки → один или несколько документов.
--   source = suggestion — предложил модуль; manual — человек выбрал сам.
--   kind   = single (один документ), split (несколько), partial (часть документа).
CREATE SEQUENCE IF NOT EXISTS bank_match_seq;
CREATE TABLE IF NOT EXISTS bank_matches (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    match_no        text          NOT NULL UNIQUE DEFAULT 'BM-' || lpad(nextval('bank_match_seq')::text, 6, '0'),
    line_id         text          NOT NULL,
    kind            text          NOT NULL CHECK (kind IN ('single', 'split', 'partial')),
    source          text          NOT NULL CHECK (source IN ('suggestion', 'manual')),
    rule            text,                       -- правило, по которому найдено (для suggestion)
    confidence      text          CHECK (confidence IN ('high', 'medium', 'low')),
    score           int,
    alternatives    int           NOT NULL DEFAULT 0,   -- сколько ещё документов подошли так же
    explanation     text,
    line_amount     numeric(18,2) NOT NULL,
    currency        char(3)       NOT NULL,
    status          text          NOT NULL DEFAULT 'suggested'
                    CHECK (status IN ('suggested', 'confirmed', 'rejected', 'expired', 'reversed')),
    auto_confirmed  boolean       NOT NULL DEFAULT false,
    confirmed_at    timestamptz,
    confirmed_by    text,
    reject_reason   text,
    reversed_at     timestamptz,
    reversed_by     text,
    reverse_reason  text,
    comment         text,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    created_by      text          NOT NULL,
    updated_at      timestamptz,
    updated_by      text,
    CHECK (source = 'manual' OR (rule IS NOT NULL AND confidence IS NOT NULL)),
    CHECK (status NOT IN ('confirmed', 'reversed') OR (confirmed_at IS NOT NULL AND confirmed_by IS NOT NULL)),
    CHECK (status <> 'rejected' OR reject_reason IS NOT NULL),
    CHECK (status <> 'reversed' OR (reversed_at IS NOT NULL AND reverse_reason IS NOT NULL))
);
-- На строке одновременно не больше одного открытого предложения.
CREATE UNIQUE INDEX IF NOT EXISTS bank_matches_one_suggestion ON bank_matches (line_id) WHERE status = 'suggested';
CREATE INDEX IF NOT EXISTS bank_matches_line_idx ON bank_matches (line_id, status);

CREATE TABLE IF NOT EXISTS bank_match_allocs (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    match_id    bigint        NOT NULL REFERENCES bank_matches (id),
    item_id     text          NOT NULL,
    amount      numeric(18,2) NOT NULL CHECK (amount > 0),
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    UNIQUE (match_id, item_id)
);
CREATE INDEX IF NOT EXISTS bank_match_allocs_item_idx ON bank_match_allocs (item_id);

-- Строки, которые сопоставлять не нужно: комиссия банка, перевод между своими счетами,
-- зарплата, налоги. Снять отметку — archived = true (не удаляем).
CREATE TABLE IF NOT EXISTS bank_line_marks (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    line_id     text        NOT NULL,
    kind        text        NOT NULL CHECK (kind IN ('bank_fee', 'own_transfer', 'salary', 'tax', 'cash', 'other')),
    comment     text,
    archived    boolean     NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    CHECK (kind <> 'other' OR comment IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS bank_line_marks_active ON bank_line_marks (line_id) WHERE NOT archived;

-- Выгрузка подтверждённых сопоставлений для 1С: пакет → строки.
--   apply  — разнести оплату на документ; storno — отменить ранее выгруженную (после отмены сопоставления).
CREATE SEQUENCE IF NOT EXISTS bank_export_seq;
CREATE TABLE IF NOT EXISTS bank_export_batches (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_no    text        NOT NULL UNIQUE DEFAULT 'EX-' || lpad(nextval('bank_export_seq')::text, 5, '0'),
    status      text        NOT NULL DEFAULT 'prepared' CHECK (status IN ('prepared', 'loaded', 'failed')),
    lines_count int         NOT NULL DEFAULT 0,
    loaded_at   timestamptz,
    error       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    CHECK (status <> 'loaded' OR loaded_at IS NOT NULL),
    CHECK (status <> 'failed' OR error IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS bank_export_lines (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id    bigint        NOT NULL REFERENCES bank_export_batches (id),
    alloc_id    bigint        NOT NULL REFERENCES bank_match_allocs (id),
    kind        text          NOT NULL CHECK (kind IN ('apply', 'storno')),
    voided      boolean       NOT NULL DEFAULT false,   -- пакет не загрузился: строка уйдёт в следующий
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS bank_export_lines_once ON bank_export_lines (alloc_id, kind) WHERE NOT voided;

DROP TRIGGER IF EXISTS bank_matches_touch ON bank_matches;
CREATE TRIGGER bank_matches_touch BEFORE UPDATE ON bank_matches FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS bank_match_allocs_touch ON bank_match_allocs;
CREATE TRIGGER bank_match_allocs_touch BEFORE UPDATE ON bank_match_allocs FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS bank_line_marks_touch ON bank_line_marks;
CREATE TRIGGER bank_line_marks_touch BEFORE UPDATE ON bank_line_marks FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS bank_export_batches_touch ON bank_export_batches;
CREATE TRIGGER bank_export_batches_touch BEFORE UPDATE ON bank_export_batches FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Разрешённые переходы сопоставления и запись в журнал:
--   suggested → confirmed | rejected | expired;  confirmed → reversed.
CREATE OR REPLACE FUNCTION bank_matches_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
        IF (OLD.status, NEW.status) NOT IN (
            ('suggested', 'confirmed'), ('suggested', 'rejected'), ('suggested', 'expired'),
            ('confirmed', 'reversed')) THEN
            RAISE EXCEPTION 'bank-reconciliation: переход % → % не разрешён (%)', OLD.status, NEW.status, OLD.match_no;
        END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment, details)
        VALUES (COALESCE(NEW.updated_by, 'system'), 'bank-reconciliation', 'match', NEW.match_no, 'status',
                OLD.status, NEW.status, COALESCE(NEW.reverse_reason, NEW.reject_reason, NEW.comment),
                jsonb_build_object('line_id', NEW.line_id, 'rule', NEW.rule, 'auto', NEW.auto_confirmed));
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.line_id, NEW.line_amount, NEW.source) IS DISTINCT FROM (OLD.line_id, OLD.line_amount, OLD.source) THEN
        RAISE EXCEPTION 'bank-reconciliation: строку и сумму сопоставления менять нельзя — отклоните и создайте новое';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS bank_matches_status ON bank_matches;
CREATE TRIGGER bank_matches_status BEFORE UPDATE ON bank_matches FOR EACH ROW EXECUTE FUNCTION bank_matches_guard();

-- Разнесение подтверждённого сопоставления не меняется: только отмена целиком.
CREATE OR REPLACE FUNCTION bank_allocs_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM bank_matches WHERE id = OLD.match_id AND status <> 'suggested') THEN
        RAISE EXCEPTION 'bank-reconciliation: разнесение подтверждённого сопоставления не меняется — отмените его';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
DROP TRIGGER IF EXISTS bank_allocs_guard ON bank_match_allocs;
CREATE TRIGGER bank_allocs_guard BEFORE UPDATE OR DELETE ON bank_match_allocs FOR EACH ROW EXECUTE FUNCTION bank_allocs_guard();

-- Пакет выгрузки: prepared → loaded | failed.
CREATE OR REPLACE FUNCTION bank_export_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF (OLD.status, NEW.status) NOT IN (('prepared', 'loaded'), ('prepared', 'failed')) THEN
            RAISE EXCEPTION 'bank-reconciliation: переход пакета % → % не разрешён (%)', OLD.status, NEW.status, OLD.batch_no;
        END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
        VALUES (COALESCE(NEW.updated_by, 'system'), 'bank-reconciliation', 'export', NEW.batch_no, 'status',
                OLD.status, NEW.status, NEW.error);
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS bank_export_status ON bank_export_batches;
CREATE TRIGGER bank_export_status BEFORE UPDATE ON bank_export_batches FOR EACH ROW EXECUTE FUNCTION bank_export_guard();

-- Открытые документы: сколько осталось оплатить с учётом подтверждённых сопоставлений.
CREATE OR REPLACE VIEW v_bank_open_items AS
WITH paid AS (
    SELECT a.item_id, sum(a.amount) AS paid
    FROM bank_match_allocs a
    JOIN bank_matches m ON m.id = a.match_id AND m.status = 'confirmed'
    GROUP BY a.item_id
)
SELECT i.item_id, i.item_type, i.direction, i.counterparty_tax_id, bank_norm_tax(i.counterparty_tax_id) AS tax_norm,
       i.counterparty_name, i.doc_no, i.doc_date, i.amount, i.paid_before,
       COALESCE(p.paid, 0)::numeric(18,2)                                   AS paid_matched,
       (i.amount - i.paid_before - COALESCE(p.paid, 0))::numeric(18,2)      AS remaining,
       i.currency
FROM src_bank_open_items i
LEFT JOIN paid p ON p.item_id = i.item_id;

-- Строки выписки с состоянием: matched · partly_matched · unmatched · ignored.
CREATE OR REPLACE VIEW v_bank_lines AS
WITH alloc AS (
    SELECT m.line_id, sum(a.amount) AS allocated,
           bool_and(m.source = 'suggestion') AS by_suggestion,
           bool_or(m.auto_confirmed)         AS auto_confirmed
    FROM bank_matches m
    JOIN bank_match_allocs a ON a.match_id = m.id
    WHERE m.status = 'confirmed'
    GROUP BY m.line_id
),
sug AS (
    SELECT line_id, id, match_no, confidence, rule, explanation FROM bank_matches WHERE status = 'suggested'
),
mark AS (
    SELECT line_id, kind FROM bank_line_marks WHERE NOT archived
)
SELECT l.line_id, l.statement_id, l.bank, l.account, l.value_date, l.amount, l.currency,
       l.counterparty_name, l.counterparty_tax_id, bank_norm_tax(l.counterparty_tax_id) AS tax_norm,
       l.purpose, l.doc_no,
       CASE WHEN l.amount > 0 THEN 'in' ELSE 'out' END                     AS direction,
       COALESCE(a.allocated, 0)::numeric(18,2)                               AS allocated,
       (abs(l.amount) - COALESCE(a.allocated, 0))::numeric(18,2)             AS remainder,
       CASE WHEN mk.kind IS NOT NULL                          THEN 'ignored'
            WHEN abs(l.amount) - COALESCE(a.allocated, 0) <= 0 THEN 'matched'
            WHEN COALESCE(a.allocated, 0) > 0                 THEN 'partly_matched'
            ELSE 'unmatched' END                                             AS state,
       mk.kind                                                               AS ignore_kind,
       COALESCE(a.by_suggestion, false)                                      AS by_suggestion,
       COALESCE(a.auto_confirmed, false)                                     AS auto_confirmed,
       s.id AS suggestion_id, s.match_no AS suggestion_no, s.confidence AS suggestion_confidence,
       s.explanation AS suggestion_explanation,
       current_date - l.value_date                                           AS age_days
FROM src_bank_statement_lines l
LEFT JOIN alloc a ON a.line_id = l.line_id
LEFT JOIN sug s   ON s.line_id = l.line_id
LEFT JOIN mark mk ON mk.line_id = l.line_id;

-- Экран «Предложения»: открытые предложения с документами. conflict — тот же документ
-- предложен и для другой строки (например, клиент заплатил дважды).
CREATE OR REPLACE VIEW v_bank_suggestions AS
SELECT m.id AS match_id, m.match_no, m.line_id, l.value_date, l.bank, l.account, l.amount, l.currency,
       l.counterparty_name, l.purpose, m.kind, m.rule, m.confidence, m.score, m.alternatives, m.explanation,
       jsonb_agg(jsonb_build_object('item_id', a.item_id, 'doc_no', i.doc_no, 'item_type', i.item_type,
                                    'amount', a.amount, 'remaining', i.remaining) ORDER BY a.id) AS allocations,
       bool_or(EXISTS (SELECT 1 FROM bank_match_allocs a2 JOIN bank_matches m2 ON m2.id = a2.match_id
                       WHERE m2.status = 'suggested' AND m2.id <> m.id AND a2.item_id = a.item_id)) AS conflict,
       m.created_at
FROM bank_matches m
JOIN bank_match_allocs a ON a.match_id = m.id
LEFT JOIN v_bank_open_items i ON i.item_id = a.item_id
LEFT JOIN src_bank_statement_lines l ON l.line_id = m.line_id
WHERE m.status = 'suggested'
GROUP BY m.id, l.line_id, l.value_date, l.bank, l.account, l.amount, l.currency, l.counterparty_name, l.purpose;

-- Экран «Не разнесено»: строки без подтверждённого сопоставления (или с остатком).
CREATE OR REPLACE VIEW v_bank_unmatched AS
SELECT line_id, statement_id, bank, account, value_date, amount, currency, counterparty_name,
       counterparty_tax_id, purpose, allocated, remainder, state, suggestion_no, suggestion_confidence,
       suggestion_explanation, age_days,
       age_days > (airl_setting('bank-reconciliation', 'unmatched_grace_days', '2'))::text::int AS overdue
FROM v_bank_lines
WHERE state IN ('unmatched', 'partly_matched');

-- Сводка для руководителя: строки и суммы по состоянию. Суммы — только в валюте отчётов
-- (настройка currency); строки в других валютах считаются отдельно, в итог не складываются.
CREATE OR REPLACE VIEW v_bank_summary AS
SELECT state, currency, currency = bank_currency() AS in_report_currency,
       count(*) AS lines, sum(abs(amount))::numeric(18,2) AS amount, sum(remainder)::numeric(18,2) AS remainder
FROM v_bank_lines
GROUP BY state, currency;

-- История: все сопоставления с разнесением (лента «кто что подтвердил и отменил»).
CREATE OR REPLACE VIEW v_bank_matches AS
SELECT m.id AS match_id, m.match_no, m.line_id, m.kind, m.source, m.rule, m.confidence, m.status,
       m.auto_confirmed, m.line_amount, m.currency, m.explanation,
       a.item_id, i.item_type, i.doc_no, i.counterparty_name, a.amount AS alloc_amount,
       m.confirmed_at, m.confirmed_by, m.reject_reason, m.reversed_at, m.reversed_by, m.reverse_reason,
       m.created_at, m.created_by
FROM bank_matches m
JOIN bank_match_allocs a ON a.match_id = m.id
LEFT JOIN src_bank_open_items i ON i.item_id = a.item_id;

-- Точность правил: основание включать автоподтверждение после пробного периода.
-- precision_pct — доля предложений правила, которые люди подтвердили и не отменили.
CREATE OR REPLACE VIEW v_bank_rule_stats AS
SELECT rule, confidence,
       count(*)                                                              AS suggested,
       count(*) FILTER (WHERE status IN ('confirmed', 'reversed') AND NOT auto_confirmed) AS confirmed_by_people,
       count(*) FILTER (WHERE status = 'rejected')                           AS rejected,
       count(*) FILTER (WHERE status = 'reversed')                           AS reversed,
       count(*) FILTER (WHERE auto_confirmed)                                AS auto_confirmed,
       round(100.0 * count(*) FILTER (WHERE status = 'confirmed' AND NOT auto_confirmed)
             / NULLIF(count(*) FILTER (WHERE status IN ('confirmed', 'reversed', 'rejected') AND NOT auto_confirmed), 0), 1)
                                                                             AS precision_pct
FROM bank_matches
WHERE source = 'suggestion'
GROUP BY rule, confidence;

-- Выгрузка для 1С: одна строка — одна оплата по документу (storno — с минусом).
-- Эту выгрузку забирает навык интеграций и проводит в 1С; модуль в 1С не пишет.
CREATE OR REPLACE VIEW v_bank_export_1c AS
SELECT b.batch_no, b.status AS batch_status, b.created_at AS batch_created_at, e.kind,
       l.value_date, l.statement_id, l.line_id, l.account, l.bank, l.counterparty_tax_id, l.counterparty_name,
       i.item_type, a.item_id, i.doc_no,
       CASE WHEN e.kind = 'storno' THEN -a.amount ELSE a.amount END AS amount,
       m.currency, CASE WHEN l.amount > 0 THEN 'in' ELSE 'out' END AS direction,
       m.match_no, e.voided
FROM bank_export_lines e
JOIN bank_export_batches b ON b.id = e.batch_id
JOIN bank_match_allocs a   ON a.id = e.alloc_id
JOIN bank_matches m        ON m.id = a.match_id
LEFT JOIN src_bank_statement_lines l ON l.line_id = m.line_id
LEFT JOIN src_bank_open_items i      ON i.item_id = a.item_id;

-- Проверка разнесения перед подтверждением: сумма по строке и по документам не больше
-- остатков, валюта и направление совпадают. Блокирует строку и документы до конца транзакции.
CREATE OR REPLACE FUNCTION bank_check_allocs(p_match_id bigint) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_m    bank_matches%ROWTYPE;
    v_line record;
    v_sum  numeric;
    v_bad  record;
BEGIN
    SELECT * INTO v_m FROM bank_matches WHERE id = p_match_id;
    PERFORM pg_advisory_xact_lock(hashtext('bank-line:' || v_m.line_id));
    PERFORM pg_advisory_xact_lock(hashtext('bank-item:' || item_id))
    FROM (SELECT item_id FROM bank_match_allocs WHERE match_id = p_match_id ORDER BY item_id) x;

    SELECT * INTO v_line FROM v_bank_lines WHERE line_id = v_m.line_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'bank-reconciliation: строки % нет в выписке', v_m.line_id; END IF;
    IF v_line.state = 'ignored' THEN
        RAISE EXCEPTION 'bank-reconciliation: строка % отмечена как «не сопоставлять» (%)', v_m.line_id, v_line.ignore_kind;
    END IF;
    SELECT COALESCE(sum(amount), 0) INTO v_sum FROM bank_match_allocs WHERE match_id = p_match_id;
    IF v_sum = 0 THEN RAISE EXCEPTION 'bank-reconciliation: в сопоставлении % нет документов', v_m.match_no; END IF;
    IF v_sum > v_line.remainder THEN
        RAISE EXCEPTION 'bank-reconciliation: разнесено % больше остатка строки %', v_sum, v_line.remainder;
    END IF;
    SELECT a.item_id, i.remaining, i.currency, i.direction, a.amount INTO v_bad
    FROM bank_match_allocs a
    LEFT JOIN v_bank_open_items i ON i.item_id = a.item_id
    WHERE a.match_id = p_match_id
      AND (i.item_id IS NULL OR a.amount > i.remaining OR i.currency <> v_line.currency OR i.direction <> v_line.direction)
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'bank-reconciliation: документ % не подходит (остаток %, валюта %, направление %; разносим %)',
            v_bad.item_id, v_bad.remaining, v_bad.currency, v_bad.direction, v_bad.amount;
    END IF;
END $$;

-- Подтвердить предложение как есть. Если разнесение нужно другое — отклонить и сопоставить вручную.
CREATE OR REPLACE FUNCTION bank_confirm(p_match_id bigint, p_actor text, p_auto boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_m bank_matches%ROWTYPE;
BEGIN
    SELECT * INTO v_m FROM bank_matches WHERE id = p_match_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'bank-reconciliation: сопоставление % не найдено', p_match_id; END IF;
    IF v_m.status <> 'suggested' THEN
        RAISE EXCEPTION 'bank-reconciliation: подтвердить можно только предложение (% сейчас %)', v_m.match_no, v_m.status;
    END IF;
    PERFORM bank_check_allocs(p_match_id);
    UPDATE bank_matches SET status = 'confirmed', confirmed_at = now(), confirmed_by = p_actor,
                            auto_confirmed = p_auto, updated_by = p_actor
     WHERE id = p_match_id;
    RETURN v_m.match_no;
END $$;

CREATE OR REPLACE FUNCTION bank_reject(p_match_id bigint, p_actor text, p_reason text) RETURNS text
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_no text;
BEGIN
    IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'bank-reconciliation: укажите причину отклонения'; END IF;
    UPDATE bank_matches SET status = 'rejected', reject_reason = p_reason, updated_by = p_actor
     WHERE id = p_match_id AND status = 'suggested'
    RETURNING match_no INTO v_no;
    IF v_no IS NULL THEN RAISE EXCEPTION 'bank-reconciliation: отклонить можно только открытое предложение (%)', p_match_id; END IF;
    RETURN v_no;
END $$;

-- Ручное сопоставление: p_allocs = [{"item_id": "INV-1", "amount": 100000}, ...].
-- Открытое предложение по строке отклоняется с причиной «заменено ручным сопоставлением».
CREATE OR REPLACE FUNCTION bank_match_manual(p_line_id text, p_allocs jsonb, p_actor text, p_comment text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_line record;
    v_id   bigint;
    v_n    int;
BEGIN
    SELECT * INTO v_line FROM src_bank_statement_lines WHERE line_id = p_line_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'bank-reconciliation: строки % нет в выписке', p_line_id; END IF;
    IF jsonb_typeof(p_allocs) <> 'array' OR jsonb_array_length(p_allocs) = 0 THEN
        RAISE EXCEPTION 'bank-reconciliation: укажите документы и суммы';
    END IF;
    UPDATE bank_matches SET status = 'rejected', reject_reason = 'заменено ручным сопоставлением', updated_by = p_actor
     WHERE line_id = p_line_id AND status = 'suggested';
    v_n := jsonb_array_length(p_allocs);
    INSERT INTO bank_matches (line_id, kind, source, line_amount, currency, comment, created_by, updated_by)
    VALUES (p_line_id, CASE WHEN v_n > 1 THEN 'split' ELSE 'single' END, 'manual',
            v_line.amount, v_line.currency, p_comment, p_actor, p_actor)
    RETURNING id INTO v_id;
    INSERT INTO bank_match_allocs (match_id, item_id, amount, created_by)
    SELECT v_id, x->>'item_id', (x->>'amount')::numeric(18,2), p_actor FROM jsonb_array_elements(p_allocs) x;
    -- одна позиция меньше остатка документа — частичная оплата
    UPDATE bank_matches m SET kind = 'partial'
     WHERE m.id = v_id AND v_n = 1
       AND EXISTS (SELECT 1 FROM bank_match_allocs a JOIN v_bank_open_items i ON i.item_id = a.item_id
                   WHERE a.match_id = v_id AND a.amount < i.remaining);
    RETURN bank_confirm(v_id, p_actor);
END $$;

-- Отмена подтверждённого сопоставления (ошиблись документом, возврат платежа).
-- Причина обязательна; если оплата уже выгружена в 1С, следующий пакет выгрузки содержит сторно.
CREATE OR REPLACE FUNCTION bank_reverse(p_match_id bigint, p_actor text, p_reason text) RETURNS text
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_m bank_matches%ROWTYPE;
    v_rcp text := airl_setting('bank-reconciliation', 'reverse_recipient', '"role:chief_accountant"') #>> '{}';
BEGIN
    IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'bank-reconciliation: укажите причину отмены'; END IF;
    SELECT * INTO v_m FROM bank_matches WHERE id = p_match_id FOR UPDATE;
    IF NOT FOUND OR v_m.status <> 'confirmed' THEN
        RAISE EXCEPTION 'bank-reconciliation: отменить можно только подтверждённое сопоставление (%)', p_match_id;
    END IF;
    UPDATE bank_matches SET status = 'reversed', reversed_at = now(), reversed_by = p_actor,
                            reverse_reason = p_reason, updated_by = p_actor
     WHERE id = p_match_id;
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    VALUES ('bank-reconciliation:reversed:' || v_m.match_no || ':' || v_rcp, 'bank-reconciliation',
            airl_setting('bank-reconciliation', 'channel', '"telegram"') #>> '{}', v_rcp,
            'Отменено сопоставление ' || v_m.match_no || ' (строка ' || v_m.line_id || '): ' || p_reason)
    ON CONFLICT (dedup_key) DO NOTHING;
    RETURN v_m.match_no;
END $$;

-- Отметить строку «не сопоставлять» и снять отметку.
CREATE OR REPLACE FUNCTION bank_mark_line(p_line_id text, p_kind text, p_actor text, p_comment text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_id bigint;
BEGIN
    IF EXISTS (SELECT 1 FROM v_bank_lines WHERE line_id = p_line_id AND allocated > 0) THEN
        RAISE EXCEPTION 'bank-reconciliation: по строке % уже есть подтверждённое сопоставление', p_line_id;
    END IF;
    UPDATE bank_matches SET status = 'expired', comment = 'строка отмечена: ' || p_kind, updated_by = p_actor
     WHERE line_id = p_line_id AND status = 'suggested';
    INSERT INTO bank_line_marks (line_id, kind, comment, created_by, updated_by)
    VALUES (p_line_id, p_kind, p_comment, p_actor, p_actor) RETURNING id INTO v_id;
    INSERT INTO airl_audit (actor, module, entity, entity_id, action, comment, details)
    VALUES (p_actor, 'bank-reconciliation', 'line', p_line_id, 'update', p_comment, jsonb_build_object('mark', p_kind));
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION bank_unmark_line(p_line_id text, p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_n int;
BEGIN
    UPDATE bank_line_marks SET archived = true, updated_by = p_actor WHERE line_id = p_line_id AND NOT archived;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, details)
        VALUES (p_actor, 'bank-reconciliation', 'line', p_line_id, 'update', jsonb_build_object('mark', null));
    END IF;
    RETURN v_n;
END $$;

-- Подбор предложений. Запускать после каждой загрузки выписки; повторный запуск безопасен:
-- строки с открытым предложением не трогает, устаревшие предложения закрывает (expired),
-- отклонённую пару «строка — документ» не предлагает снова.
-- Правила (уверенность):
--   amount_tax_doc  сумма = остаток документа, БИН/ИНН совпадает, номер в назначении  high
--   split_tax_doc   сумма = сумме нескольких документов, БИН/ИНН и номера совпадают  high
--   amount_doc      сумма и номер совпадают, БИН/ИНН нет или другой                   medium
--   amount_tax      сумма и БИН/ИНН совпадают, номера в назначении нет               medium
--   split_tax_all   сумма = сумме всех открытых документов контрагента (2–10 шт.)    medium
--   partial_tax_doc БИН/ИНН и номер совпадают, сумма меньше остатка (частичная)       medium
--   amount_only     совпала только сумма (документ не старше amount_only_days)       low
-- Если подошли несколько документов с одинаковой оценкой — уверенность low, выбирает человек.
-- Автоподтверждение — только при auto_confirm_enabled = true, с даты auto_confirm_from,
-- для правил из auto_confirm_rules, уверенности high и без альтернатив.
CREATE OR REPLACE FUNCTION bank_suggest(p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_amount_only_days int     := (airl_setting('bank-reconciliation', 'amount_only_days', '60'))::text::int;
    v_auto             boolean := (airl_setting('bank-reconciliation', 'auto_confirm_enabled', 'false'))::text::boolean;
    v_auto_from        date    := (airl_setting('bank-reconciliation', 'auto_confirm_from', 'null') #>> '{}')::date;
    v_auto_rules       text[]  := ARRAY(SELECT jsonb_array_elements_text(
                                     airl_setting('bank-reconciliation', 'auto_confirm_rules', '["amount_tax_doc"]')));
    r    record;
    v_id bigint;
    v_n  int := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('bank-suggest'));

    UPDATE bank_matches m SET status = 'expired', comment = 'документ или строка изменились', updated_by = p_actor
    WHERE m.status = 'suggested' AND (
          NOT EXISTS (SELECT 1 FROM v_bank_lines l WHERE l.line_id = m.line_id AND l.state <> 'ignored'
                        AND l.remainder >= (SELECT sum(a.amount) FROM bank_match_allocs a WHERE a.match_id = m.id))
       OR EXISTS (SELECT 1 FROM bank_match_allocs a LEFT JOIN v_bank_open_items i ON i.item_id = a.item_id
                  WHERE a.match_id = m.id AND (i.item_id IS NULL OR i.remaining < a.amount)));

    FOR r IN
        WITH l AS (
            SELECT line_id, value_date, direction, currency, remainder, tax_norm, purpose
            FROM v_bank_lines
            WHERE state IN ('unmatched', 'partly_matched') AND suggestion_id IS NULL AND remainder > 0
        ),
        i AS (SELECT * FROM v_bank_open_items WHERE remaining > 0),
        pair AS (
            SELECT l.line_id, l.remainder, l.value_date, l.tax_norm AS line_tax,
                   i.item_id, i.doc_no, i.doc_date, i.remaining,
                   (i.remaining = l.remainder)                            AS amt_eq,
                   (l.tax_norm IS NOT NULL AND l.tax_norm = i.tax_norm)   AS tax_eq,
                   bank_doc_in_text(i.doc_no, l.purpose)                  AS doc_in
            FROM l
            JOIN i ON i.currency = l.currency AND i.direction = l.direction
                  AND (i.remaining = l.remainder OR i.tax_norm = l.tax_norm)
            WHERE NOT EXISTS (SELECT 1 FROM bank_matches x JOIN bank_match_allocs xa ON xa.match_id = x.id
                              WHERE x.line_id = l.line_id AND x.status IN ('rejected', 'reversed') AND xa.item_id = i.item_id)
        ),
        single AS (
            SELECT line_id,
                   CASE WHEN amt_eq AND tax_eq AND doc_in THEN 'amount_tax_doc'
                        WHEN amt_eq AND doc_in             THEN 'amount_doc'
                        WHEN amt_eq AND tax_eq             THEN 'amount_tax'
                        WHEN tax_eq AND doc_in AND remainder < remaining THEN 'partial_tax_doc'
                        WHEN amt_eq AND value_date - doc_date BETWEEN -3 AND v_amount_only_days THEN 'amount_only'
                   END AS rule,
                   jsonb_build_array(jsonb_build_object('item_id', item_id, 'amount', least(remainder, remaining))) AS allocs,
                   concat_ws('; ',
                       CASE WHEN amt_eq THEN 'сумма совпадает с остатком ' || doc_no
                            WHEN tax_eq AND doc_in AND remainder < remaining
                            THEN 'частичная оплата: ' || remainder || ' из ' || remaining || ' по ' || doc_no END,
                       CASE WHEN tax_eq THEN 'БИН/ИНН совпадает'
                            WHEN line_tax IS NOT NULL THEN 'БИН/ИНН плательщика другой'
                            ELSE 'БИН/ИНН в выписке нет' END,
                       CASE WHEN doc_in THEN 'номер «' || doc_no || '» есть в назначении' END) AS explanation
            FROM pair
        ),
        split_doc AS (
            SELECT line_id, 'split_tax_doc'::text AS rule,
                   jsonb_agg(jsonb_build_object('item_id', item_id, 'amount', remaining) ORDER BY doc_date, item_id) AS allocs,
                   'сумма равна сумме ' || count(*) || ' документов (' || string_agg(doc_no, ', ' ORDER BY doc_date, item_id)
                   || '); БИН/ИНН совпадает; номера есть в назначении' AS explanation
            FROM pair WHERE tax_eq AND doc_in
            GROUP BY line_id HAVING count(*) >= 2 AND sum(remaining) = max(remainder)
        ),
        split_all AS (
            SELECT line_id, 'split_tax_all'::text AS rule,
                   jsonb_agg(jsonb_build_object('item_id', item_id, 'amount', remaining) ORDER BY doc_date, item_id) AS allocs,
                   'сумма равна сумме всех ' || count(*) || ' открытых документов контрагента ('
                   || string_agg(doc_no, ', ' ORDER BY doc_date, item_id) || '); БИН/ИНН совпадает' AS explanation
            FROM pair WHERE tax_eq
            GROUP BY line_id HAVING count(*) BETWEEN 2 AND 10 AND sum(remaining) = max(remainder)
        ),
        cand AS (
            SELECT * FROM single WHERE rule IS NOT NULL
            UNION ALL SELECT * FROM split_doc
            UNION ALL SELECT * FROM split_all
        ),
        scored AS (
            SELECT c.*, s.score, s.confidence
            FROM cand c
            JOIN (VALUES ('amount_tax_doc', 100, 'high'), ('split_tax_doc', 95, 'high'),
                         ('amount_doc', 75, 'medium'), ('amount_tax', 70, 'medium'),
                         ('split_tax_all', 65, 'medium'), ('partial_tax_doc', 60, 'medium'),
                         ('amount_only', 30, 'low')) AS s(rule, score, confidence) USING (rule)
        ),
        ranked AS (
            SELECT scored.*,
                   row_number() OVER (PARTITION BY line_id ORDER BY score DESC, allocs::text) AS rn,
                   count(*) OVER (PARTITION BY line_id, score) - 1                            AS alternatives
            FROM scored
        )
        SELECT line_id, rule, allocs, explanation, score, alternatives,
               CASE WHEN alternatives > 0 THEN 'low' ELSE confidence END AS confidence
        FROM ranked WHERE rn = 1
    LOOP
        INSERT INTO bank_matches (line_id, kind, source, rule, confidence, score, alternatives, explanation,
                                  line_amount, currency, created_by, updated_by)
        SELECT r.line_id,
               CASE WHEN jsonb_array_length(r.allocs) > 1 THEN 'split'
                    WHEN r.rule = 'partial_tax_doc'       THEN 'partial' ELSE 'single' END,
               'suggestion', r.rule, r.confidence, r.score, r.alternatives,
               r.explanation || CASE WHEN r.alternatives > 0
                                     THEN '; подходят ещё ' || r.alternatives || ' док. — выберите вручную' ELSE '' END,
               l.amount, l.currency, p_actor, p_actor
        FROM src_bank_statement_lines l WHERE l.line_id = r.line_id
        RETURNING id INTO v_id;
        INSERT INTO bank_match_allocs (match_id, item_id, amount, created_by)
        SELECT v_id, x->>'item_id', (x->>'amount')::numeric(18,2), p_actor FROM jsonb_array_elements(r.allocs) x;
        v_n := v_n + 1;

        IF v_auto AND v_auto_from IS NOT NULL AND current_date >= v_auto_from
           AND r.confidence = 'high' AND r.alternatives = 0 AND r.rule = ANY (v_auto_rules) THEN
            BEGIN
                PERFORM bank_confirm(v_id, 'auto:' || r.rule, true);
            EXCEPTION WHEN OTHERS THEN
                NULL;   -- документ уже занят другой строкой: остаётся предложением для человека
            END;
        END IF;
    END LOOP;
    RETURN v_n;
END $$;

-- Пакет выгрузки для 1С: новые подтверждённые разнесения (apply) и сторно отменённых
-- после выгрузки. Нечего выгружать — NULL, пустой пакет не создаётся.
CREATE OR REPLACE FUNCTION bank_export_prepare(p_actor text) RETURNS text
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_id bigint;
    v_no text;
    v_n  int;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('bank-export'));
    IF NOT EXISTS (
        SELECT 1 FROM bank_match_allocs a JOIN bank_matches m ON m.id = a.match_id
        WHERE (m.status = 'confirmed'
               AND NOT EXISTS (SELECT 1 FROM bank_export_lines e WHERE e.alloc_id = a.id AND e.kind = 'apply' AND NOT e.voided))
           OR (m.status = 'reversed'
               AND EXISTS (SELECT 1 FROM bank_export_lines e WHERE e.alloc_id = a.id AND e.kind = 'apply' AND NOT e.voided)
               AND NOT EXISTS (SELECT 1 FROM bank_export_lines e WHERE e.alloc_id = a.id AND e.kind = 'storno' AND NOT e.voided))) THEN
        RETURN NULL;
    END IF;
    INSERT INTO bank_export_batches (created_by, updated_by) VALUES (p_actor, p_actor) RETURNING id, batch_no INTO v_id, v_no;
    INSERT INTO bank_export_lines (batch_id, alloc_id, kind, created_by)
    SELECT v_id, a.id, 'apply', p_actor
    FROM bank_match_allocs a JOIN bank_matches m ON m.id = a.match_id
    WHERE m.status = 'confirmed'
      AND NOT EXISTS (SELECT 1 FROM bank_export_lines e WHERE e.alloc_id = a.id AND e.kind = 'apply' AND NOT e.voided)
    UNION ALL
    SELECT v_id, a.id, 'storno', p_actor
    FROM bank_match_allocs a JOIN bank_matches m ON m.id = a.match_id
    WHERE m.status = 'reversed'
      AND EXISTS (SELECT 1 FROM bank_export_lines e WHERE e.alloc_id = a.id AND e.kind = 'apply' AND NOT e.voided)
      AND NOT EXISTS (SELECT 1 FROM bank_export_lines e WHERE e.alloc_id = a.id AND e.kind = 'storno' AND NOT e.voided);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    UPDATE bank_export_batches SET lines_count = v_n WHERE id = v_id;
    INSERT INTO airl_audit (actor, module, entity, entity_id, action, details)
    VALUES (p_actor, 'bank-reconciliation', 'export', v_no, 'export', jsonb_build_object('lines', v_n));
    RETURN v_no;
END $$;

-- Итог загрузки пакета в 1С (вызывает интеграция). failed — строки пакета вернутся в следующий.
CREATE OR REPLACE FUNCTION bank_export_set_status(p_batch_no text, p_status text, p_actor text, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_id bigint;
BEGIN
    UPDATE bank_export_batches
       SET status = p_status, loaded_at = CASE WHEN p_status = 'loaded' THEN now() END,
           error = p_error, updated_by = p_actor
     WHERE batch_no = p_batch_no
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'bank-reconciliation: пакет % не найден', p_batch_no; END IF;
    IF p_status = 'failed' THEN
        UPDATE bank_export_lines SET voided = true WHERE batch_id = v_id;
    END IF;
END $$;

-- Показатель: доля строк выписки, закрытых предложением модуля без ручного выбора
-- (подтверждено человеком или автоматически), по месяцу даты платежа. Отмеченные
-- «не сопоставлять» в расчёт не входят.
CREATE OR REPLACE VIEW m_bank_auto_match_rate AS
WITH c AS (
    SELECT date_trunc('month', value_date) AS m,
           round(100.0 * count(*) FILTER (WHERE state = 'matched' AND by_suggestion)
                 / NULLIF(count(*) FILTER (WHERE state <> 'ignored'), 0), 1) AS v
    FROM v_bank_lines
    GROUP BY date_trunc('month', value_date)
)
SELECT 'bank_auto_match_rate'::text AS metric_id,
       to_char(m, 'YYYY-MM')        AS period,
       v                            AS value,
       '%'::text                    AS unit,
       airl_traffic(v,
           (airl_setting('bank-reconciliation', 'match_rate_warn', '70'))::text::numeric,
           (airl_setting('bank-reconciliation', 'match_rate_bad', '50'))::text::numeric,
           true)                    AS status
FROM c;

-- Показатель: строки без сопоставления старше unmatched_grace_days дней, на сегодня.
CREATE OR REPLACE VIEW m_bank_unmatched_count AS
SELECT 'bank_unmatched_count'::text AS metric_id,
       to_char(current_date, 'YYYY-MM-DD') AS period,
       (count(*) FILTER (WHERE overdue))::numeric AS value,
       'шт'::text AS unit,
       airl_traffic(count(*) FILTER (WHERE overdue),
           (airl_setting('bank-reconciliation', 'unmatched_warn', '1'))::text::numeric,
           (airl_setting('bank-reconciliation', 'unmatched_bad', '10'))::text::numeric,
           false) AS status
FROM v_bank_unmatched;

-- Уведомления (по расписанию, раз в час): строка без сопоставления дольше
-- unmatched_grace_days — бухгалтеру, один раз на строку.
CREATE OR REPLACE FUNCTION bank_queue_notifications() RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_channel text := airl_setting('bank-reconciliation', 'channel', '"telegram"') #>> '{}';
    v_rcp     text := airl_setting('bank-reconciliation', 'recipient', '"role:accountant"') #>> '{}';
    v_n int;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'bank-reconciliation:unmatched:' || u.line_id || ':' || v_rcp, 'bank-reconciliation', v_channel, v_rcp,
           'Не разнесён платёж ' || to_char(u.value_date, 'DD.MM') || ': ' || u.counterparty_name || ', '
           || to_char(u.amount, 'FM999G999G999G990D00') || ' ' || u.currency || ' (' || u.age_days || ' дн.)'
    FROM v_bank_unmatched u
    WHERE u.overdue
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;
