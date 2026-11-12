# Архитектура демо-хаба AIRL

Хаб — оболочка (вход, шапка, экран руководителя, реестр) и пять сервисов отделов на одном домене
по путям `/finance`, `/sales`, `/marketing`, `/edu`, `/hr`. Все читают одно хранилище PostgreSQL: общие данные `core`,
единые показатели `metrics`; каждый пишет только в свою витрину `mart_<отдел>`.

## Страна и закон
Казахстан, KZT, НДС 12 % (показатели без НДС). Закон РК о персональных данных: база и копии —
на территории РК (в бою — сервер в РК; в демо — локальная песочница). Особых данных нет.

```yaml
# airl-context
mode: hub
country: KZ
currency: KZT
languages: [ru]
data_kind: personal          # имена и ИИН слушателей-физлиц, ФИО сотрудников (синтетические); окладов в хабе нет
login: hub                   # демо-издатель JWT RS256 в оболочке; в бою — Authentik
data_organization: shared-db-schemas
needs_dwh: true
dwh: postgresql-16 (raw_* → core → metrics → mart_<отдел>), 5 витрин
nosql: false
orchestrator: false          # загрузка — функция core.load() раз в сутки (cron на сервере)
level: 2
services: ["hub: оболочка и экран руководителя", "finance: ОПиУ, должники, сверка банка", "sales: воронка и план-факт", "marketing: каналы, кампании, бюджет рекламы", "edu: потоки и отсев", "hr: кадры, вакансии, онбординг, ФОТ по отделам"]
maintainer: team             # сервер, прокси и копии ведёт команда AIRL
unknowns: ["сервер и домен хаба", "доступ к 1С AIRL (OData)", "поддержка после курса"]
```

## 1. Контекст

```mermaid
flowchart LR
    CEO((Руководитель)) -->|смотрит цифры| H["Хаб руководителя<br/><small>PWA</small>"]
    FD((Финансы)) -->|ОПиУ, долги, банк| F["Сервис «Финансы»"]
    SM((Продажи)) -->|заявки, план| S["Сервис «Продажи»"]
    MK((Маркетинг)) -->|каналы, бюджет| M["Сервис «Маркетинг»"]
    CU((Кураторы)) -->|потоки, отсев| E["Сервис «Обучение»"]
    HRP((HR)) -->|вакансии, онбординг| R["Сервис «HR»"]
    F & S & M & E & R -->|/api/hub/summary| H
    C1[["1С ×2 базы + ЗУП"]] -.->|раз в сутки, только чтение| DWH[("Хранилище")]
    BK[["Выписки 2 банков"]] -.-> DWH
    AMO[["amoCRM"]] -.-> DWH
    ADS[["Кабинеты Meta, Google, Telegram"]] -.-> DWH
    GS[["Таблицы: потоки, вакансии, бюджет маркетинга"]] -.-> DWH
    DWH -.-> H & F & S & M & E & R
    classDef new fill:#efeafe,stroke:#8f7bf0,color:#16161a
    classDef ext fill:#ffffff,stroke:#16161a,color:#16161a
    class H,F,S,M,E,R,DWH new
    class C1,BK,AMO,GS,ADS ext
```
Как читать: фиолетовое построено в демо; белое — системы AIRL (в демо их заменяют синтетические
выгрузки той же формы). Пунктир — только чтение: в 1С, банк и amoCRM хаб ничего не пишет.

## 2. Структура продукта

```mermaid
flowchart TB
    U((Сотрудник<br/>с телефона или ПК)) --> PX["Прокси и сертификат<br/><small>Caddy · proxy/Caddyfile из hub/services.json</small>"]
    subgraph Сервер хаба
        PX -->|/| HUB["Оболочка хаба<br/><small>вход, JWT, экран руководителя</small>"]
        PX -->|/finance/*| FIN["Финансы<br/><small>Node.js, модули pnl-cashflow, receivables, bank-reconciliation</small>"]
        PX -->|/sales/*| SAL["Продажи<br/><small>Node.js, модуль plan-fact</small>"]
        PX -->|/marketing/*| MKT["Маркетинг<br/><small>Node.js</small>"]
        PX -->|/edu/*| EDU["Обучение<br/><small>Node.js</small>"]
        PX -->|/hr/*| HR["HR<br/><small>Node.js, модуль onboarding</small>"]
        HUB -.->|JWKS| FIN & SAL & MKT & EDU & HR
        DB[("PostgreSQL 16<br/><small>raw · core · metrics · mart_*</small>")]
        HUB -->|svc_hub: metrics| DB
        FIN -->|svc_finance| DB
        SAL -->|svc_sales| DB
        EDU -->|svc_edu| DB
        MKT -->|svc_marketing: metrics| DB
        HR -->|svc_hr: metrics, src_onb_employees| DB
        JOB[/"Загрузка raw → core<br/><small>core.load(), раз в сутки</small>"/] --> DB
        AI[/"Утренняя сводка<br/><small>ai/run_digest.sh, ai_reader</small>"/] -.-> DB
        BK[/"Резервная копия<br/><small>pg_dump ночью</small>"/] -.-> DB
    end
```
Как читать: прокси не срезает путь — каждый сервис собран под свой `base_path`. Каждый сервис
ходит в базу своим пользователем; права проверены атаками (`SECURITY.md`).

