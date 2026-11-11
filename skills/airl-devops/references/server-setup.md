# Сервер шаг за шагом

Команды для частей 0–7 плана из `SKILL.md`. Рассчитаны на Ubuntu 22.04 / 24.04.
Всё в угловых скобках (`<IP>`, `<домен>`, `<пользователь>`, `<проект>`, `<порт>`) —
**спроси у человека или возьми из проекта и подставь настоящее значение**. Команду
с неподставленной скобкой не выдавай. `<порт>` — порт, который приложение слушает
внутри контейнера: возьми его из кода и `Dockerfile`, не угадывай.

Перед каждой командой из жёлтой и красной зоны памятки — остановка и явное «да».

## Часть 0. Репозиторий, Dockerfile и первый образ

Сервер получает готовый образ продукта из реестра GitHub. Поэтому образ должен
появиться раньше, чем контейнеры на сервере.

1. **Репозиторий.** Проверь `git remote -v`. Удалённого репозитория нет — проведи
   человека: приватный репозиторий на GitHub создаёт он сам, затем первый коммит
   и отправка. До коммита убедись, что `.env` записан в `.gitignore`.
2. **Dockerfile.** Нет в репозитории — напиши под стек проекта:
   - многоэтапная сборка: в первом этапе зависимости и сборка, во втором только
     то, что нужно для работы;
   - **один контейнер отдаёт всё на одном порту**: интерфейс (собранные файлы PWA),
     API и `/healthz`. Если интерфейс — статические файлы, их раздаёт серверная
     часть продукта;
   - процесс работает не под root (`USER`), порт объявлен в `EXPOSE`;
   - `.dockerignore`: `.env*`, `.git`, `node_modules`, копии базы.
3. **Проверка образа** на компьютере человека, если стоит Docker, иначе сразу в CI:

```bash
docker build -t <проект>:test .
```

4. **Сборка в GitHub Actions.** Создай `.github/workflows/deploy.yml` из части 7,
   но **пока без последнего шага «Выкладка на сервер»**. Отправь в `main`, дождись
   зелёной сборки и запиши метку образа (полный хеш коммита) — она понадобится
   в части 3 как `APP_TAG`.
5. Образ в реестре приватный. Серверу нужен токен только на чтение пакетов
   (`read:packages`): человек создаёт его сам в настройках GitHub и вводит на
   сервере в части 3. В чат токен не вставляется.

## Часть 1. Сервер, вход по ключу, обычный пользователь

На компьютере человека (не на сервере) — ключ, если его ещё нет:

```bash
ssh-keygen -t ed25519 -C "<подпись ключа>"
```

```bash
ssh-copy-id root@<IP>
```

На Windows `ssh-copy-id` нет: открыть файл `.ssh\id_ed25519.pub` в папке пользователя,
скопировать строку и добавить её в панели провайдера при создании сервера.

На сервере под root — новый пользователь с правом `sudo` и тем же ключом:

```bash
adduser <пользователь>
```

```bash
usermod -aG sudo <пользователь>
```

```bash
rsync --archive --chown=<пользователь>:<пользователь> /root/.ssh /home/<пользователь>
```

**Не закрывая это окно**, открой второе и проверь вход:

```bash
ssh <пользователь>@<IP>
```

```bash
sudo whoami
```

Должно вывести `root`. Только после этого закрывай вход под root и по паролю. Файл
называется с `00-`, потому что sshd берёт первое встреченное значение, а на облачных
образах Ubuntu уже лежит `50-cloud-init.conf`, который разрешает пароль:

```bash
printf 'PermitRootLogin no\nPasswordAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/00-airl.conf
```

```bash
sudo sshd -t && sudo systemctl reload ssh
```

Проверка, что настройка действительно применилась — обе строки должны быть `no`:

```bash
sudo sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin)'
```

Проверь в третьем окне, что вход новым пользователем всё ещё работает. Не работает —
первое окно ещё открыто под root: удали файл и перезагрузи ssh.

Обновления безопасности:

```bash
sudo apt update && sudo apt install -y unattended-upgrades curl
```

## Часть 2. Межсетевой экран

Порядок важен: сначала разрешить SSH, потом включать.

```bash
sudo ufw allow OpenSSH
```

```bash
sudo ufw allow 80/tcp
```

```bash
sudo ufw allow 443/tcp
```

