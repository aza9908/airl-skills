-- Модуль «Склад без сканеров» (picking): адресное хранение, партии и FEFO, приёмка,
-- перемещения, сборка заказов со сканированием камерой телефона, проверка упаковки,
-- инвентаризация, расхождения, прослеживаемость партии до клиента.
-- Требует kit/kit.sql в той же схеме и представления src_pick_items, src_pick_orders,
-- src_pick_order_lines, src_pick_stock_1c (адаптер или demo_src.sql).
--
-- Модуль пишет движения товара по ячейкам (pick_moves) — только добавление.
-- Остаток по ячейке = сумма движений. Учётный остаток (система записи) остаётся в 1С,
-- пока клиент не решит иначе; расхождение с 1С видно в v_pick_reconcile.
--
-- Формат QR (печатается модулем, читается камерой):
--   AIRL:CELL:<код ячейки>            ячейка, например AIRL:CELL:ALA-A-01-02
--   AIRL:LOT:<sku>:<партия>           партия товара, например AIRL:LOT:CF-ETH-250:PR-1003P
--   AIRL:SKU:<sku>                    товар без партий (упаковка, кружки)
--   8–14 цифр                         заводской штрихкод EAN/UPC из src_pick_items.barcode

-- Номера документов.
CREATE SEQUENCE IF NOT EXISTS pick_task_seq;
CREATE SEQUENCE IF NOT EXISTS pick_receipt_seq;
CREATE SEQUENCE IF NOT EXISTS pick_count_seq;
CREATE SEQUENCE IF NOT EXISTS pick_disc_seq;

-- Зоны склада: хранение, приёмка, упаковка, отгрузка, карантин, производство.
CREATE TABLE IF NOT EXISTS pick_zones (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    warehouse_id text        NOT NULL,                     -- склад из учётной системы (RC-ALA)
    code         text        NOT NULL CHECK (code ~ '^[A-Z0-9-]{1,20}$'),
    title        text        NOT NULL,
    kind         text        NOT NULL CHECK (kind IN ('storage', 'receiving', 'packing', 'shipping', 'quarantine', 'production')),
    archived     boolean     NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text        NOT NULL,
    updated_at   timestamptz,
    updated_by   text,
    UNIQUE (warehouse_id, code)
);
-- Одна действующая зона упаковки на склад: туда модуль кладёт собранное.
CREATE UNIQUE INDEX IF NOT EXISTS pick_zones_one_packing ON pick_zones (warehouse_id) WHERE kind = 'packing' AND NOT archived;

-- Ячейки (адреса). Код уникален во всей компании: он же в QR.
CREATE TABLE IF NOT EXISTS pick_cells (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    zone_id     bigint      NOT NULL REFERENCES pick_zones (id),
    code        text        NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9-]{2,32}$'),
    title       text,
    archived    boolean     NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text
);
CREATE INDEX IF NOT EXISTS pick_cells_zone_idx ON pick_cells (zone_id);

-- Партии: зелёный лот, партия обжарки, фасованная партия, партия товара.
CREATE TABLE IF NOT EXISTS pick_lots (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku          text        NOT NULL,
    lot_no       text        NOT NULL CHECK (lot_no ~ '^[A-Za-z0-9._/-]{1,40}$'),
    kind         text        NOT NULL CHECK (kind IN ('green', 'roast', 'packed', 'goods')),
    produced_on  date,
    expiry_date  date,
    supplier_lot text,                                     -- лот поставщика (зелёное зерно)
    hold         boolean     NOT NULL DEFAULT false,       -- блок: QC отклонил, карантин
    hold_reason  text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text        NOT NULL,
    updated_at   timestamptz,
    updated_by   text,
    UNIQUE (sku, lot_no),
    CHECK (NOT hold OR hold_reason IS NOT NULL),
    CHECK (expiry_date IS NULL OR produced_on IS NULL OR expiry_date >= produced_on)
);
CREATE INDEX IF NOT EXISTS pick_lots_expiry_idx ON pick_lots (sku, expiry_date) WHERE NOT hold;

-- Связи партий для прослеживаемости: зелёный лот → партия обжарки → фасованная партия.
CREATE TABLE IF NOT EXISTS pick_lot_links (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_lot_id bigint        NOT NULL REFERENCES pick_lots (id),
    child_lot_id  bigint        NOT NULL REFERENCES pick_lots (id),
    kind          text          NOT NULL CHECK (kind IN ('roast', 'pack', 'blend', 'rework', 'split')),
    qty           numeric(18,3) CHECK (qty IS NULL OR qty > 0),   -- сколько родителя ушло в потомка
    created_at    timestamptz   NOT NULL DEFAULT now(),
    created_by    text          NOT NULL,
    updated_at    timestamptz,
    updated_by    text,
    UNIQUE (parent_lot_id, child_lot_id),
    CHECK (parent_lot_id <> child_lot_id)
);
CREATE INDEX IF NOT EXISTS pick_lot_links_child_idx ON pick_lot_links (child_lot_id);

-- Задания на сборку: одно действующее на заказ.
CREATE TABLE IF NOT EXISTS pick_tasks (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_no         text        NOT NULL UNIQUE DEFAULT 'PT-' || lpad(nextval('pick_task_seq')::text, 6, '0'),
    order_id        text        NOT NULL,                  -- ключ заказа из src_pick_orders
    warehouse_id    text        NOT NULL,
    ship_by         timestamptz,
    status          text        NOT NULL DEFAULT 'new'
                    CHECK (status IN ('new', 'assigned', 'picking', 'picked', 'checked', 'shipped', 'cancelled')),
    assigned_to     text,                                  -- сборщик (id пользователя)
    assigned_at     timestamptz,
    current_cell_id bigint      REFERENCES pick_cells (id),-- последняя отсканированная ячейка
    pack_round      int         NOT NULL DEFAULT 1,        -- круг проверки упаковки (после «Пересобрать» +1)
    started_at      timestamptz,
    picked_at       timestamptz,
    checked_at      timestamptz,
    checked_by      text,
    shipped_at      timestamptz,
    cancel_reason   text,
    status_comment  text,                                  -- комментарий к последней смене статуса (в журнал)
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      text        NOT NULL,
    updated_at      timestamptz,
    updated_by      text,
    CHECK (status IN ('new', 'cancelled') OR assigned_to IS NOT NULL),
    CHECK (status <> 'new' OR assigned_to IS NULL),
    CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL),
    CHECK (status NOT IN ('picked', 'checked', 'shipped') OR (started_at IS NOT NULL AND picked_at IS NOT NULL)),
    CHECK (status NOT IN ('checked', 'shipped') OR (checked_at IS NOT NULL AND checked_by IS NOT NULL)),
    CHECK (status <> 'shipped' OR shipped_at IS NOT NULL),
    CHECK (picked_at IS NULL OR started_at IS NULL OR picked_at >= started_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS pick_tasks_order_active ON pick_tasks (order_id) WHERE status <> 'cancelled';
-- Сборщик собирает одно задание за раз (волновая сборка — после курса).
CREATE UNIQUE INDEX IF NOT EXISTS pick_tasks_picker_active ON pick_tasks (assigned_to) WHERE status = 'picking';
CREATE INDEX IF NOT EXISTS pick_tasks_queue_idx ON pick_tasks (warehouse_id, status, ship_by);

CREATE TABLE IF NOT EXISTS pick_task_lines (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_id           bigint        NOT NULL REFERENCES pick_tasks (id),
    line_no           int           NOT NULL,
    sku               text          NOT NULL,
    qty               numeric(18,3) NOT NULL CHECK (qty > 0),
    qty_picked        numeric(18,3) NOT NULL DEFAULT 0 CHECK (qty_picked >= 0),
    qty_short         numeric(18,3) NOT NULL DEFAULT 0 CHECK (qty_short >= 0),
    short_reason      text          CHECK (short_reason IN ('not_found_in_cell', 'damaged', 'expired', 'no_stock')),
    suggested_lot_id  bigint        REFERENCES pick_lots (id),   -- FEFO на момент создания задания
    suggested_cell_id bigint        REFERENCES pick_cells (id),
    done_at           timestamptz,
    created_at        timestamptz   NOT NULL DEFAULT now(),
    created_by        text          NOT NULL,
    updated_at        timestamptz,
    updated_by        text,
    UNIQUE (task_id, line_no),
    CHECK (qty_picked + qty_short <= qty),
    CHECK (qty_short = 0 OR short_reason IS NOT NULL),
    CHECK ((done_at IS NOT NULL) = (qty_picked + qty_short = qty))
);
CREATE INDEX IF NOT EXISTS pick_task_lines_task_idx ON pick_task_lines (task_id, sku);

-- Приёмка: ожидаемая поставка → сканирование → закрытие с расхождениями.
CREATE TABLE IF NOT EXISTS pick_receipts (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    receipt_no    text        NOT NULL UNIQUE DEFAULT 'RCV-' || lpad(nextval('pick_receipt_seq')::text, 6, '0'),
    warehouse_id  text        NOT NULL,
    supplier_name text        NOT NULL,
    source_ref    text,                                    -- номер заказа поставщику (purchasing) или документа 1С
    status        text        NOT NULL DEFAULT 'expected' CHECK (status IN ('expected', 'receiving', 'done', 'cancelled')),
    expected_at   timestamptz,
    started_at    timestamptz,
    closed_at     timestamptz,
    closed_by     text,
    cancel_reason text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text        NOT NULL,
    updated_at    timestamptz,
    updated_by    text,
    CHECK (status <> 'done' OR (closed_at IS NOT NULL AND closed_by IS NOT NULL)),
    CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS pick_receipt_lines (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    receipt_id   bigint        NOT NULL REFERENCES pick_receipts (id),
    line_no      int           NOT NULL,
    sku          text          NOT NULL,
    expected_qty numeric(18,3) NOT NULL CHECK (expected_qty >= 0),  -- 0 — пришло то, чего не ждали
    received_qty numeric(18,3) NOT NULL DEFAULT 0 CHECK (received_qty >= 0),
    created_at   timestamptz   NOT NULL DEFAULT now(),
    created_by   text          NOT NULL,
    updated_at   timestamptz,
    updated_by   text,
    UNIQUE (receipt_id, line_no)
);

-- Инвентаризация: склад или зона; слепой пересчёт (кладовщик не видит учётное количество).
CREATE TABLE IF NOT EXISTS pick_counts (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    count_no     text        NOT NULL UNIQUE DEFAULT 'INV-' || lpad(nextval('pick_count_seq')::text, 6, '0'),
    warehouse_id text        NOT NULL,
    zone_id      bigint      REFERENCES pick_zones (id),   -- пусто — весь склад (зоны хранения)
    status       text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'counting', 'closed', 'cancelled')),
    started_at   timestamptz,
    closed_at    timestamptz,
    closed_by    text,
    cancel_reason text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text        NOT NULL,
    updated_at   timestamptz,
    updated_by   text,
    CHECK (status <> 'closed' OR (closed_at IS NOT NULL AND closed_by IS NOT NULL)),
    CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);
-- Один открытый пересчёт на склад: два пересчёта одновременно дают двойные корректировки.
CREATE UNIQUE INDEX IF NOT EXISTS pick_counts_one_open ON pick_counts (warehouse_id) WHERE status IN ('open', 'counting');

CREATE TABLE IF NOT EXISTS pick_count_lines (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    count_id    bigint        NOT NULL REFERENCES pick_counts (id),
    cell_id     bigint        NOT NULL REFERENCES pick_cells (id),
    sku         text          NOT NULL,
    lot_id      bigint        REFERENCES pick_lots (id),
    counted_qty numeric(18,3) NOT NULL CHECK (counted_qty >= 0),
    system_qty  numeric(18,3),                              -- заполняется при закрытии
    diff_qty    numeric(18,3) GENERATED ALWAYS AS (counted_qty - system_qty) STORED,
    counted_at  timestamptz   NOT NULL DEFAULT now(),
    counted_by  text          NOT NULL,
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL,
    updated_at  timestamptz,
    updated_by  text
);
CREATE UNIQUE INDEX IF NOT EXISTS pick_count_lines_key ON pick_count_lines (count_id, cell_id, sku, (coalesce(lot_id, 0)));

