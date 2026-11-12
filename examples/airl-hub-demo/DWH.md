# DWH.md — хранилище хаба AIRL (демо)

Режим хаба `/airl-dwh`, репозиторий хаба, команда AIRL. Вопросы 1, 2, 5, 12, 14 закрыты картой
(`COMPANY_MAP.md`, разделы 2–5, 7). Данные — синтетические (`data/generate_1c.py`).

## Ответы на 15 вопросов
| № | Вопрос | Ответ | Кто решил |
|---|---|---|---|
| 1 | Для чего данные | экран руководителя и сервисы finance, sales, marketing, edu, hr | карта |
| 2 | Откуда | 1С (2 базы) и 1С:ЗУП, выписки 2 банков, amoCRM, рекламные кабинеты, таблицы потоков, вакансий и бюджета маркетинга | карта |
| 3 | Объём и рост | ~700 реализаций, ~5 тыс. заявок, ~1 тыс. строк выписок, ~3 тыс. строк расхода кабинетов, ~550 начислений ЗУП за 18 мес.; рост ~3 %/мес | по синтетике |
| 4 | Способ загрузки | пакетно раз в сутки: CSV → `raw_*` (COPY) → `core.load()` одной транзакцией | по умолчанию |
| 5 | Справочники | контрагенты, номенклатура (направления), счета денег, статьи затрат 1С | карта |
| 6 | Уникальные ключи | `infobase:ref` документа 1С; `UNIQUE (entity_id, doc_no)`; `line_id` строки выписки | по умолчанию |
| 7 | Типы | деньги `numeric(18,2)`, валюта `char(3)`, даты `date`, время `timestamptz` (Asia/Almaty) | module-kit |
| 8 | Нормализация | `core` — 3НФ по сущностям; `metrics` — представления и функции | по умолчанию |
| 9 | Аудит | `airl_audit` в каждой витрине (каркас модулей); `hub.journal` — входы и открытия сервисов; `core.load_log` | module-kit |
| 10 | Большие таблицы | не нужны (до 10⁶ строк за годы); индексы по датам и клиенту | по умолчанию |
| 11 | Связь хранилищ | одна база PostgreSQL, Kafka/MinIO/Airflow не нужны | по умолчанию |
| 12 | Масштабирование | вертикально; при росте — материализовать `metrics.m_*` | по умолчанию |
| 13 | Доступы и качество | пользователь на сервис; сверка модулей с `metrics` (`tests/reconcile.sql`) | карта + AIRL |
| 14 | Потребители | 5 сервисов, оболочка хаба, ИИ-слой (`ai_reader`) | карта |
| 15 | Восстановление | ночной `pg_dump`, копия в другом ДЦ РК, проверка восстановления раз в месяц (DEVOPS.md) | по умолчанию |

## Слои и сущности
| Слой | Схема | Таблицы / объекты | Кто пишет |
|---|---|---|---|
| Сырой | `raw_1c` | organizations, kontragenty, dogovory, nomenklatura, realizatsiya(+_tovary), postuplenie_rs, pko, spisanie_rs, zatraty, bank_accounts, ostatki_dc, sotrudniki | `airl_loader` |
| Сырой | `raw_1c` (ЗУП) | zup_nachisleniya (по сотруднику и месяцу), zup_otsutstviya | `airl_loader` |
| Сырой | `raw_bank`, `raw_amocrm`, `raw_sheets` | statement_lines; leads (+ utm_campaign), amo_users; cohorts, cohort_students, vacancies | `airl_loader` |
| Сырой | `raw_ads` | ad_campaigns, ad_spend (кабинеты Meta, Google, Telegram + таблица бюджета), mkt_budget | `airl_loader` |
| Общие | `core` | legal_entities, clients (+client_source_map), suppliers, sales_docs, payments_in, payments_out, expenses, cash_accounts, cash_openings, bank_lines, leads (+campaign), managers, cohorts, enrollments, employees, employee_names (ФИО, только адаптер HR), payroll_monthly и absences_monthly (суммы по отделу × месяцу), vacancies, ad_campaigns, ad_spend, load_log | `core.load()` |
| Показатели | `metrics` | definitions (карта, раздел 4), `value()`, `status()`, `kpi_period()`, `series()`, `periods()`, `pnl()`, `receivables_aging()`, `lead_funnel()`, `revenue_forecast()`, `m_<id>` по месяцам, `revenue_daily`, `lead_daily`, `enrollments_daily`, `cohort_fill_rate_detail`; лента расходов `expense_entries` и `payroll_daily` (ЗУП по дням); HR — `hr_moves()`, `vacancies()`, `payroll_by_department()`, `absence_by_department()`; маркетинг — `marketing_channels()`, `marketing_campaigns()`, `ad_spend_daily`, `channel_title()` | `metrics_owner` |
| Витрины | `mart_finance` | kit + pnl-cashflow + receivables + bank-reconciliation; адаптеры `src_pnl_entries`, `src_pnl_cash`, `src_receivables_docs`, `src_rcv_clients`, `src_bank_statement_lines`, `src_bank_open_items` | `svc_finance` |
| Витрины | `mart_sales` | kit + plan-fact; `src_pf_facts`; `sales_staff`, `lead_followups` | `svc_sales` |
| Витрины | `mart_edu` | kit; `edu_flags`, `edu_curators`, `m_edu_at_risk` | `svc_edu` |
| Витрины | `mart_hr` | kit + onboarding (`onb_*`, `m_onboarding_on_time_rate`); адаптер `src_onb_employees`; `hr_staff_scope` | `svc_hr` |
| Витрины | `mart_marketing` | kit; `mkt_budgets` (версии), `mkt_campaign_notes`, `mkt_staff_channels`, `v_mkt_budget`, `m_mkt_budget_usage` | `svc_marketing` |
| Хаб | `hub` | users (scrypt), journal | `svc_hub` |

