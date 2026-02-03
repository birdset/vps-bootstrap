#!/usr/bin/env bash
set -Eeuo pipefail

# bootstrap.sh — Ubuntu 24.04, старт: root по SSH
# Авто: user+sudo, SSH hardening, (опц.) UFW, (опц.) fail2ban, (опц.) Docker, (опц.) MTProto, (опц.) aliases
#
# Ключевые моменты:
# - Пользователь создаётся НЕинтерактивно: adduser --disabled-password --gecos ""
# - Перед sshd -t создаётся /run/sshd (исправляет "Missing privilege separation directory: /run/sshd")
# - sshd_config: бэкап + откат при ошибке проверки/рестарта
# - MTProto: вопрос по умолчанию = y, порт спрашивается только если MTProto = y
# - Алиасы: пишутся в ~/.bash_aliases (стандартный путь)

LOG_FILE="/var/log/bootstrap_start2.log"
exec > >(tee -a "$LOG_FILE") 2>&1

die() { echo "ОШИБКА: $*" >&2; exit 1; }
ok()  { echo "OK: $*"; }
warn(){ echo "WARN: $*"; }

[[ "$(id -u)" -eq 0 ]] || die "Запустите скрипт от root."

# ---------------- helpers ----------------
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
valid_key() { [[ "$1" =~ ^ssh-(ed25519|rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; }

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

# ---------------- actions ----------------
install_basics() {
  apt update
  apt upgrade -y
  apt install -y curl mc git nano openssl bash
  ok "Базовые пакеты установлены/обновлены"
}

create_user() {
  if ! id "$NEW_USER" &>/dev/null; then
    # Неинтерактивно: пароль не задаём (вход по ключу), GECOS пустой
    adduser --disabled-password --gecos "" "$NEW_USER"
    ok "Пользователь создан: $NEW_USER"
  else
    ok "Пользователь уже существует: $NEW_USER"
  fi

  usermod -aG sudo "$NEW_USER"
  ok "Пользователь добавлен в sudo: $NEW_USER"
}

setup_keys() {
  [[ -n "$PUBLIC_KEY" ]] || die "SSH-ключ обязателен. Нельзя продолжать."
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
  local f="/etc/ssh/sshd_config"
  local backup
  backup="$(backup_file_must "$f")"
  ok "Бэкап sshd_config: $backup"

  ensure_kv "$f" PermitRootLogin no
  ensure_kv "$f" PasswordAuthentication no
  ensure_kv "$f" PubkeyAuthentication yes
  ensure_kv "$f" AuthorizedKeysFile ".ssh/authorized_keys"
  ensure_kv "$f" Port "$NEW_SSH_PORT"

  # Исправление "Missing privilege separation directory: /run/sshd"
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
  apt install -y ufw
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow "$NEW_SSH_PORT/tcp"
  [[ "$OPEN_443" == y ]] && ufw allow 443/tcp
  [[ "$OPEN_22"  == y ]] && ufw allow 22/tcp

  ufw --force enable
  ufw status
  ok "UFW включён и настроен"
}

setup_fail2ban() {
  apt install -y fail2ban
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

  systemctl restart fail2ban
  fail2ban-client ping >/dev/null 2>&1 && ok "Fail2ban активен" || warn "Fail2ban установлен, но ping не прошёл"
}

install_docker() {
  bash <(curl -sSL https://get.docker.com)
  systemctl is-active docker >/dev/null 2>&1 && ok "Docker daemon активен" || warn "Docker установлен, но daemon не активен"

  apt update
  apt install -y docker.io docker-compose

  if [[ "$ADD_DOCKER_GROUP" == y ]]; then
    usermod -aG docker "$NEW_USER" || warn "Не удалось добавить $NEW_USER в группу docker"
    ok "Пользователь добавлен в группу docker (нужен новый вход)"
  fi
}

install_mtproto() {
  # Проверяем docker по факту, а не по ответу диалога
  command -v docker >/dev/null 2>&1 || die "MTProto требует Docker (docker не найден)."

  ss -lnt | awk '{print $4}' | grep -qE ":${MTPROTO_PORT}\$" && die "Порт $MTPROTO_PORT занят. Выберите другой."

  docker pull telegrammessenger/proxy
  docker run -d -p "${MTPROTO_PORT}:443" --name mtproto-proxy --restart=always -v proxy-config:/data telegrammessenger/proxy:latest

  docker ps | grep -q mtproto-proxy && ok "MTProto контейнер запущен" || warn "mtproto-proxy не виден в docker ps"
  echo "Логи MTProto (secret/link):"
  docker logs mtproto-proxy || true
}

add_aliases() {
  local home aliases_file
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || die "Не найден home для пользователя $NEW_USER"

  aliases_file="$home/.bash_aliases"
  backup_file_if_exists "$aliases_file" && ok "Сделан бэкап $aliases_file" || true

  touch "$aliases_file"
  chown "$NEW_USER:$NEW_USER" "$aliases_file"
  chmod 644 "$aliases_file"

  add_alias_line() {
    local name="$1" value="$2"
    grep -qE "^alias[[:space:]]+$name=" "$aliases_file" || echo "alias $name=\"$value\"" >> "$aliases_file"
  }

  add_alias_line update     "sudo apt update && sudo apt upgrade -y"
  add_alias_line clear      "sudo docker system prune -a"
  add_alias_line unban      "sudo fail2ban-client unban --all"
  add_alias_line ctop       "sudo docker run --rm -ti -v /var/run/docker.sock:/var/run/docker.sock:ro quay.io/vektorlab/ctop:latest"
  add_alias_line watchtower "sudo docker run --rm -v /var/run/docker.sock:/var/run/docker.sock nickfedor/watchtower --run-once --cleanup"

  ok "Алиасы добавлены в $aliases_file"
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

while true; do
  NEW_SSH_PORT="$(ask_default "Новый порт SSH" "4422")"
  is_port "$NEW_SSH_PORT" && break
  echo "Некорректный порт."
done

PUBLIC_KEY="$(ask_optional "Вставьте публичный SSH-ключ одной строкой")"
[[ -n "$PUBLIC_KEY" ]] || die "SSH-ключ обязателен."
valid_key "$PUBLIC_KEY" || die "Некорректный SSH-ключ."

ALLOW_IP="$(ask_optional "IP для ignoreip в fail2ban")"

ENABLE_UFW="$(ask_yesno "Включить UFW" y)"
OPEN_443=n
OPEN_22=n
if [[ "$ENABLE_UFW" == y ]]; then
  OPEN_443="$(ask_yesno "Открыть порт 443/tcp" y)"
  OPEN_22="$(ask_yesno "Открыть порт 22/tcp (НЕ рекомендуется)" n)"
fi

INSTALL_F2B="$(ask_yesno "Установить fail2ban" y)"
INSTALL_DOCKER="$(ask_yesno "Установить Docker" y)"
ADD_DOCKER_GROUP=n
if [[ "$INSTALL_DOCKER" == y ]]; then
  ADD_DOCKER_GROUP="$(ask_yesno "Добавить пользователя в группу docker" y)"
fi

# --- MTProto: строгое условие + default = y ---
INSTALL_MTPROTO="$(ask_yesno "Установить MTProto proxy" y)"
MTPROTO_PORT="1243"
if [[ "$INSTALL_MTPROTO" == y ]]; then
  while true; do
    MTPROTO_PORT="$(ask_default "Порт для MTProto" "1243")"
    is_port "$MTPROTO_PORT" && break
    echo "Некорректный порт."
  done
fi
# ------------------------------------------------

ADD_ALIASES="$(ask_yesno "Добавить полезные алиасы новому пользователю" y)"

echo
echo "=== План ==="
echo "User: $NEW_USER | SSH port: $NEW_SSH_PORT | UFW: $ENABLE_UFW | Fail2ban: $INSTALL_F2B | Docker: $INSTALL_DOCKER | MTProto: $INSTALL_MTPROTO | Aliases: $ADD_ALIASES"
echo

[[ "$(ask_yesno "Продолжить" y)" == y ]] || die "Остановлено пользователем"

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
echo "Алиасы (если включали): source ~/.bash_aliases (или новый вход)"