-- Движения товара: только добавление. Исправление — обратным движением.
CREATE TABLE IF NOT EXISTS pick_moves (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind            text          NOT NULL CHECK (kind IN ('opening', 'receipt', 'move', 'pick', 'return', 'ship', 'adjust', 'write_off')),
    sku             text          NOT NULL,
    lot_id          bigint        REFERENCES pick_lots (id),
    from_cell_id    bigint        REFERENCES pick_cells (id),
    to_cell_id      bigint        REFERENCES pick_cells (id),
    qty             numeric(18,3) NOT NULL CHECK (qty > 0),
    task_line_id    bigint        REFERENCES pick_task_lines (id),
    receipt_line_id bigint        REFERENCES pick_receipt_lines (id),
    count_id        bigint        REFERENCES pick_counts (id),
    reason          text,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    created_by      text          NOT NULL,
    updated_at      timestamptz,
    updated_by      text,
    CHECK (from_cell_id IS NOT NULL OR to_cell_id IS NOT NULL),
    CHECK (from_cell_id IS DISTINCT FROM to_cell_id),
    CHECK (kind NOT IN ('opening', 'receipt') OR from_cell_id IS NULL),
    CHECK (kind <> 'receipt' OR receipt_line_id IS NOT NULL),
    CHECK (kind NOT IN ('pick', 'return') OR (task_line_id IS NOT NULL AND from_cell_id IS NOT NULL AND to_cell_id IS NOT NULL)),
    CHECK (kind <> 'ship' OR (task_line_id IS NOT NULL AND to_cell_id IS NULL)),
    CHECK (kind <> 'write_off' OR (to_cell_id IS NULL AND reason IS NOT NULL)),
    CHECK (kind <> 'adjust' OR count_id IS NOT NULL OR reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS pick_moves_to_idx   ON pick_moves (to_cell_id, sku, (coalesce(lot_id, 0))) WHERE to_cell_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS pick_moves_from_idx ON pick_moves (from_cell_id, sku, (coalesce(lot_id, 0))) WHERE from_cell_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS pick_moves_line_idx ON pick_moves (task_line_id) WHERE task_line_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS pick_moves_lot_idx  ON pick_moves (lot_id, kind);

-- Журнал сканирований: и удачных, и отклонённых (ошибка сборщика видна сразу).
CREATE TABLE IF NOT EXISTS pick_scans (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at          timestamptz   NOT NULL DEFAULT now(),
    actor       text          NOT NULL,
    kind        text          NOT NULL CHECK (kind IN ('pick', 'pack', 'receive', 'count', 'move')),
    task_id     bigint        REFERENCES pick_tasks (id),
    line_id     bigint        REFERENCES pick_task_lines (id),
    receipt_id  bigint        REFERENCES pick_receipts (id),
    count_id    bigint        REFERENCES pick_counts (id),
    round       int,                                       -- круг проверки упаковки
    payload     text,
    sku         text,
    lot_id      bigint        REFERENCES pick_lots (id),
    qty         numeric(18,3),
    ok          boolean       NOT NULL,
    error_code  text,
    message     text,
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    CHECK (ok = (error_code IS NULL))
);
CREATE INDEX IF NOT EXISTS pick_scans_task_idx ON pick_scans (task_id, kind, at);
CREATE INDEX IF NOT EXISTS pick_scans_actor_idx ON pick_scans (actor, at);

-- Журнал расхождений: приёмка, сборка, упаковка, пересчёт, претензия клиента.
CREATE TABLE IF NOT EXISTS pick_discrepancies (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    disc_no      text          NOT NULL UNIQUE DEFAULT 'DSC-' || lpad(nextval('pick_disc_seq')::text, 6, '0'),
    source       text          NOT NULL CHECK (source IN ('receipt', 'pick', 'pack', 'count', 'client', 'move')),
    warehouse_id text          NOT NULL,
    sku          text          NOT NULL,
    lot_id       bigint        REFERENCES pick_lots (id),
    cell_id      bigint        REFERENCES pick_cells (id),
    task_id      bigint        REFERENCES pick_tasks (id),
    receipt_id   bigint        REFERENCES pick_receipts (id),
    count_id     bigint        REFERENCES pick_counts (id),
    expected_qty numeric(18,3) NOT NULL,
    actual_qty   numeric(18,3) NOT NULL,
    diff_qty     numeric(18,3) GENERATED ALWAYS AS (actual_qty - expected_qty) STORED,
    reason       text          CHECK (reason IN ('supplier_short', 'supplier_over', 'supplier_damaged',
                     'wrong_item_picked', 'wrong_lot_picked', 'qty_error', 'not_found_in_cell', 'misplaced',
                     'damaged', 'expired', 'not_posted', 'theft_suspected', 'unit_mismatch', 'unknown')),
    responsible  text,                                     -- id сотрудника или «поставщик»
    comment      text,
    status       text          NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'cancelled')),
    resolution   text,
    resolved_at  timestamptz,
    created_at   timestamptz   NOT NULL DEFAULT now(),
    created_by   text          NOT NULL,
    updated_at   timestamptz,
    updated_by   text,
    CHECK (status <> 'resolved' OR (reason IS NOT NULL AND responsible IS NOT NULL AND resolution IS NOT NULL)),
    CHECK (status <> 'cancelled' OR resolution IS NOT NULL),
    CHECK (reason IS DISTINCT FROM 'unknown' OR comment IS NOT NULL)
);
-- Повторная проверка упаковки не плодит одинаковые расхождения.
CREATE UNIQUE INDEX IF NOT EXISTS pick_disc_task_open ON pick_discrepancies (task_id, sku, (coalesce(lot_id, 0)), source)
    WHERE status = 'open' AND task_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS pick_disc_status_idx ON pick_discrepancies (status, created_at);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['pick_zones', 'pick_cells', 'pick_lots', 'pick_tasks', 'pick_task_lines', 'pick_receipts',
                             'pick_receipt_lines', 'pick_counts', 'pick_count_lines', 'pick_discrepancies'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_touch', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION airl_touch()', t || '_touch', t);
    END LOOP;
END $$;

-- ───────────── Остатки по ячейкам ─────────────

-- Блокировка остатка «ячейка × товар × партия»: два сборщика не возьмут одну и ту же коробку дважды.
CREATE OR REPLACE FUNCTION pick_lock_stock(p_cell bigint, p_sku text, p_lot bigint) RETURNS void
LANGUAGE sql SET search_path FROM CURRENT AS $$
    SELECT pg_advisory_xact_lock(hashtextextended('picking:' || p_cell || ':' || p_sku || ':' || coalesce(p_lot, 0), 0))
$$;

CREATE OR REPLACE FUNCTION pick_balance(p_cell bigint, p_sku text, p_lot bigint) RETURNS numeric
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    SELECT coalesce((SELECT sum(qty) FROM pick_moves
                     WHERE to_cell_id = p_cell AND sku = p_sku AND coalesce(lot_id, 0) = coalesce(p_lot, 0)), 0)
         - coalesce((SELECT sum(qty) FROM pick_moves
                     WHERE from_cell_id = p_cell AND sku = p_sku AND coalesce(lot_id, 0) = coalesce(p_lot, 0)), 0)
$$;

-- Остаток по ячейке, товару и партии (только ненулевые).
CREATE OR REPLACE VIEW v_pick_balance AS
SELECT x.cell_id, x.sku, x.lot_id, sum(x.q)::numeric(18,3) AS qty
FROM (SELECT to_cell_id AS cell_id, sku, lot_id, qty AS q FROM pick_moves WHERE to_cell_id IS NOT NULL
      UNION ALL
      SELECT from_cell_id, sku, lot_id, -qty FROM pick_moves WHERE from_cell_id IS NOT NULL) x
GROUP BY x.cell_id, x.sku, x.lot_id
HAVING sum(x.q) <> 0;

-- Экран «Остатки»: где что лежит, партия, срок, блок.
CREATE OR REPLACE VIEW v_pick_stock AS
SELECT z.warehouse_id, z.code AS zone_code, z.kind AS zone_kind, b.cell_id, c.code AS cell_code,
       b.sku, i.sku_name, i.unit, b.lot_id, l.lot_no, l.kind AS lot_kind, l.expiry_date,
       (l.expiry_date - current_date) AS days_left, coalesce(l.hold, false) AS hold, l.hold_reason, b.qty
FROM v_pick_balance b
JOIN pick_cells c ON c.id = b.cell_id
JOIN pick_zones z ON z.id = c.zone_id
LEFT JOIN pick_lots l ON l.id = b.lot_id
LEFT JOIN src_pick_items i ON i.sku = b.sku;

-- Что можно отгружать клиенту: зона хранения, партия не в блоке, срок не истёк
-- (с запасом min_days_left), остаток больше нуля. Порядок — FEFO.
CREATE OR REPLACE VIEW v_pick_available AS
SELECT s.*
FROM v_pick_stock s
WHERE s.zone_kind = 'storage' AND NOT s.hold AND s.qty > 0
  AND (s.expiry_date IS NULL
       OR s.expiry_date >= current_date + (airl_setting('picking', 'min_days_left', '0'))::text::int);

-- FEFO: партии товара на складе — первой та, у которой раньше кончается срок.
CREATE OR REPLACE FUNCTION pick_fefo(p_warehouse text, p_sku text)
RETURNS TABLE (lot_id bigint, lot_no text, expiry_date date, cell_id bigint, cell_code text, qty numeric, fefo_rank bigint)
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    SELECT a.lot_id, a.lot_no, a.expiry_date, a.cell_id, a.cell_code, a.qty,
           dense_rank() OVER (ORDER BY coalesce(a.expiry_date, 'infinity'::date), a.lot_id)
    FROM v_pick_available a
    WHERE a.warehouse_id = p_warehouse AND a.sku = p_sku
    ORDER BY coalesce(a.expiry_date, 'infinity'::date), a.lot_id, a.qty DESC, a.cell_code
$$;

-- Ячейка упаковки склада (одна на склад).
CREATE OR REPLACE FUNCTION pick_packing_cell(p_warehouse text) RETURNS bigint
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    SELECT c.id FROM pick_cells c JOIN pick_zones z ON z.id = c.zone_id
    WHERE z.warehouse_id = p_warehouse AND z.kind = 'packing' AND NOT z.archived AND NOT c.archived
    ORDER BY c.id LIMIT 1
$$;

-- Разбор содержимого QR или штрихкода.
CREATE OR REPLACE FUNCTION pick_parse(p_payload text, OUT kind text, OUT sku text, OUT lot_no text, OUT cell_code text)
LANGUAGE plpgsql STABLE SET search_path FROM CURRENT AS $$
DECLARE
    p text := btrim(p_payload);
    m text[];
    n int;
BEGIN
    kind := 'unknown';
    IF p IS NULL OR p = '' THEN RETURN; END IF;
    m := regexp_match(p, '^AIRL:CELL:([A-Z0-9-]{2,32})$');
    IF m IS NOT NULL THEN kind := 'cell'; cell_code := m[1]; RETURN; END IF;
    m := regexp_match(p, '^AIRL:LOT:(.+):([A-Za-z0-9._/-]{1,40})$');
    IF m IS NOT NULL THEN kind := 'lot'; sku := m[1]; lot_no := m[2]; RETURN; END IF;
    m := regexp_match(p, '^AIRL:SKU:(.+)$');
    IF m IS NOT NULL THEN kind := 'sku'; sku := m[1]; RETURN; END IF;
    IF p ~ '^[0-9]{8,14}$' THEN
        SELECT count(*), min(i.sku) INTO n, sku FROM src_pick_items i WHERE i.barcode = p;
        kind := CASE n WHEN 0 THEN 'unknown' WHEN 1 THEN 'sku' ELSE 'ambiguous' END;
        IF n <> 1 THEN sku := NULL; END IF;
    END IF;
END $$;

-- ───────────── Правила движений ─────────────