```bash
sudo ufw enable
```

```bash
sudo ufw status
```

Наружу открыты только 22, 80, 443. Важно: Docker публикует порты **в обход ufw**.
Поэтому в `docker-compose.yml` порты баз и служебных систем не публикуются вовсе,
а порт, нужный на самом сервере, публикуется только на `127.0.0.1`.

Проверка снаружи, с компьютера человека — должен быть отказ или таймаут:

```bash
nc -zv <IP> 5432
```

На Windows (PowerShell):

```powershell
Test-NetConnection <IP> -Port 5432
```

## Часть 3. Docker и контейнеры

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
```

Это официальный установщик Docker. Скажи человеку, что скачали, и только потом:

```bash
sudo sh get-docker.sh
```

```bash
sudo usermod -aG docker <пользователь>
```

Перезайти на сервер, затем проверить:

```bash
docker run --rm hello-world
```

Папка проекта (в хабе — `/srv/hub/<id сервиса>/`):

```bash
sudo mkdir -p /srv/<проект> && sudo chown <пользователь>: /srv/<проект>
```

Вход в реестр GitHub токеном на чтение (человек вводит токен сам, он не виден):

```bash
docker login ghcr.io -u <логин GitHub>
```

В папке проекта — три файла окружения. **Приложение не получает пароль
администратора базы**: это правило проверки безопасности.

| Файл | Что в нём | Кто читает |
|---|---|---|
| `.env` | `APP_TAG=<метка образа из части 0>`, `APP_PORT=<порт>`, `HEALTH_PATH=/healthz` | Docker Compose и скрипт выкладки |
| `.env.db` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `APP_DB_USER`, `APP_DB_PASSWORD` | только контейнер базы |
| `.env.app` | `DATABASE_URL` с пользователем `APP_DB_USER` и остальные ключи продукта | только приложение |

Значения паролей человек придумывает и вписывает сам (длинные, разные), в чат они
не попадают. Права — только владельцу:

```bash
chmod 600 /srv/<проект>/.env /srv/<проект>/.env.db /srv/<проект>/.env.app
```

Пользователь приложения создаётся при первом запуске базы скриптом
`/srv/<проект>/initdb/01-app-user.sh`. Сам он таблицы не создаёт и не меняет — это
делают миграции под администратором базы; приложение только читает и пишет данные:

```bash
#!/bin/bash
set -euo pipefail
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
     -v app_user="$APP_DB_USER" -v app_pass="$APP_DB_PASSWORD" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_pass';
GRANT CONNECT ON DATABASE :"DBNAME" TO :"app_user";
GRANT USAGE ON SCHEMA public TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";
SQL
```

Скрипт выполняется один раз, на пустом томе. Если база уже существует — выполни
те же команды SQL вручную под администратором. Если таблицы уже созданы, добавь
`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public` и
`GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public` тому же пользователю.

В хабе этот скрипт не нужен: базу хранилища и пользователей `svc_<отдел>` ведёт
команда AIRL через `/airl-dwh`, сервис получает только свой `DATABASE_URL`.

Каркас `docker-compose.yml` — подставь реальные сервисы проекта:

```yaml
services:
  app:
    image: ghcr.io/<владелец строчными>/<репозиторий строчными>:${APP_TAG}
    restart: unless-stopped
    env_file: .env.app
    ports:
      - "127.0.0.1:${APP_PORT}:${APP_PORT}"
    depends_on:
      db:
        condition: service_healthy
    networks: [web, internal]

  db:
    image: postgres:16
    restart: unless-stopped
    env_file: .env.db
    volumes:
      - db_data:/var/lib/postgresql/data
      - ./initdb:/docker-entrypoint-initdb.d:ro
    networks: [internal]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 10s
      retries: 5

volumes:
  db_data:

networks:
  web:
    external: true
  internal:
