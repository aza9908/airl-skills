-- Очереди интеграционного сервиса AIRL: outbox (запись во внешние системы)
-- и inbox (входящие вебхуки). PostgreSQL 16.
--
-- Ставится в схему интеграционного сервиса (обычно `int`) одним сеансом:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
--   CREATE SCHEMA IF NOT EXISTS int;
--   SET search_path TO int;
--   \i templates/outbox.sql
--   SQL
--
-- Повторный запуск безопасен: таблицы и индексы IF NOT EXISTS, функции
-- и представления CREATE OR REPLACE. Каждая функция запоминает search_path
-- на момент установки (SET search_path FROM CURRENT) — вызывать её можно
-- из любой схемы, она всегда работает со «своими» таблицами.
--
-- Жизненный цикл записи outbox:
--
--   pending ──claim──► processing ──done──► done
--      ▲                  │
--      │                  ├─fail (можно повторить, попытки остались)──► retry ──(время)──► claim
--      │                  └─fail (нельзя повторить или попытки кончились)──► dead
--      └──────── replay ◄──────────────────────────────────────────────────────┘
--   pending/retry/dead ──cancel──► cancelled
--
-- Гарантия — «хотя бы один раз» (at-least-once): запрос во внешнюю систему может
-- уйти дважды (воркер упал после отправки, но до отметки). Поэтому каждый вызов
-- несёт idempotency_key, а принимающая сторона по нему не создаёт дубль.

-- ─────────────────────────────── outbox ───────────────────────────────

CREATE TABLE IF NOT EXISTS int_outbox (
    id               bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target           text        NOT NULL CHECK (target ~ '^[a-z][a-z0-9_]{0,39}$'),  -- '1c', 'kaspi', 'bank_halyk'
    operation        text        NOT NULL,                     -- 'payment_status.set', 'order.create'
    idempotency_key  text        NOT NULL,                     -- из бизнес-ключа: '1c:payment_request:42:v3'
    ordering_key     text,                                     -- записи с одним ключом уходят строго по очереди
    payload          jsonb       NOT NULL,
    status           text        NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'processing', 'retry', 'done', 'dead', 'cancelled')),
    attempts         integer     NOT NULL DEFAULT 0,
    max_attempts     integer     NOT NULL DEFAULT 10 CHECK (max_attempts BETWEEN 1 AND 100),
    next_attempt_at  timestamptz NOT NULL DEFAULT now(),
    locked_by        text,
    locked_until     timestamptz,                              -- аренда: после неё запись может забрать другой воркер
    last_error       text,                                     -- коротко, без персональных данных
    external_id      text,                                     -- ID созданного объекта во внешней системе
    response         jsonb,                                    -- минимальный ответ (ID, номер, статус), не весь ответ
    replay_count     integer     NOT NULL DEFAULT 0,
    created_by       text,                                     -- кто поставил: сервис, задача, пользователь
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    done_at          timestamptz,
    CONSTRAINT int_outbox_idempotency_key_uq UNIQUE (idempotency_key)
);

-- Очередь к выдаче: только незавершённые записи.
CREATE INDEX IF NOT EXISTS int_outbox_due_idx
    ON int_outbox (target, next_attempt_at, id)
    WHERE status IN ('pending', 'retry', 'processing');
CREATE INDEX IF NOT EXISTS int_outbox_ordering_idx
    ON int_outbox (target, ordering_key, id)
    WHERE ordering_key IS NOT NULL AND status IN ('pending', 'retry', 'processing', 'dead');
CREATE INDEX IF NOT EXISTS int_outbox_dead_idx ON int_outbox (target, updated_at) WHERE status = 'dead';

