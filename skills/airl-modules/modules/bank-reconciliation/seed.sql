-- Синтетические настройки и решения бухгалтера для разработки и показа.
-- Сценарий выполняется один раз: при повторном запуске (есть сопоставления) — пропускается.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('bank-reconciliation', 'amount_only_days',     '60',                       'demo'),
 ('bank-reconciliation', 'auto_confirm_enabled', 'false',                    'demo'),
 ('bank-reconciliation', 'auto_confirm_from',    'null',                     'demo'),
 ('bank-reconciliation', 'auto_confirm_rules',   '["amount_tax_doc"]',       'demo'),
 ('bank-reconciliation', 'unmatched_grace_days', '2',                        'demo'),
 ('bank-reconciliation', 'unmatched_warn',       '1',                        'demo'),
 ('bank-reconciliation', 'unmatched_bad',        '10',                       'demo'),
 ('bank-reconciliation', 'match_rate_warn',      '70',                       'demo'),
 ('bank-reconciliation', 'match_rate_bad',       '50',                       'demo'),
 ('bank-reconciliation', 'recipient',            '"role:accountant"',        'demo'),
 ('bank-reconciliation', 'reverse_recipient',    '"role:chief_accountant"',  'demo'),
 ('bank-reconciliation', 'channel',              '"telegram"',               'demo')
ON CONFLICT (module, key) DO NOTHING;

DO $$
DECLARE
    r record;
    v_batch text;
BEGIN
    IF EXISTS (SELECT 1 FROM bank_matches) THEN
        RETURN;
    END IF;

    PERFORM bank_suggest('demo');

    -- Бухгалтер разобрал старые строки: high и medium без альтернатив — подтвердил.
    FOR r IN SELECT m.id FROM bank_matches m JOIN src_bank_statement_lines l ON l.line_id = m.line_id
             WHERE m.status = 'suggested' AND m.confidence IN ('high', 'medium') AND m.alternatives = 0
               AND l.value_date < current_date - 10
             ORDER BY m.id LOOP
        PERFORM bank_confirm(r.id, 'u_accountant');
    END LOOP;

    -- Свежие строки: разбивка подтверждена, частичная оплата подтверждена.
    PERFORM bank_confirm(m.id, 'u_accountant') FROM bank_matches m
    WHERE m.status = 'suggested' AND m.kind IN ('split', 'partial');

    -- Комиссия банка — не сопоставляется.
    PERFORM bank_mark_line(line_id, 'bank_fee', 'u_accountant', 'Комиссия за обслуживание')
    FROM src_bank_statement_lines WHERE purpose LIKE 'Комиссия%';

    -- Выгрузка в 1С: первый пакет загружен.
    v_batch := bank_export_prepare('u_accountant');
    PERFORM bank_export_set_status(v_batch, 'loaded', 'integration');

    -- После выгрузки выяснилось: один платёж — возврат по другому договору. Отмена с причиной;
    -- следующий пакет содержит сторно.
    PERFORM bank_reverse(m.id, 'u_chief_accountant', 'Платёж — возврат аванса по другому договору, разнесён ошибочно')
    FROM bank_matches m
    WHERE m.id = (SELECT min(id) FROM bank_matches WHERE status = 'confirmed' AND source = 'suggestion' AND kind = 'single');
    PERFORM bank_export_prepare('u_chief_accountant');

    -- Ночной запуск подбора после загрузки: новые предложения по оставшимся строкам.
    PERFORM bank_suggest('scheduler');

    -- Два счёта на одну сумму: модуль предложил один из них с низкой уверенностью.
    -- Бухгалтер позвонил клиенту: оплачен более поздний счёт. Отклонил и выбрал вручную.
    FOR r IN SELECT m.id, m.line_id, l.amount FROM bank_matches m
             JOIN src_bank_statement_lines l ON l.line_id = m.line_id
             WHERE m.status = 'suggested' AND m.confidence = 'low' AND l.purpose = 'Оплата за поставку кофе' LOOP
        PERFORM bank_reject(r.id, 'u_accountant', 'Два счёта на одну сумму — уточнил у клиента');
        PERFORM bank_match_manual(r.line_id,
            jsonb_build_array(jsonb_build_object('item_id', 'INV-3021', 'amount', r.amount)),
            'u_accountant', 'Клиент подтвердил по телефону: оплата по СФ-3021');
    END LOOP;

    PERFORM bank_queue_notifications();
END $$;