Правила загрузки 1С: только проведённые без пометки удаления; продажи и затраты со своим
юрлицом — `is_intragroup`; телефон в `core.leads` не хранится — только `md5` для склейки дублей
(ВАЖНО: без соли это псевдонимизация, а не обезличивание — см. SECURITY.md). ФИО и оклады
сотрудников — отдельная таблица `core.employee_names` (читает только адаптер HR `mart_hr.src_onb_employees`,
владелец показателей — нет); оклады в `core` не попадают: ЗУП сворачивается в суммы по отделу и месяцу при загрузке,
больничные — тоже (сведения о здоровье). Оплата труда в расходах — начисление ЗУП, разнесённое по дням месяца
(`metrics.payroll_daily`); проводка 1С «ФОТ» последним днём месяца в показатели не идёт, но сверяется с ней.

## Схема связей (core)
```mermaid
erDiagram
    legal_entities ||--o{ sales_docs : продаёт
    clients ||--o{ sales_docs : покупает
    sales_docs ||--o{ payments_in : "оплачен (документ-основание)"
    cash_accounts ||--o{ payments_in : на
    cash_accounts ||--o{ payments_out : с
    cash_accounts ||--o{ bank_lines : выписка
    suppliers ||--o{ expenses : акт
    clients ||--o{ leads : "заявка (склейка по БИН/телефону)"
    cohorts ||--o{ enrollments : места
    clients ||--o{ enrollments : учится
    employees ||--o| employee_names : "ФИО (только HR)"
    employees }o--o{ payroll_monthly : "отдел × месяц (сумма)"
    vacancies }o--o| employees : "закрыта наймом"
    ad_campaigns ||--o{ ad_spend : "расход по дням"
    ad_campaigns ||--o{ leads : "utm_campaign"
```

## Доступы (проверены атаками — SECURITY.md)
| Пользователь | Читает | Пишет |
|---|---|---|
| `airl_loader` | `raw_*` | `raw_*`, `core` (только через загрузку) |
| `metrics_owner` (без входа) | `core` | `metrics` (владелец; функции SECURITY DEFINER только на чтение) |
| `svc_finance` | `metrics`, `core.sales_docs`, `core.clients`, `core.cash_accounts`, адаптеры `src_*` | `mart_finance` |
| `svc_sales` | `metrics`, `core.leads`, `core.managers`, `src_pf_facts` | `mart_sales` |
| `svc_edu` | `metrics`, `core.cohorts`, `core.enrollments`, `core.clients(client_id, kind, name)` | `mart_edu` |
| `svc_hr` | `metrics`, адаптер `mart_hr.src_onb_employees`; `core` — нет | `mart_hr` |
| `svc_marketing` | `metrics`; `core` — нет | `mart_marketing` |
| `svc_hub` | `metrics` | `hub` |
| `ai_reader` (только чтение, 10 с) | `metrics`, `m_<…>` витрин (вкл. `m_onboarding_on_time_rate`, `m_mkt_budget_usage`) и их `airl_settings` | — |

## Сверка с источником
- Модули против `metrics`: `tests/reconcile.sql` — 9 проверок × до 18 месяцев, расхождений 0: в том числе расход кабинетов =
  1С «Реклама» и ФОТ ЗУП по дням = 1С «ФОТ» за каждый закрытый месяц, численность = работающие по ЗУП.
- С «отчётом 1С» сверить нельзя: 1С нет. В бою — выручка закрытого месяца против ОСВ 1С по 6010.

## Миграции и восстановление
`dwh/sql/00–05` и `dwh/marts/*` — повторяемые (`IF NOT EXISTS`, `CREATE OR REPLACE`, `ON CONFLICT`):
`setup_db.sh` можно запускать повторно. Отката по файлу нет — откат хранилища = восстановление из
копии (DEVOPS.md). Модули из `skills/airl-modules` скопированы без правок в `dwh/modules/`.

## Открытые вопросы
- НЕИЗВЕСТНО: доступ к 1С AIRL (OData или выгрузка), конфигурация, программист 1С.
- ПРЕДПОЛОЖЕНИЕ: оплата привязана к реализации документом-основанием (в реальной 1С бывает по договору — тогда нужен FIFO-разнос).
- ПРЕДПОЛОЖЕНИЕ: себестоимость = прямые статьи затрат; в 1С может быть отдельный счёт 7010.
- Загрузка в демо — полная перезапись `core`; в бою — окно 45 дней и `is_deleted` для исчезнувших документов.