-- Движение нельзя менять и удалять; нельзя увести из ячейки больше, чем там есть.
CREATE OR REPLACE FUNCTION pick_moves_guard() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_track boolean;
    v_lot_sku text;
    v_have numeric;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'picking: движение менять и удалять нельзя — сделайте обратное движение';
    END IF;
    SELECT i.track_lots INTO v_track FROM src_pick_items i WHERE i.sku = NEW.sku;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'picking: товара % нет в справочнике', NEW.sku;
    END IF;
    IF NEW.lot_id IS NOT NULL THEN
        SELECT l.sku INTO v_lot_sku FROM pick_lots l WHERE l.id = NEW.lot_id;
        IF v_lot_sku <> NEW.sku THEN
            RAISE EXCEPTION 'picking: партия % не от товара %', NEW.lot_id, NEW.sku;
        END IF;
    ELSIF v_track THEN
        RAISE EXCEPTION 'picking: у товара % учёт по партиям — укажите партию', NEW.sku;
    END IF;
    IF EXISTS (SELECT 1 FROM pick_cells c JOIN pick_zones z ON z.id = c.zone_id
               WHERE c.id IN (NEW.from_cell_id, NEW.to_cell_id) AND (c.archived OR z.archived)) THEN
        RAISE EXCEPTION 'picking: ячейка в архиве';
    END IF;
    IF NEW.from_cell_id IS NOT NULL THEN
        PERFORM pick_lock_stock(NEW.from_cell_id, NEW.sku, NEW.lot_id);
        v_have := pick_balance(NEW.from_cell_id, NEW.sku, NEW.lot_id);
        IF v_have < NEW.qty THEN
            RAISE EXCEPTION 'picking: в ячейке только % — нельзя взять %', v_have, NEW.qty
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pick_moves_guard ON pick_moves;
CREATE TRIGGER pick_moves_guard BEFORE INSERT OR UPDATE OR DELETE ON pick_moves FOR EACH ROW EXECUTE FUNCTION pick_moves_guard();

-- Журнал сканирований только дополняется.
CREATE OR REPLACE FUNCTION pick_readonly() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    RAISE EXCEPTION 'picking: запись % менять и удалять нельзя', TG_TABLE_NAME;
END $$;
DROP TRIGGER IF EXISTS pick_scans_readonly ON pick_scans;
CREATE TRIGGER pick_scans_readonly BEFORE UPDATE OR DELETE ON pick_scans FOR EACH ROW EXECUTE FUNCTION pick_readonly();

-- Связь партий не должна замыкаться в круг (потомок не может быть предком).
CREATE OR REPLACE FUNCTION pick_lot_links_guard() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF EXISTS (WITH RECURSIVE d(id) AS (
                   SELECT NEW.child_lot_id
                   UNION
                   SELECT k.child_lot_id FROM pick_lot_links k JOIN d ON k.parent_lot_id = d.id)
               SELECT 1 FROM d WHERE d.id = NEW.parent_lot_id) THEN
        RAISE EXCEPTION 'picking: связь партий образует круг';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pick_lot_links_guard ON pick_lot_links;
CREATE TRIGGER pick_lot_links_guard BEFORE INSERT OR UPDATE ON pick_lot_links FOR EACH ROW EXECUTE FUNCTION pick_lot_links_guard();

-- Собрано по заданию (за вычетом возвратов) в разрезе строки, товара, партии.
CREATE OR REPLACE VIEW v_pick_task_picked AS
SELECT x.task_id, m.task_line_id AS line_id, m.sku, m.lot_id,
       sum(CASE m.kind WHEN 'pick' THEN m.qty WHEN 'return' THEN -m.qty ELSE 0 END)::numeric(18,3) AS picked_qty,
       sum(CASE m.kind WHEN 'ship' THEN m.qty ELSE 0 END)::numeric(18,3) AS shipped_qty
FROM pick_moves m
JOIN pick_task_lines x ON x.id = m.task_line_id
WHERE m.kind IN ('pick', 'return', 'ship')
GROUP BY x.task_id, m.task_line_id, m.sku, m.lot_id;

-- Сравнение собранного и отсканированного при упаковке (текущий круг).
CREATE OR REPLACE FUNCTION pick_pack_diff(p_task_id bigint)
RETURNS TABLE (sku text, lot_id bigint, picked_qty numeric, packed_qty numeric)
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    WITH p AS (SELECT v.sku, v.lot_id, sum(v.picked_qty) AS q FROM v_pick_task_picked v
               WHERE v.task_id = p_task_id GROUP BY v.sku, v.lot_id HAVING sum(v.picked_qty) > 0),
         k AS (SELECT s.sku, s.lot_id, sum(s.qty) AS q FROM pick_scans s
               JOIN pick_tasks t ON t.id = s.task_id AND s.round = t.pack_round
               WHERE s.task_id = p_task_id AND s.kind = 'pack' AND s.ok GROUP BY s.sku, s.lot_id)
    SELECT coalesce(p.sku, k.sku), coalesce(p.lot_id, k.lot_id), coalesce(p.q, 0), coalesce(k.q, 0)
    FROM p FULL JOIN k ON k.sku = p.sku AND coalesce(k.lot_id, 0) = coalesce(p.lot_id, 0)
    WHERE coalesce(p.q, 0) <> coalesce(k.q, 0)
$$;

-- ───────────── Статусы ─────────────
-- Одна функция на все документы модуля: разрешённые переходы, отметки времени, журнал.
CREATE OR REPLACE FUNCTION pick_status_guard() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_init text;
    v_allowed text[];
    v_actor text;
BEGIN
    v_actor := coalesce(NEW.updated_by, NEW.created_by, 'system');
    IF TG_OP = 'INSERT' THEN
        v_init := CASE TG_TABLE_NAME WHEN 'pick_tasks' THEN 'new' WHEN 'pick_receipts' THEN 'expected'
                                     WHEN 'pick_counts' THEN 'open' ELSE 'open' END;
        IF NEW.status <> v_init THEN
            RAISE EXCEPTION 'picking: новый документ % создаётся в статусе %, а не %', TG_TABLE_NAME, v_init, NEW.status;
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;

    v_allowed := CASE TG_TABLE_NAME
        WHEN 'pick_tasks' THEN ARRAY['new>assigned', 'new>cancelled', 'assigned>picking', 'assigned>new', 'assigned>cancelled',
                                     'picking>picked', 'picking>cancelled', 'picked>checked', 'picked>picking', 'checked>shipped']
        WHEN 'pick_receipts' THEN ARRAY['expected>receiving', 'expected>cancelled', 'receiving>done', 'receiving>cancelled']
        WHEN 'pick_counts' THEN ARRAY['open>counting', 'open>cancelled', 'counting>closed', 'counting>cancelled']
        WHEN 'pick_discrepancies' THEN ARRAY['open>resolved', 'open>cancelled']
    END;
    IF NOT (OLD.status || '>' || NEW.status) = ANY (v_allowed) THEN
        RAISE EXCEPTION 'picking: переход % → % не разрешён (%)', OLD.status, NEW.status, TG_TABLE_NAME;
    END IF;

    IF TG_TABLE_NAME = 'pick_tasks' THEN
        CASE NEW.status
            WHEN 'assigned' THEN NEW.assigned_at := now();
            WHEN 'new'      THEN NEW.assigned_at := NULL; NEW.current_cell_id := NULL;
            WHEN 'picking'  THEN NEW.started_at := coalesce(NEW.started_at, now());
            WHEN 'picked'   THEN
                IF EXISTS (SELECT 1 FROM pick_task_lines l WHERE l.task_id = NEW.id AND l.done_at IS NULL) THEN
                    RAISE EXCEPTION 'picking: в задании % есть несобранные строки', NEW.task_no;
                END IF;
                NEW.picked_at := now();
            WHEN 'checked'  THEN
                IF EXISTS (SELECT 1 FROM pick_pack_diff(NEW.id)) THEN
                    RAISE EXCEPTION 'picking: упаковка задания % не совпадает с собранным', NEW.task_no;
                END IF;
                NEW.checked_at := now(); NEW.checked_by := coalesce(NEW.checked_by, v_actor);
            WHEN 'shipped'  THEN NEW.shipped_at := now();
            WHEN 'cancelled' THEN
                IF EXISTS (SELECT 1 FROM v_pick_task_picked v WHERE v.task_id = NEW.id AND v.picked_qty > 0) THEN
                    RAISE EXCEPTION 'picking: в задании % уже есть собранный товар — сначала «Пересобрать» (товар вернётся в ячейки)', NEW.task_no;
                END IF;
            ELSE NULL;
        END CASE;
    ELSIF TG_TABLE_NAME = 'pick_receipts' THEN
        IF NEW.status = 'receiving' THEN NEW.started_at := coalesce(NEW.started_at, now()); END IF;
        IF NEW.status = 'done' THEN NEW.closed_at := now(); NEW.closed_by := v_actor; END IF;
        IF NEW.status = 'cancelled' AND EXISTS (SELECT 1 FROM pick_receipt_lines l WHERE l.receipt_id = NEW.id AND l.received_qty > 0) THEN
            RAISE EXCEPTION 'picking: по приёмке % уже принят товар — закройте её с расхождениями', NEW.receipt_no;
        END IF;
    ELSIF TG_TABLE_NAME = 'pick_counts' THEN
        IF NEW.status = 'counting' THEN NEW.started_at := coalesce(NEW.started_at, now()); END IF;
        IF NEW.status = 'closed' THEN NEW.closed_at := now(); NEW.closed_by := v_actor; END IF;
    ELSIF TG_TABLE_NAME = 'pick_discrepancies' THEN
        NEW.resolved_at := now();
    END IF;

    INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
    VALUES (v_actor, 'picking', TG_TABLE_NAME, NEW.id::text, 'status', OLD.status, NEW.status,
            coalesce(to_jsonb(NEW) ->> 'status_comment', to_jsonb(NEW) ->> 'cancel_reason', to_jsonb(NEW) ->> 'resolution'));
    RETURN NEW;
END $$;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['pick_tasks', 'pick_receipts', 'pick_counts', 'pick_discrepancies'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_status', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION pick_status_guard()', t || '_status', t);
    END LOOP;
END $$;

-- Новое расхождение — заведующему складом (один раз на расхождение).
CREATE OR REPLACE FUNCTION pick_disc_notify() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_to text := airl_setting('picking', 'head_recipient', '"warehouse_head"') #>> '{}';
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    VALUES ('picking:discrepancy:' || NEW.id || ':' || v_to, 'picking',
            airl_setting('picking', 'channel', '"telegram"') #>> '{}', v_to,
            'Склад ' || NEW.warehouse_id || ': расхождение ' || NEW.disc_no || ' (' || NEW.source || ') по ' || NEW.sku
            || ': ожидали ' || NEW.expected_qty || ', факт ' || NEW.actual_qty || '. Укажите причину и ответственного.')
    ON CONFLICT (dedup_key) DO NOTHING;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pick_disc_notify ON pick_discrepancies;
CREATE TRIGGER pick_disc_notify AFTER INSERT ON pick_discrepancies FOR EACH ROW EXECUTE FUNCTION pick_disc_notify();

-- ───────────── Сканирование ─────────────

CREATE OR REPLACE FUNCTION pick_log_scan(p_kind text, p_actor text, p_task bigint, p_line bigint, p_receipt bigint,
                                         p_count bigint, p_round int, p_payload text, p_sku text, p_lot bigint,
                                         p_qty numeric, p_ok boolean, p_code text, p_msg text)
RETURNS void LANGUAGE sql SET search_path FROM CURRENT AS $$
    INSERT INTO pick_scans (actor, kind, task_id, line_id, receipt_id, count_id, round, payload, sku, lot_id, qty,
                            ok, error_code, message, created_by)
    VALUES (p_actor, p_kind, p_task, p_line, p_receipt, p_count, p_round, left(p_payload, 200), p_sku, p_lot, p_qty,
            p_ok, CASE WHEN p_ok THEN NULL ELSE p_code END, p_msg, p_actor)
$$;

-- Сканирование при сборке. Сначала (по желанию) QR ячейки, затем этикетка партии
-- или штрихкод товара без партий. Каждое сканирование пишется в журнал; ошибка
-- возвращается, а не выбрасывается: экран показывает message и просит пересканировать.
-- Коды ошибок: task_not_found, task_not_open, not_assignee, other_task_open, unknown_code,
-- ambiguous_code, scan_lot_label, wrong_cell, wrong_item, line_complete, bad_qty, qty_over,
-- unknown_lot, lot_on_hold, expired, not_fefo, no_stock, no_packing_cell.
CREATE OR REPLACE FUNCTION pick_scan(p_task_id bigint, p_payload text, p_qty numeric, p_actor text)
RETURNS TABLE (ok boolean, error_code text, message text, line_id bigint, qty_left numeric)
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
#variable_conflict use_column
DECLARE
    t        pick_tasks%ROWTYPE;
    l        pick_task_lines%ROWTYPE;
    lt       pick_lots%ROWTYPE;
    s        record;
    b        record;
    v_ok     boolean := false;
    v_code   text;
    v_msg    text;
    v_qty    numeric := coalesce(p_qty, 1);
    v_cell   bigint;
    v_pack   bigint;
    v_have   numeric;
    v_left   numeric;
    v_track  boolean;
    v_task   bigint;
