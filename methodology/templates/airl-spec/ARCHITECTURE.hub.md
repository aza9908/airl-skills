<!-- Шаблон схемы сервиса отдела в хабе. Пишет /airl-spec (режим B); дополняют
     /airl-architecture-extra, /airl-dwh и /airl-devops в том же блоке airl-context.
     Страна, роли, слои хранилища и сервер — из карты компании: здесь не выбираются. -->

# Архитектура сервиса «[Название]» — отдел [Отдел]

## Что строим
[одна фраза из SPEC.md, раздел 1]

## Страна и закон
Из раздела 1 карты (`airl/COMPANY_MAP.md`): страна [KZ / UZ / другая], валюта [код],
особые данные [нет / да: какие]. Свои значения здесь не придумываются.

## Схемы
<!-- По references/diagrams.md: контекст, структура сервиса, поток данных
     core/metrics → сервис → mart_<отдел> → хаб. -->
```mermaid
flowchart LR
    C[(core и metrics)] --> S[Сервис отдела: PWA и API]
    S --> M[(mart_[отдел])]
    S --> H[Хаб: /api/hub/summary]
```

## Контекст для следующих шагов
```yaml
# airl-context
mode: hub
service_id: [id отдела]
map_version: "[версия карты]"
country: [KZ]                 # из раздела 1 карты
currency: [KZT]
languages: [ru]
data_kind: [personal]         # из раздела 7 карты: ordinary | personal | sensitive | payment
login: hub                    # вход только через хаб
hosting: hub                  # сервер хаба, его ведёт команда AIRL
data_organization: shared-db-schemas
needs_dwh: true
level: 2
services: ["[id]: сервис отдела [отдел]"]
external_apis: []             # прямых вызовов 1С и CRM нет: данные через хранилище
downtime_ok: hours            # hours | minutes | none
data_loss_ok: hour            # копии витрины — не реже раза в час
maintainer: team              # сервер, прокси и копии ведёт команда AIRL
# дописывает /airl-dwh
database: postgresql
nosql: []
orchestrator: none
# дописывает /airl-devops
provider: "[сервер хаба]"
deploy: ci
escalation_contact: ""
unknowns: []
```
