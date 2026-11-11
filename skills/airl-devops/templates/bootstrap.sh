#!/usr/bin/env bash
# bootstrap.sh — первичная настройка нового сервера Ubuntu 24.04 (подходит и для 22.04).
# Шаблон навыка airl-devops. Повторный запуск безопасен: каждый шаг сначала проверяет,
# сделан ли он, и ничего не ломает на уже настроенном сервере.
#
# Порядок (под root или через sudo, ключ уже добавлен root при создании сервера):
#   1) bash bootstrap.sh --user <пользователь> --project <проект>
#   2) НЕ закрывая окно, во втором окне: ssh <пользователь>@<IP>, затем sudo whoami → root
#   3) bash bootstrap.sh --user <пользователь> --project <проект> --harden-ssh
#
# Что делает:
#   пользователь с sudo и тем же ключом, что у root; автоматические обновления безопасности;
#   межсетевой экран (открыты только 22, 80, 443); fail2ban для SSH; Docker из официального
#   репозитория; ограничение логов Docker; сеть web для прокси; папки /srv/proxy,
#   /srv/<проект>-<среда>, /srv/backups; файл подкачки 2 ГБ на серверах с памятью меньше 4 ГБ.
#   С --harden-ssh: вход только по ключу и не под root, проверка итоговых настроек через sshd -T.
#
# Параметры:
#   --user <имя>        пользователь сервера (обязательно)
#   --project <имя>     имя проекта для папок /srv/<проект>-<среда>
#   --envs "<среды>"    какие среды завести, по умолчанию "staging prod"
#   --harden-ssh        закрыть вход по паролю и под root (после проверки входа пользователем)
#   --no-swap           не создавать файл подкачки

set -euo pipefail

USER_NAME=""
PROJECT=""
ENVS="staging prod"
HARDEN_SSH=0
MAKE_SWAP=1

die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
ok() { printf '   ок: %s\n' "$*"; }
note() { printf '   ВНИМАНИЕ: %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) [ $# -ge 2 ] || die "--user без значения"; USER_NAME="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || die "--project без значения"; PROJECT="$2"; shift 2 ;;
    --envs) [ $# -ge 2 ] || die "--envs без значения"; ENVS="$2"; shift 2 ;;
    --harden-ssh) HARDEN_SSH=1; shift ;;
    --no-swap) MAKE_SWAP=0; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) die "неизвестный параметр: $1 (см. --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "запустите под root или через sudo"
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "нужен --user: строчные латинские буквы, цифры, - и _"
[ "$USER_NAME" != "root" ] || die "--user не может быть root"
if [ -n "$PROJECT" ]; then
  [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || die "--project: строчные латинские буквы, цифры, - и _"
fi
for e in $ENVS; do
  [[ "$e" =~ ^[a-z0-9-]{1,20}$ ]] || die "--envs: неверное имя среды «$e»"
done

# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || die "скрипт рассчитан на Ubuntu, а здесь ${ID:-неизвестно}"
case "${VERSION_ID:-}" in
  24.04|22.04) ok "Ubuntu $VERSION_ID" ;;
  *) note "проверено на Ubuntu 24.04 и 22.04, здесь $VERSION_ID — продолжаю осторожно" ;;
esac

export DEBIAN_FRONTEND=noninteractive
USER_HOME="/home/$USER_NAME"

# write_if_changed <файл> <права> — содержимое со стандартного ввода; код 0, если файл изменён
write_if_changed() {
  local target="$1" mode="$2" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
  install -m "$mode" "$tmp" "$target"
  rm -f "$tmp"
  return 0
}

# ---------- 1. Пакеты и обновления безопасности ----------
step "Пакеты и автоматические обновления безопасности"
apt-get update -q
apt-get install -y -q --no-install-recommends \
  ca-certificates curl gnupg ufw fail2ban python3-systemd unattended-upgrades jq rsync cron
if write_if_changed /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
then ok "автообновления включены"; else ok "автообновления уже включены"; fi

# ---------- 2. Пользователь ----------
step "Пользователь $USER_NAME"
if id -u "$USER_NAME" >/dev/null 2>&1; then
  ok "пользователь уже есть"
else
  adduser --disabled-password --gecos "" "$USER_NAME"
  ok "пользователь создан"
  if [ -t 0 ]; then
    echo "   Задайте пароль для sudo (по SSH он не используется — вход только по ключу):"
    passwd "$USER_NAME"
  else
    note "задайте пароль для sudo вручную: sudo passwd $USER_NAME"
  fi
fi
usermod -aG sudo "$USER_NAME"

install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$USER_HOME/.ssh"
if [ -s "$USER_HOME/.ssh/authorized_keys" ]; then
  ok "у пользователя уже есть ключи входа"
elif [ -s /root/.ssh/authorized_keys ]; then
  install -m 600 -o "$USER_NAME" -g "$USER_NAME" /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys"
  ok "ключ root скопирован пользователю"
else
  note "ключей нет ни у root, ни у $USER_NAME — добавьте ключ (ssh-copy-id), иначе --harden-ssh не сработает"
fi

# ---------- 3. Межсетевой экран ----------
step "Межсетевой экран: открыты только 22, 80, 443"
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
if ufw status | grep -q '^Status: active'; then
  ok "ufw уже включён"
