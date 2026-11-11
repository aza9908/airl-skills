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
