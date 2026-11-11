-- Синтетические записи модуля для разработки и показа: клиника в Ташкентской области,
-- 2000 вымышленных пациентов, рабочее время и записи за 150 дней и на неделю вперёд.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('appointments', 'org_name',           '"Orzu Medical"',  'demo'),
 ('appointments', 'timezone',           '"Asia/Tashkent"', 'demo'),
 ('appointments', 'reminder_hours',     '[24, 2]',         'demo'),
 ('appointments', 'quiet_from',         '"21:00"',         'demo'),
 ('appointments', 'quiet_to',           '"09:00"',         'demo'),
 ('appointments', 'booking_days',       '7',               'demo'),
 ('appointments', 'recall_window_days', '14',              'demo'),
 ('appointments', 'late_cancel_hours',  '2',               'demo'),
 ('appointments', 'consent_version',    '"v1-2026-09"',    'demo'),
 ('appointments', 'no_show_warn',       '10',              'demo'),
 ('appointments', 'no_show_bad',        '15',              'demo'),
 ('appointments', 'utilization_warn',   '70',              'demo'),
 ('appointments', 'utilization_bad',    '50',              'demo'),
 ('appointments', 'return_warn',        '35',              'demo'),
 ('appointments', 'return_bad',         '25',              'demo')
ON CONFLICT (module, key) DO NOTHING;

-- Пациенты. Каждый 50-й делит телефон с предыдущим (семья с одним номером).
INSERT INTO apt_customers (customer_no, display_name, phone, birth_date, preferred_language,
                           telegram_user_id, created_at, created_by)
SELECT 'P-' || lpad(n::text, 6, '0'),
       (ARRAY['Нигора', 'Бахтиёр', 'Дилноза', 'Шерзод', 'Малика', 'Жасур', 'Гулнора', 'Азиз',
              'Феруза', 'Санжар', 'Мадина', 'Отабек', 'Зарина', 'Улугбек', 'Камола', 'Рустам'])[1 + n % 16]
           || ' ' || substr('АБВГДЗИКЛМНОРСТУФХШЮЯ', 1 + (n * 7) % 21, 1) || '.',
       '+99890' || lpad((((n - (n % 50 = 0)::int) * 7919) % 10000000)::text, 7, '0'),
       date '1950-01-01' + (n * 137) % 25000,
       CASE WHEN n % 97 = 0 THEN 'kk' WHEN n % 3 = 1 THEN 'ru' ELSE 'uz' END,
       CASE WHEN n % 10 < 7 THEN 500000000 + n END,
       now() - interval '200 days', 'reception_1'
FROM generate_series(1, 2000) AS n
ON CONFLICT (customer_no) DO NOTHING;

-- Согласие на обработку — у всех; на Telegram — у подключивших бота, кроме каждого 20-го.
INSERT INTO apt_consents (customer_id, kind, granted, consent_version, given_at, source, created_by)
SELECT c.id, 'processing', true, 'v1-2026-09', c.created_at, 'reception', 'reception_1'
FROM apt_customers c
WHERE NOT EXISTS (SELECT 1 FROM apt_consents x WHERE x.customer_id = c.id AND x.kind = 'processing');

INSERT INTO apt_consents (customer_id, kind, granted, consent_version, given_at, source, created_by)
SELECT c.id, 'telegram', true, 'v1-2026-09', c.created_at + interval '1 minute', 'telegram_bot', 'bot'
FROM apt_customers c
WHERE c.telegram_user_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM apt_consents x WHERE x.customer_id = c.id AND x.kind = 'telegram');

INSERT INTO apt_consents (customer_id, kind, granted, consent_version, given_at, source, created_by)
SELECT c.id, 'telegram', false, 'v1-2026-09', now() - interval '30 days', 'telegram_bot', 'bot'
FROM apt_customers c
WHERE c.telegram_user_id IS NOT NULL AND substr(c.customer_no, 3)::int % 20 = 0
  AND NOT EXISTS (SELECT 1 FROM apt_consents x WHERE x.customer_id = c.id AND x.kind = 'telegram' AND NOT x.granted);

-- Рабочее время: пн–сб, 09:00–13:00 по Ташкенту, 150 дней назад и 7 вперёд.
INSERT INTO apt_shifts (resource_id, starts_at, ends_at, source, created_by)
SELECT r.resource_id,
       (d::date + time '09:00') AT TIME ZONE 'Asia/Tashkent',
       (d::date + time '13:00') AT TIME ZONE 'Asia/Tashkent',
       'import', 'demo'
