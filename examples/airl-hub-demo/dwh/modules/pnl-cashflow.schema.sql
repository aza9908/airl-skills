-- Модуль «ОПиУ и ДДС» (pnl-cashflow). Требует kit/kit.sql в той же схеме и представления
-- src_pnl_entries, src_pnl_cash (адаптер или demo_src.sql).
-- Управленческий отчёт о прибылях и убытках по месяцам и филиалам (факт, бюджет, прошлый
-- год, расшифровка до проводки) и движение денег по видам деятельности. Пересчёт фактов —
-- функция pnl_rebuild() (после каждой загрузки из 1С); экраны читают готовую таблицу pnl_facts.

CREATE OR REPLACE FUNCTION pnl_currency() RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    SELECT airl_setting('pnl-cashflow', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}'
$$;

-- Управленческие статьи — дерево. section задаёт место в отчёте:
--   revenue → cogs → [валовая прибыль] → opex → other → [EBITDA] → depreciation → [EBIT]
--   → finance → tax → [чистая прибыль].
-- nature — доход или расход: бюджет вводится положительным, знак ставит модуль.
CREATE TABLE IF NOT EXISTS pnl_articles (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text        NOT NULL UNIQUE,
    title       text        NOT NULL,
    parent_code text        REFERENCES pnl_articles (code),
    section     text        NOT NULL CHECK (section IN ('revenue', 'cogs', 'opex', 'other', 'depreciation', 'finance', 'tax')),
    nature      text        NOT NULL CHECK (nature IN ('income', 'expense')),
    ord         int         NOT NULL DEFAULT 100,
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    CHECK (parent_code IS NULL OR parent_code <> code)
);

-- Статья для проводок, счёт которых не сопоставлен: видна в отчёте отдельной строкой,
-- чтобы итог не врал. Список таких счетов — v_pnl_unmapped.
INSERT INTO pnl_articles (code, title, section, nature, ord, created_by)
VALUES ('_UNMAPPED', 'Не разнесено по статьям (проверьте сопоставление счетов)', 'other', 'expense', 999, 'system')
ON CONFLICT (code) DO NOTHING;

-- Счёт учёта (или начало номера счёта) → статья. Побеждает самое длинное совпадение:
-- «7210» — вся группа, «7210.05» — точнее.
CREATE TABLE IF NOT EXISTS pnl_account_map (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_prefix text        NOT NULL UNIQUE,
    article_code   text        NOT NULL REFERENCES pnl_articles (code),
    note           text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     text        NOT NULL,
    updated_at     timestamptz,
    updated_by     text
);

-- Контрагенты — компании своей группы: обороты с ними исключаются в отчёте «по компании».
CREATE TABLE IF NOT EXISTS pnl_group_counterparties (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    counterparty_id text        NOT NULL UNIQUE,
    title           text        NOT NULL,
    archived        boolean     NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      text        NOT NULL,
    updated_at      timestamptz,
    updated_by      text
);

-- Распределение общих расходов (офис, IT) на филиалы.
--   fixed_pct     — по долям из pnl_alloc_shares (сумма 100);
--   revenue_share — пропорционально внешней выручке филиалов-получателей в том же месяце.
-- article_code NULL — все операционные расходы (opex) филиала-источника.
CREATE TABLE IF NOT EXISTS pnl_alloc_rules (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         text        NOT NULL UNIQUE,
    title        text        NOT NULL,
    from_branch  text        NOT NULL,
    article_code text        REFERENCES pnl_articles (code),
    method       text        NOT NULL CHECK (method IN ('fixed_pct', 'revenue_share')),
    priority     int         NOT NULL DEFAULT 100,
    valid_from   date        NOT NULL CHECK (extract(day FROM valid_from) = 1),
    valid_to     date        CHECK (valid_to IS NULL OR extract(day FROM valid_to) = 1),
    active       boolean     NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text        NOT NULL,
    updated_at   timestamptz,
    updated_by   text,
    CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE TABLE IF NOT EXISTS pnl_alloc_shares (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_id     bigint        NOT NULL REFERENCES pnl_alloc_rules (id),
    to_branch   text          NOT NULL,
    share_pct   numeric(6,2)  CHECK (share_pct IS NULL OR share_pct BETWEEN 0 AND 100),
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    UNIQUE (rule_id, to_branch)
);

-- Бюджет: статья × месяц × филиал, положительной суммой в валюте отчётов.
-- branch_id = 'all' — бюджет компании по статье (вместо суммы филиалов); нужен, когда
-- филиалы продают друг другу и сумма их бюджетов задваивает выручку и себестоимость.
CREATE TABLE IF NOT EXISTS pnl_budgets (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    article_code text          NOT NULL REFERENCES pnl_articles (code),
    month        date          NOT NULL CHECK (extract(day FROM month) = 1),
    branch_id    text          NOT NULL,
    amount       numeric(18,2) NOT NULL CHECK (amount >= 0),
    currency     char(3)       NOT NULL DEFAULT pnl_currency(),
    note         text,
    created_at   timestamptz   NOT NULL DEFAULT now(),
    created_by   text          NOT NULL,
    updated_at   timestamptz,
    updated_by   text,
    UNIQUE (article_code, month, branch_id)
);

-- Статьи ДДС из 1С → вид деятельности. internal — переводы между своими счетами.
CREATE TABLE IF NOT EXISTS pnl_cf_articles (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text        NOT NULL UNIQUE,
    title       text        NOT NULL,
    activity    text        NOT NULL CHECK (activity IN ('operating', 'investing', 'financing', 'internal')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text
);

-- Остаток денег на начало дня as_of по каждому счёту (из 1С при установке).
CREATE TABLE IF NOT EXISTS pnl_cash_openings (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cash_account text          NOT NULL UNIQUE,
    as_of        date          NOT NULL,
    amount       numeric(18,2) NOT NULL,
    currency     char(3)       NOT NULL DEFAULT pnl_currency(),
    created_at   timestamptz   NOT NULL DEFAULT now(),
    created_by   text          NOT NULL,
    updated_at   timestamptz,
    updated_by   text
);

-- Закрытие месяца: пока месяц не закрыт в 1С (себестоимость, амортизация, курсовые),
-- цифры в отчёте помечены «предварительно». open → closed → reopened → closed.
CREATE TABLE IF NOT EXISTS pnl_periods (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    month       date        NOT NULL UNIQUE CHECK (extract(day FROM month) = 1),
    status      text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'reopened')),
    comment     text,
    closed_at   timestamptz,
    closed_by   text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    CHECK (status <> 'closed' OR closed_at IS NOT NULL),
    CHECK (status <> 'reopened' OR comment IS NOT NULL)
);

