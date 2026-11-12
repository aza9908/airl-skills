-- Общие данные (core): очищенные сущности, одна карточка клиента.
-- Таблицы создаёт администратор; наполняет только загрузка (airl_loader) функцией core.load().
-- Источники: raw_1c (2 базы 1С: airl, airl_dev), raw_bank, raw_amocrm, raw_sheets.
-- Правила загрузки 1С: только проведённые документы без пометки удаления;
-- продажи и расходы между своими юрлицами помечаются is_intragroup.

CREATE TABLE IF NOT EXISTS core.legal_entities (
    entity_id   text PRIMARY KEY,               -- infobase: airl | airl_dev
    name        text NOT NULL,
    bin         text NOT NULL
);

-- Одна карточка клиента. Ключи склейки (раздел 3 карты): БИН/ИИН из 1С → телефон+имя.
-- client_id не содержит персональных данных (хеш от номера).
CREATE TABLE IF NOT EXISTS core.clients (
    client_id   text PRIMARY KEY,
    kind        text NOT NULL CHECK (kind IN ('company', 'person')),
    name        text NOT NULL,                  -- для person — ПДн
    tax_id      text,                           -- БИН компании / ИИН физлица (ПДн)
    phone       text,                           -- ПДн
    email       text,                           -- ПДн
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS core.client_source_map (
    system      text NOT NULL,                  -- 1c:airl | 1c:airl_dev | amocrm
    source_ref  text NOT NULL,
    client_id   text NOT NULL REFERENCES core.clients,
    PRIMARY KEY (system, source_ref)
);

CREATE TABLE IF NOT EXISTS core.suppliers (
    supplier_id text PRIMARY KEY,               -- infobase:ref
    entity_id   text NOT NULL,
    name        text NOT NULL,
    tax_id      text,
    is_group    boolean NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS core.sales_docs (
    doc_id        text PRIMARY KEY,             -- infobase:ref документа «Реализация»
    entity_id     text NOT NULL REFERENCES core.legal_entities,
    doc_no        text NOT NULL,
    doc_date      date NOT NULL,
    client_id     text REFERENCES core.clients, -- NULL для внутригрупповых
    counterparty_entity text,                   -- своё юрлицо-покупатель (внутригрупповые)
    is_intragroup boolean NOT NULL,
    service_line  text NOT NULL,                -- Курс VibeOps | Корпоративное обучение | Разработка ИИ | Консалтинг
    qty           numeric(12,2) NOT NULL,
    cohort_code   text,
    amount_gross  numeric(18,2) NOT NULL,       -- с НДС
    vat           numeric(18,2) NOT NULL,
    amount_net    numeric(18,2) NOT NULL,       -- без НДС
    currency      char(3) NOT NULL,
    due_date      date,
    manager_id    text,
    UNIQUE (entity_id, doc_no)
);
CREATE INDEX IF NOT EXISTS sales_docs_date_idx ON core.sales_docs (doc_date);
CREATE INDEX IF NOT EXISTS sales_docs_client_idx ON core.sales_docs (client_id);

CREATE TABLE IF NOT EXISTS core.cash_accounts (
    account_id  text PRIMARY KEY,
    entity_id   text NOT NULL REFERENCES core.legal_entities,
    name        text NOT NULL,
    bank_name   text,
    iban        text,
    kind        text NOT NULL CHECK (kind IN ('bank', 'cash')),
    currency    char(3) NOT NULL
);

CREATE TABLE IF NOT EXISTS core.cash_openings (
    account_id  text PRIMARY KEY REFERENCES core.cash_accounts,
    as_of       date NOT NULL,
    amount      numeric(18,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS core.payments_in (
    payment_id    text PRIMARY KEY,             -- infobase:ref «Поступление на р/с» или «ПКО»
    entity_id     text NOT NULL REFERENCES core.legal_entities,
    pay_date      date NOT NULL,
    client_id     text REFERENCES core.clients,
    doc_id        text REFERENCES core.sales_docs,
    amount        numeric(18,2) NOT NULL,
    channel       text NOT NULL CHECK (channel IN ('bank', 'cash')),
    account_id    text NOT NULL REFERENCES core.cash_accounts,
    bank_line_id  text,
    is_intragroup boolean NOT NULL
);
CREATE INDEX IF NOT EXISTS payments_in_doc_idx ON core.payments_in (doc_id, pay_date);

CREATE TABLE IF NOT EXISTS core.expenses (
    expense_id    text PRIMARY KEY,             -- infobase:ref
    entity_id     text NOT NULL REFERENCES core.legal_entities,
    doc_date      date NOT NULL,
    doc_type      text NOT NULL,
    supplier_id   text REFERENCES core.suppliers,
    account_code  text NOT NULL,
    article       text NOT NULL,                -- статья затрат 1С
    amount_net    numeric(18,2) NOT NULL,
    vat           numeric(18,2) NOT NULL,
    is_intragroup boolean NOT NULL
);
CREATE INDEX IF NOT EXISTS expenses_date_idx ON core.expenses (doc_date);

CREATE TABLE IF NOT EXISTS core.payments_out (
    payment_id    text PRIMARY KEY,
    entity_id     text NOT NULL REFERENCES core.legal_entities,
    pay_date      date NOT NULL,
    supplier_id   text REFERENCES core.suppliers,
    amount        numeric(18,2) NOT NULL,       -- положительное число
    cf_article    text NOT NULL,
    account_id    text NOT NULL REFERENCES core.cash_accounts,
    bank_line_id  text,
    is_intragroup boolean NOT NULL
);

-- Строки банковских выписок (оба банка). booked — уже разнесена в 1С.
CREATE TABLE IF NOT EXISTS core.bank_lines (
    line_id           text PRIMARY KEY,
    statement_id      text NOT NULL,
    bank              text NOT NULL,
    account_id        text NOT NULL REFERENCES core.cash_accounts,
    entity_id         text NOT NULL,
    value_date        date NOT NULL,
    amount            numeric(18,2) NOT NULL,
    currency          char(3) NOT NULL,
    counterparty_name text,                      -- может быть ПДн (физлица)
    counterparty_tax_id text,                    -- может быть ПДн (ИИН)
    purpose           text,
    doc_no            text,
    booked            boolean NOT NULL
);

CREATE TABLE IF NOT EXISTS core.managers (
    manager_id  text PRIMARY KEY,
    name        text NOT NULL
);

-- Заявки amoCRM. Телефон не храним — только хеш для склейки дублей.
CREATE TABLE IF NOT EXISTS core.leads (
    lead_id      text PRIMARY KEY,
    created_at   timestamptz NOT NULL,
    created_date date NOT NULL,                 -- дата по Asia/Almaty
    pipeline     text NOT NULL,
    channel      text NOT NULL,
    status       text NOT NULL,
    stage        text NOT NULL CHECK (stage IN ('open', 'won', 'lost')),
    amount       numeric(18,2),
    manager_id   text,
    client_id    text REFERENCES core.clients,
    contact_key  text NOT NULL,                 -- md5 телефона: ключ дублей
    is_duplicate boolean NOT NULL,              -- повтор того же контакта в течение 30 дней
    closed_date  date,
    loss_reason  text
);
CREATE INDEX IF NOT EXISTS leads_date_idx ON core.leads (created_date);
ALTER TABLE core.leads ADD COLUMN IF NOT EXISTS campaign text;   -- utm_campaign из amoCRM

CREATE TABLE IF NOT EXISTS core.cohorts (
    cohort_code text PRIMARY KEY,
    course      text NOT NULL,
    start_date  date NOT NULL,
    end_date    date NOT NULL,
    capacity    int  NOT NULL,
    format      text NOT NULL,
    curator     text
);

CREATE TABLE IF NOT EXISTS core.enrollments (
    enrollment_id text PRIMARY KEY,             -- cohort:seat
    cohort_code   text NOT NULL REFERENCES core.cohorts,
    client_id     text REFERENCES core.clients,
    status        text NOT NULL CHECK (status IN ('записан', 'учится', 'завершил', 'отчислен')),
    attended_pct  int,
    final_project boolean NOT NULL
);

-- Сотрудники: без ФИО и окладов (ФИО — отдельно в core.employee_names, только для HR; окладов нет).
CREATE TABLE IF NOT EXISTS core.employees (
    emp_id      text PRIMARY KEY,
    entity_id   text NOT NULL,
    department  text NOT NULL,
    position    text NOT NULL,
    hire_date   date NOT NULL,
    fire_date   date
);

-- ФИО сотрудников — ПДн, отдельно от карточки: читает только адаптер HR (mart_hr.src_onb_employees).
-- Оклады в core не загружаются вовсе: ФОТ — только суммой по отделу и месяцу.
CREATE TABLE IF NOT EXISTS core.employee_names (
    emp_id      text PRIMARY KEY REFERENCES core.employees,
    full_name   text NOT NULL
);

-- ФОТ из 1С:ЗУП: начислено + налоги работодателя, по юрлицу × отделу × месяцу (без людей).
-- is_final = false — плановое начисление текущего месяца (предварительно).
CREATE TABLE IF NOT EXISTS core.payroll_monthly (
    entity_id      text    NOT NULL,
    department     text    NOT NULL,
    month          date    NOT NULL,
    headcount      int     NOT NULL,
    accrued        numeric(18,2) NOT NULL,
    employer_taxes numeric(18,2) NOT NULL,
    is_final       boolean NOT NULL,
    PRIMARY KEY (entity_id, department, month)
);

-- Отсутствия из 1С:ЗУП (отпуск, больничный): дни по отделу × месяцу, без людей
-- (больничный — сведения о здоровье, по человеку в хаб не попадает).
CREATE TABLE IF NOT EXISTS core.absences_monthly (
    department  text NOT NULL,
    month       date NOT NULL,
    kind        text NOT NULL CHECK (kind IN ('vacation', 'sick')),
    days        int  NOT NULL,
    people      int  NOT NULL,
    PRIMARY KEY (department, month, kind)
);

-- Вакансии из таблицы HR: открыта → закрыта наймом | отменена.
CREATE TABLE IF NOT EXISTS core.vacancies (
    vacancy_id    text PRIMARY KEY,
    position      text NOT NULL,
    department    text NOT NULL,
    opened        date NOT NULL,
    closed        date,
    status        text NOT NULL CHECK (status IN ('open', 'closed', 'cancelled')),
    source        text NOT NULL,
    candidates    int,
    hired_emp_id  text
);

-- Рекламные кампании (кабинеты Meta, Google, Telegram и таблица бюджета маркетинга).
-- campaign_id = utm_campaign — по нему склеиваются расход и заявки amoCRM.
CREATE TABLE IF NOT EXISTS core.ad_campaigns (
    campaign_id text PRIMARY KEY,
    channel     text NOT NULL,              -- как core.leads.channel (utm_source)
    cabinet     text NOT NULL,
    title       text NOT NULL,
    start_date  date NOT NULL,
    end_date    date
);

-- Расход по дням и кампаниям, без НДС, KZT.
CREATE TABLE IF NOT EXISTS core.ad_spend (
    day         date NOT NULL,
    campaign_id text NOT NULL REFERENCES core.ad_campaigns,
    channel     text NOT NULL,
    amount      numeric(18,2) NOT NULL,
    impressions int,
    clicks      int,
    PRIMARY KEY (day, campaign_id)
);
CREATE INDEX IF NOT EXISTS ad_spend_day_idx ON core.ad_spend (day);

CREATE TABLE IF NOT EXISTS core.load_log (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    rows_loaded int,
    data_as_of  date
);

-- Загрузка raw → core. Одна транзакция: либо всё, либо ничего. Повторный запуск безопасен.
CREATE OR REPLACE FUNCTION core.load() RETURNS int
LANGUAGE plpgsql SET search_path = core, pg_temp AS $$
DECLARE
    v_log bigint;
    v_n   int := 0;
    v_c   int;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('core.load'));
    INSERT INTO core.load_log DEFAULT VALUES RETURNING id INTO v_log;

    TRUNCATE core.ad_spend, core.ad_campaigns, core.vacancies, core.absences_monthly, core.payroll_monthly,
             core.employee_names, core.enrollments, core.cohorts, core.leads, core.managers, core.bank_lines,
             core.payments_out, core.expenses, core.payments_in, core.cash_openings,
             core.cash_accounts, core.sales_docs, core.suppliers, core.client_source_map,
             core.clients, core.employees, core.legal_entities;

    INSERT INTO core.legal_entities SELECT infobase, name, bin FROM raw_1c.organizations;

    -- Клиенты: покупатели (есть «Реализация»), не свои юрлица. Ключ — БИН/ИИН.
    WITH buyers AS (
        SELECT DISTINCT ON (k.bin_iin) k.bin_iin, k.kind, k.name, k.phone, k.email
        FROM raw_1c.kontragenty k
        WHERE k.deletion_mark = 'false' AND k.is_group = 'false'
          AND EXISTS (SELECT 1 FROM raw_1c.realizatsiya r WHERE r.kontragent_ref = k.ref AND r.infobase = k.infobase)
        ORDER BY k.bin_iin, k.infobase
    )
    INSERT INTO core.clients (client_id, kind, name, tax_id, phone, email)
    SELECT 'CL-' || substr(md5(bin_iin), 1, 12),
           CASE WHEN kind = 'ФизЛицо' THEN 'person' ELSE 'company' END,
           name, bin_iin, NULLIF(phone, ''), lower(NULLIF(email, ''))
    FROM buyers;

    INSERT INTO core.client_source_map (system, source_ref, client_id)
    SELECT '1c:' || k.infobase, k.ref, c.client_id
    FROM raw_1c.kontragenty k JOIN core.clients c ON c.tax_id = k.bin_iin
    WHERE k.is_group = 'false';

    INSERT INTO core.suppliers (supplier_id, entity_id, name, tax_id, is_group)
    SELECT k.infobase || ':' || k.ref, k.infobase, k.name, k.bin_iin, k.is_group = 'true'
    FROM raw_1c.kontragenty k
    WHERE k.code LIKE 'SUP-%' OR k.is_group = 'true';

    INSERT INTO core.sales_docs
    SELECT r.infobase || ':' || r.ref, r.infobase, r.number, r.date::date,
           m.client_id,
           CASE WHEN k.is_group = 'true' THEN o.infobase END,
           k.is_group = 'true',
           n.group_name, t.qty::numeric, NULLIF(t.cohort_code, ''),
           r.sum_total::numeric, r.sum_vat::numeric, r.sum_total::numeric - r.sum_vat::numeric,
           r.currency, NULLIF(r.due_date, '')::date, NULLIF(r.manager_code, '')
    FROM raw_1c.realizatsiya r
    JOIN raw_1c.kontragenty k ON k.ref = r.kontragent_ref AND k.infobase = r.infobase
    JOIN raw_1c.realizatsiya_tovary t ON t.doc_ref = r.ref AND t.infobase = r.infobase AND t.line_no = '1'
    JOIN raw_1c.nomenklatura n ON n.ref = t.nomenklatura_ref
    LEFT JOIN core.client_source_map m ON m.system = '1c:' || r.infobase AND m.source_ref = r.kontragent_ref
    LEFT JOIN raw_1c.organizations o ON o.bin = k.bin_iin
    WHERE r.posted = 'true' AND r.deletion_mark = 'false';

    INSERT INTO core.cash_accounts
    SELECT ref, infobase, name, NULLIF(bank_name, ''), NULLIF(iban, ''),
           CASE WHEN kind = 'kassa' THEN 'cash' ELSE 'bank' END, currency
    FROM raw_1c.bank_accounts;
    INSERT INTO core.cash_openings SELECT account_ref, date::date, sum::numeric FROM raw_1c.ostatki_dc;

    INSERT INTO core.payments_in
    SELECT p.infobase || ':' || p.ref, p.infobase, p.date::date, m.client_id,
           NULLIF(p.infobase || ':' || p.osnovanie_ref, p.infobase || ':'), p.sum::numeric, 'bank',
           p.bank_account_ref, NULLIF(p.bank_line_id, ''), k.is_group = 'true'
    FROM raw_1c.postuplenie_rs p
    JOIN raw_1c.kontragenty k ON k.ref = p.kontragent_ref AND k.infobase = p.infobase
    LEFT JOIN core.client_source_map m ON m.system = '1c:' || p.infobase AND m.source_ref = p.kontragent_ref
    WHERE p.posted = 'true' AND p.deletion_mark = 'false'
    UNION ALL
    SELECT p.infobase || ':' || p.ref, p.infobase, p.date::date, m.client_id,
           NULLIF(p.infobase || ':' || p.osnovanie_ref, p.infobase || ':'), p.sum::numeric, 'cash',
           p.kassa_ref, NULL, false
    FROM raw_1c.pko p
    LEFT JOIN core.client_source_map m ON m.system = '1c:' || p.infobase AND m.source_ref = p.kontragent_ref
    WHERE p.posted = 'true' AND p.deletion_mark = 'false';

    INSERT INTO core.expenses
    SELECT z.infobase || ':' || z.ref, z.infobase, z.date::date, z.doc_type,
           NULLIF(z.infobase || ':' || z.kontragent_ref, z.infobase || ':'),
           z.account_code, z.statya_zatrat, z.sum::numeric, z.sum_vat::numeric,
           COALESCE(k.is_group = 'true', false)
    FROM raw_1c.zatraty z
    LEFT JOIN raw_1c.kontragenty k ON k.ref = z.kontragent_ref AND k.infobase = z.infobase
    WHERE z.posted = 'true' AND z.deletion_mark = 'false';

    INSERT INTO core.payments_out
    SELECT s.infobase || ':' || s.ref, s.infobase, s.date::date,
           NULLIF(s.infobase || ':' || s.kontragent_ref, s.infobase || ':'),
           s.sum::numeric, s.cf_article, s.bank_account_ref, NULLIF(s.bank_line_id, ''),
           COALESCE(k.is_group = 'true', false)
    FROM raw_1c.spisanie_rs s
    LEFT JOIN raw_1c.kontragenty k ON k.ref = s.kontragent_ref AND k.infobase = s.infobase
    WHERE s.posted = 'true' AND s.deletion_mark = 'false';

    INSERT INTO core.bank_lines
    SELECT l.line_id, l.statement_id, l.bank, a.account_id, a.entity_id, l.value_date::date,
           l.amount::numeric, l.currency, NULLIF(l.counterparty_name, ''), NULLIF(l.counterparty_bin, ''),
           l.purpose, NULLIF(l.doc_no, ''),
           EXISTS (SELECT 1 FROM core.payments_in p WHERE p.bank_line_id = l.line_id)
             OR EXISTS (SELECT 1 FROM core.payments_out p WHERE p.bank_line_id = l.line_id)
    FROM raw_bank.statement_lines l
    JOIN core.cash_accounts a ON a.iban = l.account_iban;

    INSERT INTO core.managers SELECT id, name FROM raw_amocrm.amo_users;

    WITH l AS (
        SELECT x.id, x.created_at::timestamptz AS created_at,
               (x.created_at::timestamptz AT TIME ZONE 'Asia/Almaty')::date AS created_date,
               x.pipeline, x.utm_source, x.status, NULLIF(x.price, '')::numeric AS price,
               x.responsible_user_id, md5(x.contact_phone) AS contact_key, x.contact_phone,
               NULLIF(x.company_bin, '') AS company_bin, NULLIF(x.closed_at, '')::date AS closed_date,
               NULLIF(x.loss_reason, '') AS loss_reason, NULLIF(x.utm_campaign, '') AS utm_campaign,
               lag(x.created_at::timestamptz) OVER (PARTITION BY md5(x.contact_phone) ORDER BY x.created_at::timestamptz, x.id) AS prev_at
        FROM raw_amocrm.leads x
    ),
    cl AS (SELECT DISTINCT ON (phone) phone, client_id FROM core.clients WHERE kind = 'person' AND phone IS NOT NULL ORDER BY phone, client_id)
    INSERT INTO core.leads (lead_id, created_at, created_date, pipeline, channel, status, stage, amount, manager_id,
                            client_id, contact_key, is_duplicate, closed_date, loss_reason, campaign)
    SELECT l.id, l.created_at, l.created_date, l.pipeline, l.utm_source, l.status,
           CASE l.status WHEN 'Успешно реализовано' THEN 'won' WHEN 'Закрыто и не реализовано' THEN 'lost' ELSE 'open' END,
           l.price, l.responsible_user_id,
           COALESCE((SELECT c.client_id FROM core.clients c WHERE c.tax_id = l.company_bin LIMIT 1),
                    (SELECT cl.client_id FROM cl WHERE l.company_bin IS NULL AND cl.phone = l.contact_phone)),
           l.contact_key,
           COALESCE(l.prev_at >= l.created_at - interval '30 days', false),
           l.closed_date, l.loss_reason, l.utm_campaign
    FROM l;

    INSERT INTO core.cohorts
    SELECT cohort_code, course, start_date::date, end_date::date, capacity::int, format, NULLIF(curator, '')
    FROM raw_sheets.cohorts;

    INSERT INTO core.enrollments
    SELECT s.cohort_code || ':' || s.seat_no, s.cohort_code, m.client_id, s.status,
           NULLIF(s.attended_pct, '')::int, s.final_project = 'да'
    FROM raw_sheets.cohort_students s
    LEFT JOIN core.client_source_map m ON m.system = '1c:airl' AND m.source_ref = s.kontragent_ref;

    INSERT INTO core.employees
    SELECT ref, infobase, podrazdelenie, dolzhnost, hire_date::date, NULLIF(fire_date, '')::date
    FROM raw_1c.sotrudniki;
    INSERT INTO core.employee_names SELECT ref, fio FROM raw_1c.sotrudniki;

    INSERT INTO core.payroll_monthly
    SELECT z.infobase, z.podrazdelenie, z.month::date, count(*), sum(z.nachisleno::numeric),
           sum(z.nalogi_rabotodatelya::numeric), bool_and(z.status = 'final')
    FROM raw_1c.zup_nachisleniya z GROUP BY 1, 2, 3;

    -- отсутствие уже разрезано по месяцам в ЗУП; дни — календарные
    INSERT INTO core.absences_monthly
    SELECT s.podrazdelenie, date_trunc('month', o.date_from::date)::date,
           CASE o.kind WHEN 'Больничный' THEN 'sick' ELSE 'vacation' END,
           sum(o.date_to::date - o.date_from::date + 1), count(DISTINCT o.tab_no)
    FROM raw_1c.zup_otsutstviya o
    JOIN raw_1c.sotrudniki s ON s.tab_no = o.tab_no AND s.infobase = o.infobase
    GROUP BY 1, 2, 3;

    INSERT INTO core.vacancies
    SELECT v.vacancy_id, v.position, v.department, v.opened::date, NULLIF(v.closed, '')::date, v.status, v.source,
           NULLIF(v.candidates, '')::int, s.ref
    FROM raw_sheets.vacancies v LEFT JOIN raw_1c.sotrudniki s ON s.tab_no = NULLIF(v.hired_tab_no, '');

    INSERT INTO core.ad_campaigns
    SELECT utm_campaign, channel, cabinet, title, start_date::date, NULLIF(end_date, '')::date FROM raw_ads.ad_campaigns;
    INSERT INTO core.ad_spend
    SELECT date::date, utm_campaign, channel, sum(spend::numeric), sum(impressions::int), sum(clicks::int)
    FROM raw_ads.ad_spend GROUP BY 1, 2, 3;

    SELECT (SELECT count(*) FROM core.sales_docs) + (SELECT count(*) FROM core.payments_in)
         + (SELECT count(*) FROM core.expenses) + (SELECT count(*) FROM core.leads)
         + (SELECT count(*) FROM core.bank_lines) INTO v_c;
    v_n := v_c;
    UPDATE core.load_log SET finished_at = now(), rows_loaded = v_n,
           data_as_of = (SELECT max(doc_date) FROM core.sales_docs) WHERE id = v_log;
    RETURN v_n;
END $$;

-- Права слоя: загрузка пишет core, владелец показателей читает core.
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA core TO airl_loader;
GRANT EXECUTE ON FUNCTION core.load() TO airl_loader;
REVOKE EXECUTE ON FUNCTION core.load() FROM PUBLIC;

-- Владелец показателей читает core целиком (формулы карты), больше ничего.
GRANT SELECT ON ALL TABLES IN SCHEMA core TO metrics_owner;

-- ФИО сотрудников — только адаптеру HR (выдаёт 04_grants.sql), владельцу показателей не нужны.
REVOKE SELECT ON core.employee_names FROM metrics_owner;