## 3. Поток данных

```mermaid
flowchart LR
    C1[["1С: реализации, оплаты,<br/>затраты; ЗУП: сотрудники, начисления, отсутствия"]] --> R1[("raw_1c")]
    BK[["Банки: выписки"]] --> R2[("raw_bank")]
    AMO[["amoCRM: заявки, UTM"]] --> R3[("raw_amocrm")]
    GS[["Потоки, слушатели, вакансии"]] --> R4[("raw_sheets")]
    AD[["Кабинеты и бюджет маркетинга"]] --> R5[("raw_ads")]
    R1 & R2 & R3 & R4 & R5 -->|core.load| CORE[("core<br/><small>одна карточка клиента;<br/>ФОТ и отсутствия — суммы по отделу</small>")]
    CORE --> MET[("metrics<br/><small>формулы карты</small>")]
    CORE -->|адаптеры src_*| MF[("mart_finance")]
    MET -->|src_pf_facts| MS[("mart_sales")]
    MET --> HUB["Экран руководителя"]
    MF <--> FIN["Финансы"]
    MS <--> SAL["Продажи"]
    ME[("mart_edu")] <--> EDU["Обучение"]
    CORE -->|адаптер src_onb_employees| MH[("mart_hr<br/><small>модуль onboarding</small>")]
    MH <--> HR["HR"]
    MM[("mart_marketing<br/><small>бюджет, заметки</small>")] <--> MKT["Маркетинг"]
    MET -->|ad_spend_daily| MM
    MET --> FIN & SAL & MKT & EDU & HR
    FIN & SAL & MKT & EDU & HR -->|summary| HUB
```
Как читать: модули читают данные только через адаптеры `src_*`; показатели модулей сверены
с `metrics` до копейки (`tests/reconcile.sql`, 0 расхождений). Оплата труда для ОПиУ — одна лента
`metrics.expense_entries` (ЗУП по дням месяца) и для хаба, и для модуля pnl-cashflow. Расход на рекламу
и ФОТ закрытых месяцев сверены с проводками 1С («Реклама», «ФОТ»).

## 4. Вход и открытие сервиса (главный сценарий)

```mermaid
sequenceDiagram
    actor U as Руководитель отдела
    participant H as Оболочка хаба
    participant F as Сервис «Финансы»
    participant D as Хранилище
    U->>H: логин и пароль (/auth/login)
    H->>D: hub.users: хеш scrypt, блокировка после 5 ошибок
    H-->>U: cookie airl_session (JWT RS256, HttpOnly, Secure, SameSite=Lax)
    U->>H: экран руководителя
    H->>D: metrics.kpi_period(месяц) — только свой отдел
    H->>F: /finance/api/hub/summary (Bearer токен пользователя, 3 с)
    F->>F: проверка подписи по JWKS, iss, aud, срок, роль
    F->>D: metrics + mart_finance (svc_finance)
    F-->>H: 4 показателя, светофор, предупреждения
    H-->>U: плитка «Финансы», переход без повторного входа
```

## 5. Статусы (сопоставление строки банка — модуль bank-reconciliation)

```mermaid
stateDiagram-v2
    [*] --> suggested: подбор bank_suggest
    suggested --> confirmed: «Подтвердить» (бухгалтер)
    suggested --> rejected: «Отклонить» + причина
    suggested --> expired: документ оплачен другой строкой
    confirmed --> reversed: отмена + причина
```

## Решения
| Вопрос | Решение | Почему |
|---|---|---|
| Стек сервисов | Node.js 22 без фреймворков, `pg`, PWA на чистом JS | одна зависимость; любой участник курса прочитает код |
| Вход | встроенный издатель JWT в оболочке (RS256 + JWKS) | демо без сервера; контракт тот же, что у Authentik, замена без правки сервисов |
| Хранилище | одна база, схемы по слоям, пользователь на сервис | права «свой участок» держит база, а не код |
| Прокси | Caddy, конфиг генерируется из реестра | `/airl-hub` часть 5, `/airl-devops` |
| ИИ | шаблонная сводка `/airl-ai` без модели | ключа API нет; числа те же, что в `metrics` |
| HR и маркетинг | свои сервисы; HR — модуль onboarding, маркетинг — без модуля leads (воронка в amoCRM) | `/airl-modules`, карта, раздел 10 |
| ПДн сотрудников | ФИО — отдельная таблица только для адаптера HR; оклады в хаб не попадают, ФОТ — по отделам (меньше 3 человек — объединены) | закон РК о ПДн, минимум данных |
| Цена в месяц (бой, оценка) | VPS в РК 4 vCPU/8 ГБ ≈ 25–35 тыс. ₸ + копии в другом ДЦ РК ≈ 5 тыс. ₸ | для ~35 сотрудников и 6 процессов Node.js хватает с запасом |
