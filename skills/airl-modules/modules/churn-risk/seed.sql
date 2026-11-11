-- Синтетические причины, действия менеджеров и отложенные клиенты для разработки и показа.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('churn-risk', 'recent_weeks',        '4',          'demo'),
 ('churn-risk', 'baseline_months',     '3',          'demo'),
 ('churn-risk', 'drop_pct',            '30',         'demo'),
 ('churn-risk', 'min_orders',          '3',          'demo'),
 ('churn-risk', 'silence_days',        '30',         'demo'),
 ('churn-risk', 'lost_days',           '90',         'demo'),
 ('churn-risk', 'new_days',            '60',         'demo'),
 ('churn-risk', 'include_aggregators', 'false',      'demo'),
 ('churn-risk', 'currency',            '"KZT"',      'demo'),
 ('churn-risk', 'risk_share_warn',     '10',         'demo'),
 ('churn-risk', 'risk_share_bad',      '20',         'demo'),
 ('churn-risk', 'revenue_share_warn',  '5',          'demo'),
 ('churn-risk', 'revenue_share_bad',   '10',         'demo'),
 ('churn-risk', 'channel',             '"telegram"', 'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO churn_reasons (code, title, created_by) VALUES
 ('price',        'Цена выше, чем у конкурентов',            'demo'),
 ('quality',      'Качество или вкус не устраивают',         'demo'),
 ('competitor',   'Перешёл к другому поставщику',            'demo'),
 ('service',      'Сервис, доставка, сроки',                 'demo'),
 ('assortment',   'Нет нужного товара',                      'demo'),
 ('seasonal',     'Сезонность (летняя точка, каникулы)',     'demo'),
 ('closed',       'Закрылся или на ремонте',                 'demo'),
 ('owner_change', 'Сменился владелец или закупщик',          'demo'),
 ('cash',         'Финансовые трудности клиента',            'demo'),
 ('unknown',      'Не удалось выяснить',                     'demo')
ON CONFLICT (code) DO NOTHING;

INSERT INTO churn_actions (client_id, action_type, reason_code, outcome, comment, next_step, next_step_date, created_at, created_by)
SELECT v.client_id, v.action_type, v.reason_code, v.outcome, v.comment, v.next_step, current_date + v.next_in, now() - v.ago, v.author
FROM (VALUES
 ('CH-003', 'call',    'price',      'will_order',  'Управляющий сравнивает с другим обжарщиком, просит скидку 5%', 'Отправить КП со скидкой на объём', 2,    interval '3 days',  'm_ruslan'),
 ('CH-005', 'visit',   'quality',    'pending',     'Бариста жалуется на кислотность нового лота Эфиопии',         'Провести дегустацию с бариста',    -2,   interval '9 days',  'm_dana'),
 ('CH-007', 'call',    NULL,         'not_reached', NULL,                                                            'Перезвонить владельцу',            -1,   interval '6 days',  'm_ruslan'),
 ('CH-011', 'call',    'competitor', 'lost',        'Подписали контракт с другим поставщиком на год',              NULL,                               NULL, interval '20 days', 'm_aidana')
) AS v(client_id, action_type, reason_code, outcome, comment, next_step, next_in, ago, author)
WHERE NOT EXISTS (SELECT 1 FROM churn_actions a
                  WHERE a.client_id = v.client_id AND a.action_type = v.action_type AND a.created_by = v.author);

INSERT INTO churn_snoozes (client_id, snooze_until, reason_code, comment, created_by)
SELECT 'CH-015', make_date(extract(year FROM current_date)::int + 1, 5, 1), 'seasonal',
       'Летняя веранда, работает с мая по сентябрь', 'm_ruslan'
WHERE NOT EXISTS (SELECT 1 FROM churn_snoozes WHERE client_id = 'CH-015');