-- Журнал пересчётов и расчётная таблица фактов (месяц × филиал × статья).
-- pnl_facts — не ввод людей: pnl_rebuild() пересобирает её целиком.
CREATE TABLE IF NOT EXISTS pnl_runs (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entries       int,
    unmapped      int,
    facts         int,
    finished_at   timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text        NOT NULL
);

CREATE TABLE IF NOT EXISTS pnl_facts (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        bigint        NOT NULL REFERENCES pnl_runs (id),
    month         date          NOT NULL,
    branch_id     text          NOT NULL,      -- '_elim' — исключение внутригрупповых оборотов
    article_code  text          NOT NULL,
    kind          text          NOT NULL CHECK (kind IN ('direct', 'alloc_out', 'alloc_in', 'elimination')),
    intragroup    boolean       NOT NULL DEFAULT false,
    rule_id       bigint,
    amount        numeric(18,2) NOT NULL,      -- доход «+», расход «−»
    entries       int           NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS pnl_facts_key_idx ON pnl_facts (month, branch_id, article_code);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['pnl_articles', 'pnl_account_map', 'pnl_group_counterparties', 'pnl_alloc_rules',
                             'pnl_alloc_shares', 'pnl_budgets', 'pnl_cf_articles', 'pnl_cash_openings', 'pnl_periods'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_touch', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION airl_touch()', t || '_touch', t);
    END LOOP;
END $$;

-- Дерево статей: раздел дочерней статьи совпадает с родителем, циклов нет.
CREATE OR REPLACE FUNCTION pnl_articles_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_parent pnl_articles%ROWTYPE;
    v_code   text := NEW.parent_code;
    v_steps  int := 0;
BEGIN
    IF NEW.parent_code IS NOT NULL THEN
        SELECT * INTO v_parent FROM pnl_articles WHERE code = NEW.parent_code;
        IF v_parent.section <> NEW.section THEN
            RAISE EXCEPTION 'pnl-cashflow: статья % в разделе %, а родитель % — в разделе %',
                NEW.code, NEW.section, NEW.parent_code, v_parent.section;
        END IF;
        WHILE v_code IS NOT NULL AND v_steps < 50 LOOP
            IF v_code = NEW.code THEN RAISE EXCEPTION 'pnl-cashflow: цикл в дереве статей (%)', NEW.code; END IF;
            SELECT parent_code INTO v_code FROM pnl_articles WHERE code = v_code;
            v_steps := v_steps + 1;
        END LOOP;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pnl_articles_guard ON pnl_articles;
CREATE TRIGGER pnl_articles_guard BEFORE INSERT OR UPDATE ON pnl_articles FOR EACH ROW EXECUTE FUNCTION pnl_articles_guard();

-- Переходы статуса месяца и журнал.
CREATE OR REPLACE FUNCTION pnl_periods_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF (OLD.status, NEW.status) NOT IN (('open', 'closed'), ('closed', 'reopened'), ('reopened', 'closed')) THEN
            RAISE EXCEPTION 'pnl-cashflow: переход месяца % → % не разрешён (%)', OLD.status, NEW.status, OLD.month;
        END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
        VALUES (COALESCE(NEW.updated_by, 'system'), 'pnl-cashflow', 'period', to_char(NEW.month, 'YYYY-MM'), 'status',
                OLD.status, NEW.status, NEW.comment);
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pnl_periods_status ON pnl_periods;
CREATE TRIGGER pnl_periods_status BEFORE UPDATE ON pnl_periods FOR EACH ROW EXECUTE FUNCTION pnl_periods_guard();

CREATE OR REPLACE FUNCTION pnl_close_month(p_month date, p_actor text, p_comment text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_month date := date_trunc('month', p_month)::date;
BEGIN
    IF v_month >= date_trunc('month', current_date) THEN
        RAISE EXCEPTION 'pnl-cashflow: текущий месяц ещё не закончился (%)', to_char(v_month, 'YYYY-MM');
    END IF;
    INSERT INTO pnl_periods (month, created_by, updated_by) VALUES (v_month, p_actor, p_actor)
    ON CONFLICT (month) DO NOTHING;
    UPDATE pnl_periods SET status = 'closed', closed_at = now(), closed_by = p_actor,
                           comment = COALESCE(p_comment, comment), updated_by = p_actor
     WHERE month = v_month AND status <> 'closed';
    RETURN to_char(v_month, 'YYYY-MM');
END $$;

CREATE OR REPLACE FUNCTION pnl_reopen_month(p_month date, p_actor text, p_reason text) RETURNS text
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_n int;
BEGIN
    IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'pnl-cashflow: укажите причину открытия месяца'; END IF;
    UPDATE pnl_periods SET status = 'reopened', comment = p_reason, updated_by = p_actor
     WHERE month = date_trunc('month', p_month)::date AND status = 'closed';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'pnl-cashflow: месяц % не закрыт', to_char(p_month, 'YYYY-MM'); END IF;
    RETURN to_char(p_month, 'YYYY-MM');
END $$;

-- Статья для счёта учёта: самое длинное совпадение начала номера.
CREATE OR REPLACE FUNCTION pnl_article_for(p_account text) RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    SELECT COALESCE((SELECT article_code FROM pnl_account_map
                     WHERE p_account LIKE account_prefix || '%'
                     ORDER BY length(account_prefix) DESC LIMIT 1), '_UNMAPPED')
$$;

-- Статьи с глубиной и порядком показа.
CREATE OR REPLACE VIEW v_pnl_articles AS
WITH RECURSIVE p AS (
    SELECT code, title, parent_code, section, nature, 0 AS depth,
           lpad(ord::text, 5, '0') || code AS sort_path
    FROM pnl_articles WHERE parent_code IS NULL
    UNION ALL
    SELECT a.code, a.title, a.parent_code, a.section, a.nature, p.depth + 1,
           p.sort_path || '/' || lpad(a.ord::text, 5, '0') || a.code
    FROM pnl_articles a JOIN p ON a.parent_code = p.code
)
SELECT p.*, NOT EXISTS (SELECT 1 FROM pnl_articles c WHERE c.parent_code = p.code) AS is_leaf
FROM p;

-- Предки каждой статьи (включая её саму): для свёртки по дереву и расшифровки.
CREATE OR REPLACE VIEW v_pnl_article_tree AS
WITH RECURSIVE t AS (
    SELECT code AS ancestor, code AS descendant FROM pnl_articles
    UNION ALL
    SELECT t.ancestor, a.code FROM t JOIN pnl_articles a ON a.parent_code = t.descendant
)
SELECT ancestor, descendant FROM t;

-- Проверка правил распределения: доли fixed_pct дают 100 %, у revenue_share есть получатели.
CREATE OR REPLACE VIEW v_pnl_alloc_check AS
SELECT r.id AS rule_id, r.code, r.title, r.from_branch, r.article_code, r.method, r.priority,
       r.valid_from, r.valid_to, r.active,
       count(s.id) AS targets, sum(s.share_pct) AS share_total,
       (count(s.id) > 0 AND (r.method <> 'fixed_pct' OR COALESCE(sum(s.share_pct), 0) = 100)) AS ok
FROM pnl_alloc_rules r
LEFT JOIN pnl_alloc_shares s ON s.rule_id = r.id
GROUP BY r.id;

-- Пересчёт фактов: проводки → статьи → распределение общих расходов → исключение
-- внутригрупповых оборотов. Повторный запуск безопасен (таблица пересобирается).
-- Исключение: обороты с контрагентами группы (pnl_group_counterparties) не попадают в итог
-- «по компании»; их чистая сумма (доход − расход) добавляется к статье себестоимости
-- intragroup_cogs_article — так продажа зерна обжаркой своему филиалу не раздувает ни
-- выручку, ни себестоимость группы. Нереализованная прибыль в остатках не исключается.
CREATE OR REPLACE FUNCTION pnl_rebuild(p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_run  bigint;
    v_cur  text    := pnl_currency();
    v_elim boolean := (airl_setting('pnl-cashflow', 'eliminate_intragroup', 'true'))::text::boolean;
    v_cogs text    := airl_setting('pnl-cashflow', 'intragroup_cogs_article', '"COGS-GOODS"') #>> '{}';
    v_n    int;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('pnl-rebuild'));
    INSERT INTO pnl_runs (created_by) VALUES (p_actor) RETURNING id INTO v_run;
    DELETE FROM pnl_facts;

    INSERT INTO pnl_facts (run_id, month, branch_id, article_code, kind, intragroup, amount, entries)
    SELECT v_run, date_trunc('month', e.entry_date)::date, e.branch_id, pnl_article_for(e.account_code), 'direct',
           (g.counterparty_id IS NOT NULL),
           sum(CASE WHEN e.direction = 'income' THEN e.amount ELSE -e.amount END), count(*)
    FROM src_pnl_entries e
    LEFT JOIN pnl_group_counterparties g ON g.counterparty_id = e.counterparty_id AND NOT g.archived
    WHERE e.currency = v_cur
    GROUP BY 2, 3, 4, 5, 6;

    INSERT INTO pnl_facts (run_id, month, branch_id, article_code, kind, intragroup, rule_id, amount)
    WITH src AS (
        SELECT f.month, f.branch_id, f.article_code, f.amount, r.id AS rule_id
        FROM pnl_facts f
        JOIN pnl_articles a ON a.code = f.article_code
        CROSS JOIN LATERAL (
            SELECT r.id FROM pnl_alloc_rules r
            JOIN v_pnl_alloc_check c ON c.rule_id = r.id AND c.ok
            WHERE r.active AND r.from_branch = f.branch_id
              AND f.month >= r.valid_from AND (r.valid_to IS NULL OR f.month <= r.valid_to)
              AND CASE WHEN r.article_code IS NULL THEN a.section = 'opex'
                       ELSE EXISTS (SELECT 1 FROM v_pnl_article_tree t
                                    WHERE t.ancestor = r.article_code AND t.descendant = f.article_code) END
            ORDER BY r.priority, r.id LIMIT 1
        ) r
        WHERE f.run_id = v_run AND f.kind = 'direct' AND NOT f.intragroup
    ),
    rev AS (
        SELECT f.month, f.branch_id, sum(f.amount) AS amount
        FROM pnl_facts f JOIN pnl_articles a ON a.code = f.article_code AND a.section = 'revenue'
        WHERE f.run_id = v_run AND f.kind = 'direct' AND NOT f.intragroup
        GROUP BY f.month, f.branch_id
    ),
    w AS (
        SELECT s.rule_id, mo.month, s.to_branch,
               CASE WHEN r.method = 'fixed_pct' THEN s.share_pct / 100
                    ELSE greatest(rev.amount, 0) / NULLIF(sum(greatest(rev.amount, 0)) OVER (PARTITION BY s.rule_id, mo.month), 0)
               END AS weight
        FROM pnl_alloc_shares s
        JOIN pnl_alloc_rules r ON r.id = s.rule_id
        CROSS JOIN (SELECT DISTINCT month FROM src) mo
        LEFT JOIN rev ON rev.month = mo.month AND rev.branch_id = s.to_branch
    ),
    ins AS (
        SELECT src.month, src.branch_id, src.article_code, src.rule_id, w.to_branch,
               round(src.amount * w.weight, 2) AS amount
        FROM src JOIN w ON w.rule_id = src.rule_id AND w.month = src.month
        WHERE w.weight IS NOT NULL AND w.weight > 0
    )
    SELECT v_run, month, to_branch, article_code, 'alloc_in', false, rule_id, amount FROM ins
    UNION ALL
    SELECT v_run, month, branch_id, article_code, 'alloc_out', false, rule_id, -sum(amount)
    FROM ins GROUP BY month, branch_id, article_code, rule_id;

    IF v_elim AND v_cogs IS NOT NULL THEN
        INSERT INTO pnl_facts (run_id, month, branch_id, article_code, kind, intragroup, amount)
        SELECT v_run, month, '_elim', v_cogs, 'elimination', false, sum(amount)
        FROM pnl_facts
        WHERE run_id = v_run AND kind = 'direct' AND intragroup
        GROUP BY month
        HAVING sum(amount) <> 0;
    END IF;

    SELECT count(*) INTO v_n FROM pnl_facts WHERE run_id = v_run;
    UPDATE pnl_runs SET facts = v_n, finished_at = now(),
           entries  = (SELECT count(*) FROM src_pnl_entries WHERE currency = v_cur),
           unmapped = (SELECT COALESCE(sum(entries), 0) FROM pnl_facts WHERE run_id = v_run AND article_code = '_UNMAPPED')
     WHERE id = v_run;
    RETURN v_n;
END $$;

-- Отчёт о прибылях и убытках: месяц × филиал ('all' — компания) × строка отчёта.
-- Строки: разделы (S:…), статьи по дереву, промежуточные итоги (=gross_profit, =ebitda,
-- =ebit, =net_profit). Доход «+», расход «−». fact_ly — тот же месяц прошлого года.
-- pct_of_revenue — доля от выручки той же строки ключа (для валовой прибыли — маржа).
-- preliminary — месяц не закрыт (себестоимость и начисления могут измениться).
CREATE OR REPLACE VIEW v_pnl_report AS
WITH cfg AS (
    SELECT (airl_setting('pnl-cashflow', 'eliminate_intragroup', 'true'))::text::boolean AS elim
),
f AS (
    SELECT month, branch_id, article_code, sum(amount) AS amount
    FROM pnl_facts WHERE branch_id <> '_elim'
    GROUP BY month, branch_id, article_code
    UNION ALL
    SELECT month, 'all', article_code, sum(amount)
    FROM pnl_facts, cfg
    WHERE (branch_id <> '_elim' AND NOT (intragroup AND cfg.elim)) OR (branch_id = '_elim' AND cfg.elim)
    GROUP BY month, article_code
),
b0 AS (
    SELECT bu.month, bu.branch_id, bu.article_code,
           CASE a.nature WHEN 'income' THEN bu.amount ELSE -bu.amount END AS amount
    FROM pnl_budgets bu JOIN pnl_articles a ON a.code = bu.article_code
    WHERE bu.currency = pnl_currency()
),
b AS (
    -- бюджет компании: строка с branch_id = 'all', если введена (нужна при продажах внутри
    -- группы), иначе сумма филиалов
    SELECT month, branch_id, article_code, sum(amount) AS amount FROM b0 GROUP BY 1, 2, 3
    UNION ALL
    SELECT month, 'all', article_code, sum(amount) FROM b0 x
    WHERE x.branch_id <> 'all'
      AND NOT EXISTS (SELECT 1 FROM b0 y WHERE y.branch_id = 'all' AND y.month = x.month AND y.article_code = x.article_code)
    GROUP BY 1, 3
),
fb AS (
    SELECT COALESCE(f.month, b.month) AS month, COALESCE(f.branch_id, b.branch_id) AS branch_id,
           COALESCE(f.article_code, b.article_code) AS article_code, f.amount AS fact, b.amount AS budget
    FROM f FULL JOIN b ON b.month = f.month AND b.branch_id = f.branch_id AND b.article_code = f.article_code
),
sec AS (
    SELECT fb.month, fb.branch_id, a.section, sum(fb.fact) AS fact, sum(fb.budget) AS budget
    FROM fb JOIN pnl_articles a ON a.code = fb.article_code
    GROUP BY fb.month, fb.branch_id, a.section
),
secp AS (
    SELECT month, branch_id,
           sum(fact) FILTER (WHERE section = 'revenue') AS rev_f,  sum(budget) FILTER (WHERE section = 'revenue') AS rev_b,
           sum(fact) FILTER (WHERE section = 'cogs') AS cogs_f,    sum(budget) FILTER (WHERE section = 'cogs') AS cogs_b,
           sum(fact) FILTER (WHERE section = 'opex') AS opex_f,    sum(budget) FILTER (WHERE section = 'opex') AS opex_b,
           sum(fact) FILTER (WHERE section = 'other') AS oth_f,    sum(budget) FILTER (WHERE section = 'other') AS oth_b,
           sum(fact) FILTER (WHERE section = 'depreciation') AS da_f, sum(budget) FILTER (WHERE section = 'depreciation') AS da_b,
           sum(fact) FILTER (WHERE section = 'finance') AS fin_f,  sum(budget) FILTER (WHERE section = 'finance') AS fin_b,
           sum(fact) FILTER (WHERE section = 'tax') AS tax_f,      sum(budget) FILTER (WHERE section = 'tax') AS tax_b
    FROM sec GROUP BY month, branch_id
),
sec_order AS (
    SELECT * FROM (VALUES ('revenue', '10', 'Выручка'), ('cogs', '20', 'Себестоимость'),
                          ('opex', '30', 'Операционные расходы'), ('other', '40', 'Прочие операционные доходы и расходы'),
                          ('depreciation', '50', 'Амортизация'), ('finance', '60', 'Финансовые доходы и расходы'),
                          ('tax', '70', 'Налог на прибыль')) AS s(section, sort, title)
),
lines AS (
    -- статьи (свёртка по дереву)
    SELECT fb.month, fb.branch_id, t.ancestor AS line_code, va.title AS line_title, 'article'::text AS line_kind,
           va.depth + 1 AS depth, so.sort || '/' || va.sort_path AS sort_key, va.is_leaf,
           sum(fb.fact) AS fact, sum(fb.budget) AS budget
    FROM fb
    JOIN v_pnl_article_tree t ON t.descendant = fb.article_code
    JOIN v_pnl_articles va ON va.code = t.ancestor
    JOIN sec_order so ON so.section = va.section
    GROUP BY fb.month, fb.branch_id, t.ancestor, va.title, va.depth, so.sort, va.sort_path, va.is_leaf
    UNION ALL
    -- разделы
    SELECT sec.month, sec.branch_id, 'S:' || sec.section, so.title, 'section', 0, so.sort, false, sec.fact, sec.budget
    FROM sec JOIN sec_order so ON so.section = sec.section
    UNION ALL
    -- промежуточные итоги
    SELECT s.month, s.branch_id, v.code, v.title, 'subtotal', 0, v.sort, false, v.fact, v.budget
    FROM secp s
    CROSS JOIN LATERAL (VALUES
        ('=gross_profit', 'Валовая прибыль', '25',
         COALESCE(rev_f, 0) + COALESCE(cogs_f, 0), COALESCE(rev_b, 0) + COALESCE(cogs_b, 0)),
        ('=ebitda', 'EBITDA', '45',
         COALESCE(rev_f, 0) + COALESCE(cogs_f, 0) + COALESCE(opex_f, 0) + COALESCE(oth_f, 0),
         COALESCE(rev_b, 0) + COALESCE(cogs_b, 0) + COALESCE(opex_b, 0) + COALESCE(oth_b, 0)),
        ('=ebit', 'Операционная прибыль (EBIT)', '55',
         COALESCE(rev_f, 0) + COALESCE(cogs_f, 0) + COALESCE(opex_f, 0) + COALESCE(oth_f, 0) + COALESCE(da_f, 0),
         COALESCE(rev_b, 0) + COALESCE(cogs_b, 0) + COALESCE(opex_b, 0) + COALESCE(oth_b, 0) + COALESCE(da_b, 0)),
        ('=net_profit', 'Чистая прибыль', '90',
         COALESCE(rev_f, 0) + COALESCE(cogs_f, 0) + COALESCE(opex_f, 0) + COALESCE(oth_f, 0) + COALESCE(da_f, 0)
           + COALESCE(fin_f, 0) + COALESCE(tax_f, 0),
         COALESCE(rev_b, 0) + COALESCE(cogs_b, 0) + COALESCE(opex_b, 0) + COALESCE(oth_b, 0) + COALESCE(da_b, 0)
           + COALESCE(fin_b, 0) + COALESCE(tax_b, 0))
    ) AS v(code, title, sort, fact, budget)
)
SELECT l.month, to_char(l.month, 'YYYY-MM') AS period, l.branch_id, l.line_code, l.line_title, l.line_kind,
       l.depth, l.sort_key, l.is_leaf,
       l.fact::numeric(18,2)                                          AS fact,
       l.budget::numeric(18,2)                                        AS budget,
       (l.fact - l.budget)::numeric(18,2)                             AS deviation,
       round(100.0 * (l.fact - l.budget) / NULLIF(abs(l.budget), 0), 1) AS deviation_pct,
       ly.fact::numeric(18,2)                                         AS fact_ly,
       round(100.0 * (l.fact - ly.fact) / NULLIF(abs(ly.fact), 0), 1)  AS yoy_pct,
       round(100.0 * l.fact / NULLIF(sp.rev_f, 0), 1)                 AS pct_of_revenue,
       pnl_currency()::char(3)                                        AS currency,
       NOT EXISTS (SELECT 1 FROM pnl_periods p WHERE p.month = l.month AND p.status = 'closed') AS preliminary
FROM lines l
LEFT JOIN lines ly ON ly.month = (l.month - interval '1 year')::date AND ly.branch_id = l.branch_id AND ly.line_code = l.line_code
LEFT JOIN secp sp  ON sp.month = l.month AND sp.branch_id = l.branch_id;

-- Расшифровка до проводки (BI-012): line_codes — все строки отчёта, в которые входит
-- проводка (статья и её родители, раздел). Для промежуточного итога экран фильтрует по разделам.
CREATE OR REPLACE VIEW v_pnl_drill AS
SELECT e.entry_id, e.entry_date, date_trunc('month', e.entry_date)::date AS month,
       to_char(e.entry_date, 'YYYY-MM') AS period, e.branch_id, e.account_code,
       x.article_code, a.title AS article_title, a.section,
       ARRAY(SELECT t.ancestor FROM v_pnl_article_tree t WHERE t.descendant = x.article_code) || ('S:' || a.section) AS line_codes,
       CASE WHEN e.direction = 'income' THEN e.amount ELSE -e.amount END AS amount_signed,
       e.amount, e.direction, e.currency, e.source_doc, e.counterparty_id,
       EXISTS (SELECT 1 FROM pnl_group_counterparties g WHERE g.counterparty_id = e.counterparty_id AND NOT g.archived) AS intragroup
FROM src_pnl_entries e
CROSS JOIN LATERAL (SELECT pnl_article_for(e.account_code) AS article_code) x
LEFT JOIN pnl_articles a ON a.code = x.article_code;

-- Распределённые суммы: что, откуда, куда и по какому правилу (расшифровка распределения).
CREATE OR REPLACE VIEW v_pnl_allocations AS
SELECT f.month, to_char(f.month, 'YYYY-MM') AS period, r.code AS rule_code, r.title AS rule_title, r.method,
       f.branch_id, f.kind, f.article_code, a.title AS article_title, f.amount
FROM pnl_facts f
JOIN pnl_alloc_rules r ON r.id = f.rule_id
LEFT JOIN pnl_articles a ON a.code = f.article_code
WHERE f.kind IN ('alloc_in', 'alloc_out');

-- Качество данных: счета без статьи и проводки в другой валюте (в итог не входят).
CREATE OR REPLACE VIEW v_pnl_unmapped AS
SELECT e.account_code, e.currency, count(*) AS entries,
       sum(CASE WHEN e.direction = 'income' THEN e.amount ELSE -e.amount END)::numeric(18,2) AS amount_signed,
       min(e.entry_date) AS first_date, max(e.entry_date) AS last_date,
       CASE WHEN e.currency <> pnl_currency() THEN 'other_currency' ELSE 'no_article' END AS problem
FROM src_pnl_entries e
WHERE pnl_article_for(e.account_code) = '_UNMAPPED' OR e.currency <> pnl_currency()
GROUP BY e.account_code, e.currency;

-- Движение денег: месяц × филиал × вид деятельности × статья ДДС (в валюте отчётов).
CREATE OR REPLACE VIEW v_pnl_cashflow AS
SELECT date_trunc('month', c.pay_date)::date AS month, to_char(c.pay_date, 'YYYY-MM') AS period, c.branch_id,
       COALESCE(a.activity, 'unmapped') AS activity, c.cf_article, COALESCE(a.title, c.cf_article) AS article_title,
       COALESCE(sum(c.amount) FILTER (WHERE c.amount > 0), 0)::numeric(18,2)  AS inflow,
       COALESCE(-sum(c.amount) FILTER (WHERE c.amount < 0), 0)::numeric(18,2) AS outflow,
       sum(c.amount)::numeric(18,2) AS net, count(*) AS payments
FROM src_pnl_cash c
LEFT JOIN pnl_cf_articles a ON a.code = c.cf_article
WHERE c.currency = pnl_currency()
GROUP BY 1, 2, 3, 4, 5, 6;

-- Остаток денег по компании на конец месяца (счета с введённым начальным остатком,
-- в валюте отчётов). Переводы между своими счетами (internal) в сумме дают ноль.
CREATE OR REPLACE VIEW v_pnl_cash_balance AS
WITH o AS (
    SELECT cash_account, as_of, amount FROM pnl_cash_openings WHERE currency = pnl_currency()
),
months AS (
    SELECT generate_series(date_trunc('month', (SELECT min(as_of) FROM o)), date_trunc('month', current_date), interval '1 month')::date AS month
),
flows AS (
    SELECT date_trunc('month', c.pay_date)::date AS month, COALESCE(a.activity, 'unmapped') AS activity, sum(c.amount) AS amount
    FROM src_pnl_cash c
    JOIN o ON o.cash_account = c.cash_account AND c.pay_date >= o.as_of
    LEFT JOIN pnl_cf_articles a ON a.code = c.cf_article
    WHERE c.currency = pnl_currency()
    GROUP BY 1, 2
),
per AS (
    SELECT m.month,
           COALESCE((SELECT sum(amount) FROM o WHERE date_trunc('month', o.as_of) = m.month), 0) AS opening_added,
           COALESCE(sum(f.amount) FILTER (WHERE f.activity = 'operating'), 0) AS operating,
           COALESCE(sum(f.amount) FILTER (WHERE f.activity = 'investing'), 0) AS investing,
           COALESCE(sum(f.amount) FILTER (WHERE f.activity = 'financing'), 0) AS financing,
           COALESCE(sum(f.amount) FILTER (WHERE f.activity = 'internal'), 0)  AS internal,
           COALESCE(sum(f.amount) FILTER (WHERE f.activity = 'unmapped'), 0)  AS unmapped
    FROM months m LEFT JOIN flows f ON f.month = m.month
    GROUP BY m.month
)
SELECT month, to_char(month, 'YYYY-MM') AS period,
       (sum(opening_added + operating + investing + financing + internal + unmapped) OVER w - (operating + investing + financing + internal + unmapped))::numeric(18,2) AS opening,
       operating::numeric(18,2), investing::numeric(18,2), financing::numeric(18,2),
       internal::numeric(18,2), unmapped::numeric(18,2),
       (sum(opening_added + operating + investing + financing + internal + unmapped) OVER w)::numeric(18,2) AS closing,
       pnl_currency()::char(3) AS currency
FROM per
WINDOW w AS (ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);

-- Статус месяцев для экрана «Закрытие».
CREATE OR REPLACE VIEW v_pnl_periods AS
SELECT m.month, to_char(m.month, 'YYYY-MM') AS period, COALESCE(p.status, 'open') AS status,
       p.closed_at, p.closed_by, p.comment, COALESCE(p.status, 'open') <> 'closed' AS preliminary
FROM (SELECT DISTINCT month FROM pnl_facts) m
LEFT JOIN pnl_periods p ON p.month = m.month;

-- Показатель-семейство: валовая маржа по филиалам и компании ('all'), %.
CREATE OR REPLACE VIEW m_pnl_gross_margin AS
WITH x AS (
    SELECT month, branch_id,
           sum(fact) FILTER (WHERE line_code = '=gross_profit') AS gp,
           sum(fact) FILTER (WHERE line_code = 'S:revenue')     AS rev
    FROM v_pnl_report
    WHERE month <= current_date
    GROUP BY month, branch_id
)
SELECT ('gross_margin:' || branch_id)::text AS metric_id,
       to_char(month, 'YYYY-MM')            AS period,
       round(100.0 * gp / rev, 1)           AS value,
       '%'::text                            AS unit,
       airl_traffic(round(100.0 * gp / rev, 1),
           (airl_setting('pnl-cashflow', 'margin_warn', '35'))::text::numeric,
           (airl_setting('pnl-cashflow', 'margin_bad', '25'))::text::numeric,
           true)                            AS status
FROM x WHERE rev > 0;

-- Показатель-семейство: чистая прибыль по филиалам и компании. Светофор — к бюджету:
-- не ниже бюджета — ok; ниже не больше чем на net_warn_pct % — warning; иначе danger.
-- Без бюджета: прибыль ≥ 0 — ok, убыток — danger. Только завершённые месяцы: неполный
-- текущий месяц с месячным бюджетом не сравнивается.
CREATE OR REPLACE VIEW m_pnl_net_profit AS
SELECT ('net_profit:' || branch_id)::text AS metric_id,
       period,
       fact                               AS value,
       pnl_currency()::text               AS unit,
       CASE WHEN budget IS NULL OR budget = 0 THEN CASE WHEN fact >= 0 THEN 'ok' ELSE 'danger' END
            WHEN fact >= budget THEN 'ok'
            WHEN fact >= budget - abs(budget) * (airl_setting('pnl-cashflow', 'net_warn_pct', '10'))::text::numeric / 100 THEN 'warning'
            ELSE 'danger' END             AS status
FROM v_pnl_report
WHERE line_code = '=net_profit' AND month < date_trunc('month', current_date) AND fact IS NOT NULL;

-- Показатель: остаток денег компании на конец месяца.
CREATE OR REPLACE VIEW m_pnl_cash_balance AS
SELECT 'cash_balance'::text AS metric_id,
       period,
       closing              AS value,
       currency::text       AS unit,
       airl_traffic(closing,
           (airl_setting('pnl-cashflow', 'cash_warn', '20000000'))::text::numeric,
           (airl_setting('pnl-cashflow', 'cash_bad', '5000000'))::text::numeric,
           true)            AS status
FROM v_pnl_cash_balance;

-- Уведомления (раз в день после pnl_rebuild): перерасход статьи расходов сверх
-- budget_tolerance_pct в текущем и прошлом месяце — финансовому директору, один раз на
-- статью × филиал × месяц; счета без статьи — главному бухгалтеру, один раз на счёт.
CREATE OR REPLACE FUNCTION pnl_queue_notifications() RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_channel text    := airl_setting('pnl-cashflow', 'channel', '"telegram"') #>> '{}';
    v_fin     text    := airl_setting('pnl-cashflow', 'recipient', '"role:fin_director"') #>> '{}';
    v_acc     text    := airl_setting('pnl-cashflow', 'data_recipient', '"role:chief_accountant"') #>> '{}';
    v_tol     numeric := (airl_setting('pnl-cashflow', 'budget_tolerance_pct', '10'))::text::numeric;
    v_n int; v_total int := 0;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'pnl-cashflow:overrun:' || r.period || ':' || r.branch_id || ':' || r.line_code || ':' || v_fin,
           'pnl-cashflow', v_channel, v_fin,
           'Перерасход ' || r.period || ', ' || r.branch_id || ': «' || r.line_title || '» '
           || replace(to_char(-r.fact, 'FM999,999,999,990'), ',', ' ') || ' при бюджете ' || replace(to_char(-r.budget, 'FM999,999,999,990'), ',', ' ')
           || ' ' || r.currency || CASE WHEN r.preliminary THEN ' (предварительно)' ELSE '' END
    FROM v_pnl_report r
    WHERE r.line_kind = 'article' AND r.is_leaf AND r.branch_id <> 'all'
      AND r.budget < 0 AND r.fact < r.budget * (1 + v_tol / 100)
      AND r.month >= (date_trunc('month', current_date) - interval '1 month')::date
      AND r.month <= current_date
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;

    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'pnl-cashflow:unmapped:' || u.account_code || ':' || v_acc, 'pnl-cashflow', v_channel, v_acc,
           'Счёт ' || u.account_code || ' не сопоставлен со статьёй отчёта: ' || u.entries || ' проводок, '
           || replace(to_char(abs(u.amount_signed), 'FM999,999,999,990'), ',', ' ') || ' ' || u.currency
    FROM v_pnl_unmapped u
    WHERE u.problem = 'no_article'
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    RETURN v_total;
END $$;
