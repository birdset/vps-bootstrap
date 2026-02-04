#!/usr/bin/env bash
set -Eeuo pipefail

# bootstrap.sh — Ubuntu 24.04, старт: root по SSH
# Авто: user+sudo, SSH hardening, (опц.) UFW, (опц.) fail2ban, (опц.) Docker, (опц.) MTProto, (опц.) aliases
#
# КРИТИЧЕСКИЕ ИСПРАВЛЕНИЯ (по вашим логам):
# 1) Docker: убран конфликт пакетов (НЕ ставим docker.io/containerd из Ubuntu после get.docker.com).
#    Ставим Docker через get.docker.com + docker-compose-plugin из Docker repo.
# 2) MTProto: при включённом UFW автоматически открываем выбранный порт MTProto.
# 3) Aliases: гарантированно создаём ~/.bash_aliases и проверяем запись; ~/.bashrc уже умеет его подключать, но добавим маркер-блок при отсутствии.
# 4) Логирование: каждое действие пишет OK/WARN, чтобы было видно, где остановка.

LOG_FILE="/var/log/bootstrap_start2.log"
exec > >(tee -a "$LOG_FILE") 2>&1

die() { echo "ОШИБКА: $*" >&2; exit 1; }
ok()  { echo "OK: $*"; }
warn(){ echo "WARN: $*"; }

[[ "$(id -u)" -eq 0 ]] || die "Запустите скрипт от root."

# ---------------- helpers ----------------
APT_UPDATED=0

