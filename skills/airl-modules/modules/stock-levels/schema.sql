-- Модуль «Остатки, дефицит, неликвиды» (stock-levels). Требует kit/kit.sql в той же
-- схеме и представления src_stock, src_sales_daily (адаптер или demo_src.sql).
-- Модуль не двигает товар и не меняет остатки в учётной системе: он показывает,
-- где мало, где лишнее, что истекает, и предлагает закупку. Решает человек.

-- Мин/макс по товару и складу. Пустое поле = считается автоматически из настроек.
CREATE TABLE IF NOT EXISTS stk_limits (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku            text          NOT NULL,
    warehouse_id   text          NOT NULL,
    min_qty        numeric(18,3) CHECK (min_qty IS NULL OR min_qty >= 0),
    max_qty        numeric(18,3) CHECK (max_qty IS NULL OR max_qty >= 0),
    lead_time_days int           CHECK (lead_time_days IS NULL OR lead_time_days >= 0),
    safety_days    int           CHECK (safety_days IS NULL OR safety_days >= 0),
    order_multiple numeric(18,3) CHECK (order_multiple IS NULL OR order_multiple > 0),
    note           text,
    archived       boolean       NOT NULL DEFAULT false,
    created_at     timestamptz   NOT NULL DEFAULT now(),
    created_by     text          NOT NULL,
    updated_at     timestamptz,
    updated_by     text,
    UNIQUE (sku, warehouse_id),
    CHECK (min_qty IS NULL OR max_qty IS NULL OR min_qty <= max_qty)
);