-- Журнал попыток: метрики ошибок и аудит «что, когда и с каким итогом отправляли».
CREATE TABLE IF NOT EXISTS int_attempt_log (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    queue       text        NOT NULL CHECK (queue IN ('outbox', 'inbox')),
    ref_id      bigint      NOT NULL,
    target      text        NOT NULL,                 -- для inbox — источник
    attempt     integer     NOT NULL,
    ok          boolean     NOT NULL,
    error       text,
    worker      text,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS int_attempt_log_at_idx ON int_attempt_log (target, at);
CREATE INDEX IF NOT EXISTS int_attempt_log_ref_idx ON int_attempt_log (queue, ref_id);

-- Пауза перед повтором: base · 2^(attempt-1), не больше cap, со случайным
-- разбросом ±20% (чтобы после сбоя все записи не ударили в систему разом).
-- При множителе 2 и разбросе ±20% каждая следующая пауза строго длиннее.
CREATE OR REPLACE FUNCTION int_backoff(p_attempt integer,
                                       p_base interval DEFAULT interval '30 seconds',
                                       p_cap  interval DEFAULT interval '6 hours')
RETURNS interval
LANGUAGE sql VOLATILE
SET search_path FROM CURRENT
AS $$
    SELECT least(p_base * power(2, greatest(p_attempt, 1) - 1)::numeric, p_cap)
           * (0.8 + random() * 0.4);
$$;

-- Поставить запись в очередь. Повтор с тем же ключом и тем же содержимым
-- возвращает ID уже стоящей записи; тот же ключ с другим содержимым — ошибка
-- (это баг вызывающего: один ключ — одно действие).
CREATE OR REPLACE FUNCTION int_enqueue(p_target          text,
                                       p_operation       text,
                                       p_idempotency_key text,
                                       p_payload         jsonb,
                                       p_ordering_key    text        DEFAULT NULL,
                                       p_max_attempts    integer     DEFAULT 10,
                                       p_not_before      timestamptz DEFAULT now(),
                                       p_created_by      text        DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_id bigint;
    v_existing int_outbox%ROWTYPE;
BEGIN
    IF p_idempotency_key IS NULL OR length(p_idempotency_key) = 0 THEN
        RAISE EXCEPTION 'int_enqueue: пустой idempotency_key' USING ERRCODE = '22023';
    END IF;

    INSERT INTO int_outbox (target, operation, idempotency_key, ordering_key, payload,
                            max_attempts, next_attempt_at, created_by)
    VALUES (p_target, p_operation, p_idempotency_key, p_ordering_key, p_payload,
            p_max_attempts, coalesce(p_not_before, now()), p_created_by)
    ON CONFLICT ON CONSTRAINT int_outbox_idempotency_key_uq DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NOT NULL THEN
        RETURN v_id;
    END IF;

    SELECT * INTO v_existing FROM int_outbox WHERE idempotency_key = p_idempotency_key;
    IF v_existing.target <> p_target OR v_existing.operation <> p_operation
       OR v_existing.payload <> p_payload THEN
        RAISE EXCEPTION 'int_enqueue: ключ % уже занят другой операцией или другим содержимым (запись %)',
                        p_idempotency_key, v_existing.id
              USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
END;
$$;

-- Забрать до p_n записей для цели. FOR UPDATE SKIP LOCKED: два воркера
-- никогда не получат одну запись. Берутся:
--   • pending/retry, у которых подошло время;
--   • processing с истёкшей арендой (воркер упал) — попытка засчитывается.
-- Из цепочки с одним ordering_key берётся только самая ранняя незавершённая
-- запись; запись в dead держит цепочку, пока её не переиграют или не отменят.
CREATE OR REPLACE FUNCTION int_claim_batch(p_target text,
                                           p_n      integer  DEFAULT 10,
                                           p_worker text     DEFAULT 'worker',
                                           p_lease  interval DEFAULT interval '5 minutes')
RETURNS SETOF int_outbox
LANGUAGE sql
SET search_path FROM CURRENT
AS $$
    WITH picked AS (
        SELECT o.id
        FROM int_outbox o
        WHERE o.target = p_target
          AND (   (o.status IN ('pending', 'retry') AND o.next_attempt_at <= now())
               OR (o.status = 'processing' AND o.locked_until < now()))
          AND (o.ordering_key IS NULL OR NOT EXISTS (
                SELECT 1 FROM int_outbox p
                WHERE p.target = o.target
                  AND p.ordering_key = o.ordering_key
                  AND p.id < o.id
                  AND p.status IN ('pending', 'retry', 'processing', 'dead')))
        ORDER BY o.next_attempt_at, o.id
        LIMIT greatest(p_n, 0)
        FOR UPDATE OF o SKIP LOCKED
    )
    UPDATE int_outbox o
       SET status = 'processing',
           attempts = o.attempts + 1,
           locked_by = p_worker,
           locked_until = now() + p_lease,
           updated_at = now()
      FROM picked
     WHERE o.id = picked.id
    RETURNING o.*;
$$;

-- Отметить успех. Возвращает false, если запись уже не наша (аренда истекла
-- и её забрал другой воркер) — тогда ничего не меняется.
CREATE OR REPLACE FUNCTION int_mark_done(p_id          bigint,
                                         p_worker      text  DEFAULT NULL,
                                         p_external_id text  DEFAULT NULL,
                                         p_response    jsonb DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_row int_outbox%ROWTYPE;
BEGIN
    UPDATE int_outbox
       SET status = 'done', done_at = now(), updated_at = now(),
           external_id = coalesce(p_external_id, external_id),
           response = coalesce(p_response, response),
           last_error = NULL, locked_by = NULL, locked_until = NULL
     WHERE id = p_id AND status = 'processing'
       AND (p_worker IS NULL OR locked_by = p_worker)
    RETURNING * INTO v_row;
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    INSERT INTO int_attempt_log (queue, ref_id, target, attempt, ok, worker)
    VALUES ('outbox', v_row.id, v_row.target, v_row.attempts, true, p_worker);
    RETURN true;
END;
$$;

-- Отметить неудачу. p_retryable = false (ошибка данных, 4xx, закрытый период) —
-- сразу в dead: повтор не поможет, нужен человек. Иначе — retry с паузой
-- int_backoff(), а после max_attempts — dead. p_retry_after — пауза,
-- которую попросила сама система (заголовок Retry-After), если она длиннее.
-- Возвращает новый статус или NULL, если запись уже не наша.
CREATE OR REPLACE FUNCTION int_mark_failed(p_id          bigint,
                                           p_error       text,
                                           p_retryable   boolean  DEFAULT true,
                                           p_worker      text     DEFAULT NULL,
                                           p_retry_after interval DEFAULT NULL,
                                           p_base        interval DEFAULT interval '30 seconds',
                                           p_cap         interval DEFAULT interval '6 hours')
RETURNS text
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_row int_outbox%ROWTYPE;
    v_error text := left(coalesce(p_error, 'без описания'), 1000);
BEGIN
    SELECT * INTO v_row FROM int_outbox
     WHERE id = p_id AND status = 'processing'
       AND (p_worker IS NULL OR locked_by = p_worker)
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    IF NOT p_retryable OR v_row.attempts >= v_row.max_attempts THEN
        UPDATE int_outbox
           SET status = 'dead', last_error = v_error, updated_at = now(),
               locked_by = NULL, locked_until = NULL
         WHERE id = p_id;
        v_row.status := 'dead';
    ELSE
        UPDATE int_outbox
           SET status = 'retry', last_error = v_error, updated_at = now(),
               locked_by = NULL, locked_until = NULL,
               next_attempt_at = now() + greatest(int_backoff(v_row.attempts, p_base, p_cap),
                                                  coalesce(p_retry_after, interval '0'))
         WHERE id = p_id;
        v_row.status := 'retry';
    END IF;

    INSERT INTO int_attempt_log (queue, ref_id, target, attempt, ok, error, worker)
    VALUES ('outbox', v_row.id, v_row.target, v_row.attempts, false, v_error, p_worker);
    RETURN v_row.status;
END;
$$;

-- Вернуть невыполненную запись в очередь без штрафа (воркер останавливается
-- и не успел её отправить). Попытка не засчитывается.
CREATE OR REPLACE FUNCTION int_release(p_id bigint, p_worker text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
SET search_path FROM CURRENT
AS $$
    WITH r AS (
        UPDATE int_outbox
           SET status = CASE WHEN attempts <= 1 THEN 'pending' ELSE 'retry' END,
               attempts = greatest(attempts - 1, 0),
               locked_by = NULL, locked_until = NULL, updated_at = now()
         WHERE id = p_id AND status = 'processing'
           AND (p_worker IS NULL OR locked_by = p_worker)
        RETURNING 1)
    SELECT EXISTS (SELECT 1 FROM r);
$$;

-- Переиграть запись из dead (после того как причину устранили).
-- Ключ идемпотентности тот же — внешняя система не создаст дубль, если первая
-- попытка всё-таки дошла. Счётчик попыток обнуляется, replay_count растёт.
CREATE OR REPLACE FUNCTION int_replay(p_id bigint, p_by text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    UPDATE int_outbox
       SET status = 'pending', attempts = 0, next_attempt_at = now(),
           replay_count = replay_count + 1, updated_at = now(),
           last_error = 'replay' || coalesce(' by ' || p_by, '') || ' after: ' || coalesce(last_error, '')
     WHERE id = p_id AND status = 'dead';
    RETURN FOUND;
END;
$$;

-- Переиграть все dead одной цели (например, после починки HTTP-сервиса 1С).
CREATE OR REPLACE FUNCTION int_replay_target(p_target text, p_by text DEFAULT NULL)
RETURNS integer
LANGUAGE sql
SET search_path FROM CURRENT
AS $$
    SELECT count(*)::integer FROM int_outbox o
     WHERE o.target = p_target AND o.status = 'dead' AND int_replay(o.id, p_by);
$$;

-- Отменить запись, которую отправлять больше не нужно (освобождает цепочку
-- ordering_key). Отправленные (done) не отменяются — для них нужна обратная
-- операция в самой системе.
CREATE OR REPLACE FUNCTION int_cancel(p_id bigint, p_reason text, p_by text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    UPDATE int_outbox
       SET status = 'cancelled', updated_at = now(),
           last_error = left('cancelled' || coalesce(' by ' || p_by, '') || ': ' || coalesce(p_reason, ''), 1000)
     WHERE id = p_id AND status IN ('pending', 'retry', 'dead');
    RETURN FOUND;
END;
$$;

-- ─────────────────────────────── inbox ────────────────────────────────

-- Входящие события (вебхуки). Сырое тело хранится как пришло: по нему
-- проверяется подпись и можно разобрать событие заново после исправления кода.
-- Уникальность (source, event_id) — только среди событий с верной подписью:
-- поддельный запрос с чужим event_id не должен «занять» место настоящего.
CREATE TABLE IF NOT EXISTS int_inbox (
    id               bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source           text        NOT NULL CHECK (source ~ '^[a-z][a-z0-9_]{0,39}$'),
    event_id         text        NOT NULL,                 -- ID события у источника (update_id, transaction id)
    event_type       text,
    raw_body         text        NOT NULL,
    headers          jsonb,                                -- только нужные заголовки, без секретов
    signature_valid  boolean     NOT NULL,
    status           text        NOT NULL DEFAULT 'received'
                     CHECK (status IN ('received', 'processing', 'retry', 'done', 'dead', 'rejected', 'ignored')),
    attempts         integer     NOT NULL DEFAULT 0,
    max_attempts     integer     NOT NULL DEFAULT 10,
    next_attempt_at  timestamptz NOT NULL DEFAULT now(),
    locked_by        text,
    locked_until     timestamptz,
    last_error       text,
    received_at      timestamptz NOT NULL DEFAULT now(),
    processed_at     timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS int_inbox_source_event_uq
    ON int_inbox (source, event_id) WHERE signature_valid;
CREATE INDEX IF NOT EXISTS int_inbox_due_idx
    ON int_inbox (source, next_attempt_at, id)
    WHERE status IN ('received', 'retry', 'processing');

-- Принять событие. Обработчик вебхука вызывает это и сразу отвечает 200
-- (или 401, если подпись неверна); разбор идёт асинхронно.
-- is_new = false — это повтор уже принятого события, отвечаем 200 и ничего не делаем.
CREATE OR REPLACE FUNCTION int_inbox_receive(p_source          text,
                                             p_event_id        text,
                                             p_raw_body        text,
                                             p_signature_valid boolean,
                                             p_headers         jsonb DEFAULT NULL,
                                             p_event_type      text  DEFAULT NULL,
                                             OUT id bigint, OUT is_new boolean)
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    IF NOT p_signature_valid THEN
        -- Храним для разбора атаки, но в очередь обработки не ставим.
        INSERT INTO int_inbox AS i (source, event_id, event_type, raw_body, headers, signature_valid, status)
        VALUES (p_source, p_event_id, p_event_type, left(p_raw_body, 10000), p_headers, false, 'rejected')
        RETURNING i.id INTO id;
        is_new := false;
        RETURN;
    END IF;

    INSERT INTO int_inbox AS i (source, event_id, event_type, raw_body, headers, signature_valid)
    VALUES (p_source, p_event_id, p_event_type, p_raw_body, p_headers, true)
    ON CONFLICT (source, event_id) WHERE signature_valid DO NOTHING
    RETURNING i.id INTO id;

    IF id IS NOT NULL THEN
        is_new := true;
    ELSE
        SELECT i.id INTO id FROM int_inbox i
         WHERE i.source = p_source AND i.event_id = p_event_id AND i.signature_valid;
        is_new := false;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION int_inbox_claim(p_source text,
                                           p_n      integer  DEFAULT 10,
                                           p_worker text     DEFAULT 'worker',
                                           p_lease  interval DEFAULT interval '5 minutes')
RETURNS SETOF int_inbox
LANGUAGE sql
SET search_path FROM CURRENT
AS $$
    WITH picked AS (
        SELECT i.id FROM int_inbox i
        WHERE i.source = p_source AND i.signature_valid
          AND (   (i.status IN ('received', 'retry') AND i.next_attempt_at <= now())
               OR (i.status = 'processing' AND i.locked_until < now()))
        ORDER BY i.id
        LIMIT greatest(p_n, 0)
        FOR UPDATE OF i SKIP LOCKED
    )
    UPDATE int_inbox i
       SET status = 'processing', attempts = i.attempts + 1,
           locked_by = p_worker, locked_until = now() + p_lease
      FROM picked WHERE i.id = picked.id
    RETURNING i.*;
$$;

-- p_ignored = true — событие нам не нужно (чужой тип), но разобрано.
CREATE OR REPLACE FUNCTION int_inbox_mark_done(p_id bigint, p_worker text DEFAULT NULL,
                                               p_ignored boolean DEFAULT false)
RETURNS boolean
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_row int_inbox%ROWTYPE;
BEGIN
    UPDATE int_inbox
       SET status = CASE WHEN p_ignored THEN 'ignored' ELSE 'done' END,
           processed_at = now(), last_error = NULL, locked_by = NULL, locked_until = NULL
     WHERE id = p_id AND status = 'processing' AND (p_worker IS NULL OR locked_by = p_worker)
    RETURNING * INTO v_row;
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    INSERT INTO int_attempt_log (queue, ref_id, target, attempt, ok, worker)
    VALUES ('inbox', v_row.id, v_row.source, v_row.attempts, true, p_worker);
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION int_inbox_mark_failed(p_id        bigint,
                                                 p_error     text,
                                                 p_retryable boolean  DEFAULT true,
                                                 p_worker    text     DEFAULT NULL,
                                                 p_base      interval DEFAULT interval '30 seconds',
                                                 p_cap       interval DEFAULT interval '6 hours')
RETURNS text
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_row int_inbox%ROWTYPE;
    v_error text := left(coalesce(p_error, 'без описания'), 1000);
    v_status text;
BEGIN
    SELECT * INTO v_row FROM int_inbox
     WHERE id = p_id AND status = 'processing' AND (p_worker IS NULL OR locked_by = p_worker)
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    v_status := CASE WHEN NOT p_retryable OR v_row.attempts >= v_row.max_attempts THEN 'dead' ELSE 'retry' END;
    UPDATE int_inbox
       SET status = v_status, last_error = v_error, locked_by = NULL, locked_until = NULL,
           next_attempt_at = CASE WHEN v_status = 'retry'
                                  THEN now() + int_backoff(v_row.attempts, p_base, p_cap)
                                  ELSE next_attempt_at END
     WHERE id = p_id;
    INSERT INTO int_attempt_log (queue, ref_id, target, attempt, ok, error, worker)
    VALUES ('inbox', v_row.id, v_row.source, v_row.attempts, false, v_error, p_worker);
    RETURN v_status;
END;
$$;

CREATE OR REPLACE FUNCTION int_inbox_replay(p_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    UPDATE int_inbox
       SET status = 'retry', attempts = 0, next_attempt_at = now(),
           last_error = 'replay after: ' || coalesce(last_error, '')
     WHERE id = p_id AND status = 'dead' AND signature_valid;
    RETURN FOUND;
END;
$$;

-- ──────────────────────────── сверка ────────────────────────────────

-- Итог ежедневной сверки «что мы отправили» ↔ «что есть в системе».
-- Строку пишет задача сверки интеграции (своя у каждой цели).
CREATE TABLE IF NOT EXISTS int_reconciliation (
    id            bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target        text        NOT NULL,
    check_name    text        NOT NULL,             -- 'payment_status', 'orders', 'stock'
    period_from   timestamptz NOT NULL,
    period_to     timestamptz NOT NULL,
    expected      integer     NOT NULL,             -- отправлено нами (done в outbox)
    found         integer     NOT NULL,             -- найдено в системе
    missing       integer     NOT NULL DEFAULT 0,   -- отправили, а в системе нет
    mismatched    integer     NOT NULL DEFAULT 0,   -- есть, но сумма/статус другие
    unexpected    integer     NOT NULL DEFAULT 0,   -- в системе есть, а мы не отправляли (ручной ввод, дубль)
    details       jsonb,                            -- ID расхождений, без персональных данных
    status        text        GENERATED ALWAYS AS (
                      CASE WHEN missing + mismatched > 0 THEN 'danger'
                           WHEN unexpected > 0 THEN 'warning'
                           ELSE 'ok' END) STORED,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT int_reconciliation_uq UNIQUE (target, check_name, period_from, period_to)
);

-- ─────────────────────── представления и метрики ─────────────────────

-- Очередь «мёртвых писем»: что не ушло и требует человека.
CREATE OR REPLACE VIEW int_dead_letter AS
SELECT 'outbox'::text AS queue, o.id, o.target AS target, o.operation AS kind,
       o.idempotency_key AS key, o.attempts, o.replay_count, o.last_error, o.updated_at,
       (SELECT count(*) FROM int_outbox b
         WHERE b.target = o.target AND b.ordering_key = o.ordering_key AND b.id > o.id
           AND b.status IN ('pending', 'retry')) AS blocked_behind
FROM int_outbox o WHERE o.status = 'dead'
UNION ALL
SELECT 'inbox', i.id, i.source, i.event_type, i.event_id, i.attempts, 0, i.last_error,
       coalesce(i.processed_at, i.received_at), 0
FROM int_inbox i WHERE i.status = 'dead';

-- Здоровье по каждой цели: глубина очереди, задержка, ошибки за час.
CREATE OR REPLACE VIEW int_health AS
WITH t AS (
    SELECT target FROM int_outbox
    UNION SELECT source FROM int_inbox
),
q AS (
    SELECT target,
           count(*) FILTER (WHERE status IN ('pending', 'retry', 'processing')) AS queue_depth,
           count(*) FILTER (WHERE status = 'dead') AS dead,
           extract(epoch FROM now() - min(created_at)
                   FILTER (WHERE status IN ('pending', 'retry', 'processing')))::bigint AS lag_seconds
    FROM int_outbox GROUP BY target
),
ib AS (
    SELECT source AS target,
           count(*) FILTER (WHERE status IN ('received', 'retry', 'processing')) AS queue_depth,
           count(*) FILTER (WHERE status = 'dead') AS dead,
           count(*) FILTER (WHERE status = 'rejected' AND received_at > now() - interval '1 hour') AS rejected_1h,
           extract(epoch FROM now() - min(received_at)
                   FILTER (WHERE status IN ('received', 'retry', 'processing')))::bigint AS lag_seconds
    FROM int_inbox GROUP BY source
),
e AS (
    SELECT target, count(*) AS attempts_1h, count(*) FILTER (WHERE NOT ok) AS errors_1h
    FROM int_attempt_log WHERE at > now() - interval '1 hour' GROUP BY target
),
r AS (
    SELECT DISTINCT ON (target) target, status AS last_recon_status, created_at AS last_recon_at
    FROM int_reconciliation ORDER BY target, created_at DESC
)
SELECT t.target,
       coalesce(q.queue_depth, 0) + coalesce(ib.queue_depth, 0) AS queue_depth,
       coalesce(q.dead, 0) + coalesce(ib.dead, 0)               AS dead,
       greatest(coalesce(q.lag_seconds, 0), coalesce(ib.lag_seconds, 0)) AS lag_seconds,
       coalesce(e.attempts_1h, 0) AS attempts_1h,
       coalesce(e.errors_1h, 0)   AS errors_1h,
       CASE WHEN coalesce(e.attempts_1h, 0) = 0 THEN 0
            ELSE round(100.0 * e.errors_1h / e.attempts_1h, 1) END AS error_rate_1h_pct,
       coalesce(ib.rejected_1h, 0) AS rejected_signatures_1h,
       r.last_recon_status, r.last_recon_at
FROM t
LEFT JOIN q  ON q.target = t.target
LEFT JOIN ib ON ib.target = t.target
LEFT JOIN e  ON e.target = t.target
LEFT JOIN r  ON r.target = t.target;

-- Показатели в формате модулей AIRL (metric_id, period, value, unit, status)
-- для плитки «Интеграции» в хабе и для оповещений. Пороги — пример, подберите
-- под каждую цель.
CREATE OR REPLACE VIEW m_int_health AS
SELECT 'int_queue_depth:' || target AS metric_id, current_date AS period,
       queue_depth::numeric AS value, 'шт' AS unit,
       CASE WHEN queue_depth > 500 THEN 'danger' WHEN queue_depth > 100 THEN 'warning' ELSE 'ok' END AS status
FROM int_health
UNION ALL
SELECT 'int_lag_minutes:' || target, current_date, round(lag_seconds / 60.0, 1), 'мин',
       CASE WHEN lag_seconds > 3600 THEN 'danger' WHEN lag_seconds > 900 THEN 'warning' ELSE 'ok' END
FROM int_health
UNION ALL
SELECT 'int_error_rate:' || target, current_date, error_rate_1h_pct, '%',
       CASE WHEN error_rate_1h_pct > 20 THEN 'danger' WHEN error_rate_1h_pct > 5 THEN 'warning' ELSE 'ok' END
FROM int_health
UNION ALL
SELECT 'int_dead:' || target, current_date, dead::numeric, 'шт',
       CASE WHEN dead > 0 THEN 'danger' ELSE 'ok' END
FROM int_health
UNION ALL
SELECT 'int_reconciliation:' || target, current_date,
       CASE last_recon_status WHEN 'ok' THEN 1 ELSE 0 END, 'да/нет',
       CASE WHEN last_recon_at IS NULL OR last_recon_at < now() - interval '26 hours' THEN 'danger'
            ELSE last_recon_status END
FROM int_health
WHERE last_recon_at IS NOT NULL OR target IN (SELECT DISTINCT target FROM int_outbox);

-- ─────────────────────────── уборка ─────────────────────────────────

-- Удаляет завершённые записи старше p_keep. dead и незавершённые не трогает.
-- Срок хранения согласуйте с бухгалтерией и юристом (аудит, персональные данные).
CREATE OR REPLACE FUNCTION int_purge(p_keep interval DEFAULT interval '90 days')
RETURNS integer
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    n1 integer; n2 integer; n3 integer;
BEGIN
    DELETE FROM int_outbox WHERE status IN ('done', 'cancelled') AND updated_at < now() - p_keep;
    GET DIAGNOSTICS n1 = ROW_COUNT;
    DELETE FROM int_inbox WHERE status IN ('done', 'ignored', 'rejected') AND received_at < now() - p_keep;
    GET DIAGNOSTICS n2 = ROW_COUNT;
    DELETE FROM int_attempt_log WHERE at < now() - p_keep;
    GET DIAGNOSTICS n3 = ROW_COUNT;
    RETURN n1 + n2 + n3;
END;
$$;
