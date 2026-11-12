# Аудит методики сопровождения VibeOps — дыры и их статус

Дата: 2026-11-12 · Версия навыков: 1.9.0 → 2.0.0 · Ветка `superskills`

Что проверяли: каждый `skills/*/SKILL.md`, их `references/`, скрипты, от которых
зависят приёмка и прогресс (`skills/airl-progress/scripts/progress.py`,
`skills/airl-hub/scripts/check_service.py`), и `README.md`.

Статусы: **исправлено** — правка в навыках этой версии · **передано в methodology** —
вопрос организации курса, его закрывают руководства в `methodology/` (их пишет
отдельный агент) · **осталось** — известно, не исправлено, причина указана.

Итог: 18 разрывов передачи, 20 шаблонов (14 не было, 6 были встроены в справочники),
16 тупиков, 9 противоречий, 8 мест, где новичок застревает. Всего 71.

---

## 1. Передача между навыками (H)

### Матрица «кто пишет → кто читает»

| Артефакт | Пишет | Читает | Что сверяли |
|---|---|---|---|
| `CLAUDE.md` (разделы «Состояние», «Журнал задач») | `/airl-context` | все навыки (общее правило), `progress.py` (`claude_md`, ≥200 байт) | имена разделов совпадают |
| `SCOPE.md` | `/airl-spec` A0 | `/airl-modules`, `/airl-connect`, `/airl-integrations` | корзины «модуль», «купить», «инженерный трек» |
| `COMPANY_MAP.md` / `airl/COMPANY_MAP.md` | `/airl-spec` A, A2 | все навыки хаба, `check_service.py` (разделы 4, 6, `map_version`), `progress.py` (`company_map`) | `### id — Название` в разделе 4, `` `id` `` и «Даёт доступ» в разделе 6 |
| `SPEC.md` (разделы 1–13) | `/airl-spec` S, B | все навыки; `progress.py`: «Цена боли» в разделе 1, «Метрика успеха», `- [ ]` в разделе 10, `- [x] Demo Day`, заголовок с «Модул» | номера разделов, строки-маркеры |
| `ARCHITECTURE.md`, блок `# airl-context` | `/airl-spec`, дополняют `/airl-architecture-extra`, `/airl-dwh`, `/airl-devops` | `/airl-dwh`, `/airl-pwa`, `/airl-cybersecurity`, `/airl-code-review`, `/airl-devops`, `progress.py` (`mode:`) | имена ключей |
| `airl.service.json` | `/airl-spec` B | `/airl-pwa`, `/airl-cybersecurity`, `/airl-modules`, `/airl-hub`, `check_service.py`, `progress.py` | `id`, `base_path`, `hub.health/summary/metrics`, `data.reads/reads_shared/writes`, `public_paths`, `pii`, `version` |
| `DWH.md` | `/airl-dwh` | `/airl-pwa`, `/airl-code-review`, `/airl-devops`, `/airl-ai`, `/airl-integrations`, `progress.py` (≥300 байт) | — |
| миграции `*.sql` | `/airl-dwh`, `/airl-modules` | `/airl-code-review`, `/airl-devops`, `progress.py` (`migrations`, `module`) | `kit` или id модуля в имени |
| `CONNECT.md` | `/airl-connect` | `/airl-hub` (плитка), `progress.py` (`module`) | — |
| код: `manifest`, `sw.js`, `/healthz`, `/api/hub/summary` | `/airl-pwa` | `/airl-devops`, `/airl-hub`, `check_service.py`, `progress.py` | строки `healthz`, `hub/summary` |
| `SECURITY.md` (вердикт) | `/airl-cybersecurity` | `/airl-code-review`, `/airl-devops`, `/airl-hub` ворота 6, `progress.py` (`security_ok`) | строка вердикта |
| `REVIEW.md` (число блокирующих) | `/airl-code-review` | `/airl-devops`, `/airl-hub` ворота 7, `progress.py` (`review_ok`) | «Блокирующих замечаний: N» |
| `DEVOPS.md` (откат, копии, контакт) | `/airl-devops` | `/airl-hub` ворота 12, `/airl-debug`, `/airl-integrations`, `progress.py` (≥300 байт) | дата отката |
| `Dockerfile`, compose, `.github/workflows/` | `/airl-devops` | `/airl-code-review`, `progress.py` | — |
| `AI.md`, `ai/*.json` | `/airl-ai` | итоговый документ | — |
| `HUB.md` | `/airl-hub` A | итоговый документ команды AIRL | — |
| `HUB_CHECK.md` («Решение») | `/airl-hub` B1, B2 | команда AIRL, `progress.py` (`demo` хаба) | значения «Решения» |
| `INTEGRATIONS.md` | `/airl-integrations` | итоговый документ инженерного трека | — |
| `DEBUG.md` | `/airl-debug` | `/airl-debug` (повторы), `CLAUDE.md` | — |