```

Обязательно: у базы **именованный том** (иначе данные исчезнут при пересоздании
контейнера), у базы **нет** раздела `ports`, у каждого сервиса `restart: unless-stopped`
(поднимется сам после перезагрузки сервера), образ с меткой версии, а не `latest`.
Порт приложения опубликован только на `127.0.0.1` — снаружи он недоступен, а
скрипт выкладки проверяет по нему `/healthz` с самого сервера. Так проверка не
зависит от того, есть ли внутри образа `wget` или `curl`.

Общая сеть для прокси создаётся один раз:

```bash
docker network create web
```

Запуск и проверка:

```bash
cd /srv/<проект> && docker compose up -d && docker compose ps
```

```bash
curl -fsS http://127.0.0.1:<порт>/healthz
```

`/healthz` должен отвечать без входа. Если после проверки безопасности он отдаёт
401 — это ошибка в продукте: адрес исключается из проверки токена.

Затем примени миграции базы тем способом, который записан в `DWH.md`, и повтори
проверку. Образы на сервере не собираются: на тарифах с памятью до 2 ГБ сборка
может уронить сервер.

## Часть 4. Прокси и защищённое соединение

Сначала DNS: A-запись `<домен>` → `<IP>` в панели регистратора домена. Проверка
с компьютера (на Windows тоже работает):

```bash
nslookup <домен>
```

Должен вернуться IP сервера. Пока не вернулся — сертификат не выпустится, ждём.

Прокси Caddy сам выпускает и продлевает сертификат Let's Encrypt. Отдельный проект
в `/srv/proxy/` (создай папку так же, как папку проекта). Настройка лежит в папке
`conf/`, а не одним файлом: так правки файла сразу видны контейнеру.

```yaml
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./conf:/etc/caddy:ro
      - caddy_data:/data
    networks: [web]
volumes:
  caddy_data:
networks:
  web:
    external: true
```

`/srv/proxy/conf/Caddyfile` для одного продукта на своём домене:

```caddyfile
<домен> {
    encode zstd gzip
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
    }
    reverse_proxy app:<порт>
}
```

`app` — имя сервиса из `docker-compose.yml` продукта: прокси видит его через общую
сеть `web`. В хабе у каждого сервиса своё имя (его `id`), и файл с блоками
`handle /<id>/*` ведёт `/airl-hub`.

```bash
cd /srv/proxy && docker compose up -d
```

После любой правки — проверка настройки и перезагрузка без остановки:

```bash
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
```

```bash
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Проверка снаружи:

```bash
curl -sI https://<домен>
```

Первая строка должна содержать `200` (или `302`, если продукт сразу ведёт на вход).

Уже стоит nginx — не меняй на Caddy ради единообразия: сертификат через `certbot
--nginx -d <домен>`, перед каждой перезагрузкой `sudo nginx -t`.

## Часть 5. Резервные копии и проверка восстановления

Скрипт `/srv/<проект>/backup.sh`. Копия сначала пишется во временный файл: если
выгрузка оборвётся, обрывок не останется лежать под видом копии.

```bash
#!/bin/bash
set -euo pipefail
cd /srv/<проект>
mkdir -p backups
OUT="backups/db_$(date +%F_%H%M).dump"
TMP="$OUT.tmp"
trap 'rm -f "$TMP"' EXIT
docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$TMP"
test -s "$TMP"
mv "$TMP" "$OUT"
find backups -name 'db_*.dump' -mtime +14 -delete
```

```bash
chmod +x /srv/<проект>/backup.sh && /srv/<проект>/backup.sh && ls -lh /srv/<проект>/backups
```

Расписание — каждый день в 03:00 (`crontab -e`):

```text
0 3 * * * /srv/<проект>/backup.sh >> /srv/<проект>/backups/backup.log 2>&1
```

Копия на том же сервере спасает от ошибки, но не от потери сервера. Вторая копия —
в другое место: объектное хранилище провайдера или второй сервер (`rclone copy`).
Для персональных данных граждан РК вторая копия тоже остаётся в Казахстане.

**Проверка восстановления — обязательна.** Во временную базу, не в рабочую:

```bash
docker run -d --name restore-test -e POSTGRES_PASSWORD=test postgres:16
```

```bash
until docker exec restore-test pg_isready -U postgres; do sleep 1; done
```

```bash
docker exec -i restore-test pg_restore -U postgres -d postgres --no-owner --no-privileges < /srv/<проект>/backups/<файл копии>
```

```bash
docker exec restore-test psql -U postgres -c '\dt'
```

Таблицы на месте, число строк в главной таблице похоже на правду — запиши дату проверки
в `DEVOPS.md`. Затем убери временную базу:

```bash
docker rm -f restore-test
```

## Часть 6. Мониторинг и оповещения

Минимум, который должен быть у каждого продукта:

1. Адрес `GET /healthz` в продукте, без авторизации и без данных.
2. Внешняя проверка `https://<домен>/healthz` раз в 1–5 минут с оповещением
   в Telegram или на почту: готовый сервис (UptimeRobot, Better Stack) или Uptime
   Kuma на **другом** сервере. Проверка на том же сервере не заметит, что сервер упал.
3. Оповещение о диске: строка в cron, которая пишет в Telegram при заполнении
   больше 80%.
4. Ротация логов Docker, чтобы они не съели диск — `/etc/docker/daemon.json`:

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "5" } }
```

Перезапуск Docker после этой правки перезапускает контейнеры — жёлтая зона.

Набор Grafana + Prometheus + Loki — только если так решено в `ARCHITECTURE.md`.

## Часть 7. Автоматическая выкладка из GitHub и откат

Цепочка: отправили код в `main` → проверки → сборка образа → образ в реестр GitHub
→ сервер забирает образ по метке → проверка `/healthz` → при сбое возврат
на предыдущую метку.

### Скрипт выкладки на сервере

`/srv/<проект>/deploy.sh` обновляет только приложение (база не перезапускается)
и сам откатывается, если новая версия не отвечает:

```bash
#!/bin/bash
set -euo pipefail
cd /srv/<проект>
NEW_TAG="${1:-}"
[[ "$NEW_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Нужна метка образа" >&2; exit 2; }

grep -q '^APP_TAG=' .env || echo 'APP_TAG=' >> .env
OLD_TAG=$(grep -oP '^APP_TAG=\K.*' .env)
PORT=$(grep -oP '^APP_PORT=\K.*' .env)
HEALTH=$(grep -oP '^HEALTH_PATH=\K.*' .env || true)
HEALTH="${HEALTH:-/healthz}"

set_tag() { sed -i "s/^APP_TAG=.*/APP_TAG=$1/" .env; }

