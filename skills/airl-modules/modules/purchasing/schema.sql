-- Модуль «Закупки» (purchasing): потребность → заявка → согласование → выбор поставщика
-- по предложениям → заказ поставщику → ожидаемые поставки и частичные поступления →
-- проверка качества → оплата (из учёта). Справочник условий поставщиков и контрактных цен,
-- точка заказа по остаткам и расходу, отклонения: опоздание, недопоставка, цена выше контракта.
-- Требует kit/kit.sql в той же схеме и представления src_pur_items, src_pur_suppliers,
-- src_pur_stock, src_pur_consumption, src_pur_payments (адаптер или demo_src.sql).
-- Прогноз спроса на месяцы вперёд — отдельный модуль demand-forecast; здесь — правило.

CREATE SEQUENCE IF NOT EXISTS pur_request_seq;
CREATE SEQUENCE IF NOT EXISTS pur_po_seq;
CREATE SEQUENCE IF NOT EXISTS pur_receipt_seq;

-- Условия поставщика: оплата, срок поставки, минимальный заказ, контракт.
CREATE TABLE IF NOT EXISTS pur_supplier_terms (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id        text          NOT NULL UNIQUE,          -- ключ из src_pur_suppliers
    payment_terms_days int           NOT NULL DEFAULT 0 CHECK (payment_terms_days BETWEEN 0 AND 365),
    prepayment_pct     numeric(5,2)  NOT NULL DEFAULT 0 CHECK (prepayment_pct BETWEEN 0 AND 100),
    lead_time_days     int           CHECK (lead_time_days IS NULL OR lead_time_days BETWEEN 0 AND 365),
    min_order_amount   numeric(18,2) CHECK (min_order_amount IS NULL OR min_order_amount >= 0),
    currency           char(3)       NOT NULL,
    contract_no        text,
    contract_from      date,
    contract_until     date,
    incoterms          text,
    notes              text,
    archived           boolean       NOT NULL DEFAULT false,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    created_by         text          NOT NULL,
    updated_at         timestamptz,
    updated_by         text,
    CHECK (contract_until IS NULL OR contract_from IS NULL OR contract_until >= contract_from),
    CHECK (contract_until IS NULL OR contract_no IS NOT NULL)
);

