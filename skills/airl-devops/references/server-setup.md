# Сервер шаг за шагом

Команды для частей 1–7 плана из `SKILL.md`. Рассчитаны на Ubuntu 22.04 / 24.04.
Всё в угловых скобках (`<IP>`, `<домен>`, `<пользователь>`) — **спроси у человека
и подставь настоящее значение**. Команду с неподставленной скобкой не выдавай.

Перед каждой командой из жёлтой и красной зоны памятки — остановка и явное «да».

## Часть 1. Сервер, вход по ключу, обычный пользователь

На компьютере человека (не на сервере) — ключ, если его ещё нет:

```bash
ssh-keygen -t ed25519 -C "<имя-для-подписи-ключа>"
```

```bash
ssh-copy-id root@<IP>
```

На Windows без `ssh-copy-id`: открыть файл `~/.ssh/id_ed25519.pub`, скопировать строку
и добавить её в панели провайдера или в `/root/.ssh/authorized_keys`.

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

Должно вывести `root`. Только после этого закрывай вход под root и по паролю —
в файле `/etc/ssh/sshd_config.d/99-airl.conf`:

```text
PermitRootLogin no
PasswordAuthentication no
```

```bash
sudo sshd -t && sudo systemctl reload ssh
```

Проверь в третьем окне, что вход новым пользователем всё ещё работает. Не работает —
первое окно ещё открыто под root: верни настройку обратно.

Обновления безопасности:

```bash
sudo apt update && sudo apt install -y unattended-upgrades
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
а если порт нужен на самом сервере — только так: `127.0.0.1:5432:5432`.

Проверка снаружи, с компьютера человека:

```bash
nc -zv <IP> 5432
```

Должен быть отказ или таймаут.

## Часть 3. Docker и контейнеры

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
```

Это официальный установщик Docker. Покажи человеку, что скачали, и только потом:

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

Папка проекта: `/srv/<проект>/` (в хабе — `/srv/hub/<id сервиса>/`). В ней
`docker-compose.yml` и файл окружения `.env` с правами только для владельца:

```bash
chmod 600 /srv/<проект>/.env
```

Каркас `docker-compose.yml` — подставь реальные сервисы проекта:

```yaml
services:
  app:
    image: ghcr.io/<владелец>/<репозиторий>:${APP_TAG}
    restart: unless-stopped
    env_file: .env
    depends_on:
      db:
        condition: service_healthy
    networks: [web, internal]
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/healthz"]
      interval: 15s
      timeout: 3s
      retries: 5

  db:
    image: postgres:16
    restart: unless-stopped
    env_file: .env
    volumes:
      - db_data:/var/lib/postgresql/data
    networks: [internal]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER"]
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

Общая сеть для прокси создаётся один раз:

```bash
docker network create web
```

На тарифах с памятью до 2 ГБ не собирай образы на сервере: сборка идёт в GitHub
Actions (часть 7), на сервер приходит готовый образ.

## Часть 4. Прокси и защищённое соединение

Сначала DNS: A-запись `<домен>` → `<IP>`. Проверка с компьютера:

```bash
dig +short <домен>
```

Должен вернуться IP сервера. Пока не вернулся — сертификат не выпустится, ждём.

Прокси Caddy сам выпускает и продлевает сертификат Let's Encrypt. Отдельный проект
в `/srv/proxy/`:

```yaml
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
    networks: [web]
volumes:
  caddy_data:
networks:
  web:
    external: true
