-- Витрина отдела «HR» (mart_hr): модуль onboarding (kit.sql + onboarding.schema.sql ставятся раньше)
-- и своё — кто из HR ведёт какие отделы. Ставится под svc_hr. Повторный запуск безопасен.
-- Оклады и ФИО сюда не копируются: ФИО — в адаптере src_onb_employees, ФОТ — агрегат в metrics.
SET search_path TO mart_hr;

-- «Свои записи» HR-менеджера: отделы, онбординг которых он ведёт (руководитель HR — все).
CREATE TABLE IF NOT EXISTS hr_staff_scope (
    login        text PRIMARY KEY,
    departments  text[] NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text NOT NULL
);