set_tag "$NEW_TAG"
docker compose pull app
docker compose up -d app

for _ in $(seq 1 12); do
  if curl -fsS "http://127.0.0.1:$PORT$HEALTH" >/dev/null 2>&1; then
    if [ -n "$OLD_TAG" ] && [ "$OLD_TAG" != "$NEW_TAG" ]; then
      echo "$OLD_TAG" > .previous_tag
    fi
    echo "Выложено: $NEW_TAG"
    exit 0
  fi
  sleep 5
done

if [ -n "$OLD_TAG" ] && [ "$OLD_TAG" != "$NEW_TAG" ]; then
  echo "Проверка не прошла, откат на $OLD_TAG" >&2
  set_tag "$OLD_TAG"
  docker compose up -d app
else
  echo "Проверка не прошла, предыдущей версии нет: смотрите docker compose logs app" >&2
  set_tag ""
fi
exit 1
```

```bash
chmod +x /srv/<проект>/deploy.sh
```

### Ключ только для выкладки

Отдельный ключ, не личный ключ человека. Создаётся на компьютере человека:

```bash
ssh-keygen -t ed25519 -f deploy_key -N "" -C "deploy-<проект>"
```

Публичную часть (`deploy_key.pub`) добавь в `~/.ssh/authorized_keys` пользователя
на сервере **с ограничением**: этим ключом можно только запустить скрипт выкладки,
оболочку он не открывает. Одной строкой:

```text
command="/srv/<проект>/deploy.sh \"$SSH_ORIGINAL_COMMAND\"",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA... deploy-<проект>
```

Приватную часть (`deploy_key`) человек вставляет в секреты GitHub и удаляет файл
с компьютера. В чат ключ не вставляется.

Секреты репозитория (Settings → Secrets and variables → Actions) заводит человек
руками: `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`.

### Файл выкладки

`.github/workflows/deploy.yml`. В части 0 он создаётся без последнего шага, здесь
шаг «Выкладка на сервер» добавляется:

```yaml
name: deploy
on:
  push:
    branches: [main]
concurrency: deploy
permissions:
  contents: read
  packages: write
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # сюда — шаги проверок проекта: линтер, тесты
      - name: Имя образа строчными буквами
        run: echo "IMAGE=ghcr.io/${GITHUB_REPOSITORY,,}" >> "$GITHUB_ENV"
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ env.IMAGE }}:${{ github.sha }}
          build-args: |
            APP_VERSION=${{ github.sha }}
      - name: Выкладка на сервер
        env:
          SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          HOST: ${{ secrets.DEPLOY_HOST }}
          USER: ${{ secrets.DEPLOY_USER }}
        run: |
          install -m 600 /dev/null key
          echo "$SSH_KEY" > key
          ssh -i key -o StrictHostKeyChecking=accept-new "$USER@$HOST" "${{ github.sha }}"