apt_update_once() {
  if (( APT_UPDATED == 0 )); then
    apt-get update
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  apt-get install -y "$@"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

ask_default() {
  local p="$1" d="$2" v
  read -r -p "$p [$d]: " v || true
  v="$(trim "$v")"
  echo "${v:-$d}"
}

ask_optional() {
  local p="$1" v
  read -r -p "$p (Enter — пропустить): " v || true
  v="$(trim "$v")"
  echo "$v"
}

ask_yesno() {
  local p="$1" d="$2" a
  while true; do
    read -r -p "$p (y/n) [$d]: " a || true
    a="$(trim "${a:-$d}")"
    case "$a" in
      y|Y) echo y; return 0 ;;
      n|N) echo n; return 0 ;;
      *) echo "Введите y или n." ;;
    esac
  done
}

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= $1 && $1 <= 65535 )); }
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ "$1" != "root" ]]; }
valid_key()  { [[ "$1" =~ ^ssh-(ed25519|rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; }

backup_file_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%F_%H%M%S)"
    return 0
  fi
  return 1
}

backup_file_must() {
  local f="$1"
  [[ -f "$f" ]] || die "Файл не найден: $f"
  local b="${f}.bak.$(date +%F_%H%M%S)"
  cp -a "$f" "$b"
  echo "$b"
}

ensure_kv() {
  local f="$1" k="$2" v="$3"
  if grep -qE "^[#[:space:]]*$k[[:space:]]+" "$f"; then
    sed -i -E "s|^[#[:space:]]*$k[[:space:]]+.*|$k $v|" "$f"
  else
    echo "$k $v" >> "$f"
  fi
}

port_listening() {
  local p="$1"
  ss -lntp 2>/dev/null | grep -qE ":${p}\b"
}

ensure_run_sshd_dir() {
  mkdir -p /run/sshd
  chown root:root /run/sshd
  chmod 0755 /run/sshd
}

append_block_once() {
  local file="$1" marker="$2" block="$3"
  touch "$file"
  if ! grep -qF "$marker" "$file"; then
    printf "\n%s\n%s\n" "$marker" "$block" >> "$file"
    return 0
  fi
  return 1
}

# ---------------- actions ----------------
install_basics() {
  ok "Шаг: install_basics"
  apt_update_once
  apt-get upgrade -y
  apt_install curl mc git nano openssl bash ca-certificates gnupg
  ok "Базовые пакеты установлены/обновлены"
}

create_user() {
  ok "Шаг: create_user"
  if ! id "$NEW_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$NEW_USER"
    passwd "$NEW_USER"
    ok "Пользователь создан: $NEW_USER"
  else
    ok "Пользователь уже существует: $NEW_USER"
  fi

  usermod -aG sudo "$NEW_USER"
  ok "Пользователь добавлен в sudo: $NEW_USER"
}

setup_keys() {
  ok "Шаг: setup_keys"
  [[ -n "$PUBLIC_KEY" ]] || die "SSH-ключ обязателен."
  valid_key "$PUBLIC_KEY" || die "Некорректный SSH-ключ (ssh-ed25519/ssh-rsa одной строкой)."

  local home
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || die "Не найден home для пользователя $NEW_USER"

  install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$home/.ssh"
  local ak="$home/.ssh/authorized_keys"
  touch "$ak"
  chown "$NEW_USER:$NEW_USER" "$ak"
  chmod 600 "$ak"

  grep -qxF "$PUBLIC_KEY" "$ak" || echo "$PUBLIC_KEY" >> "$ak"
  ok "SSH-ключ добавлен в $ak"
}

configure_ssh() {
  ok "Шаг: configure_ssh"
  local f="/etc/ssh/sshd_config"
  local backup
  backup="$(backup_file_must "$f")"
  ok "Бэкап sshd_config: $backup"

  ensure_kv "$f" PermitRootLogin no
  ensure_kv "$f" PasswordAuthentication no
  ensure_kv "$f" PubkeyAuthentication yes
  ensure_kv "$f" AuthorizedKeysFile ".ssh/authorized_keys"
  ensure_kv "$f" Port "$NEW_SSH_PORT"

  ensure_run_sshd_dir

  if ! sshd -t; then
    cp -a "$backup" "$f"
    die "sshd -t не прошёл. Откат на бэкап выполнен."
  fi

  if ! systemctl restart ssh; then
    cp -a "$backup" "$f"
    systemctl restart ssh || true
    die "Не удалось перезапустить SSH. Откат на бэкап выполнен."
  fi

  if port_listening "$NEW_SSH_PORT"; then
    ok "sshd слушает порт $NEW_SSH_PORT"
  else
    warn "Не вижу, что sshd слушает порт $NEW_SSH_PORT. Проверь: ss -lntp | grep sshd"
  fi

  ok "SSH настроен"
}

setup_ufw() {
  ok "Шаг: setup_ufw"
  apt_install ufw
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow "$NEW_SSH_PORT/tcp"
  [[ "$OPEN_443" == y ]] && ufw allow 443/tcp
  [[ "$OPEN_22"  == y ]] && ufw allow 22/tcp

  # Если MTProto включён — откроем порт сразу, чтобы сервис был доступен извне
  if [[ "${INSTALL_MTPROTO:-n}" == y ]]; then
    ufw allow "${MTPROTO_PORT}/tcp"
    ok "UFW: открыт порт MTProto ${MTPROTO_PORT}/tcp"
  fi

  ufw --force enable
  ufw status verbose
  ok "UFW включён и настроен"
}

setup_fail2ban() {
  ok "Шаг: setup_fail2ban"
  apt_install fail2ban
  systemctl enable --now fail2ban

  local f="/etc/fail2ban/jail.d/sshd.local"
  cat > "$f" <<EOF
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled = true
maxretry = 3
findtime = 1d
bantime = 1w
port = ssh
EOF

  [[ -n "$ALLOW_IP" ]] && echo "ignoreip = $ALLOW_IP" >> "$f"

  systemctl restart fail2ban || true
  if fail2ban-client ping >/dev/null 2>&1; then
    ok "Fail2ban активен"
  else
    warn "Fail2ban установлен, но ping не прошёл (проверь: systemctl status fail2ban)"
  fi
}

install_docker() {
  ok "Шаг: install_docker"

  # Установка Docker (официальный способ через get.docker.com)
  # ВАЖНО: НЕ ставим потом docker.io/containerd из Ubuntu — это и вызвало конфликт containerd.io vs containerd.
  curl -fsSL https://get.docker.com | sh

  systemctl enable --now docker
  if systemctl is-active docker >/dev/null 2>&1; then
    ok "Docker daemon активен"
  else
    die "Docker установлен, но daemon не активен (systemctl status docker)"
  fi

  # docker compose plugin (из Docker repo, не docker-compose пакет Ubuntu)
  apt_install docker-compose-plugin

  if [[ "$ADD_DOCKER_GROUP" == y ]]; then
    usermod -aG docker "$NEW_USER" || warn "Не удалось добавить $NEW_USER в группу docker"
    ok "Пользователь добавлен в группу docker (нужен новый вход в сессию)"
  fi
}

install_mtproto() {
  ok "Шаг: install_mtproto"
  command -v docker >/dev/null 2>&1 || die "MTProto требует Docker (docker не найден)."

  # проверка порта на занятость на хосте
  if ss -lnt | awk '{print $4}' | grep -qE ":${MTPROTO_PORT}\$"; then
    die "Порт $MTPROTO_PORT занят на хосте. Выберите другой."
  fi

  # idempotent: если контейнер уже есть — не создаём второй
  if docker ps -a --format '{{.Names}}' | grep -qx 'mtproto-proxy'; then
    warn "Контейнер mtproto-proxy уже существует. Пропускаю создание."
    docker start mtproto-proxy || true
  else
    docker pull telegrammessenger/proxy:latest
    docker run -d \
      --name mtproto-proxy \
      --restart=always \
      -p "${MTPROTO_PORT}:443" \
      -v proxy-config:/data \
      telegrammessenger/proxy:latest
  fi

  if docker ps --format '{{.Names}}' | grep -qx 'mtproto-proxy'; then
    ok "MTProto контейнер запущен (порт ${MTPROTO_PORT} -> 443)"
  else
    warn "Контейнер mtproto-proxy не запущен. Проверь: docker logs mtproto-proxy"
  fi

  echo "Логи MTProto (secret/link):"
  docker logs mtproto-proxy || true
}

add_aliases() {
  ok "Шаг: add_aliases"
  local home bashrc aliases_file marker block

  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || die "Не найден home для пользователя $NEW_USER"

  bashrc="$home/.bashrc"
  aliases_file="$home/.bash_aliases"

  # 1) Создать/обновить ~/.bash_aliases
  backup_file_if_exists "$aliases_file" && ok "Сделан бэкап $aliases_file" || true
  install -m 644 -o "$NEW_USER" -g "$NEW_USER" /dev/null "$aliases_file"

  add_alias_line() {
    local name="$1" value="$2"
    grep -qE "^alias[[:space:]]+$name=" "$aliases_file" || echo "alias $name=\"$value\"" >> "$aliases_file"
  }

  add_alias_line update     "sudo apt update && sudo apt upgrade -y"
  add_alias_line clear      "sudo docker system prune -a"
  add_alias_line unban      "sudo fail2ban-client unban --all"
  add_alias_line ctop       "sudo docker run --rm -ti -v /var/run/docker.sock:/var/run/docker.sock:ro quay.io/vektorlab/ctop:latest"
  add_alias_line watchtower "sudo docker run --rm -v /var/run/docker.sock:/var/run/docker.sock nickfedor/watchtower --run-once --cleanup"

  # 2) Гарантировать подключение ~/.bash_aliases из ~/.bashrc (на некоторых образах может отличаться)
  marker="# --- bootstrap: load .bash_aliases ---"
  block='if [ -f ~/.bash_aliases ]; then
  . ~/.bash_aliases
fi'
  backup_file_if_exists "$bashrc" && ok "Сделан бэкап $bashrc" || true
  append_block_once "$bashrc" "$marker" "$block" && ok "Добавлено подключение ~/.bash_aliases в ~/.bashrc" || true
  chown "$NEW_USER:$NEW_USER" "$bashrc"

  # 3) Проверка: alias update обязан быть в файле
  if ! grep -qE '^alias[[:space:]]+update=' "$aliases_file"; then
    die "Алиасы не записались в $aliases_file (проверка не прошла)."
  fi

  ok "Алиасы добавлены в $aliases_file"
  ok "Для активации: новый вход или 'source ~/.bashrc' под пользователем $NEW_USER"
}

# ---------------- input ----------------
echo "=== VPS Bootstrap (Ubuntu 24.04) ==="
echo "Лог: $LOG_FILE"
echo

while true; do
  NEW_USER="$(ask_default "Имя нового пользователя" "user")"
  valid_user "$NEW_USER" && break
  echo "Некорректное имя (не root, латиница/цифры/_/-)."
done

PUBLIC_KEY="$(ask_optional "Вставьте публичный SSH-ключ одной строкой")"
[[ -n "$PUBLIC_KEY" ]] || die "SSH-ключ обязателен."
valid_key "$PUBLIC_KEY" || die "Некорректный SSH-ключ."

NEW_SSH_PORT="4422"
ALLOW_IP=""
INSTALL_MTPROTO="y"
MTPROTO_PORT="1243"
ENABLE_UFW="y"
OPEN_443="y"
OPEN_22="y"
INSTALL_F2B="y"
INSTALL_DOCKER="y"
ADD_DOCKER_GROUP="y"
ADD_ALIASES="y"

echo
echo "=== План ==="
echo "User: $NEW_USER | SSH port: $NEW_SSH_PORT | UFW: $ENABLE_UFW | Fail2ban: $INSTALL_F2B | Docker: $INSTALL_DOCKER | MTProto: $INSTALL_MTPROTO | MTProto port: $MTPROTO_PORT | Aliases: $ADD_ALIASES"
echo

ok "Стартуем без дополнительных вопросов."

# ---------------- run ----------------
install_basics
create_user
setup_keys
configure_ssh
[[ "$ENABLE_UFW" == y ]] && setup_ufw
[[ "$INSTALL_F2B" == y ]] && setup_fail2ban
[[ "$INSTALL_DOCKER" == y ]] && install_docker
[[ "$INSTALL_MTPROTO" == y ]] && install_mtproto
[[ "$ADD_ALIASES" == y ]] && add_aliases

echo
echo "=== Готово ==="
echo "Вход: ssh -p $NEW_SSH_PORT $NEW_USER@<IP_СЕРВЕРА>"
echo "Лог: $LOG_FILE"
echo "Если включали MTProto: порт ${MTPROTO_PORT}/tcp открыт в UFW (если UFW включали)"
echo "Алиасы (если включали): новый вход или 'source ~/.bashrc'"