-- Журнал расхождений: пересчитали — не сошлось с учётом. Корректировку в учёте
-- проводит человек, модуль хранит факт, причину и ответственного.
CREATE TABLE IF NOT EXISTS stk_discrepancies (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_no        text          NOT NULL UNIQUE,
    sku           text          NOT NULL,
    warehouse_id  text          NOT NULL,
    batch         text,
    system_qty    numeric(18,3) NOT NULL,
    counted_qty   numeric(18,3) NOT NULL CHECK (counted_qty >= 0),
    diff_qty      numeric(18,3) GENERATED ALWAYS AS (counted_qty - system_qty) STORED,
    reason        text          NOT NULL CHECK (reason IN ('pick_error', 'receipt_error', 'not_posted',
                      'damage', 'expired', 'theft_suspected', 'unit_mismatch', 'unknown')),
    responsible   text,
    comment       text,
    status        text          NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'cancelled')),
    resolution    text,
    counted_at    timestamptz   NOT NULL,
    counted_by    text          NOT NULL,
    created_at    timestamptz   NOT NULL DEFAULT now(),
    created_by    text          NOT NULL,
    updated_at    timestamptz,
    updated_by    text,
    CHECK (status <> 'resolved' OR resolution IS NOT NULL),
    CHECK (reason <> 'unknown' OR comment IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS stk_discrepancies_sku_idx ON stk_discrepancies (sku, warehouse_id, counted_at);

-- Предложения закупки. Создаёт функция stk_generate_suggestions(), дальше решает закупщик.
CREATE TABLE IF NOT EXISTS stk_suggestions (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku            text          NOT NULL,
    warehouse_id   text          NOT NULL,
    suggested_on   date          NOT NULL DEFAULT current_date,
    on_hand_qty    numeric(18,3) NOT NULL,
    avg_daily_qty  numeric(18,3) NOT NULL,
    min_qty        numeric(18,3) NOT NULL,
    max_qty        numeric(18,3) NOT NULL,
    suggested_qty  numeric(18,3) NOT NULL CHECK (suggested_qty > 0),
    status         text          NOT NULL DEFAULT 'suggested'
                   CHECK (status IN ('suggested', 'accepted', 'ordered', 'dismissed')),
    accepted_qty   numeric(18,3) CHECK (accepted_qty IS NULL OR accepted_qty > 0),
    order_ref      text,
    ordered_at     timestamptz,
    dismiss_reason text,
    created_at     timestamptz   NOT NULL DEFAULT now(),
    created_by     text          NOT NULL,
    updated_at     timestamptz,
    updated_by     text,
    UNIQUE (sku, warehouse_id, suggested_on),
    CHECK (status <> 'dismissed' OR dismiss_reason IS NOT NULL),
    CHECK (status <> 'ordered' OR (order_ref IS NOT NULL AND ordered_at IS NOT NULL))
);

DROP TRIGGER IF EXISTS stk_limits_touch ON stk_limits;
CREATE TRIGGER stk_limits_touch BEFORE UPDATE ON stk_limits FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS stk_discrepancies_touch ON stk_discrepancies;
CREATE TRIGGER stk_discrepancies_touch BEFORE UPDATE ON stk_discrepancies FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS stk_suggestions_touch ON stk_suggestions;
CREATE TRIGGER stk_suggestions_touch BEFORE UPDATE ON stk_suggestions FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Переходы статусов предложения и журнал: suggested → accepted → ordered; suggested|accepted → dismissed.
CREATE OR REPLACE FUNCTION stk_suggestion_status() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT ((OLD.status = 'suggested' AND NEW.status IN ('accepted', 'dismissed'))
             OR (OLD.status = 'accepted'  AND NEW.status IN ('ordered', 'dismissed'))) THEN
            RAISE EXCEPTION 'stock-levels: переход % → % не разрешён', OLD.status, NEW.status;
        END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
        VALUES (coalesce(NEW.updated_by, 'system'), 'stock-levels', 'stk_suggestions', NEW.id::text,
                'status', OLD.status, NEW.status, NEW.dismiss_reason);
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS stk_suggestions_status ON stk_suggestions;
CREATE TRIGGER stk_suggestions_status BEFORE UPDATE ON stk_suggestions FOR EACH ROW EXECUTE FUNCTION stk_suggestion_status();

-- Средние продажи (расход) в день за окно sales_window_days и дата последней продажи.
CREATE OR REPLACE VIEW v_stk_sales_rate AS
SELECT s.sku, s.warehouse_id,
       round(coalesce(sum(s.qty_out) FILTER (WHERE s.day >= current_date - w.days), 0) / w.days, 3)::numeric(18,3) AS avg_daily_qty,
       max(s.day) FILTER (WHERE s.qty_out > 0) AS last_sale_day
FROM src_sales_daily s
CROSS JOIN (SELECT greatest((airl_setting('stock-levels', 'sales_window_days', '60'))::text::int, 1) AS days) w
GROUP BY s.sku, s.warehouse_id, w.days;

-- Главное представление: позиция = товар × склад. Остаток (без просроченных партий),
-- покрытие в днях, мин/макс, состояние.
CREATE OR REPLACE VIEW v_stk_levels AS
WITH cfg AS (
    SELECT (airl_setting('stock-levels', 'lead_time_days', '14'))::text::int   AS lead_time_days,
           (airl_setting('stock-levels', 'safety_days', '7'))::text::int       AS safety_days,
           (airl_setting('stock-levels', 'order_cycle_days', '14'))::text::int AS order_cycle_days,
           (airl_setting('stock-levels', 'slow_days', '60'))::text::int        AS slow_days
), onhand AS (
    SELECT sku, warehouse_id, max(sku_name) AS sku_name, max(unit) AS unit,
           sum(qty) FILTER (WHERE expiry_date IS NULL OR expiry_date >= current_date) AS qty,
           sum(qty) FILTER (WHERE expiry_date < current_date) AS expired_qty,
           sum(qty * unit_cost) AS stock_value,
           max(currency) AS currency,
           max(updated_at) AS stock_updated_at,
           min(expiry_date) FILTER (WHERE qty > 0) AS nearest_expiry
    FROM src_stock
    GROUP BY sku, warehouse_id
), keys AS (
    SELECT sku, warehouse_id FROM onhand
    UNION SELECT sku, warehouse_id FROM v_stk_sales_rate WHERE avg_daily_qty > 0
    UNION SELECT sku, warehouse_id FROM stk_limits WHERE NOT archived
), calc AS (
    SELECT k.sku, k.warehouse_id,
           coalesce(o.sku_name, k.sku) AS sku_name, o.unit,
           coalesce(o.qty, 0)::numeric(18,3) AS on_hand_qty,
           coalesce(o.expired_qty, 0)::numeric(18,3) AS expired_qty,
           o.stock_value::numeric(18,2) AS stock_value, o.currency,
           o.stock_updated_at, o.nearest_expiry,
           coalesce(r.avg_daily_qty, 0)::numeric(18,3) AS avg_daily_qty,
           r.last_sale_day,
           coalesce(l.lead_time_days, c.lead_time_days) AS lead_time_days,
           coalesce(l.safety_days, c.safety_days) AS safety_days,
           l.order_multiple,
           CASE WHEN l.min_qty IS NOT NULL THEN 'manual' ELSE 'auto' END AS limit_source,
           coalesce(l.min_qty,
                    ceil(coalesce(r.avg_daily_qty, 0) * (coalesce(l.lead_time_days, c.lead_time_days) + coalesce(l.safety_days, c.safety_days))))::numeric(18,3) AS min_qty,
           l.max_qty AS manual_max_qty,
           c.order_cycle_days, c.slow_days
    FROM keys k
    CROSS JOIN cfg c
    LEFT JOIN onhand o ON o.sku = k.sku AND o.warehouse_id = k.warehouse_id
    LEFT JOIN v_stk_sales_rate r ON r.sku = k.sku AND r.warehouse_id = k.warehouse_id
    LEFT JOIN stk_limits l ON l.sku = k.sku AND l.warehouse_id = k.warehouse_id AND NOT l.archived
)
SELECT sku, warehouse_id, sku_name, unit, on_hand_qty, expired_qty, stock_value, currency, stock_updated_at, nearest_expiry,
       avg_daily_qty, last_sale_day, lead_time_days, safety_days, limit_source, min_qty,
       coalesce(manual_max_qty, min_qty + ceil(avg_daily_qty * order_cycle_days))::numeric(18,3) AS max_qty,
       CASE WHEN avg_daily_qty > 0 THEN round(on_hand_qty / avg_daily_qty, 1) END::numeric(10,1) AS days_of_cover,
       CASE
           WHEN min_qty > 0 AND on_hand_qty <= min_qty THEN 'deficit'
           WHEN on_hand_qty > 0 AND (last_sale_day IS NULL OR last_sale_day < current_date - slow_days) THEN 'slow'
           WHEN on_hand_qty > coalesce(manual_max_qty, min_qty + ceil(avg_daily_qty * order_cycle_days))
                AND coalesce(manual_max_qty, min_qty + ceil(avg_daily_qty * order_cycle_days)) > 0 THEN 'excess'
           ELSE 'ok'
       END::text AS state,
       CASE WHEN min_qty > 0 AND on_hand_qty <= min_qty THEN
           (CASE WHEN order_multiple IS NULL
                 THEN ceil(coalesce(manual_max_qty, min_qty + ceil(avg_daily_qty * order_cycle_days)) - on_hand_qty)
                 ELSE ceil((coalesce(manual_max_qty, min_qty + ceil(avg_daily_qty * order_cycle_days)) - on_hand_qty) / order_multiple) * order_multiple
            END)
       END::numeric(18,3) AS to_order_qty
FROM calc;

-- Экран «Дефицит»: ниже минимума, самые срочные сверху.
CREATE OR REPLACE VIEW v_stk_deficit AS
SELECT l.*,
       (l.days_of_cover IS NOT NULL AND l.days_of_cover < l.lead_time_days) AS critical,
       EXISTS (SELECT 1 FROM stk_suggestions s
               WHERE s.sku = l.sku AND s.warehouse_id = l.warehouse_id
                 AND s.status IN ('suggested', 'accepted', 'ordered')
                 AND s.suggested_on >= current_date - (l.lead_time_days + l.safety_days)) AS has_open_suggestion
FROM v_stk_levels l
WHERE l.state = 'deficit';

-- Экран «Неликвиды и излишки»: нет продаж slow_days дней или остаток выше максимума.
CREATE OR REPLACE VIEW v_stk_slow AS
SELECT l.sku, l.warehouse_id, l.sku_name, l.unit, l.on_hand_qty, l.stock_value, l.currency,
       l.last_sale_day,
       (current_date - l.last_sale_day) AS days_without_sales,
       l.max_qty, l.days_of_cover, l.state
FROM v_stk_levels l
WHERE l.state IN ('slow', 'excess');

-- Экран «Истекает срок»: партии по FEFO — первой уходит та, у которой срок раньше.
CREATE OR REPLACE VIEW v_stk_expiring AS
SELECT s.sku, s.sku_name, s.warehouse_id, s.batch, s.qty, s.unit, s.expiry_date,
       (s.expiry_date - current_date) AS days_left,
       (s.expiry_date < current_date) AS expired,
       (s.qty * s.unit_cost)::numeric(18,2) AS batch_value, s.currency,
       row_number() OVER (PARTITION BY s.sku, s.warehouse_id ORDER BY s.expiry_date, s.batch) AS fefo_order
FROM src_stock s
WHERE s.expiry_date IS NOT NULL AND s.qty > 0
  AND s.expiry_date <= current_date + (airl_setting('stock-levels', 'expiry_warn_days', '30'))::text::int;

-- Экран «Предложения закупки».
CREATE OR REPLACE VIEW v_stk_suggestions AS
SELECT s.id, s.sku, l.sku_name, s.warehouse_id, l.unit, s.suggested_on, s.status,
       s.on_hand_qty AS on_hand_at_suggestion, l.on_hand_qty AS on_hand_now,
       s.avg_daily_qty, s.min_qty, s.max_qty, s.suggested_qty, s.accepted_qty,
       s.order_ref, s.ordered_at, s.dismiss_reason, l.days_of_cover,
       s.created_by, s.updated_by, s.updated_at
FROM stk_suggestions s
LEFT JOIN v_stk_levels l ON l.sku = s.sku AND l.warehouse_id = s.warehouse_id;

-- Экран «Расхождения»: журнал пересчётов с оценкой в деньгах.
CREATE OR REPLACE VIEW v_stk_discrepancies AS
SELECT d.id, d.doc_no, d.sku, coalesce(p.sku_name, d.sku) AS sku_name, d.warehouse_id, d.batch,
       d.system_qty, d.counted_qty, d.diff_qty,
       (d.diff_qty * p.unit_cost)::numeric(18,2) AS diff_value, p.currency,
       d.reason, d.responsible, d.comment, d.status, d.resolution, d.counted_at, d.counted_by
FROM stk_discrepancies d
LEFT JOIN LATERAL (
    SELECT max(s.sku_name) AS sku_name, max(s.unit_cost) AS unit_cost, max(s.currency) AS currency
    FROM src_stock s WHERE s.sku = d.sku
) p ON true;

-- Создать предложения закупки по дефициту. Повторный вызов в тот же день ничего не дублирует.
CREATE OR REPLACE FUNCTION stk_generate_suggestions(p_actor text) RETURNS int LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE n int;
BEGIN
    INSERT INTO stk_suggestions (sku, warehouse_id, suggested_on, on_hand_qty, avg_daily_qty,
                                 min_qty, max_qty, suggested_qty, created_by)
    SELECT d.sku, d.warehouse_id, current_date, d.on_hand_qty, d.avg_daily_qty, d.min_qty, d.max_qty,
           d.to_order_qty, p_actor
    FROM v_stk_deficit d
    WHERE d.to_order_qty > 0
      AND NOT d.has_open_suggestion
      AND NOT EXISTS (SELECT 1 FROM stk_suggestions s
                      WHERE s.sku = d.sku AND s.warehouse_id = d.warehouse_id AND s.status = 'dismissed'
                        AND s.updated_at > now() - make_interval(days => (airl_setting('stock-levels', 'dismiss_snooze_days', '7'))::text::int))
    ON CONFLICT (sku, warehouse_id, suggested_on) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- Показатель: медиана покрытия в днях по позициям, которые продаются (на сегодня).
CREATE OR REPLACE VIEW m_stock_days AS
WITH v AS (
    SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY days_of_cover)::numeric, 1) AS value
    FROM v_stk_levels WHERE avg_daily_qty > 0
), cfg AS (
    SELECT (airl_setting('stock-levels', 'lead_time_days', '14'))::text::numeric AS lead,
           (airl_setting('stock-levels', 'safety_days', '7'))::text::numeric AS safety,
           (airl_setting('stock-levels', 'cover_high_days', '90'))::text::numeric AS high
)
SELECT 'stock_days'::text AS metric_id,
       to_char(current_date, 'YYYY-MM-DD') AS period,
       v.value,
       'дн'::text AS unit,
       CASE WHEN v.value IS NULL THEN 'warning'
            WHEN v.value < cfg.lead THEN 'danger'
            WHEN v.value < cfg.lead + cfg.safety OR v.value > cfg.high THEN 'warning'
            ELSE 'ok' END::text AS status