### Найденные разрывы

| № | Где | Что не так | Статус |
|---|---|---|---|
| H1 | `skills/airl-hub/scripts/check_service.py:83` (вся функция `check_files`) | Ворота 6 и 7 (`SECURITY.md`, `REVIEW.md`) помечены «да · файл», но скрипт их не читает: проверку делали глазами, строки вердикта нигде не разбирались одинаково с `progress.py` | исправлено: скрипт читает оба файла рядом с `airl.service.json` и разбирает их тем же правилом, что `progress.py` |
| H2 | `skills/airl-hub/SKILL.md:281`, `skills/airl-devops/references/production-readiness.md:16`, `skills/airl-cybersecurity/SKILL.md:332` | Три разных формулировки вердикта: «можно подключать — да», «можно открывать людям — да», `**Можно открывать людям** (в хабе: подключать к хабу): да / нет`. `progress.py:616` понимает только последнюю | исправлено: одна строка из шаблона `SECURITY.md`, ссылки на неё в хабе и чек-листе продакшена |
| H3 | `skills/airl-code-review/templates/REVIEW.md:8`, `skills/airl-progress/scripts/progress.py:632` | В пустом шаблоне уже стоит «Блокирующих замечаний: 0» — нетронутая копия шаблона засчитывалась как пройденное ревью | исправлено: в шаблоне `[N]`; `progress.py` и `check_service.py` не засчитывают ревью с незаполненным коммитом |
| H4 | `skills/airl-progress/scripts/progress.py:616` | Строка вердикта «да / нет» без выбора засчитывалась как «да» | исправлено |
| H5 | `skills/airl-hub/SKILL.md:319`, `progress.py:639` | Незаполненное «Решение: готов к приёмке / подключён / не подключён / …» давало 0,25 | исправлено: строка с вариантами через « / » не засчитывается |
| H6 | `skills/airl-spec/references/solo-product.md:157`, `progress.py:823` | Этап Demo Day у своего продукта засчитывается по `- [x] Demo Day`, но ни один навык не говорит поставить эту отметку | исправлено: `/airl-devops`, раздел «Demo Day (свой продукт)» |
| H7 | `skills/airl-modules/SKILL.md:105` | «Запиши в `SPEC.md` новым разделом «Модули»» — без номера; разделы ТЗ навыки ищут по номерам, раздел без номера мог встать между 12 и 13 | исправлено: `## 14. Модули` во всех шаблонах `SPEC.md` и в навыке (маркер `progress.py` «Модул» сохраняется) |
| H8 | `skills/airl-dwh/SKILL.md:489` | «Дополни блок airl-context: тип базы, хранилище, NoSQL, оркестратор» — имена ключей не заданы, следующие навыки их не найдут | исправлено: ключи `database`, `needs_dwh`, `nosql`, `orchestrator` в шаблоне `ARCHITECTURE.md` и в навыке |
| H9 | `skills/airl-devops/SKILL.md:504` | То же для `/airl-devops`: «провайдер, способ выкладки, контакт» без имён ключей | исправлено: `provider`, `deploy`, `escalation_contact` |
| H10 | `skills/airl-spec/references/service-spec.md:240` | Блок `airl-context` сервиса отдела без `hosting`, `downtime_ok`, `data_loss_ok`, `external_apis`, которые читают `/airl-code-review` и `/airl-devops` | исправлено: ключи добавлены в шаблон `ARCHITECTURE.hub.md` |
| H11 | `skills/airl-architecture-extra/SKILL.md:290` | Список значений `data_organization` без `single-db`, которое пишет `/airl-spec` по умолчанию | исправлено |
| H12 | `skills/airl-hub/SKILL.md:313` | Режим B2 идёт в репозитории хаба, а `HUB_CHECK.md` должен лежать в репозитории сервиса (его читает `progress.py`) — не сказано, кто и как его туда кладёт | исправлено: «закоммить в репозиторий сервиса (или передай владельцу сервиса)» |
| H13 | `skills/airl-connect/SKILL.md:158` | План настройки (шаг 2) пишется, но в шаблоне `CONNECT.md` для него нет раздела; приёмки (шаг 5) тоже нет | исправлено в шаблоне |
| H14 | `skills/airl-cybersecurity/SKILL.md:389` | После «можно открывать» следующий шаг — сразу `/airl-devops`, мимо `/airl-code-review`, хотя `/airl-devops` и ворота 7 требуют `REVIEW.md` | исправлено |
| H15 | `skills/airl-modules/SKILL.md:202` | После модулей следующий шаг — `/airl-cybersecurity` (неделя 3), мимо `/airl-pwa` (неделя 2) | исправлено |
| H16 | `skills/airl-pwa/SKILL.md:68`, `airl-dwh/SKILL.md:72`, `airl-architecture-extra/SKILL.md:66` | `DESIGN.md` читают три навыка, но ни один его не пишет (наследие однодневного блока `/design`) | осталось: у каждого навыка есть запасной путь (вопрос о стиле); отдельный шаблон не нужен |
| H17 | `README.md:86`, `README.md:128` | Пути 1 и 2 в README пропускают `/airl-code-review`, хотя без `REVIEW.md` нет ворот 7 и пункта `review_ok`; в пути 2 у отделов нет `/airl-modules` и `/airl-connect` | исправлено |
| H18 | `skills/airl-spec/references/service-spec.md:167` | В плане спринтов сервиса отдела нет строки недели 1, а у своего продукта есть — `/airl-pwa` и `/airl-dwh` отмечают недели по этим строкам | исправлено |