```

`Caddyfile` для одного продукта на своём домене:

```caddyfile
<домен> {
    encode zstd gzip
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
    }
    reverse_proxy app:3000
}
```

В хабе — по блоку `handle /<id>/*` на сервис; этот файл ведёт `/airl-hub`.

Проверка настройки и перезагрузка без остановки:

```bash
docker compose -p proxy exec caddy caddy validate --config /etc/caddy/Caddyfile
```

```bash
docker compose -p proxy exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Проверка снаружи:

```bash
curl -sI https://<домен> | head -n 1
```

Уже стоит nginx — не меняй на Caddy ради единообразия: сертификат через `certbot
--nginx -d <домен>`, перед каждой перезагрузкой `sudo nginx -t`.

## Часть 5. Резервные копии и проверка восстановления

Скрипт `/srv/<проект>/backup.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd /srv/<проект>
STAMP=$(date +%F_%H%M)
mkdir -p backups
docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "backups/db_$STAMP.dump"
test -s "backups/db_$STAMP.dump"
find backups -name 'db_*.dump' -mtime +14 -delete
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
docker exec -i restore-test pg_restore -U postgres -d postgres --no-owner < backups/<файл копии>
```

```bash
docker exec restore-test psql -U postgres -c '\dt *.*' | head -n 30
```

Таблицы на месте, число строк в главной таблице похоже на правду — запиши дату проверки
в `DEVOPS.md`. Затем убери временную базу:

```bash
docker rm -f restore-test
```

## Часть 6. Мониторинг и оповещения

Минимум, который должен быть у каждого продукта:

1. Адрес `GET /healthz` в продукте, без авторизации и без данных.
2. Внешняя проверка этого адреса раз в 1–5 минут с оповещением в Telegram или на
   почту: готовый сервис (UptimeRobot, Better Stack) или Uptime Kuma на **другом**
   сервере. Проверка на том же сервере не заметит, что сервер упал.
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

Отдельный ключ только для выкладки (не личный ключ человека): создаётся на
компьютере, публичная часть — в `~/.ssh/authorized_keys` пользователя на сервере,
приватная — в секреты GitHub. В чат ключ не вставляется.

Секреты репозитория (Settings → Secrets and variables → Actions) заводит человек
руками: `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`.

`.github/workflows/deploy.yml`:

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
    env:
      IMAGE: ghcr.io/${{ github.repository }}
      TAG: ${{ github.sha }}
    steps:
      - uses: actions/checkout@v4
      # сюда — шаги проверок проекта: линтер, тесты
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ env.IMAGE }}:${{ env.TAG }}
      - name: Выкладка на сервер
        env:
          SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          HOST: ${{ secrets.DEPLOY_HOST }}
          USER: ${{ secrets.DEPLOY_USER }}
        run: |
          install -m 600 /dev/null key && echo "$SSH_KEY" > key
          ssh -i key -o StrictHostKeyChecking=accept-new "$USER@$HOST" \
            "/srv/<проект>/deploy.sh $TAG"
```

Имя образа в реестре — строчными буквами. Сервер должен уметь читать реестр:
один раз `docker login ghcr.io` на сервере с токеном только на чтение пакетов.

`/srv/<проект>/deploy.sh` на сервере — обновляет только свой сервис и сам
откатывается:

```bash
#!/bin/bash
set -euo pipefail
cd /srv/<проект>
NEW_TAG="$1"
OLD_TAG=$(grep -oP '^APP_TAG=\K.*' .env || true)

set_tag() { sed -i "s/^APP_TAG=.*/APP_TAG=$1/" .env; }

set_tag "$NEW_TAG"
docker compose pull app
docker compose up -d app

for i in $(seq 1 12); do
  if docker compose exec -T app wget -qO- http://localhost:3000/healthz >/dev/null 2>&1; then
    echo "$OLD_TAG" > .previous_tag
    echo "Выложено: $NEW_TAG"
    exit 0
  fi
  sleep 5
done

echo "Проверка не прошла, откат на $OLD_TAG" >&2
set_tag "$OLD_TAG"
docker compose up -d app
exit 1
```

В `.env` должна быть строка `APP_TAG=<метка>`. База при выкладке не перезапускается:
команды затрагивают только `app`.

Откат вручную одной командой — на метку, которая работала до последней выкладки:

```bash
/srv/<проект>/deploy.sh "$(cat /srv/<проект>/.previous_tag)"
```

**Проверь откат один раз намеренно**, пока продукт не открыт людям: выложи версию,
откати, убедись, что открылась предыдущая. Запиши дату в `DEVOPS.md`.

Миграции базы — отдельным шагом перед выкладкой и только после свежей копии
(часть 5). Миграция должна быть совместима с предыдущей версией кода, иначе откат
кода не поможет: сначала добавляем новое, старое удаляем в следующем релизе.
