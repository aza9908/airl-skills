-- Демо-источник: врачи и кабинеты синтетической многопрофильной клиники
-- в Ташкентской области. Только для разработки и показа.
-- В работе src_apt_resources заменяет адаптер /airl-dwh или /airl-connect
-- (справочник врачей из МИС или кадров).

CREATE TABLE IF NOT EXISTS demo_apt_resources (
    resource_id   text PRIMARY KEY,
    resource_name text    NOT NULL,
    specialty     text    NOT NULL,
    branch_id     text    NOT NULL,
    slot_minutes  int     NOT NULL,
    active        boolean NOT NULL
);

INSERT INTO demo_apt_resources VALUES
 ('DR-NEU-1', 'Каримова Нигора',  'Невролог',  'CHR-1', 30, true),
 ('DR-THR-1', 'Юсупов Бахтиёр',   'Терапевт',  'CHR-1', 20, true),
 ('DR-CRD-1', 'Ахмедова Дилноза', 'Кардиолог', 'CHR-1', 30, true),
 ('DR-PED-1', 'Рахимов Шерзод',   'Педиатр',   'CHR-1', 20, true),
 ('RM-USG-1', 'Кабинет УЗИ',      'УЗИ',       'CHR-1', 20, true)
ON CONFLICT (resource_id) DO NOTHING;

CREATE OR REPLACE VIEW src_apt_resources AS
SELECT resource_id, resource_name, specialty, branch_id, slot_minutes, active
FROM demo_apt_resources;

-- Визиты из МИС для режима mis_mirror (синтетика). В работе — адаптер над МИС.
CREATE TABLE IF NOT EXISTS demo_apt_mis_visits (
    visit_id     text PRIMARY KEY,
    patient_id   text NOT NULL,
    patient_name text NOT NULL,
    phone        text,
    birth_date   date,
    resource_id  text NOT NULL,
    starts_at    timestamptz NOT NULL,
    ends_at      timestamptz NOT NULL,
    status       text NOT NULL,
    cancelled_at timestamptz
);
INSERT INTO demo_apt_mis_visits VALUES
 ('V-90001', 'P-7001', 'Сабина', '+998901110001', '1988-04-12', 'DR-CRD-1', date_trunc('hour', now()) + interval '3 days', date_trunc('hour', now()) + interval '3 days 30 minutes', 'booked', NULL),
 ('V-90002', 'P-7002', 'Ойбек',  '+998901110002', '1975-09-30', 'DR-CRD-1', date_trunc('hour', now()) - interval '2 days', date_trunc('hour', now()) - interval '2 days' + interval '30 minutes', 'done', NULL),
 ('V-90003', 'P-7002', 'Ойбек',  '+998901110002', '1975-09-30', 'DR-CRD-1', date_trunc('hour', now()) + interval '5 days', date_trunc('hour', now()) + interval '5 days 30 minutes', 'cancelled', now())
ON CONFLICT (visit_id) DO NOTHING;

CREATE OR REPLACE VIEW src_apt_mis_visits AS
SELECT visit_id, patient_id, patient_name, phone, birth_date, resource_id, starts_at, ends_at, status, cancelled_at
FROM demo_apt_mis_visits;