## 2. Шаблоны документов (T)

Было: шаблоны лежали внутри `references/*.md` или в тексте `SKILL.md`, а части документов
не было вовсе. Стало: каждый документ — файл в `skills/<навык>/templates/`, справочник
ссылается на него, копия для руководств — `methodology/templates/<навык>/`
(`scripts/sync_templates.py`).

| № | Документ | Было | Стало | Статус |
|---|---|---|---|---|
| T1 | `CLAUDE.md` | в тексте `airl-context/SKILL.md:36` | `airl-context/templates/CLAUDE.md` | исправлено |
| T2 | `SPEC.md` (свой продукт) | `airl-spec/references/solo-product.md:94` | `airl-spec/templates/SPEC.md` | исправлено |
| T3 | `SPEC.md` (сервис отдела) | `airl-spec/references/service-spec.md:91` | `airl-spec/templates/SPEC.hub.md` | исправлено |
| T4 | `ARCHITECTURE.md` (свой продукт) | `airl-spec/references/solo-product.md:191` | `airl-spec/templates/ARCHITECTURE.md` | исправлено |
| T5 | `ARCHITECTURE.md` (сервис отдела) | только блок в `service-spec.md:236` | `airl-spec/templates/ARCHITECTURE.hub.md` | исправлено |
| T6 | `airl.service.json` | `service-spec.md:189` | `airl-spec/templates/airl.service.json` | исправлено |
| T7 | `COMPANY_MAP.md` | `airl-spec/references/company-map.md:117` | `airl-spec/templates/COMPANY_MAP.md` | исправлено |
| T8 | `SCOPE.md` | `airl-spec/references/scope.md:104` | `airl-spec/templates/SCOPE.md` | исправлено |
| T9 | запрос на изменение объёма | не было | `airl-spec/templates/SCOPE_CHANGE.md` | исправлено |
| T10 | `PRD_CONTEXT.md`, `PRD_FINAL.md`, `BACKLOG.md` | `prd-pipeline.md`, `prd-templates.md` | остались в справочниках режима P | осталось: это уже отдельные файлы шаблонов, режим P читает их целиком; вынос не меняет поведения |
| T11 | `DWH.md` | только список из 12 пунктов, `airl-dwh/SKILL.md:474` | `airl-dwh/templates/DWH.md` | исправлено |
| T12 | `CONNECT.md` | `airl-connect/SKILL.md:117` (без плана и приёмки) | `airl-connect/templates/CONNECT.md` | исправлено |
| T13 | `SECURITY.md` | `airl-cybersecurity/SKILL.md:328` | `airl-cybersecurity/templates/SECURITY.md` | исправлено |
| T14 | `REVIEW.md` | `airl-code-review/templates/REVIEW.md` (с готовым «0») | тот же файл, пустышка `[N]` и пояснения | исправлено |
| T15 | `DEVOPS.md` | только список из 14 пунктов, `airl-devops/SKILL.md:485` | `airl-devops/templates/DEVOPS.md` | исправлено |
| T16 | `Dockerfile`, `docker-compose.yml`, `.env.example` | compose в `server-setup.md:240`, остального нет | `airl-devops/templates/` | исправлено |
| T17 | `AI.md` | `airl-ai/SKILL.md:204` | `airl-ai/templates/AI.md` | исправлено |
| T18 | `HUB.md`, `HUB_CHECK.md` | `HUB.md` — одна строка `airl-hub/SKILL.md:209`; `HUB_CHECK.md` — `:315` | `airl-hub/templates/` | исправлено |
| T19 | `DEBUG.md` | `airl-debug/SKILL.md:186` | `airl-debug/templates/DEBUG.md` | исправлено |
| T20 | `INTEGRATIONS.md` | `airl-integrations/SKILL.md:146` | `airl-integrations/templates/INTEGRATIONS.md` | исправлено |