else
  ufw --force enable >/dev/null
  ok "ufw включён (SSH разрешён до включения)"
fi
note "Docker публикует порты в обход ufw: в compose порты баз не публикуются, служебные — только на 127.0.0.1"

# ---------- 4. fail2ban ----------
step "fail2ban: блокировка подбора пароля к SSH"
if write_if_changed /etc/fail2ban/jail.d/airl.local 644 <<'EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
then
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  ok "настройка записана, fail2ban перезапущен"
else
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  ok "fail2ban уже настроен"
fi

# ---------- 5. Docker ----------
step "Docker из официального репозитория"
if command -v docker >/dev/null 2>&1; then
  ok "Docker уже установлен: $(docker --version)"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker установлен: $(docker --version)"
fi
usermod -aG docker "$USER_NAME"
note "группа docker равна правам root: добавляйте в неё только тех, кому доверяете сервер"

DAEMON_JSON='{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "live-restore": true
}'
install -d -m 755 /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  printf '%s\n' "$DAEMON_JSON" > /etc/docker/daemon.json
  if [ -z "$(docker ps -q)" ]; then
    systemctl restart docker
    ok "ограничение логов Docker включено"
  else
    note "ограничение логов записано, но контейнеры уже работают: перезапустите Docker в окно обслуживания (sudo systemctl restart docker — жёлтая зона)"
  fi
elif jq -e '."log-opts"."max-size"' /etc/docker/daemon.json >/dev/null 2>&1; then
  ok "ограничение логов Docker уже есть"
else
  note "/etc/docker/daemon.json уже есть, но без ограничения логов — допишите log-opts вручную (не перезаписываю)"
fi

if docker network inspect web >/dev/null 2>&1; then
  ok "сеть web уже есть"
else
  docker network create web >/dev/null
  ok "сеть web создана"
fi

# ---------- 6. Папки ----------
step "Папки"
install -d -m 750 -o "$USER_NAME" -g "$USER_NAME" /srv/proxy /srv/proxy/conf /srv/backups
if [ -n "$PROJECT" ]; then
  for e in $ENVS; do
    install -d -m 750 -o "$USER_NAME" -g "$USER_NAME" "/srv/$PROJECT-$e" "/srv/$PROJECT-$e/backups"
    ok "/srv/$PROJECT-$e"
  done
fi
ok "/srv/proxy, /srv/backups"

# ---------- 7. Файл подкачки ----------
step "Файл подкачки"
mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
if [ -n "$(swapon --show --noheadings)" ]; then
  ok "подкачка уже есть"
elif [ "$MAKE_SWAP" = 0 ]; then
  ok "пропущено по --no-swap"
elif [ "$mem_kb" -lt 4000000 ]; then
  if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "подкачка 2 ГБ включена (памяти меньше 4 ГБ)"
else
  ok "памяти достаточно, подкачка не нужна"
fi

# ---------- 8. SSH ----------
step "SSH"
if [ "$HARDEN_SSH" = 1 ]; then
  [ -s "$USER_HOME/.ssh/authorized_keys" ] || die "у $USER_NAME нет ключа входа — закрывать вход по паролю нельзя"
  # 00- — потому что sshd берёт первое значение, а в образах уже лежит 50-cloud-init.conf
  if write_if_changed /etc/ssh/sshd_config.d/00-airl.conf 644 <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
EOF
  then
    if ! sshd -t; then
      rm -f /etc/ssh/sshd_config.d/00-airl.conf
      die "sshd -t нашёл ошибку — настройка удалена, вход не изменён"
    fi
    systemctl reload ssh || systemctl restart ssh
    ok "настройка SSH применена"
  else
    ok "настройка SSH уже применена"
  fi
  bad=0
  for k in permitrootlogin passwordauthentication kbdinteractiveauthentication; do
    v=$(sshd -T 2>/dev/null | awk -v k="$k" '$1 == k {print $2}')
    if [ "$v" = "no" ]; then ok "$k no"; else note "$k = ${v:-?} (ожидали no) — другой файл настройки перебивает значение"; bad=1; fi
  done
  [ "$bad" = 0 ] || die "SSH закрыт не полностью — проверьте /etc/ssh/sshd_config и sshd_config.d/"
  note "НЕ закрывайте текущее окно, пока не проверите вход $USER_NAME в новом окне"
else
  for k in permitrootlogin passwordauthentication; do
    printf '   сейчас: %s\n' "$(sshd -T 2>/dev/null | awk -v k="$k" '$1 == k {print $1, $2}')"
  done
  note "вход по паролю и под root ещё открыт. Проверьте вход $USER_NAME во втором окне и запустите скрипт с --harden-ssh"
fi

# ---------- Итог ----------
step "Итог"
ufw status | sed 's/^/   /'
fail2ban-client status sshd 2>/dev/null | sed -n '1,4p' | sed 's/^/   /' || true
printf '   %s\n' "$(docker compose version 2>/dev/null || echo 'docker compose не найден')"
echo
echo "Готово. Перезайдите на сервер под $USER_NAME, чтобы заработала группа docker."
echo "Сохраните этот скрипт в репозитории (infra/bootstrap.sh): сервер должен собираться заново из git."