BEGIN
    <<chk>>
    BEGIN
        SELECT * INTO t FROM pick_tasks x WHERE x.id = p_task_id FOR UPDATE;
        IF NOT FOUND THEN v_code := 'task_not_found'; v_msg := 'Задание не найдено'; EXIT chk; END IF;
        v_task := t.id;
        IF t.status NOT IN ('assigned', 'picking') THEN
            v_code := 'task_not_open'; v_msg := 'Задание ' || t.task_no || ' сейчас не в сборке (' || t.status || ')'; EXIT chk;
        END IF;
        IF t.assigned_to IS DISTINCT FROM p_actor THEN
            v_code := 'not_assignee'; v_msg := 'Задание собирает ' || coalesce(t.assigned_to, '—'); EXIT chk;
        END IF;
        IF t.status = 'assigned' AND EXISTS (SELECT 1 FROM pick_tasks o WHERE o.assigned_to = p_actor AND o.status = 'picking' AND o.id <> t.id) THEN
            v_code := 'other_task_open'; v_msg := 'Сначала закончите задание, которое уже собираете'; EXIT chk;
        END IF;

        s := pick_parse(p_payload);
        IF s.kind = 'cell' THEN
            SELECT c.id INTO v_cell FROM pick_cells c JOIN pick_zones z ON z.id = c.zone_id
            WHERE c.code = s.cell_code AND NOT c.archived AND z.warehouse_id = t.warehouse_id AND z.kind = 'storage';
            IF NOT FOUND THEN v_code := 'wrong_cell'; v_msg := 'Ячейка ' || s.cell_code || ' не из зоны хранения этого склада'; EXIT chk; END IF;
            UPDATE pick_tasks x SET current_cell_id = v_cell, updated_by = p_actor WHERE x.id = t.id;
            IF t.status = 'assigned' THEN UPDATE pick_tasks x SET status = 'picking', updated_by = p_actor WHERE x.id = t.id; END IF;
            v_ok := true; v_msg := 'Ячейка ' || s.cell_code || '. Сканируйте товар'; EXIT chk;
        ELSIF s.kind = 'ambiguous' THEN
            v_code := 'ambiguous_code'; v_msg := 'Штрихкод есть у нескольких товаров — сканируйте этикетку партии'; EXIT chk;
        ELSIF s.kind NOT IN ('lot', 'sku') THEN
            v_code := 'unknown_code'; v_msg := 'Код не распознан'; EXIT chk;
        END IF;

        SELECT i.track_lots INTO v_track FROM src_pick_items i WHERE i.sku = s.sku;
        IF s.kind = 'sku' AND coalesce(v_track, false) THEN
            v_code := 'scan_lot_label'; v_msg := 'У этого товара учёт по партиям — сканируйте этикетку партии'; EXIT chk;
        END IF;

        SELECT * INTO l FROM pick_task_lines x
        WHERE x.task_id = t.id AND x.sku = s.sku AND x.done_at IS NULL
        ORDER BY x.line_no LIMIT 1 FOR UPDATE;
        IF NOT FOUND THEN
            IF EXISTS (SELECT 1 FROM pick_task_lines x WHERE x.task_id = t.id AND x.sku = s.sku) THEN
                v_code := 'line_complete'; v_msg := 'Этот товар уже собран полностью';
            ELSE
                v_code := 'wrong_item'; v_msg := 'Этого товара нет в заказе. Верните его в ячейку';
            END IF;
            EXIT chk;
        END IF;
        v_left := l.qty - l.qty_picked - l.qty_short;
        IF v_qty <= 0 THEN v_code := 'bad_qty'; v_msg := 'Количество должно быть больше нуля'; EXIT chk; END IF;
        IF v_qty > v_left THEN
            v_code := 'qty_over'; v_msg := 'Нужно ещё ' || v_left || ', а отсканировано ' || v_qty; EXIT chk;
        END IF;

        IF s.kind = 'lot' THEN
            SELECT * INTO lt FROM pick_lots x WHERE x.sku = s.sku AND x.lot_no = s.lot_no;
            IF NOT FOUND THEN v_code := 'unknown_lot'; v_msg := 'Партия ' || s.lot_no || ' не найдена'; EXIT chk; END IF;
            IF lt.hold THEN v_code := 'lot_on_hold'; v_msg := 'Партия ' || lt.lot_no || ' заблокирована: ' || lt.hold_reason; EXIT chk; END IF;
            IF lt.expiry_date < current_date + (airl_setting('picking', 'min_days_left', '0'))::text::int THEN
                v_code := 'expired'; v_msg := 'Срок партии ' || lt.lot_no || ' истёк или слишком мал (' || to_char(lt.expiry_date, 'DD.MM.YYYY') || ')'; EXIT chk;
            END IF;
            IF (airl_setting('picking', 'fefo_strict', 'true'))::text::boolean THEN
                SELECT a.lot_no, a.expiry_date, a.cell_code INTO b FROM v_pick_available a
                WHERE a.warehouse_id = t.warehouse_id AND a.sku = s.sku AND a.lot_id <> lt.id
                  AND coalesce(a.expiry_date, 'infinity'::date) < coalesce(lt.expiry_date, 'infinity'::date)
                ORDER BY a.expiry_date, a.qty DESC LIMIT 1;
                IF FOUND THEN
                    v_code := 'not_fefo';
                    v_msg := 'Сначала партия ' || b.lot_no || ' (годна до ' || to_char(b.expiry_date, 'DD.MM.YYYY') || '), ячейка ' || b.cell_code;
                    EXIT chk;
                END IF;
            END IF;
        END IF;

        v_cell := t.current_cell_id;
        IF v_cell IS NULL THEN
            SELECT a.cell_id INTO v_cell FROM v_pick_available a
            WHERE a.warehouse_id = t.warehouse_id AND a.sku = s.sku AND coalesce(a.lot_id, 0) = coalesce(lt.id, 0)
            ORDER BY (a.cell_id = l.suggested_cell_id) DESC, a.qty DESC LIMIT 1;
            IF NOT FOUND THEN v_code := 'no_stock'; v_msg := 'Этого товара нет на остатке в зоне хранения'; EXIT chk; END IF;
        END IF;
        PERFORM pick_lock_stock(v_cell, s.sku, lt.id);
        v_have := pick_balance(v_cell, s.sku, lt.id);
        IF v_have < v_qty THEN
            IF v_have <= 0 THEN
                v_code := 'wrong_cell'; v_msg := 'В этой ячейке нет этого товара (партии). Проверьте адрес';
            ELSE
                v_code := 'no_stock'; v_msg := 'В ячейке только ' || v_have;
            END IF;
            EXIT chk;
        END IF;
        v_pack := pick_packing_cell(t.warehouse_id);
        IF v_pack IS NULL THEN v_code := 'no_packing_cell'; v_msg := 'На складе не настроена зона упаковки'; EXIT chk; END IF;

        INSERT INTO pick_moves (kind, sku, lot_id, from_cell_id, to_cell_id, qty, task_line_id, created_by)
        VALUES ('pick', s.sku, lt.id, v_cell, v_pack, v_qty, l.id, p_actor);
        UPDATE pick_task_lines x
        SET qty_picked = x.qty_picked + v_qty,
            done_at = CASE WHEN x.qty_picked + v_qty + x.qty_short >= x.qty THEN now() END,
            updated_by = p_actor
        WHERE x.id = l.id;
        IF t.status = 'assigned' THEN
            UPDATE pick_tasks x SET status = 'picking', updated_by = p_actor WHERE x.id = t.id;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pick_task_lines x WHERE x.task_id = t.id AND x.done_at IS NULL) THEN
            UPDATE pick_tasks x SET status = 'picked', updated_by = p_actor WHERE x.id = t.id;
        END IF;
        v_ok := true; v_left := v_left - v_qty;
        v_msg := CASE WHEN v_left > 0 THEN 'Принято. Осталось ' || v_left ELSE 'Строка собрана' END;
    END chk;

    PERFORM pick_log_scan('pick', p_actor, v_task, l.id, NULL, NULL, NULL, p_payload, s.sku, lt.id, v_qty, v_ok, v_code, v_msg);
    RETURN QUERY SELECT v_ok, CASE WHEN v_ok THEN NULL ELSE v_code END, v_msg, l.id, v_left;
END $$;

