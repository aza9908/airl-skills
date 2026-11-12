-- Витрина отдела «Обучение» (mart_edu): то, что вводят кураторы. Каркас kit.sql
-- ставится до этого файла (журнал airl_audit, настройки). Повторный запуск безопасен.
-- Чужие данные не копируются: слушатель — ссылка enrollment_id на core.enrollments.
SET search_path TO mart_edu;

-- Отметка куратора о слушателе: риск отсева и что сделали.
CREATE TABLE IF NOT EXISTS edu_flags (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    enrollment_id text        NOT NULL,
    cohort_code   text        NOT NULL,
    level         text        NOT NULL CHECK (level IN ('risk', 'watch', 'resolved')),
    reason        text        NOT NULL CHECK (reason IN ('absences', 'no_homework', 'payment', 'personal', 'other')),
    comment       text        CHECK (comment IS NULL OR length(comment) <= 1000),
    status        text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text        NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    text        NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS edu_flags_active ON edu_flags (enrollment_id) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS edu_flags_cohort ON edu_flags (cohort_code);

DROP TRIGGER IF EXISTS edu_flags_touch ON edu_flags;
CREATE TRIGGER edu_flags_touch BEFORE UPDATE ON edu_flags FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Кто из пользователей хаба — какой куратор потоков (для «только свои потоки»).
CREATE TABLE IF NOT EXISTS edu_curators (
    login       text PRIMARY KEY,
    curator     text NOT NULL,            -- как в core.cohorts.curator
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text NOT NULL
);

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('kit', 'currency', '"KZT"', 'setup'),
 ('edu', 'risk_attendance_below_pct', '60', 'setup')
ON CONFLICT (module, key) DO NOTHING;

-- Показатель витрины: слушатели под риском отсева в идущих потоках (для предупреждений хаба).
CREATE OR REPLACE VIEW m_edu_at_risk AS
SELECT 'edu_at_risk'::text AS metric_id, to_char(current_date, 'YYYY-MM-DD') AS period,
       count(*)::numeric AS value, 'чел'::text AS unit,
       CASE WHEN count(*) = 0 THEN 'ok' WHEN count(*) <= 3 THEN 'warning' ELSE 'danger' END AS status
FROM edu_flags WHERE status = 'active' AND level = 'risk';