FROM v, cfg;

-- Показатель: сколько позиций ниже минимума (на сегодня).
CREATE OR REPLACE VIEW m_stock_deficit_count AS
SELECT 'stock_deficit_count'::text AS metric_id,
       to_char(current_date, 'YYYY-MM-DD') AS period,
       count(*)::numeric AS value,
       'поз.'::text AS unit,
       airl_traffic(count(*),
           (airl_setting('stock-levels', 'deficit_warn', '1'))::text::numeric,
           (airl_setting('stock-levels', 'deficit_bad', '5'))::text::numeric,
           false) AS status
FROM v_stk_deficit;

-- Показатель: стоимость неликвидов (state = 'slow') по себестоимости; без цен — число позиций.
-- Светофор — по доле неликвидов в стоимости всего запаса.
CREATE OR REPLACE VIEW m_slow_movers_value AS
WITH t AS (
    SELECT sum(stock_value) FILTER (WHERE state = 'slow') AS slow_value,
           sum(stock_value) AS total_value,
           count(*) FILTER (WHERE state = 'slow') AS slow_count,
           count(stock_value) AS priced
    FROM v_stk_levels
)
SELECT 'slow_movers_value'::text AS metric_id,
       to_char(current_date, 'YYYY-MM-DD') AS period,
       (CASE WHEN t.priced > 0 THEN coalesce(t.slow_value, 0) ELSE t.slow_count END)::numeric AS value,
       (CASE WHEN t.priced > 0 THEN airl_setting('stock-levels', 'currency', '"KZT"') #>> '{}' ELSE 'поз.' END)::text AS unit,
       (CASE WHEN t.priced > 0 THEN
            airl_traffic(round(100 * coalesce(t.slow_value, 0) / NULLIF(t.total_value, 0), 2),
                (airl_setting('stock-levels', 'slow_share_warn', '10'))::text::numeric,
                (airl_setting('stock-levels', 'slow_share_bad', '20'))::text::numeric, false)
        ELSE airl_traffic(t.slow_count, 1, 5, false) END)::text AS status
FROM t;