FROM src_apt_resources r
CROSS JOIN generate_series(current_date - 150, current_date + 7, interval '1 day') AS d
WHERE extract(isodow FROM d) BETWEEN 1 AND 6
ON CONFLICT (resource_id, starts_at) DO NOTHING;

-- Записи: детерминированный «случайный» выбор слотов, пациентов и исходов.
INSERT INTO apt_appointments (appt_no, customer_id, resource_id, starts_at, ends_at, status, source,
                              confirmed_at, arrived_at, cancelled_at, cancel_reason, created_at, created_by)
SELECT 'A-' || x.resource_id || '-' || to_char(x.slot_start AT TIME ZONE 'Asia/Tashkent', 'YYYYMMDD-HH24MI'),
       c.id, x.resource_id, x.slot_start, x.slot_end, x.status,
       (ARRAY['phone', 'telegram', 'phone', 'walk_in', 'telegram', 'site'])[1 + x.h % 6],
       CASE WHEN x.status IN ('confirmed', 'arrived', 'done') THEN x.slot_start - interval '20 hours' END,
       CASE WHEN x.status IN ('arrived', 'done') THEN x.slot_start - interval '10 minutes' END,
       CASE WHEN x.status LIKE 'cancelled%' THEN x.slot_start - CASE WHEN x.h % 2 = 0 THEN interval '1 hour' ELSE interval '1 day' END END,
       CASE WHEN x.status = 'cancelled_by_patient' THEN 'patient_request'
            WHEN x.status = 'cancelled_by_clinic' THEN 'doctor_unavailable' END,
       least(x.slot_start - make_interval(days => 1 + x.h % 6), now()), 'reception_1'
FROM (
    SELECT s.resource_id, g.slot_start, g.slot_start + make_interval(mins => r.slot_minutes) AS slot_end,
           g.h, g.ci,
           CASE WHEN g.slot_start >= now() THEN CASE WHEN g.h % 3 = 0 THEN 'confirmed' ELSE 'booked' END
                WHEN g.h % 100 < 11 THEN 'no_show'
                WHEN g.h % 100 < 17 THEN 'cancelled_by_patient'
                WHEN g.h % 100 < 19 THEN 'cancelled_by_clinic'
                ELSE 'done' END AS status
    FROM apt_shifts s
    JOIN src_apt_resources r ON r.resource_id = s.resource_id
    CROSS JOIN LATERAL (
        SELECT gs AS slot_start,
               abs(hashtext(s.resource_id || gs::text)) AS h,
               abs(hashtext('c' || s.resource_id || gs::text)) % 2000 + 1 AS ci
        FROM generate_series(s.starts_at, s.ends_at - make_interval(mins => r.slot_minutes),
                             make_interval(mins => r.slot_minutes)) AS gs
    ) g
    WHERE g.h % 100 < 72 + (CASE WHEN s.resource_id = 'RM-USG-1' THEN -25 ELSE 0 END)
) x
JOIN apt_customers c ON c.customer_no = 'P-' || lpad(x.ci::text, 6, '0')
ON CONFLICT (appt_no) DO NOTHING;

-- Ответы в боте на подтверждённые будущие записи.
INSERT INTO apt_responses (appointment_id, channel, response, received_at, created_by)
SELECT a.id, 'telegram', 'confirm', a.confirmed_at, 'bot'
FROM apt_appointments a
WHERE a.status = 'confirmed' AND a.confirmed_at IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM apt_responses x WHERE x.appointment_id = a.id);

-- «Пора на приём»: пациентам кардиолога и невролога через 30 дней после визита за последние 45 дней.
INSERT INTO apt_recalls (customer_id, resource_id, due_date, reason, status, source_appointment_id, created_by)
SELECT a.customer_id, a.resource_id, (a.starts_at AT TIME ZONE 'Asia/Tashkent')::date + 30, 'follow_up',
       CASE WHEN a.id % 4 = 0 THEN 'contacted' ELSE 'due' END, a.id, 'doctor'
FROM apt_appointments a
WHERE a.status = 'done' AND a.resource_id IN ('DR-CRD-1', 'DR-NEU-1')
  AND a.starts_at > now() - interval '45 days' AND a.id % 3 = 0
ON CONFLICT (customer_id, due_date, reason) DO NOTHING;

DO $$ BEGIN PERFORM apt_plan_reminders(); END $$;
