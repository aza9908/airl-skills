-- Демо-источники: синтетические клиенты кофейной компании (кофейни, офисы) и
-- справочник запчастей. Только для разработки и показа.
-- В работе src_clients и src_parts заменяет адаптер /airl-dwh или /airl-connect.
--
-- src_clients — общий вход для service-requests и complaints: определение
-- demo_clients и src_clients в обоих модулях одинаковое, поэтому модули можно
-- ставить в одну схему в любом порядке.

CREATE TABLE IF NOT EXISTS demo_clients (
    client_id   text PRIMARY KEY,
    client_name text NOT NULL,
    city        text,
    address     text,
    phone       text
);

INSERT INTO demo_clients VALUES
 ('C-0101', 'Кофейня «Утро» на Абая',         'Алматы', 'пр. Абая, 52',          '+77011110101'),
 ('C-0102', 'Кофейня «Зерно» ТРЦ Mega',       'Алматы', 'ул. Розыбакиева, 247',  '+77011110102'),
 ('C-0103', 'Офис ТОО «Даму Логистик»',       'Алматы', 'ул. Сатпаева, 30А',     '+77011110103'),
 ('C-0104', 'Отель «Тау» — лобби-бар',        'Алматы', 'ул. Желтоксан, 115',    '+77011110104'),
 ('C-0201', 'Кофейня «Байтерек кофе»',        'Астана', 'пр. Мангилик Ел, 8',    '+77011110201'),
 ('C-0202', 'Кафе «Esil Breakfast»',           'Астана', 'ул. Кунаева, 12',       '+77011110202'),
 ('C-0203', 'Коворкинг «Орда»',               'Астана', 'пр. Туран, 37',         NULL),
 ('C-0301', 'Розничный покупатель (сайт)',    'Алматы', NULL,                    NULL)
ON CONFLICT (client_id) DO NOTHING;

CREATE OR REPLACE VIEW src_clients AS
SELECT client_id, client_name, city, address, phone
FROM demo_clients;

CREATE TABLE IF NOT EXISTS demo_svc_parts (
    sku       text PRIMARY KEY,
    part_name text NOT NULL,
    unit      text NOT NULL
);

INSERT INTO demo_svc_parts VALUES
 ('SP-GASKET-58',  'Уплотнитель группы 58 мм',         'шт'),
 ('SP-SHOWER-58',  'Сеточка душа группы 58 мм',        'шт'),
 ('SP-PUMP-ULKA',  'Помпа вибрационная Ulka',          'шт'),
 ('SP-BURR-64',    'Жернова 64 мм (пара)',             'компл'),
 ('SP-PRESS-SW',   'Прессостат',                       'шт'),
 ('SP-FILTER-BWT', 'Картридж фильтра воды BWT',        'шт'),
 ('SP-DESCALE',    'Средство для декальцинации 1 л',   'шт')
ON CONFLICT (sku) DO NOTHING;

CREATE OR REPLACE VIEW src_parts AS
SELECT sku, part_name, unit
FROM demo_svc_parts;
