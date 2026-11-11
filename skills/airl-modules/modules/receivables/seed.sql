-- Синтетические действия по взысканию и обещания оплатить для разработки и показа.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('receivables', 'currency',              '"KZT"',               'demo'),
 ('receivables', 'use_contract_terms',    'true',                'demo'),
 ('receivables', 'include_aggregators',   'false',               'demo'),
 ('receivables', 'overdue_warn',          '3000000',             'demo'),
 ('receivables', 'overdue_bad',           '10000000',            'demo'),
 ('receivables', 'share_warn',            '20',                  'demo'),
 ('receivables', 'share_bad',             '35',                  'demo'),
 ('receivables', 'promise_tolerance_pct', '5',                   'demo'),
 ('receivables', 'finance_recipient',     '"role:fin_director"', 'demo'),
 ('receivables', 'channel',               '"telegram"',          'demo')
ON CONFLICT (module, key) DO NOTHING;

-- Действия. Ключ для повторного запуска — клиент + время создания (их нет дважды).
INSERT INTO rcv_actions (client_id, doc_no, kind, result, comment, next_contact_date, created_at, created_by)
SELECT v.client_id, v.doc_no, v.kind, v.result, v.comment, current_date + v.next_in, now() - v.ago, v.author
FROM (VALUES
 ('CL-002', 'РН-1003', 'call',    'promised',    'Бухгалтер обещал оплатить остаток после инкассации', 3,    interval '7 days',  'm_aidana'),
 ('CL-003', 'РН-1004', 'call',    'promised',    'Управляющий: оплатят частично до конца недели',      -3,   interval '12 days', 'm_ruslan'),
 ('CL-003', 'РН-1004', 'letter',  'other',       'Направлена претензия по долгу старше 90 дней',       5,    interval '2 days',  'u_fin'),
 ('CL-005', 'РН-1006', 'call',    'promised',    'Обещали оплатить после выручки за выходные',         4,    interval '1 day',   'm_dana'),
 ('CL-007', 'РН-1008', 'call',    'not_reached', NULL,                                                  1,    interval '3 days',  'm_ruslan'),
 ('CL-011', 'РН-1013', 'meeting', 'disputed',    'Клиент оспаривает 2 коробки — недовложение при доставке', 7, interval '5 days', 'm_ruslan')
) AS v(client_id, doc_no, kind, result, comment, next_in, ago, author)
WHERE NOT EXISTS (SELECT 1 FROM rcv_actions a
                  WHERE a.client_id = v.client_id AND a.kind = v.kind AND a.doc_no = v.doc_no AND a.created_by = v.author);

-- Обещания. balance_at_promise задан явно, чтобы показать «выполнено» и «нарушено»
-- на неподвижных демо-данных; в работе он заполняется сам (триггер rcv_promises_fill).
INSERT INTO rcv_promises (client_id, action_id, promised_date, promised_amount, currency, balance_at_promise, comment, created_at, created_by)
SELECT v.client_id, a.id, current_date + v.date_in, v.amount, 'KZT', v.balance, v.comment, a.created_at, a.created_by
FROM (VALUES
 ('CL-002', 'm_aidana', -2,  1400000, 7500000, 'Остаток по РН-1003'),
 ('CL-003', 'm_ruslan', -5,  600000,  NULL,    'Частичная оплата по РН-1004'),
 ('CL-005', 'm_dana',   3,   300000,  NULL,    'Остаток по РН-1006')
) AS v(client_id, author, date_in, amount, balance, comment)
JOIN rcv_actions a ON a.client_id = v.client_id AND a.created_by = v.author AND a.result = 'promised'
WHERE NOT EXISTS (SELECT 1 FROM rcv_promises p WHERE p.action_id = a.id);