-- Цены: контрактные (с ними сравниваются заказы) и прайс-листы.
CREATE TABLE IF NOT EXISTS pur_prices (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id text          NOT NULL,
    sku         text          NOT NULL,
    kind        text          NOT NULL CHECK (kind IN ('contract', 'price_list')),
    price       numeric(18,2) NOT NULL CHECK (price > 0),
    currency    char(3)       NOT NULL,
    moq         numeric(18,3) CHECK (moq IS NULL OR moq > 0),
    valid_from  date          NOT NULL,
    valid_to    date,
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    UNIQUE (supplier_id, sku, kind, valid_from),
    CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
CREATE INDEX IF NOT EXISTS pur_prices_lookup_idx ON pur_prices (sku, supplier_id, kind, valid_from DESC);

-- Настройки позиции: основной поставщик, свой срок поставки и страховые дни, кратность.
CREATE TABLE IF NOT EXISTS pur_item_settings (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku                   text          NOT NULL,
    warehouse_id          text          NOT NULL,
    preferred_supplier_id text,
    lead_time_days        int           CHECK (lead_time_days IS NULL OR lead_time_days BETWEEN 0 AND 365),
    safety_days           int           CHECK (safety_days IS NULL OR safety_days >= 0),
    review_days           int           CHECK (review_days IS NULL OR review_days > 0),
    order_multiple        numeric(18,3) CHECK (order_multiple IS NULL OR order_multiple > 0),
    min_order_qty         numeric(18,3) CHECK (min_order_qty IS NULL OR min_order_qty > 0),
    archived              boolean       NOT NULL DEFAULT false,
    created_at            timestamptz   NOT NULL DEFAULT now(),
    created_by            text          NOT NULL,
    updated_at            timestamptz,
    updated_by            text,
    UNIQUE (sku, warehouse_id)
);

-- Заявка на закупку: одна позиция или услуга. Источник — точка заказа, вручную, план.
CREATE TABLE IF NOT EXISTS pur_requests (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_no     text          NOT NULL UNIQUE DEFAULT 'REQ-' || lpad(nextval('pur_request_seq')::text, 6, '0'),
    sku            text,                                       -- пусто для услуг без кода
    description    text,
    category       text          NOT NULL CHECK (category IN ('green_coffee', 'packaging', 'goods', 'spare_parts', 'equipment', 'services', 'other')),
    warehouse_id   text          NOT NULL,
    qty            numeric(18,3) NOT NULL CHECK (qty > 0),
    unit           text,
    needed_by      date,
    source         text          NOT NULL CHECK (source IN ('reorder', 'manual', 'plan')),
    unplanned      boolean       NOT NULL DEFAULT false,       -- внеплановая: всегда через согласование
    est_price      numeric(18,2) CHECK (est_price IS NULL OR est_price >= 0),
    est_amount     numeric(18,2) GENERATED ALWAYS AS (round(qty * est_price, 2)) STORED,
    currency       char(3)       NOT NULL DEFAULT (airl_setting('purchasing', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}'),
    status         text          NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'ordered', 'cancelled')),
    submitted_at   timestamptz,
    approved_by    text,
    approved_at    timestamptz,
    approval_ref   text,                                       -- номер заявки в модуле approvals (режим approvals)
    reject_reason  text,
    cancel_reason  text,
    justification  text,                                       -- зачем внеплановая
    created_at     timestamptz   NOT NULL DEFAULT now(),
    created_by     text          NOT NULL,
    updated_at     timestamptz,
    updated_by     text,
    CHECK (sku IS NOT NULL OR description IS NOT NULL),
    CHECK (NOT unplanned OR justification IS NOT NULL),
    CHECK (status NOT IN ('approved', 'ordered') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
    CHECK (approved_by IS NULL OR approved_by = 'auto_rule' OR approved_by <> created_by),   -- «четыре глаза»
    CHECK (status <> 'rejected' OR reject_reason IS NOT NULL),
    CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);
-- Одна открытая заявка «по точке заказа» на позицию и склад: повторный запуск не плодит дубли.
CREATE UNIQUE INDEX IF NOT EXISTS pur_requests_reorder_open ON pur_requests (sku, warehouse_id)
    WHERE source = 'reorder' AND status IN ('draft', 'submitted', 'approved');
CREATE INDEX IF NOT EXISTS pur_requests_status_idx ON pur_requests (status, created_at);

-- Предложения поставщиков по заявке: сравнение цен. fx_rate — курс к валюте модуля на дату предложения.
CREATE TABLE IF NOT EXISTS pur_offers (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id     bigint        NOT NULL REFERENCES pur_requests (id),
    supplier_id    text          NOT NULL,
    price          numeric(18,2) NOT NULL CHECK (price > 0),
    currency       char(3)       NOT NULL,
    fx_rate        numeric(18,6) NOT NULL DEFAULT 1 CHECK (fx_rate > 0),
    lead_time_days int           CHECK (lead_time_days IS NULL OR lead_time_days >= 0),
    moq            numeric(18,3) CHECK (moq IS NULL OR moq > 0),
    valid_until    date,
    comment        text,
    chosen         boolean       NOT NULL DEFAULT false,
    choose_reason  text,                                       -- обязательно, если выбран не самый дешёвый
    created_at     timestamptz   NOT NULL DEFAULT now(),
    created_by     text          NOT NULL,
    updated_at     timestamptz,
    updated_by     text,
    UNIQUE (request_id, supplier_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS pur_offers_one_chosen ON pur_offers (request_id) WHERE chosen;

-- Заказ поставщику.
CREATE TABLE IF NOT EXISTS pur_orders (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_no              text          NOT NULL UNIQUE DEFAULT 'PO-' || lpad(nextval('pur_po_seq')::text, 6, '0'),
    supplier_id        text          NOT NULL,
    warehouse_id       text          NOT NULL,                 -- куда привезти
    currency           char(3)       NOT NULL,
    status             text          NOT NULL DEFAULT 'draft'
                       CHECK (status IN ('draft', 'sent', 'confirmed', 'partially_received', 'received', 'closed', 'cancelled')),
    order_date         date,
    expected_date      date          NOT NULL,
    payment_terms_days int           NOT NULL DEFAULT 0 CHECK (payment_terms_days >= 0),
    sent_at            timestamptz,
    confirmed_at       timestamptz,
    received_at        timestamptz,
    closed_at          timestamptz,
    cancel_reason      text,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    created_by         text          NOT NULL,
    updated_at         timestamptz,
    updated_by         text,
    CHECK (status = 'draft' OR status = 'cancelled' OR (sent_at IS NOT NULL AND order_date IS NOT NULL)),
    CHECK (status NOT IN ('received', 'closed') OR received_at IS NOT NULL),
    CHECK (status <> 'closed' OR closed_at IS NOT NULL),
    CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS pur_orders_status_idx ON pur_orders (status, expected_date);
CREATE INDEX IF NOT EXISTS pur_orders_supplier_idx ON pur_orders (supplier_id, order_date);

CREATE TABLE IF NOT EXISTS pur_order_lines (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_id          bigint        NOT NULL REFERENCES pur_orders (id),
    line_no        int           NOT NULL,
    request_id     bigint        UNIQUE REFERENCES pur_requests (id),   -- заявка попадает в заказ один раз
    sku            text,
    description    text,
    qty            numeric(18,3) NOT NULL CHECK (qty > 0),
    unit           text,
    price          numeric(18,2) NOT NULL CHECK (price >= 0),
    amount         numeric(18,2) GENERATED ALWAYS AS (round(qty * price, 2)) STORED,
    contract_price numeric(18,2),                              -- контрактная цена на дату заказа (снимок)
    expected_date  date,                                       -- своя дата строки, если отличается
    received_qty   numeric(18,3) NOT NULL DEFAULT 0 CHECK (received_qty >= 0),   -- принято без брака QC
    closed_short   boolean       NOT NULL DEFAULT false,
    short_reason   text,
    created_at     timestamptz   NOT NULL DEFAULT now(),
    created_by     text          NOT NULL,
    updated_at     timestamptz,
    updated_by     text,
    UNIQUE (po_id, line_no),
    CHECK (sku IS NOT NULL OR description IS NOT NULL),
    CHECK (NOT closed_short OR short_reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS pur_order_lines_sku_idx ON pur_order_lines (sku);

-- Поступления по строкам заказа (частичные — несколько строк). Статус — проверка качества.
CREATE TABLE IF NOT EXISTS pur_receipts (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    receipt_no  text          NOT NULL UNIQUE DEFAULT 'GR-' || lpad(nextval('pur_receipt_seq')::text, 6, '0'),
    po_line_id  bigint        NOT NULL REFERENCES pur_order_lines (id),
    qty         numeric(18,3) NOT NULL CHECK (qty > 0),
    received_at timestamptz   NOT NULL DEFAULT now(),
    lot_no      text,                                          -- лот поставщика (зелёное зерно)
    source      text          NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'picking', '1c')),
    source_ref  text          UNIQUE,                          -- id поступления в источнике: повторная загрузка не дублирует
    status      text          NOT NULL CHECK (status IN ('accepted', 'qc_pending', 'qc_passed', 'qc_rejected')),
    qc_comment  text,
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    CHECK (status <> 'qc_rejected' OR qc_comment IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS pur_receipts_line_idx ON pur_receipts (po_line_id, received_at);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['pur_supplier_terms', 'pur_prices', 'pur_item_settings', 'pur_requests', 'pur_offers',
                             'pur_orders', 'pur_order_lines', 'pur_receipts'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_touch', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION airl_touch()', t || '_touch', t);
    END LOOP;
END $$;

-- Контрактные цены одного поставщика на одну позицию не должны пересекаться по датам.
CREATE OR REPLACE FUNCTION pur_prices_guard() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF NEW.kind = 'contract' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('purchasing:price:' || NEW.supplier_id || ':' || NEW.sku, 0));
        IF EXISTS (SELECT 1 FROM pur_prices p
                   WHERE p.supplier_id = NEW.supplier_id AND p.sku = NEW.sku AND p.kind = 'contract' AND p.id <> NEW.id
                     AND daterange(p.valid_from, p.valid_to, '[]') && daterange(NEW.valid_from, NEW.valid_to, '[]')) THEN
            RAISE EXCEPTION 'purchasing: у % уже есть контрактная цена на % в эти даты — закройте старую (valid_to)', NEW.supplier_id, NEW.sku;
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pur_prices_guard ON pur_prices;
CREATE TRIGGER pur_prices_guard BEFORE INSERT OR UPDATE ON pur_prices FOR EACH ROW EXECUTE FUNCTION pur_prices_guard();

-- Действующая контрактная цена на дату.
CREATE OR REPLACE FUNCTION pur_contract_price(p_supplier text, p_sku text, p_currency text, p_on date)
RETURNS numeric LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    SELECT p.price FROM pur_prices p
    WHERE p.supplier_id = p_supplier AND p.sku = p_sku AND p.kind = 'contract' AND p.currency = p_currency
      AND p.valid_from <= p_on AND (p.valid_to IS NULL OR p.valid_to >= p_on)
    ORDER BY p.valid_from DESC LIMIT 1
$$;

-- Строки заказа меняются только в черновике (кроме приёмки и закрытия недопоставки);
-- контрактная цена фиксируется снимком при добавлении строки.
CREATE OR REPLACE FUNCTION pur_lines_guard() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE po pur_orders%ROWTYPE;
BEGIN
    SELECT * INTO po FROM pur_orders WHERE id = NEW.po_id;
    IF TG_OP = 'INSERT' THEN
        IF po.status <> 'draft' THEN RAISE EXCEPTION 'purchasing: строки добавляются только в черновик заказа %', po.po_no; END IF;
        IF NEW.sku IS NOT NULL THEN
            NEW.contract_price := pur_contract_price(po.supplier_id, NEW.sku, po.currency, coalesce(po.order_date, current_date));
        END IF;
    ELSIF (NEW.qty, NEW.price, NEW.sku, NEW.po_id) IS DISTINCT FROM (OLD.qty, OLD.price, OLD.sku, OLD.po_id) AND po.status <> 'draft' THEN
        RAISE EXCEPTION 'purchasing: заказ % уже отправлен — количество и цену меняет новый заказ', po.po_no;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pur_lines_guard ON pur_order_lines;
CREATE TRIGGER pur_lines_guard BEFORE INSERT OR UPDATE ON pur_order_lines FOR EACH ROW EXECUTE FUNCTION pur_lines_guard();

-- ───────────── Статусы ─────────────
CREATE OR REPLACE FUNCTION pur_status_guard() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_actor   text := coalesce(NEW.updated_by, NEW.created_by, 'system');
    v_allowed text[];
    v_init    text[];
    v_comment text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_init := CASE TG_TABLE_NAME WHEN 'pur_requests' THEN ARRAY['draft'] WHEN 'pur_orders' THEN ARRAY['draft']
                                     ELSE ARRAY['accepted', 'qc_pending'] END;
        IF NOT NEW.status = ANY (v_init) THEN
            RAISE EXCEPTION 'purchasing: новая запись % создаётся в статусе %', TG_TABLE_NAME, v_init[1];
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
    v_allowed := CASE TG_TABLE_NAME
        WHEN 'pur_requests' THEN ARRAY['draft>submitted', 'draft>cancelled', 'submitted>approved', 'submitted>rejected',
                                       'submitted>draft', 'submitted>cancelled', 'approved>ordered', 'approved>cancelled']
        WHEN 'pur_orders' THEN ARRAY['draft>sent', 'draft>cancelled', 'sent>confirmed', 'sent>cancelled',
                                     'sent>partially_received', 'sent>received', 'confirmed>partially_received',
                                     'confirmed>received', 'confirmed>cancelled', 'partially_received>received',
                                     'received>partially_received', 'received>closed']
        ELSE ARRAY['qc_pending>qc_passed', 'qc_pending>qc_rejected']
    END;
    IF NOT (OLD.status || '>' || NEW.status) = ANY (v_allowed) THEN
        RAISE EXCEPTION 'purchasing: переход % → % не разрешён (%)', OLD.status, NEW.status, TG_TABLE_NAME;
    END IF;

    IF TG_TABLE_NAME = 'pur_requests' THEN
        IF NEW.status = 'submitted' THEN NEW.submitted_at := now(); END IF;
        IF NEW.status = 'approved' THEN
            NEW.approved_at := coalesce(NEW.approved_at, now());
            IF (airl_setting('purchasing', 'approval_mode', '"builtin"') #>> '{}') = 'approvals'
               AND NEW.approved_by <> 'auto_rule' AND NEW.approval_ref IS NULL THEN
                RAISE EXCEPTION 'purchasing: согласование ведётся в модуле approvals — нужен номер его заявки';
            END IF;
        END IF;
        v_comment := coalesce(NEW.reject_reason, NEW.cancel_reason, NEW.approval_ref);
    ELSIF TG_TABLE_NAME = 'pur_orders' THEN
        CASE NEW.status
            WHEN 'sent' THEN
                IF NOT EXISTS (SELECT 1 FROM pur_order_lines l WHERE l.po_id = NEW.id) THEN
                    RAISE EXCEPTION 'purchasing: в заказе % нет строк', NEW.po_no;
                END IF;
                NEW.sent_at := now(); NEW.order_date := coalesce(NEW.order_date, current_date);
            WHEN 'confirmed' THEN NEW.confirmed_at := now();
            WHEN 'received' THEN
                IF EXISTS (SELECT 1 FROM pur_order_lines l WHERE l.po_id = NEW.id AND NOT l.closed_short AND l.received_qty < l.qty) THEN
                    RAISE EXCEPTION 'purchasing: по заказу % пришло не всё — закройте недопоставку или ждите', NEW.po_no;
                END IF;
                NEW.received_at := now();
            WHEN 'partially_received' THEN NEW.received_at := NULL;
            WHEN 'closed' THEN
                IF EXISTS (SELECT 1 FROM pur_receipts r JOIN pur_order_lines l ON l.id = r.po_line_id
                           WHERE l.po_id = NEW.id AND r.status = 'qc_pending') THEN
                    RAISE EXCEPTION 'purchasing: по заказу % есть поступления без проверки качества', NEW.po_no;
                END IF;
                NEW.closed_at := now();
            WHEN 'cancelled' THEN
                IF EXISTS (SELECT 1 FROM pur_receipts r JOIN pur_order_lines l ON l.id = r.po_line_id WHERE l.po_id = NEW.id) THEN
                    RAISE EXCEPTION 'purchasing: по заказу % уже было поступление — закройте недопоставку, а не отменяйте', NEW.po_no;
                END IF;
            ELSE NULL;
        END CASE;
        v_comment := NEW.cancel_reason;
    ELSE
        v_comment := NEW.qc_comment;
    END IF;

    INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
    VALUES (v_actor, 'purchasing', TG_TABLE_NAME, NEW.id::text, 'status', OLD.status, NEW.status, v_comment);
    RETURN NEW;
END $$;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['pur_requests', 'pur_orders', 'pur_receipts'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_status', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION pur_status_guard()', t || '_status', t);
    END LOOP;
END $$;

-- ───────────── Точка заказа ─────────────
-- По позиции и складу: средний расход в день за window_days, разброс, срок поставки,
-- страховой запас, точка заказа, позиция (остаток + в пути + открытые заявки) и
-- предлагаемое количество. Страховой запас: safety_method = 'days' — safety_days × расход;
-- 'stddev' — z(service_level) × σ дневного расхода × √срок поставки.
CREATE OR REPLACE VIEW v_pur_reorder AS
WITH cfg AS (
    SELECT greatest((airl_setting('purchasing', 'window_days', '60'))::text::int, 2) AS n,
           (airl_setting('purchasing', 'lead_time_days', '14'))::text::int AS lt,
           (airl_setting('purchasing', 'safety_days', '7'))::text::int AS sd,
           (airl_setting('purchasing', 'review_days', '14'))::text::int AS rv,
           airl_setting('purchasing', 'safety_method', '"days"') #>> '{}' AS method,
           (airl_setting('purchasing', 'service_level', '95'))::text::numeric AS sl
), cons AS (
    SELECT c.sku, c.warehouse_id, sum(c.qty_out) AS s, sum(c.qty_out * c.qty_out) AS s2
    FROM src_pur_consumption c, cfg WHERE c.day >= current_date - cfg.n AND c.day < current_date
    GROUP BY c.sku, c.warehouse_id
), stock AS (
    SELECT sku, warehouse_id, sum(qty) AS qty, max(updated_at) AS updated_at FROM src_pur_stock GROUP BY 1, 2
), on_order AS (
    SELECT l.sku, o.warehouse_id, sum(greatest(l.qty - l.received_qty, 0)) AS qty
    FROM pur_order_lines l JOIN pur_orders o ON o.id = l.po_id
    WHERE o.status IN ('draft', 'sent', 'confirmed', 'partially_received') AND NOT l.closed_short AND l.sku IS NOT NULL
    GROUP BY 1, 2
), requested AS (
    SELECT r.sku, r.warehouse_id, sum(r.qty) AS qty FROM pur_requests r
    WHERE r.status IN ('draft', 'submitted', 'approved') AND r.sku IS NOT NULL GROUP BY 1, 2
), base AS (
    SELECT c.sku, c.warehouse_id, i.sku_name, i.unit, i.category,
           round(c.s / cfg.n, 3) AS avg_daily,
           sqrt(greatest((c.s2 - c.s * c.s / cfg.n) / (cfg.n - 1), 0)) AS sd_daily,
           coalesce(st.lead_time_days, t.lead_time_days, cfg.lt) AS lead_time_days,
           coalesce(st.safety_days, cfg.sd) AS safety_days,
           coalesce(st.review_days, cfg.rv) AS review_days,
           st.order_multiple, st.min_order_qty, st.preferred_supplier_id,
           cfg.method, CASE WHEN cfg.sl >= 99 THEN 2.33 WHEN cfg.sl >= 98 THEN 2.05 WHEN cfg.sl >= 95 THEN 1.65
                            WHEN cfg.sl >= 90 THEN 1.28 ELSE 1.0 END AS z,
           coalesce(sk.qty, 0) AS on_hand, sk.updated_at AS stock_updated_at,
           coalesce(oo.qty, 0) AS on_order, coalesce(rq.qty, 0) AS requested
    FROM cons c CROSS JOIN cfg
    JOIN src_pur_items i ON i.sku = c.sku AND i.stocked
    LEFT JOIN pur_item_settings st ON st.sku = c.sku AND st.warehouse_id = c.warehouse_id AND NOT st.archived
    LEFT JOIN pur_supplier_terms t ON t.supplier_id = st.preferred_supplier_id AND NOT t.archived
    LEFT JOIN stock sk ON sk.sku = c.sku AND sk.warehouse_id = c.warehouse_id
    LEFT JOIN on_order oo ON oo.sku = c.sku AND oo.warehouse_id = c.warehouse_id
    LEFT JOIN requested rq ON rq.sku = c.sku AND rq.warehouse_id = c.warehouse_id
    WHERE c.s > 0
), calc AS (
    SELECT b.*,
           round(CASE WHEN b.method = 'stddev' THEN b.z * b.sd_daily * sqrt(b.lead_time_days::numeric) ELSE b.safety_days * b.avg_daily END, 3) AS safety_stock,
           (b.on_hand + b.on_order + b.requested) AS position
    FROM base b
), rop AS (
    SELECT c.*, round(c.avg_daily * c.lead_time_days + c.safety_stock, 3) AS reorder_point,
           round(c.on_hand / NULLIF(c.avg_daily, 0), 1) AS days_of_cover
    FROM calc c
)
SELECT r.sku, r.warehouse_id, r.sku_name, r.unit, r.category, r.avg_daily, round(r.sd_daily, 3) AS sd_daily,
       r.lead_time_days, r.safety_stock, r.reorder_point, r.on_hand, r.on_order, r.requested, r.position,
       r.days_of_cover, r.stock_updated_at, r.preferred_supplier_id,
       (r.position <= r.reorder_point) AS below_rop,
       CASE WHEN r.position > r.reorder_point THEN 0 ELSE
           greatest(coalesce(r.min_order_qty, 0),
                    ceil((r.reorder_point + r.avg_daily * r.review_days - r.position) / coalesce(r.order_multiple, 1)) * coalesce(r.order_multiple, 1))
       END::numeric(18,3) AS suggest_qty
FROM rop r;

-- Заявки по точке заказа (запускать раз в день; дублей не будет — одна открытая на позицию).
CREATE OR REPLACE FUNCTION pur_generate_requests(p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE n int;
BEGIN
    INSERT INTO pur_requests (sku, category, warehouse_id, qty, unit, needed_by, source, est_price, currency, created_by)
    SELECT r.sku, r.category, r.warehouse_id, r.suggest_qty, r.unit, current_date + r.lead_time_days, 'reorder',
           pr.price, coalesce(pr.currency, airl_setting('purchasing', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}'),
           p_actor
    FROM v_pur_reorder r
    LEFT JOIN LATERAL (SELECT p.price, p.currency FROM pur_prices p
                       WHERE p.sku = r.sku AND p.kind = 'contract' AND p.valid_from <= current_date
                         AND (p.valid_to IS NULL OR p.valid_to >= current_date)
                       ORDER BY (p.supplier_id = r.preferred_supplier_id) DESC NULLS LAST, p.price LIMIT 1) pr ON true
    WHERE r.suggest_qty > 0
    ON CONFLICT (sku, warehouse_id) WHERE source = 'reorder' AND status IN ('draft', 'submitted', 'approved') DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- ───────────── Действия ─────────────

-- Отправить заявку. Встроенный режим (approval_mode = 'builtin'): плановая заявка
-- до auto_approve_limit одобряется правилом сразу; внеплановая и крупная ждёт
-- согласующего (approver_recipient). Режим 'approvals': заявка ждёт решения в модуле approvals.
CREATE OR REPLACE FUNCTION pur_submit(p_request_id bigint, p_actor text) RETURNS text
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    r      pur_requests%ROWTYPE;
    v_mode text := airl_setting('purchasing', 'approval_mode', '"builtin"') #>> '{}';
    v_lim  numeric := (airl_setting('purchasing', 'auto_approve_limit', '300000'))::text::numeric;
    v_to   text := airl_setting('purchasing', 'approver_recipient', '"purchasing_head"') #>> '{}';
BEGIN
    SELECT * INTO r FROM pur_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'purchasing: заявка % не найдена', p_request_id; END IF;
    UPDATE pur_requests SET status = 'submitted', updated_by = p_actor WHERE id = r.id;
    IF v_mode = 'builtin' AND NOT r.unplanned AND r.est_amount IS NOT NULL
       AND r.currency = (airl_setting('purchasing', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}')
       AND r.est_amount <= v_lim THEN
        UPDATE pur_requests SET status = 'approved', approved_by = 'auto_rule', approved_at = now(), updated_by = p_actor WHERE id = r.id;
        RETURN 'approved';
    END IF;
    IF v_mode = 'builtin' THEN
        INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
        VALUES ('purchasing:approve:' || r.id || ':' || v_to, 'purchasing', airl_setting('purchasing', 'channel', '"telegram"') #>> '{}', v_to,
                'Заявка ' || r.request_no || CASE WHEN r.unplanned THEN ' (внеплановая)' ELSE '' END || ': '
                || coalesce(r.sku, r.description) || ' × ' || r.qty || coalesce(', ~' || r.est_amount || ' ' || r.currency, '')
                || '. Нужно ваше решение.')
        ON CONFLICT (dedup_key) DO NOTHING;
    END IF;
    RETURN 'submitted';
END $$;

-- Решение согласующего. Создатель заявки сам себе не согласует (проверяет база).
CREATE OR REPLACE FUNCTION pur_decide(p_request_id bigint, p_approve boolean, p_actor text,
                                      p_reason text DEFAULT NULL, p_approval_ref text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF p_approve THEN
        UPDATE pur_requests SET status = 'approved', approved_by = p_actor, approved_at = now(),
                                approval_ref = coalesce(p_approval_ref, approval_ref), updated_by = p_actor
        WHERE id = p_request_id AND status = 'submitted';
    ELSE
        UPDATE pur_requests SET status = 'rejected', reject_reason = p_reason, updated_by = p_actor
        WHERE id = p_request_id AND status = 'submitted';
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'purchasing: решение принимается по отправленной заявке'; END IF;
END $$;

-- Выбрать предложение поставщика. Не самое дешёвое (по цене в валюте модуля) — только с причиной.
CREATE OR REPLACE FUNCTION pur_choose_offer(p_offer_id bigint, p_actor text, p_reason text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    f pur_offers%ROWTYPE;
    r pur_requests%ROWTYPE;
BEGIN
    SELECT * INTO f FROM pur_offers WHERE id = p_offer_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'purchasing: предложение % не найдено', p_offer_id; END IF;
    SELECT * INTO r FROM pur_requests WHERE id = f.request_id FOR UPDATE;
    IF r.status <> 'approved' THEN RAISE EXCEPTION 'purchasing: поставщика выбирают по согласованной заявке'; END IF;
    IF f.valid_until < current_date THEN RAISE EXCEPTION 'purchasing: предложение истекло %', f.valid_until; END IF;
    IF p_reason IS NULL AND EXISTS (SELECT 1 FROM pur_offers o WHERE o.request_id = f.request_id AND o.id <> f.id
                                      AND (o.valid_until IS NULL OR o.valid_until >= current_date)
                                      AND o.price * o.fx_rate < f.price * f.fx_rate) THEN
        RAISE EXCEPTION 'purchasing: есть предложение дешевле — укажите, почему выбираете это';
    END IF;
    UPDATE pur_offers SET chosen = false, updated_by = p_actor WHERE request_id = f.request_id AND chosen AND id <> f.id;
    UPDATE pur_offers SET chosen = true, choose_reason = p_reason, updated_by = p_actor WHERE id = f.id;
    INSERT INTO airl_audit (actor, module, entity, entity_id, action, comment, details)
    VALUES (p_actor, 'purchasing', 'pur_requests', r.id::text, 'update', coalesce(p_reason, 'выбрано лучшее предложение'),
            jsonb_build_object('offer_id', f.id, 'supplier_id', f.supplier_id, 'price', f.price, 'currency', f.currency));
END $$;

-- Черновики заказов из согласованных заявок: выбранное предложение, а если предложений
-- нет — основной поставщик позиции по контрактной цене. Группировка: поставщик × валюта × склад.
CREATE OR REPLACE FUNCTION pur_make_orders(p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    g record;
    v_po bigint;
    n int := 0;
BEGIN
    FOR g IN
        WITH src AS (
            SELECT r.id AS request_id, r.sku, r.description, r.qty, r.unit, r.warehouse_id, r.needed_by,
                   coalesce(o.supplier_id, st.preferred_supplier_id) AS supplier_id,
                   coalesce(o.price, pur_contract_price(st.preferred_supplier_id, r.sku, t.currency, current_date)) AS price,
                   coalesce(o.currency, t.currency) AS currency,
                   coalesce(o.lead_time_days, t.lead_time_days, (airl_setting('purchasing', 'lead_time_days', '14'))::text::int) AS lead_days
            FROM pur_requests r
            LEFT JOIN pur_offers o ON o.request_id = r.id AND o.chosen
            LEFT JOIN pur_item_settings st ON st.sku = r.sku AND st.warehouse_id = r.warehouse_id AND NOT st.archived
            LEFT JOIN pur_supplier_terms t ON t.supplier_id = coalesce(o.supplier_id, st.preferred_supplier_id)
            WHERE r.status = 'approved' AND NOT EXISTS (SELECT 1 FROM pur_order_lines l WHERE l.request_id = r.id)
        )
        SELECT supplier_id, currency, warehouse_id, max(lead_days) AS lead_days,
               array_agg(request_id ORDER BY request_id) AS ids
        FROM src WHERE supplier_id IS NOT NULL AND price IS NOT NULL AND currency IS NOT NULL
        GROUP BY supplier_id, currency, warehouse_id
    LOOP
        INSERT INTO pur_orders (supplier_id, warehouse_id, currency, expected_date, payment_terms_days, created_by)
        VALUES (g.supplier_id, g.warehouse_id, g.currency, current_date + g.lead_days,
                coalesce((SELECT payment_terms_days FROM pur_supplier_terms WHERE supplier_id = g.supplier_id), 0), p_actor)
        RETURNING id INTO v_po;
        INSERT INTO pur_order_lines (po_id, line_no, request_id, sku, description, qty, unit, price, created_by)
        SELECT v_po, row_number() OVER (ORDER BY r.id), r.id, r.sku, r.description, r.qty, r.unit,
               coalesce(o.price, pur_contract_price(g.supplier_id, r.sku, g.currency, current_date)), p_actor
        FROM pur_requests r
        LEFT JOIN pur_offers o ON o.request_id = r.id AND o.chosen
        WHERE r.id = ANY (g.ids);
        UPDATE pur_requests SET status = 'ordered', updated_by = p_actor WHERE id = ANY (g.ids);
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;

-- Отправить заказ поставщику. Цена выше контракта — руководителю закупок.
CREATE OR REPLACE FUNCTION pur_send(p_po_id bigint, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    po   pur_orders%ROWTYPE;
    v_to text := airl_setting('purchasing', 'approver_recipient', '"purchasing_head"') #>> '{}';
BEGIN
    SELECT * INTO po FROM pur_orders WHERE id = p_po_id FOR UPDATE;
    IF NOT FOUND OR po.status <> 'draft' THEN RAISE EXCEPTION 'purchasing: отправить можно черновик заказа'; END IF;
    UPDATE pur_orders SET status = 'sent', updated_by = p_actor WHERE id = po.id;
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'purchasing:price:' || po.id || ':' || v_to, 'purchasing', airl_setting('purchasing', 'channel', '"telegram"') #>> '{}', v_to,
           'Заказ ' || po.po_no || ': цена выше контракта по ' || count(*) || ' поз., переплата '
           || sum((l.price - l.contract_price) * l.qty)::numeric(18,2) || ' ' || po.currency
    FROM pur_order_lines l WHERE l.po_id = po.id AND l.price > l.contract_price
    HAVING count(*) > 0
    ON CONFLICT (dedup_key) DO NOTHING;
END $$;

-- Поставщик подтвердил заказ и дату.
CREATE OR REPLACE FUNCTION pur_confirm(p_po_id bigint, p_expected date, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    UPDATE pur_orders SET status = 'confirmed', expected_date = coalesce(p_expected, expected_date), updated_by = p_actor
    WHERE id = p_po_id AND status = 'sent';
    IF NOT FOUND THEN RAISE EXCEPTION 'purchasing: подтвердить можно отправленный заказ'; END IF;
END $$;

-- Статус заказа по строкам: всё пришло (или недопоставка закрыта) — received, иначе partially_received.
CREATE OR REPLACE FUNCTION pur_refresh_po(p_po_id bigint, p_actor text) RETURNS text
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    po pur_orders%ROWTYPE;
    v_new text;
BEGIN
    SELECT * INTO po FROM pur_orders WHERE id = p_po_id;
    IF po.status NOT IN ('sent', 'confirmed', 'partially_received', 'received') THEN RETURN po.status; END IF;
    v_new := CASE
        WHEN NOT EXISTS (SELECT 1 FROM pur_order_lines l WHERE l.po_id = po.id AND NOT l.closed_short AND l.received_qty < l.qty) THEN 'received'
        WHEN EXISTS (SELECT 1 FROM pur_receipts r JOIN pur_order_lines l ON l.id = r.po_line_id WHERE l.po_id = po.id)
             OR EXISTS (SELECT 1 FROM pur_order_lines l WHERE l.po_id = po.id AND l.closed_short) THEN 'partially_received'
        ELSE po.status END;
    IF v_new IS DISTINCT FROM po.status THEN
        UPDATE pur_orders SET status = v_new, updated_by = p_actor WHERE id = po.id;
    END IF;
    RETURN v_new;
END $$;

-- Поступление по строке заказа (частичное — сколько пришло). Заказ закрывается
-- поступлением только когда пришло всё. Больше заказанного — не больше over_receipt_pct.
-- Категории из qc_categories ждут проверки качества (журнал проверок, объект — номер поступления).
-- p_source_ref — id поступления в источнике (picking, 1С): повторная загрузка не дублирует.
CREATE OR REPLACE FUNCTION pur_receive(p_po_line_id bigint, p_qty numeric, p_actor text, p_lot_no text DEFAULT NULL,
                                       p_received_at timestamptz DEFAULT now(), p_source text DEFAULT 'manual',
                                       p_source_ref text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    l    pur_order_lines%ROWTYPE;
    po   pur_orders%ROWTYPE;
    v_id bigint;
    v_cat text;
    v_tol numeric := (airl_setting('purchasing', 'over_receipt_pct', '0'))::text::numeric;
BEGIN
    IF p_source_ref IS NOT NULL THEN
        SELECT id INTO v_id FROM pur_receipts WHERE source_ref = p_source_ref;
        IF FOUND THEN RETURN v_id; END IF;
    END IF;
    SELECT * INTO l FROM pur_order_lines WHERE id = p_po_line_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'purchasing: строка заказа % не найдена', p_po_line_id; END IF;
    -- Порядок блокировок: заказ, потом строка — два кладовщика не примут одну строку сверх заказа.
    SELECT * INTO po FROM pur_orders WHERE id = l.po_id FOR UPDATE;
    SELECT * INTO l FROM pur_order_lines WHERE id = p_po_line_id FOR UPDATE;
    IF po.status NOT IN ('sent', 'confirmed', 'partially_received') THEN
        RAISE EXCEPTION 'purchasing: заказ % в статусе % — поступление не принимается', po.po_no, po.status;
    END IF;
    IF l.closed_short THEN RAISE EXCEPTION 'purchasing: строка закрыта недопоставкой'; END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'purchasing: количество должно быть больше нуля'; END IF;
    IF l.received_qty + p_qty > l.qty * (1 + v_tol / 100) THEN
        RAISE EXCEPTION 'purchasing: по строке заказано %, уже принято %, допуск сверху % %%', l.qty, l.received_qty, v_tol;
    END IF;
    SELECT i.category INTO v_cat FROM src_pur_items i WHERE i.sku = l.sku;
    INSERT INTO pur_receipts (po_line_id, qty, received_at, lot_no, source, source_ref, status, created_by)
    VALUES (l.id, p_qty, p_received_at, p_lot_no, p_source, p_source_ref,
            CASE WHEN airl_setting('purchasing', 'qc_categories', '["green_coffee"]') ? coalesce(v_cat, '') THEN 'qc_pending' ELSE 'accepted' END,
            p_actor)
    RETURNING id INTO v_id;
    UPDATE pur_order_lines SET received_qty = received_qty + p_qty, updated_by = p_actor WHERE id = l.id;
    PERFORM pur_refresh_po(po.id, p_actor);
    RETURN v_id;
END $$;

-- Итог проверки качества поступления. Брак уменьшает принятое по строке: заказ
-- возвращается в «частично поступил», поставщик должен довезти.
CREATE OR REPLACE FUNCTION pur_set_qc(p_receipt_id bigint, p_passed boolean, p_comment text, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    r  pur_receipts%ROWTYPE;
    l  pur_order_lines%ROWTYPE;
    v_to text := airl_setting('purchasing', 'buyer_recipient', '"buyer"') #>> '{}';
BEGIN
    SELECT * INTO r FROM pur_receipts WHERE id = p_receipt_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'purchasing: поступление % не найдено', p_receipt_id; END IF;
    SELECT * INTO l FROM pur_order_lines WHERE id = r.po_line_id;
    PERFORM 1 FROM pur_orders WHERE id = l.po_id FOR UPDATE;
    SELECT * INTO r FROM pur_receipts WHERE id = p_receipt_id FOR UPDATE;
    IF r.status <> 'qc_pending' THEN RAISE EXCEPTION 'purchasing: поступление % не ждёт проверки', r.receipt_no; END IF;
    UPDATE pur_receipts SET status = CASE WHEN p_passed THEN 'qc_passed' ELSE 'qc_rejected' END,
                            qc_comment = p_comment, updated_by = p_actor
    WHERE id = r.id;
    IF NOT p_passed THEN
        UPDATE pur_order_lines SET received_qty = received_qty - r.qty, updated_by = p_actor WHERE id = l.id;
        PERFORM pur_refresh_po(l.po_id, p_actor);
        INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
        SELECT 'purchasing:qc_rejected:' || r.id || ':' || v_to, 'purchasing',
               airl_setting('purchasing', 'channel', '"telegram"') #>> '{}', v_to,
               'Поступление ' || r.receipt_no || ' по заказу ' || o.po_no || ' не прошло проверку: ' || p_comment
               || '. Претензия поставщику, ждём замену ' || r.qty || ' ' || coalesce(l.unit, '')
        FROM pur_orders o WHERE o.id = l.po_id
        ON CONFLICT (dedup_key) DO NOTHING;
    END IF;
END $$;

-- Закрыть недопоставку по строке: остаток больше не ждём.
CREATE OR REPLACE FUNCTION pur_close_line_short(p_po_line_id bigint, p_reason text, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE l pur_order_lines%ROWTYPE;
BEGIN
    SELECT * INTO l FROM pur_order_lines WHERE id = p_po_line_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'purchasing: строка не найдена'; END IF;
    PERFORM 1 FROM pur_orders WHERE id = l.po_id AND status IN ('sent', 'confirmed', 'partially_received') FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'purchasing: недопоставку закрывают по отправленному заказу'; END IF;
    IF l.received_qty >= l.qty THEN RAISE EXCEPTION 'purchasing: по строке всё пришло'; END IF;
    UPDATE pur_order_lines SET closed_short = true, short_reason = p_reason, updated_by = p_actor WHERE id = l.id;
    PERFORM pur_refresh_po(l.po_id, p_actor);
END $$;

CREATE OR REPLACE FUNCTION pur_close_po(p_po_id bigint, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    UPDATE pur_orders SET status = 'closed', updated_by = p_actor WHERE id = p_po_id AND status = 'received';
    IF NOT FOUND THEN RAISE EXCEPTION 'purchasing: закрыть можно полностью поступивший заказ'; END IF;
END $$;

-- Уведомления по сроку: заказ не пришёл к ожидаемой дате (закупщику, один раз на заказ);
-- контракт поставщика кончается через contract_warn_days (руководителю, один раз на срок).
CREATE OR REPLACE FUNCTION pur_plan_notifications() RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_buyer text := airl_setting('purchasing', 'buyer_recipient', '"buyer"') #>> '{}';
    v_head  text := airl_setting('purchasing', 'approver_recipient', '"purchasing_head"') #>> '{}';
    v_ch    text := airl_setting('purchasing', 'channel', '"telegram"') #>> '{}';
    n int; k int;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'purchasing:late:' || o.id || ':' || v_buyer, 'purchasing', v_ch, v_buyer,
           'Заказ ' || o.po_no || ' (' || coalesce(s.supplier_name, o.supplier_id) || ') ожидался '
           || to_char(o.expected_date, 'DD.MM.YYYY') || ' и ещё не пришёл полностью. Позвоните поставщику.'
    FROM pur_orders o LEFT JOIN src_pur_suppliers s ON s.supplier_id = o.supplier_id
    WHERE o.status IN ('sent', 'confirmed', 'partially_received') AND o.expected_date < current_date
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'purchasing:contract:' || t.id || '-' || t.contract_until || ':' || v_head, 'purchasing', v_ch, v_head,
           'Контракт ' || t.contract_no || ' с ' || coalesce(s.supplier_name, t.supplier_id) || ' действует до '
           || to_char(t.contract_until, 'DD.MM.YYYY') || '.'
    FROM pur_supplier_terms t LEFT JOIN src_pur_suppliers s ON s.supplier_id = t.supplier_id
    WHERE NOT t.archived AND t.contract_until BETWEEN current_date
          AND current_date + (airl_setting('purchasing', 'contract_warn_days', '30'))::text::int
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT;
    RETURN n + k;
END $$;

-- ───────────── Экраны ─────────────

-- Прогресс строки заказа: когда набрано заказанное количество (без брака QC).
CREATE OR REPLACE VIEW v_pur_line_progress AS
WITH rc AS (
    SELECT r.po_line_id, r.received_at,
           sum(r.qty) OVER (PARTITION BY r.po_line_id ORDER BY r.received_at, r.id) AS cum_qty
    FROM pur_receipts r WHERE r.status <> 'qc_rejected'
)
SELECT l.id AS po_line_id, l.po_id, o.po_no, o.supplier_id, o.warehouse_id, o.currency, o.status AS po_status,
       o.order_date, coalesce(l.expected_date, o.expected_date) AS expected_date,
       l.line_no, l.sku, l.description, l.qty, l.unit, l.price, l.amount, l.contract_price,
       l.received_qty, l.closed_short, l.short_reason,
       (SELECT min(rc.received_at) FROM rc WHERE rc.po_line_id = l.id AND rc.cum_qty >= l.qty) AS completed_at,
       (SELECT max(r.received_at) FROM pur_receipts r WHERE r.po_line_id = l.id) AS last_receipt_at
FROM pur_order_lines l
JOIN pur_orders o ON o.id = l.po_id;

-- «Поставщики»: справочник с условиями, контрактом и надёжностью за 90 дней.
CREATE OR REPLACE VIEW v_pur_suppliers AS
WITH tz AS (SELECT airl_setting('purchasing', 'timezone', '"Asia/Almaty"') #>> '{}' AS name),
rel AS (
    SELECT p.supplier_id,
           count(*) AS lines_due,
           count(*) FILTER (WHERE p.completed_at IS NOT NULL AND (p.completed_at AT TIME ZONE tz.name)::date <= p.expected_date) AS on_time
    FROM v_pur_line_progress p, tz
    WHERE p.po_status NOT IN ('draft', 'cancelled') AND p.expected_date <= current_date AND p.expected_date > current_date - 90
    GROUP BY p.supplier_id
)
SELECT s.supplier_id, s.supplier_name, s.tax_id, s.country, s.currency AS supplier_currency, s.active,
       t.payment_terms_days, t.prepayment_pct, t.lead_time_days, t.min_order_amount, t.currency AS terms_currency,
       t.contract_no, t.contract_from, t.contract_until,
       (t.contract_until < current_date) AS contract_expired,
       (SELECT count(*) FROM pur_orders o WHERE o.supplier_id = s.supplier_id AND o.status IN ('sent', 'confirmed', 'partially_received')) AS open_orders,
       rel.lines_due, round(100.0 * rel.on_time / NULLIF(rel.lines_due, 0), 1) AS on_time_pct_90d
FROM src_pur_suppliers s
LEFT JOIN pur_supplier_terms t ON t.supplier_id = s.supplier_id AND NOT t.archived
LEFT JOIN rel ON rel.supplier_id = s.supplier_id;

-- «Заявки»: со статусом и тем, чего ждут.
CREATE OR REPLACE VIEW v_pur_requests AS
SELECT r.id, r.request_no, r.sku, coalesce(i.sku_name, r.description) AS item, r.category, r.warehouse_id, r.qty, r.unit,
       r.needed_by, r.source, r.unplanned, r.justification, r.est_price, r.est_amount, r.currency, r.status,
       r.submitted_at, r.approved_by, r.approved_at, r.approval_ref, r.reject_reason, r.created_at, r.created_by,
       (SELECT count(*) FROM pur_offers o WHERE o.request_id = r.id) AS offers,
       EXISTS (SELECT 1 FROM pur_offers o WHERE o.request_id = r.id AND o.chosen) AS supplier_chosen,
       (SELECT po.po_no FROM pur_order_lines l JOIN pur_orders po ON po.id = l.po_id WHERE l.request_id = r.id) AS po_no,
       CASE r.status WHEN 'draft' THEN 'отправить на согласование'
                     WHEN 'submitted' THEN 'ждёт решения'
                     WHEN 'approved' THEN 'выбрать поставщика и сделать заказ'
                     ELSE NULL END::text AS next_step
FROM pur_requests r
LEFT JOIN src_pur_items i ON i.sku = r.sku;

-- «Сравнение предложений»: цена в валюте модуля, разница с лучшим и с контрактом.
CREATE OR REPLACE VIEW v_pur_offer_compare AS
SELECT o.id, o.request_id, r.request_no, r.sku, o.supplier_id, s.supplier_name, o.price, o.currency, o.fx_rate,
       round(o.price * o.fx_rate, 2) AS price_base,
       (airl_setting('purchasing', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}')::char(3) AS base_currency,
       round(r.qty * o.price * o.fx_rate, 2) AS amount_base,
       rank() OVER (PARTITION BY o.request_id ORDER BY o.price * o.fx_rate) AS price_rank,
       round(100 * (o.price * o.fx_rate / min(o.price * o.fx_rate) OVER (PARTITION BY o.request_id) - 1), 1) AS over_best_pct,
       pur_contract_price(o.supplier_id, r.sku, o.currency, current_date) AS contract_price,
       o.lead_time_days, o.moq, o.valid_until, (o.valid_until < current_date) AS expired, o.chosen, o.choose_reason, o.comment
FROM pur_offers o
JOIN pur_requests r ON r.id = o.request_id
LEFT JOIN src_pur_suppliers s ON s.supplier_id = o.supplier_id;

-- «Заказы поставщикам»: суммы, поступление, оплата (из учёта), срок оплаты.
CREATE OR REPLACE VIEW v_pur_orders AS
WITH tot AS (
    SELECT l.po_id, sum(l.amount) AS amount, sum(l.qty) AS qty, sum(least(l.received_qty, l.qty)) AS received_qty
    FROM pur_order_lines l GROUP BY l.po_id
), pay AS (
    SELECT p.po_no, p.currency, sum(p.amount) AS paid, max(p.paid_at) AS last_paid_at FROM src_pur_payments p GROUP BY 1, 2
)
SELECT o.id, o.po_no, o.supplier_id, s.supplier_name, o.warehouse_id, o.status, o.order_date, o.expected_date,
       o.sent_at, o.confirmed_at, o.received_at, o.closed_at, o.currency, t.amount,
       round(100 * t.received_qty / NULLIF(t.qty, 0), 1) AS received_pct,
       coalesce(pay.paid, 0)::numeric(18,2) AS paid,
       CASE WHEN coalesce(pay.paid, 0) >= t.amount THEN 'paid' WHEN coalesce(pay.paid, 0) > 0 THEN 'partial' ELSE 'unpaid' END::text AS payment_status,
       (coalesce(o.received_at::date, o.expected_date) + o.payment_terms_days) AS payment_due,
       (coalesce(pay.paid, 0) < t.amount AND coalesce(o.received_at::date, o.expected_date) + o.payment_terms_days < current_date
        AND o.status NOT IN ('draft', 'cancelled')) AS payment_overdue,
       (o.status IN ('sent', 'confirmed', 'partially_received') AND o.expected_date < current_date) AS late
FROM pur_orders o
LEFT JOIN tot t ON t.po_id = o.id
LEFT JOIN pay ON pay.po_no = o.po_no AND pay.currency = o.currency
LEFT JOIN src_pur_suppliers s ON s.supplier_id = o.supplier_id;

-- «Ожидаемые поставки»: что и когда должно прийти, сколько осталось, опаздывает ли.
CREATE OR REPLACE VIEW v_pur_expected AS
SELECT p.po_line_id, p.po_no, p.supplier_id, s.supplier_name, p.warehouse_id, p.expected_date, p.sku,
       coalesce(i.sku_name, p.description) AS item, p.qty, p.received_qty, (p.qty - p.received_qty) AS qty_left, p.unit,
       (p.expected_date < current_date) AS late, (current_date - p.expected_date) AS days_late
FROM v_pur_line_progress p
LEFT JOIN src_pur_suppliers s ON s.supplier_id = p.supplier_id
LEFT JOIN src_pur_items i ON i.sku = p.sku
WHERE p.po_status IN ('sent', 'confirmed', 'partially_received') AND NOT p.closed_short AND p.received_qty < p.qty;

-- «Отклонения»: опоздание, недопоставка, цена выше контракта, брак на приёмке.
CREATE OR REPLACE VIEW v_pur_deviations AS
WITH tz AS (SELECT airl_setting('purchasing', 'timezone', '"Asia/Almaty"') #>> '{}' AS name)
SELECT 'late'::text AS kind, p.po_no, p.supplier_id, p.sku, p.expected_date AS deviation_date,
       ((coalesce((p.completed_at AT TIME ZONE tz.name)::date, current_date) - p.expected_date))::numeric AS value,
       'дн.'::text AS unit,
       CASE WHEN p.completed_at IS NULL THEN 'ещё не пришло' ELSE 'пришло позже' END::text AS note
FROM v_pur_line_progress p, tz
WHERE p.po_status NOT IN ('draft', 'cancelled') AND NOT p.closed_short
  AND coalesce((p.completed_at AT TIME ZONE tz.name)::date, current_date) > p.expected_date
  AND (p.completed_at IS NOT NULL OR p.po_status IN ('sent', 'confirmed', 'partially_received'))
UNION ALL
SELECT 'short', p.po_no, p.supplier_id, p.sku, coalesce(p.last_receipt_at::date, p.expected_date),
       (p.qty - p.received_qty), coalesce(p.unit, ''), p.short_reason
FROM v_pur_line_progress p
WHERE p.closed_short AND p.received_qty < p.qty
UNION ALL
SELECT 'price_above_contract', p.po_no, p.supplier_id, p.sku, p.order_date,
       round(100 * (p.price / p.contract_price - 1), 2), '%',
       'переплата ' || ((p.price - p.contract_price) * p.qty)::numeric(18,2) || ' ' || p.currency
FROM v_pur_line_progress p
WHERE p.po_status NOT IN ('draft', 'cancelled') AND p.contract_price > 0 AND p.price > p.contract_price
UNION ALL
SELECT 'quality_rejected', o.po_no, o.supplier_id, l.sku, r.received_at::date, r.qty, coalesce(l.unit, ''), r.qc_comment
FROM pur_receipts r JOIN pur_order_lines l ON l.id = r.po_line_id JOIN pur_orders o ON o.id = l.po_id
WHERE r.status = 'qc_rejected';

-- Объекты для журнала проверок (inspection-journal): поступления, которые ждут проверки
-- качества. Колонки как у src_inspection_objects — адаптер добавляет их через UNION ALL.
CREATE OR REPLACE VIEW v_pur_qc_objects AS
SELECT r.receipt_no AS object_id, 'delivery'::text AS object_type,
       coalesce(s.supplier_name, o.supplier_id) || ' · ' || coalesce(i.sku_name, l.sku, l.description) || ' · ' || r.qty || ' ' || coalesce(l.unit, '') AS title,
       l.sku, r.lot_no AS lot, r.received_at AS produced_at, o.supplier_id AS produced_by, o.warehouse_id AS branch_id,
       r.status
FROM pur_receipts r
JOIN pur_order_lines l ON l.id = r.po_line_id
JOIN pur_orders o ON o.id = l.po_id
LEFT JOIN src_pur_suppliers s ON s.supplier_id = o.supplier_id
LEFT JOIN src_pur_items i ON i.sku = l.sku
WHERE r.status IN ('qc_pending', 'qc_passed', 'qc_rejected');

-- ───────────── Показатели ─────────────

-- Поставщики вовремя: строки заказов со сроком в месяце (срок уже наступил), по которым
-- всё заказанное (без брака) пришло не позже ожидаемой даты / все такие строки.
-- Закрытая недопоставка — не вовремя.
CREATE OR REPLACE VIEW m_supplier_on_time_rate AS
WITH tz AS (SELECT airl_setting('purchasing', 'timezone', '"Asia/Almaty"') #>> '{}' AS name),
due AS (
    SELECT to_char(p.expected_date, 'YYYY-MM') AS month,
           (p.completed_at IS NOT NULL AND (p.completed_at AT TIME ZONE tz.name)::date <= p.expected_date) AS on_time
    FROM v_pur_line_progress p, tz
    WHERE p.po_status NOT IN ('draft', 'cancelled') AND p.expected_date <= current_date
)
SELECT 'supplier_on_time_rate'::text AS metric_id, month AS period,
       round(100.0 * count(*) FILTER (WHERE on_time) / NULLIF(count(*), 0), 2) AS value, '%'::text AS unit,
       airl_traffic(round(100.0 * count(*) FILTER (WHERE on_time) / NULLIF(count(*), 0), 2),
                    (airl_setting('purchasing', 'on_time_warn', '90'))::text::numeric,
                    (airl_setting('purchasing', 'on_time_bad', '80'))::text::numeric, true) AS status
FROM due GROUP BY month;

-- Отклонение цены от контракта: Σ (цена − контракт) × кол-во / Σ контракт × кол-во, %;
-- строки отправленных заказов с контрактной ценой; по месяцу заказа. Минус — купили дешевле.
CREATE OR REPLACE VIEW m_purchase_price_variance AS
SELECT 'purchase_price_variance'::text AS metric_id, to_char(p.order_date, 'YYYY-MM') AS period,
       round(100 * sum((p.price - p.contract_price) * p.qty) / NULLIF(sum(p.contract_price * p.qty), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(round(100 * sum((p.price - p.contract_price) * p.qty) / NULLIF(sum(p.contract_price * p.qty), 0), 2),
                    (airl_setting('purchasing', 'ppv_warn', '2'))::text::numeric,
                    (airl_setting('purchasing', 'ppv_bad', '5'))::text::numeric, false) AS status
FROM v_pur_line_progress p
WHERE p.po_status NOT IN ('draft', 'cancelled') AND p.contract_price > 0 AND p.order_date IS NOT NULL
GROUP BY to_char(p.order_date, 'YYYY-MM');