## 3. Тупики — ситуации без инструкции (D)

| № | Ситуация | Кто должен отвечать | Статус |
|---|---|---|---|
| D1 | У участника нет GitHub, не ставится git, Claude Code или Python, корпоративный ноутбук без прав | `/airl-context` | исправлено: раздел «Если нет GitHub или ничего не ставится» |
| D2 | Нет доступа к 1С (главной системе) к неделе 2 | `/airl-dwh` | исправлено: путь «синтетика / обезличенная выгрузка» и когда переходить на «свой продукт» |
| D3 | `SECURITY.md` с вердиктом «нельзя» на неделе 4 / перед Demo Day | `/airl-cybersecurity` | исправлено |
| D4 | Сервис не прошёл ворота хаба за 2 дня до Demo Day | `/airl-hub` | исправлено: `degraded` только для 10–13, показ с локального стенда, честная строка в `HUB_CHECK.md` |
| D5 | Клиент меняет объём посреди курса | `/airl-spec` (`scope.md`) | исправлено: запрос на изменение `SCOPE_CHANGE.md`, подпись, затем A2 для карты |
| D6 | Закончился лимит токенов посреди задачи | `/airl-context` | исправлено |
| D7 | Нет бюджета на сервер | `/airl-devops` | исправлено: временная площадка с честной пометкой; не для особых данных |
| D8 | Команды для Windows и Mac различаются | `/airl-context` (таблица), `/airl-devops/references/server-setup.md` (сервер) | исправлено |
| D9 | Участник выбыл, у модуля нет владельца | `/airl-progress` (что делать со списком), `/airl-spec` (перенос объёма) | исправлено частично: навыки; правила замены участника — передано в methodology |
| D10 | Повестка офлайн-дня | организация курса | передано в methodology |
| D11 | Формат Demo Day и приёмка своего продукта | `/airl-hub` режим C (хаб); `/airl-devops` (свой продукт) | исправлено: раздел «Demo Day (свой продукт)» в `/airl-devops`; сценарий дня — передано в methodology |
| D12 | Поддержка после курса и передача клиенту | `/airl-devops` | исправлено: раздел «Если курс закончился — передача»; договор поддержки — передано в methodology |
| D13 | «Позвать инженера AIRL» — не сказано, как и куда | `/airl-debug` | исправлено: что приложить; канал связи потока — передано в methodology |
| D14 | Сервис хаба не может войти: контракт входа не заполнен к неделе 3 | `/airl-cybersecurity` (есть: «ждёт команду AIRL») | исправлено ранее, проверено |
| D15 | Готовая система не куплена к неделе 1 | `/airl-connect` | исправлено: корзина «после курса» через `SCOPE_CHANGE.md` |
| D16 | Ревью нашло блокирующее, которое не успеть до Demo Day | `/airl-code-review` | исправлено: показ на staging / локально, «нельзя выкладывать» не снижается |

## 4. Противоречия (C)

