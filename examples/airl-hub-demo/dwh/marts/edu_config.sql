-- Настройка витрины «Обучение» (mart_edu). Значения СИНТЕТИЧЕСКИЕ.
SET search_path TO mart_edu;

-- staff_edu ведёт потоки «Куратор 1» (демо): видит и отмечает только их.
INSERT INTO edu_curators (login, curator, created_by) VALUES ('staff_edu', 'Куратор 1', 'setup')
ON CONFLICT (login) DO NOTHING;