```

Последняя команда передаёт серверу только метку образа: что с ней делать, решает
ограничение ключа на сервере. `APP_VERSION` — аргумент сборки: объяви его
в `Dockerfile` (`ARG APP_VERSION` и `ENV APP_VERSION=$APP_VERSION`), продукт
отдаёт это значение в поле `version` ответа `/healthz`. Так видно, какая версия
работает.

### Откат

Вручную, одной командой на сервере — на метку, которая работала до последней выкладки:

```bash
/srv/<проект>/deploy.sh "$(cat /srv/<проект>/.previous_tag)"
```

**Проверь откат один раз намеренно**, пока продукт не открыт людям: выложи версию,
откати, убедись, что открылась предыдущая. Запиши дату в `DEVOPS.md`.

Миграции базы — отдельным шагом перед выкладкой и только после свежей копии
(часть 5). Миграция должна быть совместима с предыдущей версией кода, иначе откат
кода не поможет: сначала добавляем новое, старое удаляем в следующем релизе.

## В хабе: отличия для сервиса отдела

Сервер, прокси, хранилище и пользователей ведёт команда AIRL. В репозитории
сервиса меняется только следующее.

**Compose сервиса** (`/srv/hub/<id>/docker-compose.yml`): блока `db` и скрипта
`initdb` нет — данные лежат в общем хранилище. Сервис называется своим `id`, чтобы
прокси находил его по имени: имя `app` в общей сети досталось бы случайному отделу.

```yaml
services:
  <id>:
    image: ghcr.io/<владелец строчными>/<репозиторий строчными>:${APP_TAG}
    restart: unless-stopped
    env_file: .env.app
    ports:
      - "127.0.0.1:${APP_PORT}:${APP_PORT}"
    networks: [web, dwh]

networks:
  web:
    external: true
  dwh:
    external: true
```

- В `deploy.sh` вместо `app` везде стоит `<id>`.
- `APP_PORT` у каждого сервиса свой: порты на `127.0.0.1` общие для всего сервера.
  Номер выдаёт команда AIRL.
- `.env`: `HEALTH_PATH=/<id>/healthz`. `.env.app`: `DATABASE_URL` пользователя
  `svc_<id>` (выдаёт команда AIRL), адрес JWKS, `iss` и `aud` из раздела 8 карты.
- Версия в `/healthz` должна совпадать с `version` из `airl.service.json`. В файле
  выкладки перед сборкой добавь шаг и передай его значение в `build-args`:

```yaml
      - name: Версия сервиса
        run: echo "APP_VERSION=$(jq -r .version airl.service.json)" >> "$GITHUB_ENV"
```

  и в шаге сборки: `APP_VERSION=${{ env.APP_VERSION }}`.
- Ключ выкладки ставится пользователю `deploy_<id>`, а не общему пользователю
  сервера; `command=` в `authorized_keys` указывает на `/srv/hub/<id>/deploy.sh`.

**Прокси хаба** (ведёт команда AIRL через `/airl-hub`, файл
`/srv/proxy/conf/Caddyfile`). Репозиторий хаба склонирован на сервере, а папка
`conf/` прокси — ссылка на папку с конфигом в нём: обновление конфига — это
`git pull` и перезагрузка Caddy.

```caddyfile
<домен хаба> {
    encode zstd gzip
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
    }
    redir /sales /sales/ 308
    handle /sales/* {
        reverse_proxy sales:<порт сервиса>
    }
    handle {
        reverse_proxy hub-shell:<порт оболочки>
    }
}

auth.<домен хаба> {
    reverse_proxy <провайдер входа>:<порт>
}
```

Префикс пути прокси не срезает: сервис собран под `/<id>` и сам обслуживает
`/<id>/healthz` и `/<id>/api/...`. Строка `redir` нужна, потому что `handle /sales/*`
не ловит адрес `/sales` без косой черты. Провайдер входа стоит на поддомене
`auth.` — под путём `/auth` большинство провайдеров без отдельной настройки
не работают.