-- Взять задание: только из статуса new. Два диспетчера (или сборщика) одновременно
-- не назначат одно задание дважды: строка блокируется, второй получает ошибку.
CREATE OR REPLACE FUNCTION pick_assign(p_task_id bigint, p_picker text, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE t pick_tasks%ROWTYPE;
BEGIN
    SELECT * INTO t FROM pick_tasks WHERE id = p_task_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'picking: задание % не найдено', p_task_id; END IF;
    IF t.status <> 'new' THEN
        RAISE EXCEPTION 'picking: задание % уже назначено (%: %)', t.task_no, t.status, coalesce(t.assigned_to, '—')
            USING ERRCODE = 'unique_violation';
    END IF;
    UPDATE pick_tasks SET status = 'assigned', assigned_to = p_picker, updated_by = p_actor WHERE id = p_task_id;
END $$;

-- «Взять следующее»: самое срочное свободное задание склада. SKIP LOCKED — два сборщика,
-- нажавшие кнопку одновременно, получают разные задания.
CREATE OR REPLACE FUNCTION pick_take_next(p_warehouse text, p_picker text) RETURNS bigint
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE v_id bigint;
BEGIN
    SELECT id INTO v_id FROM pick_tasks
    WHERE warehouse_id = p_warehouse AND status = 'new'
    ORDER BY ship_by NULLS LAST, id
    LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF v_id IS NOT NULL THEN
        UPDATE pick_tasks SET status = 'assigned', assigned_to = p_picker, updated_by = p_picker WHERE id = v_id;
    END IF;
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION pick_unassign(p_task_id bigint, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    UPDATE pick_tasks SET status = 'new', assigned_to = NULL, updated_by = p_actor
    WHERE id = p_task_id AND status = 'assigned';
    IF NOT FOUND THEN RAISE EXCEPTION 'picking: снять можно только назначенное и не начатое задание'; END IF;
END $$;

-- Не хватило товара в ячейке: строка закрывается недобором, расхождение — в журнал.
CREATE OR REPLACE FUNCTION pick_line_short(p_line_id bigint, p_qty numeric, p_reason text, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    l pick_task_lines%ROWTYPE;
    t pick_tasks%ROWTYPE;
BEGIN
    SELECT * INTO l FROM pick_task_lines WHERE id = p_line_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'picking: строка % не найдена', p_line_id; END IF;
    SELECT * INTO t FROM pick_tasks WHERE id = l.task_id FOR UPDATE;
    SELECT * INTO l FROM pick_task_lines WHERE id = p_line_id FOR UPDATE;
    IF t.status NOT IN ('assigned', 'picking') OR t.assigned_to IS DISTINCT FROM p_actor THEN
        RAISE EXCEPTION 'picking: недобор отмечает сборщик своего задания в сборке';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 OR p_qty > l.qty - l.qty_picked - l.qty_short THEN
        RAISE EXCEPTION 'picking: недобор должен быть от 0 до %', l.qty - l.qty_picked - l.qty_short;
    END IF;
    IF t.status = 'assigned' THEN UPDATE pick_tasks SET status = 'picking', updated_by = p_actor WHERE id = t.id; END IF;
    UPDATE pick_task_lines
    SET qty_short = qty_short + p_qty, short_reason = p_reason,
        done_at = CASE WHEN qty_picked + qty_short + p_qty >= qty THEN now() END, updated_by = p_actor
    WHERE id = l.id;
    INSERT INTO pick_discrepancies (source, warehouse_id, sku, lot_id, cell_id, task_id, expected_qty, actual_qty,
                                    reason, responsible, comment, created_by)
    VALUES ('pick', t.warehouse_id, l.sku, l.suggested_lot_id, coalesce(t.current_cell_id, l.suggested_cell_id), t.id,
            p_qty, 0, CASE p_reason WHEN 'damaged' THEN 'damaged' WHEN 'expired' THEN 'expired' ELSE 'not_found_in_cell' END,
            NULL, 'Недобор при сборке ' || t.task_no, p_actor)
    ON CONFLICT (task_id, sku, (coalesce(lot_id, 0)), source) WHERE status = 'open' AND task_id IS NOT NULL DO NOTHING;
    IF NOT EXISTS (SELECT 1 FROM pick_task_lines x WHERE x.task_id = t.id AND x.done_at IS NULL) THEN
        UPDATE pick_tasks SET status = 'picked', updated_by = p_actor WHERE id = t.id;
    END IF;
END $$;

-- Проверка упаковки: упаковщик заново сканирует всё, что кладёт в коробку.
-- Чужой товар или партия сразу пишутся в расхождения (ответственный — сборщик).
CREATE OR REPLACE FUNCTION pick_pack_scan(p_task_id bigint, p_payload text, p_qty numeric, p_actor text)
RETURNS TABLE (ok boolean, error_code text, message text)
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
#variable_conflict use_column
DECLARE
    t       pick_tasks%ROWTYPE;
    s       record;
    v_lot   bigint;
    v_track boolean;
    v_ok    boolean := false;
    v_code  text;
    v_msg   text;
    v_qty   numeric := coalesce(p_qty, 1);
    v_pick  numeric;
    v_pack  numeric;
    v_task  bigint;
BEGIN
    <<chk>>
    BEGIN
        SELECT * INTO t FROM pick_tasks x WHERE x.id = p_task_id FOR UPDATE;
        IF NOT FOUND THEN v_code := 'task_not_found'; v_msg := 'Задание не найдено'; EXIT chk; END IF;
        v_task := t.id;
        IF t.status <> 'picked' THEN v_code := 'task_not_ready'; v_msg := 'Задание ещё не собрано или уже проверено'; EXIT chk; END IF;
        IF v_qty <= 0 THEN v_code := 'bad_qty'; v_msg := 'Количество должно быть больше нуля'; EXIT chk; END IF;
        s := pick_parse(p_payload);
        IF s.kind NOT IN ('lot', 'sku') THEN v_code := 'unknown_code'; v_msg := 'Код не распознан'; EXIT chk; END IF;
        SELECT i.track_lots INTO v_track FROM src_pick_items i WHERE i.sku = s.sku;
        IF s.kind = 'sku' AND coalesce(v_track, false) THEN
            v_code := 'scan_lot_label'; v_msg := 'Сканируйте этикетку партии'; EXIT chk;
        END IF;
        IF s.kind = 'lot' THEN
            SELECT x.id INTO v_lot FROM pick_lots x WHERE x.sku = s.sku AND x.lot_no = s.lot_no;
        END IF;
        SELECT sum(v.picked_qty) INTO v_pick FROM v_pick_task_picked v
        WHERE v.task_id = t.id AND v.sku = s.sku AND coalesce(v.lot_id, 0) = coalesce(v_lot, 0);
        SELECT sum(x.qty) INTO v_pack FROM pick_scans x
        WHERE x.task_id = t.id AND x.kind = 'pack' AND x.ok AND x.round = t.pack_round
          AND x.sku = s.sku AND coalesce(x.lot_id, 0) = coalesce(v_lot, 0);
        IF coalesce(v_pick, 0) <= 0 THEN
            v_code := 'not_in_order';
            v_msg := 'Этого товара (партии) нет в собранном. Отложите его — расхождение записано';
            INSERT INTO pick_discrepancies (source, warehouse_id, sku, lot_id, cell_id, task_id, expected_qty, actual_qty,
                                            reason, responsible, comment, created_by)
            VALUES ('pack', t.warehouse_id, s.sku, v_lot, pick_packing_cell(t.warehouse_id), t.id, 0, v_qty,
                    CASE WHEN EXISTS (SELECT 1 FROM pick_task_lines x WHERE x.task_id = t.id AND x.sku = s.sku)
                         THEN 'wrong_lot_picked' ELSE 'wrong_item_picked' END,
                    t.assigned_to, 'Найдено при упаковке ' || t.task_no, p_actor)
            ON CONFLICT (task_id, sku, (coalesce(lot_id, 0)), source) WHERE status = 'open' AND task_id IS NOT NULL DO NOTHING;
            EXIT chk;
        END IF;
        IF coalesce(v_pack, 0) + v_qty > v_pick THEN
            v_code := 'qty_over'; v_msg := 'Собрано ' || v_pick || ', в коробке уже ' || coalesce(v_pack, 0); EXIT chk;
        END IF;
        v_ok := true; v_msg := 'В коробке ' || (coalesce(v_pack, 0) + v_qty) || ' из ' || v_pick;
    END chk;
    PERFORM pick_log_scan('pack', p_actor, v_task, NULL, NULL, NULL, t.pack_round, p_payload, s.sku, v_lot, v_qty, v_ok, v_code, v_msg);
    RETURN QUERY SELECT v_ok, CASE WHEN v_ok THEN NULL ELSE v_code END, v_msg;
END $$;

-- «Упаковка сверена»: всё собранное отсканировано в коробку, лишнего нет → checked.
-- Иначе — ошибка pack_mismatch и расхождения по каждой позиции (без дублей).
CREATE OR REPLACE FUNCTION pick_pack_close(p_task_id bigint, p_actor text)
RETURNS TABLE (ok boolean, error_code text, message text)
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
#variable_conflict use_column
DECLARE
    t pick_tasks%ROWTYPE;
    d record;
    v_msg text := '';
BEGIN
    SELECT * INTO t FROM pick_tasks x WHERE x.id = p_task_id FOR UPDATE;
    IF NOT FOUND OR t.status <> 'picked' THEN
        RETURN QUERY SELECT false, 'task_not_ready'::text, 'Задание не в статусе «собрано»'::text; RETURN;
    END IF;
    FOR d IN SELECT * FROM pick_pack_diff(t.id) LOOP
        v_msg := v_msg || d.sku || ': собрано ' || d.picked_qty || ', в коробке ' || d.packed_qty || '; ';
        INSERT INTO pick_discrepancies (source, warehouse_id, sku, lot_id, task_id, expected_qty, actual_qty,
                                        reason, responsible, comment, created_by)
        VALUES ('pack', t.warehouse_id, d.sku, d.lot_id, t.id, d.picked_qty, d.packed_qty, 'qty_error',
                t.assigned_to, 'Проверка упаковки ' || t.task_no, p_actor)
        ON CONFLICT (task_id, sku, (coalesce(lot_id, 0)), source) WHERE status = 'open' AND task_id IS NOT NULL DO NOTHING;
    END LOOP;
    IF v_msg <> '' THEN
        RETURN QUERY SELECT false, 'pack_mismatch'::text, ('Не сходится: ' || v_msg)::text; RETURN;
    END IF;
    UPDATE pick_tasks x SET status = 'checked', checked_by = p_actor, updated_by = p_actor WHERE x.id = t.id;
    RETURN QUERY SELECT true, NULL::text, 'Упаковка сверена'::text;
END $$;

-- «Пересобрать»: собранное возвращается в исходные ячейки, строки обнуляются,
-- проверка упаковки начинается заново (новый круг).
CREATE OR REPLACE FUNCTION pick_task_reopen(p_task_id bigint, p_comment text, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    t pick_tasks%ROWTYPE;
    r record;
    v_pack bigint;
BEGIN
    SELECT * INTO t FROM pick_tasks WHERE id = p_task_id FOR UPDATE;
    IF NOT FOUND OR t.status NOT IN ('picked', 'picking') THEN
        RAISE EXCEPTION 'picking: пересобрать можно задание в сборке или собранное, но не проверенное';
    END IF;
    IF p_comment IS NULL THEN RAISE EXCEPTION 'picking: укажите, почему пересобираем'; END IF;
    v_pack := pick_packing_cell(t.warehouse_id);
    FOR r IN
        SELECT m.task_line_id, m.sku, m.lot_id, m.cell_id, sum(m.q) AS qty
        FROM (SELECT task_line_id, sku, lot_id, from_cell_id AS cell_id, qty AS q FROM pick_moves WHERE kind = 'pick'
              UNION ALL
              SELECT task_line_id, sku, lot_id, to_cell_id, -qty FROM pick_moves WHERE kind = 'return') m
        JOIN pick_task_lines l ON l.id = m.task_line_id AND l.task_id = t.id
        GROUP BY m.task_line_id, m.sku, m.lot_id, m.cell_id HAVING sum(m.q) > 0
    LOOP
        INSERT INTO pick_moves (kind, sku, lot_id, from_cell_id, to_cell_id, qty, task_line_id, reason, created_by)
        VALUES ('return', r.sku, r.lot_id, v_pack, r.cell_id, r.qty, r.task_line_id, p_comment, p_actor);
    END LOOP;
    UPDATE pick_task_lines SET qty_picked = 0, done_at = CASE WHEN qty_short >= qty THEN done_at END, updated_by = p_actor
    WHERE task_id = t.id;
    UPDATE pick_tasks SET pack_round = pack_round + 1, current_cell_id = NULL, status_comment = p_comment,
                          status = 'picking', updated_by = p_actor
    WHERE id = t.id;
END $$;

-- Отгрузка: проверенное задание уходит со склада (движения ship — основа прослеживаемости).
CREATE OR REPLACE FUNCTION pick_ship(p_task_id bigint, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    t pick_tasks%ROWTYPE;
    r record;
    v_pack bigint;
BEGIN
    SELECT * INTO t FROM pick_tasks WHERE id = p_task_id FOR UPDATE;
    IF NOT FOUND OR t.status <> 'checked' THEN
        RAISE EXCEPTION 'picking: отгрузить можно только задание с проверенной упаковкой';
    END IF;
    v_pack := pick_packing_cell(t.warehouse_id);
    FOR r IN SELECT v.line_id, v.sku, v.lot_id, v.picked_qty - v.shipped_qty AS qty
             FROM v_pick_task_picked v WHERE v.task_id = t.id AND v.picked_qty - v.shipped_qty > 0 LOOP
        INSERT INTO pick_moves (kind, sku, lot_id, from_cell_id, to_cell_id, qty, task_line_id, created_by)
        VALUES ('ship', r.sku, r.lot_id, v_pack, NULL, r.qty, r.line_id, p_actor);
    END LOOP;
    UPDATE pick_tasks SET status = 'shipped', updated_by = p_actor WHERE id = t.id;
END $$;

CREATE OR REPLACE FUNCTION pick_cancel_task(p_task_id bigint, p_reason text, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    UPDATE pick_tasks SET status = 'cancelled', cancel_reason = p_reason, updated_by = p_actor WHERE id = p_task_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'picking: задание % не найдено', p_task_id; END IF;
END $$;

-- Задания из подтверждённых заказов (запускать каждые 5–15 минут). Повторный запуск
-- не создаёт дублей. Заказ отменён в учёте — несобранное задание отменяется,
-- уже собираемое остаётся и попадает заведующему (собранное вернуть в ячейки).
CREATE OR REPLACE FUNCTION pick_generate_tasks(p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    o record;
    v_id bigint;
    n int := 0;
    v_to text := airl_setting('picking', 'head_recipient', '"warehouse_head"') #>> '{}';
BEGIN
    FOR o IN
        SELECT so.* FROM src_pick_orders so
        WHERE so.status = 'confirmed'
          AND EXISTS (SELECT 1 FROM src_pick_order_lines ol WHERE ol.order_id = so.order_id)
          AND NOT EXISTS (SELECT 1 FROM pick_tasks t WHERE t.order_id = so.order_id AND t.status <> 'cancelled')
        ORDER BY so.ship_by, so.order_id
    LOOP
        v_id := NULL;
        INSERT INTO pick_tasks (order_id, warehouse_id, ship_by, created_by)
        VALUES (o.order_id, o.warehouse_id, o.ship_by, p_actor)
        ON CONFLICT (order_id) WHERE status <> 'cancelled' DO NOTHING
        RETURNING id INTO v_id;
        CONTINUE WHEN v_id IS NULL;
        INSERT INTO pick_task_lines (task_id, line_no, sku, qty, suggested_lot_id, suggested_cell_id, created_by)
        SELECT v_id, ol.line_no, ol.sku, ol.qty, f.lot_id, f.cell_id, p_actor
        FROM src_pick_order_lines ol
        LEFT JOIN LATERAL (SELECT ff.lot_id, ff.cell_id FROM pick_fefo(o.warehouse_id, ol.sku) ff LIMIT 1) f ON true
        WHERE ol.order_id = o.order_id;
        n := n + 1;
    END LOOP;

    UPDATE pick_tasks t SET status = 'cancelled', cancel_reason = 'заказ отменён в учёте', updated_by = p_actor
    FROM src_pick_orders so
    WHERE so.order_id = t.order_id AND so.status = 'cancelled' AND t.status IN ('new', 'assigned');

    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'picking:order_cancelled:' || t.id || ':' || v_to, 'picking',
           airl_setting('picking', 'channel', '"telegram"') #>> '{}', v_to,
           'Заказ ' || so.order_no || ' отменён, а задание ' || t.task_no || ' уже собирается (' || t.assigned_to || '). Остановите сборку.'
    FROM pick_tasks t JOIN src_pick_orders so ON so.order_id = t.order_id
    WHERE so.status = 'cancelled' AND t.status IN ('picking', 'picked', 'checked')
    ON CONFLICT (dedup_key) DO NOTHING;
    RETURN n;
END $$;

-- ───────────── Приёмка, перемещение, инвентаризация ─────────────

-- Приёмка со сканированием: этикетка партии поставщика или штрихкод + номер партии и срок.
-- Партия создаётся при первом приёме. Ячейка — QR (по умолчанию первая ячейка зоны приёмки).
CREATE OR REPLACE FUNCTION pick_receive(p_receipt_id bigint, p_payload text, p_lot_no text, p_expiry date,
                                        p_qty numeric, p_cell_payload text, p_actor text)
RETURNS TABLE (ok boolean, error_code text, message text)
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
#variable_conflict use_column
DECLARE
    r      pick_receipts%ROWTYPE;
    s      record;
    c      record;
    it     record;
    v_lotno text;
    v_lot  pick_lots%ROWTYPE;
    v_line bigint;
    v_cell bigint;
    v_ok   boolean := false;
    v_code text;
    v_msg  text;
    v_rid  bigint;
BEGIN
    <<chk>>
    BEGIN
        SELECT * INTO r FROM pick_receipts x WHERE x.id = p_receipt_id FOR UPDATE;
        IF NOT FOUND THEN v_code := 'receipt_not_found'; v_msg := 'Приёмка не найдена'; EXIT chk; END IF;
        v_rid := r.id;
        IF r.status NOT IN ('expected', 'receiving') THEN v_code := 'receipt_closed'; v_msg := 'Приёмка уже закрыта'; EXIT chk; END IF;
        IF p_qty IS NULL OR p_qty <= 0 THEN v_code := 'bad_qty'; v_msg := 'Количество должно быть больше нуля'; EXIT chk; END IF;
        s := pick_parse(p_payload);
        IF s.kind NOT IN ('lot', 'sku') THEN v_code := 'unknown_code'; v_msg := 'Код не распознан'; EXIT chk; END IF;
        SELECT i.* INTO it FROM src_pick_items i WHERE i.sku = s.sku;
        IF NOT FOUND THEN v_code := 'unknown_item'; v_msg := 'Товара ' || s.sku || ' нет в справочнике'; EXIT chk; END IF;
        v_lotno := coalesce(s.lot_no, nullif(btrim(p_lot_no), ''));
        IF it.track_lots AND v_lotno IS NULL THEN v_code := 'need_lot'; v_msg := 'Укажите номер партии'; EXIT chk; END IF;
        IF v_lotno IS NOT NULL AND v_lotno !~ '^[A-Za-z0-9._/-]{1,40}$' THEN
            v_code := 'bad_lot'; v_msg := 'Номер партии: только латиница, цифры и . _ / -'; EXIT chk;
        END IF;

        IF p_cell_payload IS NOT NULL THEN
            SELECT cc.id, z.kind INTO c FROM pick_cells cc JOIN pick_zones z ON z.id = cc.zone_id
            WHERE 'AIRL:CELL:' || cc.code = btrim(p_cell_payload) AND z.warehouse_id = r.warehouse_id AND NOT cc.archived
              AND z.kind IN ('receiving', 'storage', 'quarantine', 'production');
            IF NOT FOUND THEN v_code := 'wrong_cell'; v_msg := 'Ячейка не с этого склада или не для приёмки'; EXIT chk; END IF;
            v_cell := c.id;
        ELSE
            SELECT cc.id INTO v_cell FROM pick_cells cc JOIN pick_zones z ON z.id = cc.zone_id
            WHERE z.warehouse_id = r.warehouse_id AND z.kind = 'receiving' AND NOT cc.archived AND NOT z.archived
            ORDER BY cc.id LIMIT 1;
            IF v_cell IS NULL THEN v_code := 'no_receiving_cell'; v_msg := 'На складе нет зоны приёмки — сканируйте ячейку'; EXIT chk; END IF;
        END IF;

        IF it.track_lots THEN
            SELECT * INTO v_lot FROM pick_lots x WHERE x.sku = s.sku AND x.lot_no = v_lotno;
            IF NOT FOUND THEN
                IF p_expiry IS NULL AND it.shelf_life_days IS NOT NULL
                   AND (airl_setting('picking', 'require_expiry', 'true'))::text::boolean THEN
                    v_code := 'need_expiry'; v_msg := 'Укажите срок годности партии'; EXIT chk;
                END IF;
                INSERT INTO pick_lots (sku, lot_no, kind, expiry_date, created_by)
                VALUES (s.sku, v_lotno, CASE it.kind WHEN 'green' THEN 'green' WHEN 'roast' THEN 'roast'
                                                     WHEN 'packed' THEN 'packed' ELSE 'goods' END, p_expiry, p_actor)
                RETURNING * INTO v_lot;
            ELSIF p_expiry IS NOT NULL AND v_lot.expiry_date IS DISTINCT FROM p_expiry THEN
                v_code := 'expiry_mismatch';
                v_msg := 'У партии ' || v_lotno || ' уже записан срок ' || coalesce(to_char(v_lot.expiry_date, 'DD.MM.YYYY'), '—');
                EXIT chk;
            END IF;
        END IF;

        SELECT x.id INTO v_line FROM pick_receipt_lines x
        WHERE x.receipt_id = r.id AND x.sku = s.sku ORDER BY (x.received_qty < x.expected_qty) DESC, x.line_no LIMIT 1;
        IF v_line IS NULL THEN
            IF NOT (airl_setting('picking', 'allow_unexpected_receipt', 'true'))::text::boolean THEN
                v_code := 'not_in_receipt'; v_msg := 'Этого товара нет в ожидаемой поставке'; EXIT chk;
            END IF;
            INSERT INTO pick_receipt_lines (receipt_id, line_no, sku, expected_qty, created_by)
            VALUES (r.id, coalesce((SELECT max(x.line_no) FROM pick_receipt_lines x WHERE x.receipt_id = r.id), 0) + 1, s.sku, 0, p_actor)
            RETURNING id INTO v_line;
        END IF;
        UPDATE pick_receipt_lines x SET received_qty = x.received_qty + p_qty, updated_by = p_actor WHERE x.id = v_line;
        INSERT INTO pick_moves (kind, sku, lot_id, to_cell_id, qty, receipt_line_id, created_by)
        VALUES ('receipt', s.sku, v_lot.id, v_cell, p_qty, v_line, p_actor);
        IF r.status = 'expected' THEN
            UPDATE pick_receipts x SET status = 'receiving', updated_by = p_actor WHERE x.id = r.id;
        END IF;
        v_ok := true; v_msg := 'Принято ' || p_qty || ' ' || coalesce(it.unit, '');
    END chk;
    PERFORM pick_log_scan('receive', p_actor, NULL, NULL, v_rid, NULL, NULL, p_payload, s.sku, v_lot.id, p_qty, v_ok, v_code, v_msg);
    RETURN QUERY SELECT v_ok, CASE WHEN v_ok THEN NULL ELSE v_code END, v_msg;
END $$;

-- Закрыть приёмку: по каждой строке, где пришло не столько, сколько ждали, — расхождение.
CREATE OR REPLACE FUNCTION pick_receipt_close(p_receipt_id bigint, p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    r pick_receipts%ROWTYPE;
    n int;
BEGIN
    SELECT * INTO r FROM pick_receipts WHERE id = p_receipt_id FOR UPDATE;
    IF NOT FOUND OR r.status <> 'receiving' THEN
        RAISE EXCEPTION 'picking: закрыть можно приёмку, по которой начат приём';
    END IF;
    INSERT INTO pick_discrepancies (source, warehouse_id, sku, receipt_id, expected_qty, actual_qty, reason, responsible, comment, created_by)
    SELECT 'receipt', r.warehouse_id, l.sku, r.id, l.expected_qty, l.received_qty,
           CASE WHEN l.received_qty < l.expected_qty THEN 'supplier_short' ELSE 'supplier_over' END,
           r.supplier_name, 'Приёмка ' || r.receipt_no, p_actor
    FROM pick_receipt_lines l
    WHERE l.receipt_id = r.id AND l.received_qty <> l.expected_qty;
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE pick_receipts SET status = 'done', updated_by = p_actor WHERE id = r.id;
    RETURN n;
END $$;

-- Перемещение между ячейками или списание (p_to_cell_payload пусто, причина обязательна).
CREATE OR REPLACE FUNCTION pick_move(p_item_payload text, p_from_cell_payload text, p_to_cell_payload text,
                                     p_qty numeric, p_actor text, p_reason text DEFAULT NULL)
RETURNS TABLE (ok boolean, error_code text, message text)
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
#variable_conflict use_column
DECLARE
    s       record;
    v_lot   bigint;
    v_from  bigint;
    v_to    bigint;
    v_wh1   text;
    v_wh2   text;
    v_have  numeric;
    v_track boolean;
    v_ok    boolean := false;
    v_code  text;
    v_msg   text;
BEGIN
    <<chk>>
    BEGIN
        s := pick_parse(p_item_payload);
        IF s.kind NOT IN ('lot', 'sku') THEN v_code := 'unknown_code'; v_msg := 'Код товара не распознан'; EXIT chk; END IF;
        SELECT i.track_lots INTO v_track FROM src_pick_items i WHERE i.sku = s.sku;
        IF s.kind = 'sku' AND coalesce(v_track, false) THEN v_code := 'scan_lot_label'; v_msg := 'Сканируйте этикетку партии'; EXIT chk; END IF;
        IF s.kind = 'lot' THEN
            SELECT x.id INTO v_lot FROM pick_lots x WHERE x.sku = s.sku AND x.lot_no = s.lot_no;
            IF v_lot IS NULL THEN v_code := 'unknown_lot'; v_msg := 'Партия не найдена'; EXIT chk; END IF;
        END IF;
        SELECT cc.id, z.warehouse_id INTO v_from, v_wh1 FROM pick_cells cc JOIN pick_zones z ON z.id = cc.zone_id
        WHERE 'AIRL:CELL:' || cc.code = btrim(p_from_cell_payload);
        IF v_from IS NULL THEN v_code := 'wrong_cell'; v_msg := 'Ячейка «откуда» не распознана'; EXIT chk; END IF;
        IF p_to_cell_payload IS NOT NULL THEN
            SELECT cc.id, z.warehouse_id INTO v_to, v_wh2 FROM pick_cells cc JOIN pick_zones z ON z.id = cc.zone_id
            WHERE 'AIRL:CELL:' || cc.code = btrim(p_to_cell_payload) AND NOT cc.archived;
            IF v_to IS NULL THEN v_code := 'wrong_cell'; v_msg := 'Ячейка «куда» не распознана'; EXIT chk; END IF;
            IF v_wh1 <> v_wh2 THEN v_code := 'other_warehouse'; v_msg := 'Перемещение между складами — документом в 1С'; EXIT chk; END IF;
            IF v_from = v_to THEN v_code := 'same_cell'; v_msg := 'Ячейки совпадают'; EXIT chk; END IF;
        ELSIF p_reason IS NULL THEN
            v_code := 'need_reason'; v_msg := 'Для списания укажите причину'; EXIT chk;
        END IF;
        IF p_qty IS NULL OR p_qty <= 0 THEN v_code := 'bad_qty'; v_msg := 'Количество должно быть больше нуля'; EXIT chk; END IF;
        PERFORM pick_lock_stock(v_from, s.sku, v_lot);
        v_have := pick_balance(v_from, s.sku, v_lot);
        IF v_have < p_qty THEN v_code := 'no_stock'; v_msg := 'В ячейке только ' || v_have; EXIT chk; END IF;
        INSERT INTO pick_moves (kind, sku, lot_id, from_cell_id, to_cell_id, qty, reason, created_by)
        VALUES (CASE WHEN v_to IS NULL THEN 'write_off' ELSE 'move' END, s.sku, v_lot, v_from, v_to, p_qty, p_reason, p_actor);
        v_ok := true; v_msg := CASE WHEN v_to IS NULL THEN 'Списано ' ELSE 'Перемещено ' END || p_qty;
    END chk;
    PERFORM pick_log_scan('move', p_actor, NULL, NULL, NULL, NULL, NULL, p_item_payload, s.sku, v_lot, p_qty, v_ok, v_code, v_msg);
    RETURN QUERY SELECT v_ok, CASE WHEN v_ok THEN NULL ELSE v_code END, v_msg;
END $$;

-- Пересчёт: ячейка + товар/партия + количество. Повторное сканирование той же
-- позиции в ячейке заменяет число (пересчитали заново).
CREATE OR REPLACE FUNCTION pick_count_scan(p_count_id bigint, p_cell_payload text, p_item_payload text,
                                           p_qty numeric, p_actor text)
RETURNS TABLE (ok boolean, error_code text, message text)
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
#variable_conflict use_column
DECLARE
    k       pick_counts%ROWTYPE;
    s       record;
    v_cell  bigint;
    v_lot   bigint;
    v_track boolean;
    v_ok    boolean := false;
    v_code  text;
    v_msg   text;
    v_cid   bigint;
BEGIN
    <<chk>>
    BEGIN
        SELECT * INTO k FROM pick_counts x WHERE x.id = p_count_id FOR UPDATE;
        IF NOT FOUND THEN v_code := 'count_not_found'; v_msg := 'Пересчёт не найден'; EXIT chk; END IF;
        v_cid := k.id;
        IF k.status NOT IN ('open', 'counting') THEN v_code := 'count_closed'; v_msg := 'Пересчёт закрыт'; EXIT chk; END IF;
        SELECT cc.id INTO v_cell FROM pick_cells cc JOIN pick_zones z ON z.id = cc.zone_id
        WHERE 'AIRL:CELL:' || cc.code = btrim(p_cell_payload) AND z.warehouse_id = k.warehouse_id
          AND (k.zone_id IS NULL AND z.kind = 'storage' OR z.id = k.zone_id);
        IF v_cell IS NULL THEN v_code := 'wrong_cell'; v_msg := 'Ячейка не входит в пересчёт'; EXIT chk; END IF;
        s := pick_parse(p_item_payload);
        IF s.kind NOT IN ('lot', 'sku') THEN v_code := 'unknown_code'; v_msg := 'Код товара не распознан'; EXIT chk; END IF;
        SELECT i.track_lots INTO v_track FROM src_pick_items i WHERE i.sku = s.sku;
        IF NOT FOUND THEN v_code := 'unknown_item'; v_msg := 'Товара нет в справочнике'; EXIT chk; END IF;
        IF s.kind = 'sku' AND v_track THEN v_code := 'scan_lot_label'; v_msg := 'Сканируйте этикетку партии'; EXIT chk; END IF;
        IF s.kind = 'lot' THEN
            SELECT x.id INTO v_lot FROM pick_lots x WHERE x.sku = s.sku AND x.lot_no = s.lot_no;
            IF v_lot IS NULL THEN v_code := 'unknown_lot'; v_msg := 'Партия не найдена — напечатайте этикетку на приёмке'; EXIT chk; END IF;
        END IF;
        IF p_qty IS NULL OR p_qty < 0 THEN v_code := 'bad_qty'; v_msg := 'Количество не может быть отрицательным'; EXIT chk; END IF;
        INSERT INTO pick_count_lines (count_id, cell_id, sku, lot_id, counted_qty, counted_by, created_by)
        VALUES (k.id, v_cell, s.sku, v_lot, p_qty, p_actor, p_actor)
        ON CONFLICT (count_id, cell_id, sku, (coalesce(lot_id, 0)))
        DO UPDATE SET counted_qty = EXCLUDED.counted_qty, counted_at = now(), counted_by = EXCLUDED.counted_by, updated_by = p_actor;
        IF k.status = 'open' THEN UPDATE pick_counts x SET status = 'counting', updated_by = p_actor WHERE x.id = k.id; END IF;
        v_ok := true; v_msg := 'Записано ' || p_qty;
    END chk;
    PERFORM pick_log_scan('count', p_actor, NULL, NULL, NULL, v_cid, NULL, p_item_payload, s.sku, v_lot, p_qty, v_ok, v_code, v_msg);
    RETURN QUERY SELECT v_ok, CASE WHEN v_ok THEN NULL ELSE v_code END, v_msg;
END $$;

-- Закрыть пересчёт: то, что числится в ячейках пересчёта, но не отсканировано, считается
-- нулём; разница проводится корректировкой и пишется в расхождения. Возвращает число расхождений.
CREATE OR REPLACE FUNCTION pick_count_close(p_count_id bigint, p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    k pick_counts%ROWTYPE;
    r record;
    n int := 0;
BEGIN
    SELECT * INTO k FROM pick_counts WHERE id = p_count_id FOR UPDATE;
    IF NOT FOUND OR k.status <> 'counting' THEN RAISE EXCEPTION 'picking: закрыть можно начатый пересчёт'; END IF;

    INSERT INTO pick_count_lines (count_id, cell_id, sku, lot_id, counted_qty, counted_by, created_by)
    SELECT k.id, s.cell_id, s.sku, s.lot_id, 0, 'not_found', p_actor
    FROM v_pick_stock s
    JOIN pick_cells c ON c.id = s.cell_id
    WHERE s.warehouse_id = k.warehouse_id AND s.qty > 0
      AND (k.zone_id IS NULL AND s.zone_kind = 'storage' OR c.zone_id = k.zone_id)
      AND NOT EXISTS (SELECT 1 FROM pick_count_lines x WHERE x.count_id = k.id AND x.cell_id = s.cell_id
                        AND x.sku = s.sku AND coalesce(x.lot_id, 0) = coalesce(s.lot_id, 0));

    FOR r IN SELECT * FROM pick_count_lines WHERE count_id = k.id ORDER BY id FOR UPDATE LOOP
        PERFORM pick_lock_stock(r.cell_id, r.sku, r.lot_id);
        UPDATE pick_count_lines SET system_qty = pick_balance(r.cell_id, r.sku, r.lot_id), updated_by = p_actor
        WHERE id = r.id RETURNING * INTO r;
        IF r.diff_qty > 0 THEN
            INSERT INTO pick_moves (kind, sku, lot_id, to_cell_id, qty, count_id, created_by)
            VALUES ('adjust', r.sku, r.lot_id, r.cell_id, r.diff_qty, k.id, p_actor);
        ELSIF r.diff_qty < 0 THEN
            INSERT INTO pick_moves (kind, sku, lot_id, from_cell_id, qty, count_id, created_by)
            VALUES ('adjust', r.sku, r.lot_id, r.cell_id, -r.diff_qty, k.id, p_actor);
        END IF;
        IF r.diff_qty <> 0 THEN
            INSERT INTO pick_discrepancies (source, warehouse_id, sku, lot_id, cell_id, count_id, expected_qty, actual_qty, comment, created_by)
            VALUES ('count', k.warehouse_id, r.sku, r.lot_id, r.cell_id, k.id, r.system_qty, r.counted_qty, 'Пересчёт ' || k.count_no, p_actor);
            n := n + 1;
        END IF;
    END LOOP;
    UPDATE pick_counts SET status = 'closed', updated_by = p_actor WHERE id = k.id;
    RETURN n;
END $$;

-- Уведомления по сроку: задание не отгружено к ship_by (за late_warn_minutes),
-- партия на складе истекает через expiry_warn_days. Запускать каждые 15 минут.
CREATE OR REPLACE FUNCTION pick_plan_notifications() RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_to text := airl_setting('picking', 'head_recipient', '"warehouse_head"') #>> '{}';
    v_ch text := airl_setting('picking', 'channel', '"telegram"') #>> '{}';
    n int; k int;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'picking:late:' || t.id || ':' || v_to, 'picking', v_ch, v_to,
           'Задание ' || t.task_no || ' не отгружено к ' || to_char(t.ship_by, 'DD.MM HH24:MI') || ' (статус ' || t.status || ')'
    FROM pick_tasks t
    WHERE t.status IN ('new', 'assigned', 'picking', 'picked', 'checked')
      AND t.ship_by < now() + make_interval(mins => (airl_setting('picking', 'late_warn_minutes', '60'))::text::int)
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'picking:expiry:' || s.lot_id || ':' || v_to, 'picking', v_ch, v_to,
           'Партия ' || s.lot_no || ' (' || s.sku || ') истекает ' || to_char(min(s.expiry_date), 'DD.MM.YYYY') || ', на складе ' || sum(s.qty)
    FROM v_pick_stock s
    WHERE s.expiry_date <= current_date + (airl_setting('picking', 'expiry_warn_days', '30'))::text::int
    GROUP BY s.lot_id, s.lot_no, s.sku
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT;
    RETURN n + k;
END $$;

-- ───────────── Экраны ─────────────

-- «Сборка»: очередь заданий, срочные сверху.
CREATE OR REPLACE VIEW v_pick_tasks AS
SELECT t.id, t.task_no, t.order_id, o.order_no, o.client_id, o.client_name, t.warehouse_id, t.ship_by,
       t.status, t.assigned_to, t.assigned_at, t.started_at, t.picked_at, t.checked_at, t.checked_by, t.shipped_at,
       count(l.id) AS lines_total,
       count(l.id) FILTER (WHERE l.done_at IS NOT NULL) AS lines_done,
       count(l.id) FILTER (WHERE l.qty_short > 0) AS lines_short,
       (t.status NOT IN ('shipped', 'cancelled') AND t.ship_by < now()) AS late,
       (t.picked_at - t.started_at) AS pick_duration,
       t.cancel_reason
FROM pick_tasks t
LEFT JOIN src_pick_orders o ON o.order_id = t.order_id
LEFT JOIN pick_task_lines l ON l.task_id = t.id
GROUP BY t.id, o.order_no, o.client_id, o.client_name;

-- Экран сборщика: строка задания, куда идти и какую партию брать (FEFO на сейчас).
CREATE OR REPLACE VIEW v_pick_task_lines AS
SELECT l.id, l.task_id, t.task_no, t.status AS task_status, t.assigned_to, l.line_no, l.sku, i.sku_name, i.unit,
       l.qty, l.qty_picked, l.qty_short, (l.qty - l.qty_picked - l.qty_short) AS qty_left, l.short_reason,
       sl.lot_no AS suggested_lot_no, sc.code AS suggested_cell_code,
       f.lot_no AS next_lot_no, f.expiry_date AS next_lot_expiry, f.cell_code AS next_cell_code, f.qty AS next_cell_qty,
       l.done_at
FROM pick_task_lines l
JOIN pick_tasks t ON t.id = l.task_id
LEFT JOIN src_pick_items i ON i.sku = l.sku
LEFT JOIN pick_lots sl ON sl.id = l.suggested_lot_id
LEFT JOIN pick_cells sc ON sc.id = l.suggested_cell_id
LEFT JOIN LATERAL (SELECT ff.lot_no, ff.expiry_date, ff.cell_code, ff.qty FROM pick_fefo(t.warehouse_id, l.sku) ff LIMIT 1) f
       ON l.done_at IS NULL;

-- FEFO по складу: партии каждого товара в порядке отгрузки.
CREATE OR REPLACE VIEW v_pick_fefo AS
SELECT a.warehouse_id, a.sku, a.sku_name, a.lot_no, a.expiry_date, a.days_left, a.cell_code, a.qty,
       dense_rank() OVER (PARTITION BY a.warehouse_id, a.sku ORDER BY coalesce(a.expiry_date, 'infinity'::date), a.lot_id) AS fefo_rank
FROM v_pick_available a;

CREATE OR REPLACE VIEW v_pick_expiring AS
SELECT s.warehouse_id, s.sku, s.sku_name, s.lot_no, s.expiry_date, s.days_left, s.cell_code, s.zone_kind, s.qty, s.hold,
       (s.days_left < 0) AS expired
FROM v_pick_stock s
WHERE s.expiry_date <= current_date + (airl_setting('picking', 'expiry_warn_days', '30'))::text::int;

-- «Приёмка».
CREATE OR REPLACE VIEW v_pick_receipts AS
SELECT r.id, r.receipt_no, r.warehouse_id, r.supplier_name, r.source_ref, r.status, r.expected_at, r.started_at, r.closed_at,
       l.line_no, l.sku, i.sku_name, l.expected_qty, l.received_qty, (l.received_qty - l.expected_qty) AS diff_qty
FROM pick_receipts r
LEFT JOIN pick_receipt_lines l ON l.receipt_id = r.id
LEFT JOIN src_pick_items i ON i.sku = l.sku;

-- «Инвентаризация»: учётное количество кладовщику не показывается до закрытия (слепой пересчёт).
CREATE OR REPLACE VIEW v_pick_counts AS
SELECT k.id, k.count_no, k.warehouse_id, z.code AS zone_code, k.status, k.started_at, k.closed_at, k.closed_by,
       count(cl.id) AS lines, count(cl.id) FILTER (WHERE cl.diff_qty <> 0) AS lines_with_diff,
       round(100.0 * count(cl.id) FILTER (WHERE cl.diff_qty = 0) / NULLIF(count(cl.id) FILTER (WHERE cl.system_qty IS NOT NULL), 0), 1) AS accuracy_pct
FROM pick_counts k
LEFT JOIN pick_zones z ON z.id = k.zone_id
LEFT JOIN pick_count_lines cl ON cl.count_id = k.id
GROUP BY k.id, z.code;

-- «Расхождения»: с оценкой в деньгах по себестоимости из справочника.
CREATE OR REPLACE VIEW v_pick_discrepancies AS
SELECT d.id, d.disc_no, d.source, d.warehouse_id, d.sku, i.sku_name, l.lot_no, c.code AS cell_code,
       t.task_no, t.order_id, r.receipt_no, k.count_no,
       d.expected_qty, d.actual_qty, d.diff_qty,
       (d.diff_qty * i.unit_cost)::numeric(18,2) AS diff_value,
       (airl_setting('picking', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}')::char(3) AS currency,
       d.reason, d.responsible, d.comment, d.status, d.resolution, d.created_at, d.created_by, d.resolved_at,
       (d.status = 'open' AND d.created_at < now() - interval '7 days') AS stale
FROM pick_discrepancies d
LEFT JOIN src_pick_items i ON i.sku = d.sku
LEFT JOIN pick_lots l ON l.id = d.lot_id
LEFT JOIN pick_cells c ON c.id = d.cell_id
LEFT JOIN pick_tasks t ON t.id = d.task_id
LEFT JOIN pick_receipts r ON r.id = d.receipt_id
LEFT JOIN pick_counts k ON k.id = d.count_id;

-- Журнал движений.
CREATE OR REPLACE VIEW v_pick_moves AS
SELECT m.id, m.created_at, m.created_by, m.kind, m.sku, l.lot_no, fc.code AS from_cell, tc.code AS to_cell, m.qty,
       t.task_no, t.order_id, m.reason
FROM pick_moves m
LEFT JOIN pick_lots l ON l.id = m.lot_id
LEFT JOIN pick_cells fc ON fc.id = m.from_cell_id
LEFT JOIN pick_cells tc ON tc.id = m.to_cell_id
LEFT JOIN pick_task_lines tl ON tl.id = m.task_line_id
LEFT JOIN pick_tasks t ON t.id = tl.task_id;

-- Отклонённые сканирования за 7 дней: кто и на чём ошибается.
CREATE OR REPLACE VIEW v_pick_scan_errors AS
SELECT s.at, s.actor, s.kind, t.task_no, s.payload, s.sku, s.error_code, s.message
FROM pick_scans s
LEFT JOIN pick_tasks t ON t.id = s.task_id
WHERE NOT s.ok AND s.at > now() - interval '7 days';

-- Производительность сборщиков по дням: строки, часы сборки, строк в час, ошибки.
CREATE OR REPLACE VIEW v_pick_productivity AS
WITH tz AS (SELECT airl_setting('picking', 'timezone', '"Asia/Almaty"') #>> '{}' AS name),
t AS (
    SELECT t.id, t.assigned_to AS picker, (t.picked_at AT TIME ZONE tz.name)::date AS day,
           extract(epoch FROM t.picked_at - t.started_at) / 3600.0 AS hours,
           (SELECT count(*) FROM pick_task_lines l WHERE l.task_id = t.id) AS lines
    FROM pick_tasks t, tz
    WHERE t.picked_at IS NOT NULL AND t.started_at IS NOT NULL
)
SELECT t.picker, t.day, count(*) AS tasks, sum(t.lines) AS lines, round(sum(t.hours)::numeric, 2) AS hours,
       round(sum(t.lines) / NULLIF(sum(t.hours), 0)::numeric, 1) AS lines_per_hour,
       (SELECT count(*) FROM pick_discrepancies d WHERE d.task_id = ANY (array_agg(t.id)) AND d.source IN ('pack', 'client')) AS errors,
       (SELECT count(*) FROM pick_scans s WHERE s.actor = t.picker AND s.kind = 'pick' AND NOT s.ok
          AND s.task_id = ANY (array_agg(t.id))) AS rejected_scans
FROM t
GROUP BY t.picker, t.day;

-- Прослеживаемость: партия → её потомки (обжарка, фасовка) → заказ → клиент.
-- Начните с зелёного лота: строки покажут, к каким клиентам он ушёл.
CREATE OR REPLACE VIEW v_pick_trace AS
WITH RECURSIVE tree AS (
    SELECT l.id AS root_lot_id, l.sku AS root_sku, l.lot_no AS root_lot_no, l.id AS lot_id, 0 AS depth,
           (l.sku || ':' || l.lot_no) AS path
    FROM pick_lots l
    UNION ALL
    SELECT tr.root_lot_id, tr.root_sku, tr.root_lot_no, k.child_lot_id, tr.depth + 1,
           tr.path || ' → ' || c.sku || ':' || c.lot_no
    FROM tree tr
    JOIN pick_lot_links k ON k.parent_lot_id = tr.lot_id
    JOIN pick_lots c ON c.id = k.child_lot_id
    WHERE tr.depth < 10
)
SELECT tr.root_lot_id, tr.root_sku, tr.root_lot_no, tr.depth, tr.path, l.sku, l.lot_no,
       t.task_no, t.order_id, o.order_no, o.client_id, o.client_name,
       sum(m.qty)::numeric(18,3) AS shipped_qty, max(m.created_at) AS shipped_at
FROM tree tr
JOIN pick_lots l ON l.id = tr.lot_id
LEFT JOIN pick_moves m ON m.lot_id = tr.lot_id AND m.kind = 'ship'
LEFT JOIN pick_task_lines tl ON tl.id = m.task_line_id
LEFT JOIN pick_tasks t ON t.id = tl.task_id
LEFT JOIN src_pick_orders o ON o.order_id = t.order_id
GROUP BY tr.root_lot_id, tr.root_sku, tr.root_lot_no, tr.depth, tr.path, l.sku, l.lot_no,
         t.task_no, t.order_id, o.order_no, o.client_id, o.client_name;

-- Сверка с 1С: остаток по движениям модуля против остатка учёта, склад × товар × партия.
CREATE OR REPLACE VIEW v_pick_reconcile AS
WITH m AS (
    SELECT s.warehouse_id, s.sku, s.lot_no, sum(s.qty) AS qty FROM v_pick_stock s GROUP BY 1, 2, 3
), a AS (
    SELECT warehouse_id, sku, lot_no, sum(qty) AS qty, max(updated_at) AS updated_at FROM src_pick_stock_1c GROUP BY 1, 2, 3
)
SELECT coalesce(m.warehouse_id, a.warehouse_id) AS warehouse_id, coalesce(m.sku, a.sku) AS sku, i.sku_name,
       coalesce(m.lot_no, a.lot_no) AS lot_no,
       coalesce(m.qty, 0)::numeric(18,3) AS module_qty, coalesce(a.qty, 0)::numeric(18,3) AS accounting_qty,
       (coalesce(m.qty, 0) - coalesce(a.qty, 0))::numeric(18,3) AS diff_qty, a.updated_at AS accounting_updated_at
FROM m
FULL JOIN a ON a.warehouse_id = m.warehouse_id AND a.sku = m.sku AND a.lot_no IS NOT DISTINCT FROM m.lot_no
LEFT JOIN src_pick_items i ON i.sku = coalesce(m.sku, a.sku);

-- Этикетки для печати: ячейки и партии. payload — текст QR.
CREATE OR REPLACE VIEW v_pick_labels AS
SELECT 'cell'::text AS label_kind, z.warehouse_id, c.code, 'AIRL:CELL:' || c.code AS payload,
       c.code AS line1, z.title || coalesce(' · ' || c.title, '') AS line2, NULL::date AS expiry_date
FROM pick_cells c JOIN pick_zones z ON z.id = c.zone_id
WHERE NOT c.archived AND NOT z.archived
UNION ALL
SELECT 'lot', NULL, l.sku || ':' || l.lot_no, 'AIRL:LOT:' || l.sku || ':' || l.lot_no,
       coalesce(i.sku_name, l.sku), 'Партия ' || l.lot_no || coalesce(' · годен до ' || to_char(l.expiry_date, 'DD.MM.YYYY'), ''),
       l.expiry_date
FROM pick_lots l LEFT JOIN src_pick_items i ON i.sku = l.sku;

-- ───────────── Показатели ─────────────

-- Доля строк с ошибкой сборки, найденной после сборки (проверка упаковки или претензия
-- клиента), к собранным строкам; по неделе сборки. Отклонённые сканирования ошибкой
-- не считаются — их поймал телефон.
CREATE OR REPLACE VIEW m_picking_error_rate AS
WITH tz AS (SELECT airl_setting('picking', 'timezone', '"Asia/Almaty"') #>> '{}' AS name),
lines AS (
    SELECT to_char(t.picked_at AT TIME ZONE tz.name, 'IYYY-"W"IW') AS week, l.task_id, l.sku
    FROM pick_task_lines l JOIN pick_tasks t ON t.id = l.task_id, tz
    WHERE t.picked_at IS NOT NULL AND l.qty_picked > 0
), err AS (
    SELECT DISTINCT d.task_id, d.sku FROM pick_discrepancies d
    WHERE d.source IN ('pack', 'client') AND d.status <> 'cancelled' AND d.task_id IS NOT NULL
)
SELECT 'picking_error_rate'::text AS metric_id, x.week AS period, x.value, '%'::text AS unit,
       airl_traffic(x.value, (airl_setting('picking', 'error_warn', '0.5'))::text::numeric,
                    (airl_setting('picking', 'error_bad', '1.0'))::text::numeric, false) AS status
FROM (SELECT ln.week,
             round(100.0 * count(*) FILTER (WHERE e.task_id IS NOT NULL) / NULLIF(count(*), 0), 2) AS value
      FROM lines ln LEFT JOIN err e ON e.task_id = ln.task_id AND e.sku = ln.sku
      GROUP BY ln.week) x;

-- Строк в час: все строки собранных заданий / часы от первого сканирования до «собрано»; по неделе.
CREATE OR REPLACE VIEW m_picking_lines_per_hour AS
WITH tz AS (SELECT airl_setting('picking', 'timezone', '"Asia/Almaty"') #>> '{}' AS name),
t AS (
    SELECT to_char(t.picked_at AT TIME ZONE tz.name, 'IYYY-"W"IW') AS week,
           extract(epoch FROM t.picked_at - t.started_at) / 3600.0 AS hours,
           (SELECT count(*) FROM pick_task_lines l WHERE l.task_id = t.id) AS lines
    FROM pick_tasks t, tz
    WHERE t.picked_at IS NOT NULL AND t.started_at IS NOT NULL
)
SELECT 'picking_lines_per_hour'::text AS metric_id, t.week AS period,
       round((sum(t.lines) / NULLIF(sum(t.hours), 0))::numeric, 1) AS value, 'строк/ч'::text AS unit,
       airl_traffic(round((sum(t.lines) / NULLIF(sum(t.hours), 0))::numeric, 1),
                    (airl_setting('picking', 'lph_warn', '40'))::text::numeric,
                    (airl_setting('picking', 'lph_bad', '25'))::text::numeric, true) AS status
FROM t
GROUP BY t.week;

-- Точность остатков: доля позиций пересчёта (ячейка × товар × партия), где факт совпал
-- с движениями модуля; по месяцу закрытия пересчёта.
CREATE OR REPLACE VIEW m_inventory_accuracy AS
WITH tz AS (SELECT airl_setting('picking', 'timezone', '"Asia/Almaty"') #>> '{}' AS name)
SELECT 'inventory_accuracy'::text AS metric_id,
       to_char(k.closed_at AT TIME ZONE tz.name, 'YYYY-MM') AS period,
       round(100.0 * count(*) FILTER (WHERE cl.diff_qty = 0) / NULLIF(count(*), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(round(100.0 * count(*) FILTER (WHERE cl.diff_qty = 0) / NULLIF(count(*), 0), 2),
                    (airl_setting('picking', 'accuracy_warn', '98'))::text::numeric,
                    (airl_setting('picking', 'accuracy_bad', '95'))::text::numeric, true) AS status
FROM pick_counts k
JOIN pick_count_lines cl ON cl.count_id = k.id, tz
WHERE k.status = 'closed'
GROUP BY to_char(k.closed_at AT TIME ZONE tz.name, 'YYYY-MM');
