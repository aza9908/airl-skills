-- Демо-источник: синтетические сотрудники кофейной компании (розница, обжарка, склад).
-- Только для разработки и показа. В работе src_onb_employees заменяет адаптер /airl-dwh
-- или /airl-connect (обычно поверх кадров 1С:ЗУП или HR-системы).

CREATE TABLE IF NOT EXISTS demo_onb_employees (
    employee_id text PRIMARY KEY,
    full_name   text    NOT NULL,
    position    text    NOT NULL,
    department  text    NOT NULL,
    hired_days  int     NOT NULL,          -- сколько дней назад принят (даты остаются свежими)
    manager_id  text,
    active      boolean NOT NULL
);

INSERT INTO demo_onb_employees VALUES
 ('E-001', 'Ержан Касымов',     'Руководитель розницы', 'Розница', 1600, NULL,    true),
 ('E-002', 'Динара Ахметова',   'Старший бариста',      'Розница',  900, 'E-001', true),
 ('E-003', 'Арман Жумабеков',   'Бариста',              'Розница',  500, 'E-002', true),
 ('E-004', 'Алия Нуртаева',     'Бариста',              'Розница',  300, 'E-002', true),
 ('E-005', 'Тимур Ли',          'Обжарщик',             'Обжарка',  700, 'E-010', true),
 ('E-006', 'Сауле Омарова',     'Комплектовщик',        'Склад',    420, 'E-011', true),
 ('E-007', 'Руслан Беков',      'Комплектовщик',        'Склад',    250, 'E-011', true),
 ('E-010', 'Марат Исаев',       'Руководитель обжарки', 'Обжарка', 1400, NULL,    true),
 ('E-011', 'Гульнара Серикова', 'Заведующий складом',   'Склад',   1200, NULL,    true),
 ('E-090', 'Олег Ким',          'Бариста',              'Розница',  200, 'E-002', false),
 ('E-101', 'Айгерим Сапарова',  'Бариста',              'Розница',   40, 'E-002', true),
 ('E-102', 'Данияр Мусин',      'Бариста',              'Розница',   20, 'E-002', true),
 ('E-103', 'Камила Рахимова',   'Комплектовщик',        'Склад',      5, 'E-011', true),
 ('E-104', 'Нурлан Абенов',     'Обжарщик',             'Обжарка',   70, 'E-010', true)
ON CONFLICT (employee_id) DO NOTHING;

CREATE OR REPLACE VIEW src_onb_employees AS
SELECT employee_id, full_name, position, department,
       (current_date - hired_days)::date AS hired_at,
       manager_id, active
FROM demo_onb_employees;