| № | Где | Что расходится | Статус |
|---|---|---|---|
| C1 | `skills/airl-hub/SKILL.md:226` и `:227` | Самопроверка: «пройди ворота 1–7» и тут же «ворота 5 проверить нельзя» | исправлено: 1–4, 6, 7, 11–13 |
| C2 | `skills/airl-cybersecurity/SKILL.md:3` | В описании «лежат там, где требует закон РК», а `/airl-spec` запрещает подставлять Казахстан | исправлено: «закон страны» |
| C3 | `skills/airl-hub/SKILL.md:99`, `skills/airl-spec/references/scope.md:70` | «Неделя 0 — за 2–3 недели до офлайн-дня» и «7 недель: неделя 0, офлайн-день, 4 недели, неделя после» | исправлено: «неделя 0 начинается за 2–3 недели до офлайн-дня»; 7 недель — время инженеров на сам курс |
| C4 | `skills/airl-hub/SKILL.md:281`, `production-readiness.md:16`, `airl-cybersecurity/SKILL.md:332` | Три формулировки вердикта безопасности (см. H2) | исправлено |
| C5 | `skills/airl-architecture-extra/SKILL.md:290`, `solo-product.md:255` | `data_organization: single-db` не входит в список значений (см. H11) | исправлено |
| C6 | `README.md:86`, `skills/airl-cybersecurity/SKILL.md:389`, `skills/airl-code-review/SKILL.md:3` | Порядок недели 4: README и `/airl-cybersecurity` ведут сразу в `/airl-devops`, ревью — «до выкладки» | исправлено: защита → ревью → выкладка → хаб |
| C7 | `skills/airl-modules/SKILL.md:202`, `README.md:66` | Модули «недели 1–2», но следующий шаг — неделя 3 (см. H15) | исправлено |
| C8 | `skills/airl-architecture-extra/SKILL.md:192`, `solo-product.md:279` | «Сутки и час простоя» против «простой — час и больше, потеря — сутки» | исправлено: «простой — часы, потеря — сутки» |
| C9 | `skills/airl-spec/references/scope.md:52`, `skills/airl-modules/SKILL.md:94` | 4–6 ч участника в неделю, из них 3 ч урок → 1–3 ч на модуль; в модулях «2–3 часа» | осталось: числа совместимы (8–12 ч за 4 недели); формулировка не мешает |

## 5. Где новичок застревает (N)

| № | Где | Что предполагается знать | Статус |
|---|---|---|---|
| N1 | `skills/airl-context/SKILL.md:29` | «Проверь git и GitHub. Нет — предложи создать» без шагов | исправлено: шаги и ссылка на раздел «Если нет GitHub» |
| N2 | `skills/airl-dwh/SKILL.md:523` | «Нужен Docker Desktop» — без шагов и без варианта для ноутбука без прав | исправлено: шаги и запасной путь (облачная тестовая база без настоящих данных) |
| N3 | `skills/airl-ai/SKILL.md:135` | `VAR=... python3 …` не работает в PowerShell | исправлено: ссылка на таблицу Windows/Mac в `/airl-context` |
| N4 | `skills/airl-code-review/SKILL.md` (шаг 1) | `bash scripts/review_checks.sh` — на Windows нет bash | исправлено: Git Bash / WSL или CI |
| N5 | `skills/airl-hub/SKILL.md:223` | `python3` на Windows называется `py` | исправлено через таблицу в `/airl-context` |
| N6 | все навыки | Переменные окружения и файл `.env` — нигде не объяснено, что это и как завести | исправлено: шаблон `.env.example` с пояснениями и строка в таблице `/airl-context` |
| N7 | `skills/airl-devops/references/server-setup.md:293` | DNS: «A-запись в панели регистратора» без пояснения | осталось: в справочнике уже есть проверка `nslookup`; пошаговые скриншоты панелей регистраторов — передано в methodology |
| N8 | `skills/airl-progress/SKILL.md` | Токен GitHub — шаги есть | проверено, правка не нужна |

## 6. Что проверяют тесты

`tests/test_templates.py`:

- каждый документ, который `SKILL.md` велит создать или записать, имеет шаблон в `templates/`;
- репозиторий, собранный из заполненных шаблонов, `progress.py --local` доводит до этапа
  «Всё готово» (свой продукт и сервис отдела в хабе);
- вердикты `SECURITY.md` и `REVIEW.md` одинаково разбирают `progress.py` и `check_service.py`;
- `methodology/templates/` совпадает с `skills/*/templates/`.
