#!/usr/bin/env bash
set -Eeuo pipefail

# bootstrap.sh — Ubuntu 24.04, старт: root по SSH
# + опциональное добавление алиасов для нового пользователя

LOG_FILE="/var/log/bootstrap_start2.log"
exec > >(tee -a "$LOG_FILE") 2>&1

die() { echo "ОШИБКА: $*" >&2; exit 1; }
ok()  { echo "OK: $*"; }
warn(){ echo "WARN: $*"; }

[[ "$(id -u)" -eq 0 ]] || die "Запустите скрипт от root."

# ---------------- helpers ----------------
ask_default() {
  local p="$1" d="$2" v
  read -r -p "$p [$d]: " v || true
  echo "${v:-$d}"
}

ask_optional() {
  local p="$1" v
  read -r -p "$p (Enter — пропустить): " v || true
  echo "$v"
}

ask_yesno() {
  local p="$1" d="$2" a
  while true; do
    read -r -p "$p (y/n) [$d]: " a || true
    a="${a:-$d}"
    case "$a" in y|Y) echo y; return;; n|N) echo n; return;; esac
    echo "Введите y или n."
  done
}

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1>=1 && $1<=65535 )); }
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ "$1" != "root" ]]; }
valid_key() { [[ "$1" =~ ^ssh-(ed25519|rsa)[[:space:]][A-Za-z0-9+/=]+ ]]; }

backup_file() {
  local f="$1"
  cp -a "$f" "${f}.bak.$(date +%F_%H%M%S)"
}

ensure_kv() {
  local f="$1" k="$2" v="$3"
  if grep -qE "^[#[:space:]]*$k[[:space:]]+" "$f"; then
    sed -i -E "s|^[#[:space:]]*$k[[:space:]]+.*|$k $v|" "$f"
  else
    echo "$k $v" >> "$f"
  fi
}

# ---------------- actions ----------------
install_basics() {
  apt update && apt upgrade -y
  apt install -y curl mc git nano openssl bash
  ok "Базовые пакеты установлены"
}

create_user() {
  if ! id "$NEW_USER" &>/dev/null; then
    adduser "$NEW_USER"
    ok "Пользователь создан: $NEW_USER"
  else
    ok "Пользователь уже существует: $NEW_USER"
  fi
  usermod -aG sudo "$NEW_USER"
}

setup_keys() {
  local home
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$home/.ssh"
  local ak="$home/.ssh/authorized_keys"
  touch "$ak"; chown "$NEW_USER:$NEW_USER" "$ak"; chmod 600 "$ak"
  grep -qxF "$PUBLIC_KEY" "$ak" || echo "$PUBLIC_KEY" >> "$ak"
  ok "SSH-ключ добавлен"
}

configure_ssh() {
  local f="/etc/ssh/sshd_config"
  backup_file "$f"
  ensure_kv "$f" PermitRootLogin no
  ensure_kv "$f" PasswordAuthentication no
  ensure_kv "$f" PubkeyAuthentication yes
  ensure_kv "$f" AuthorizedKeysFile ".ssh/authorized_keys"
  ensure_kv "$f" Port "$NEW_SSH_PORT"
  sshd -t || die "Ошибка sshd_config"
  systemctl restart ssh
  ss -lntp | grep -q ":$NEW_SSH_PORT" || warn "Порт $NEW_SSH_PORT не прослушивается"
  ok "SSH настроен"
}

setup_ufw() {
  apt install -y ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$NEW_SSH_PORT/tcp"
  [[ "$OPEN_443" == y ]] && ufw allow 443/tcp
  [[ "$OPEN_22" == y ]] && ufw allow 22/tcp
  ufw --force enable
  ufw status
  ok "UFW включён"
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
  ok "Fail2ban настроен"
}

install_docker() {
  bash <(curl -sSL https://get.docker.com)
  systemctl is-active docker && ok "Docker активен" || warn "Docker установлен, но не активен"
  apt install -y docker.io docker-compose
  [[ "$ADD_DOCKER_GROUP" == y ]] && usermod -aG docker "$NEW_USER"
}

install_mtproto() {
  ss -lnt | grep -q ":$MTPROTO_PORT" && die "Порт $MTPROTO_PORT занят"
  docker pull telegrammessenger/proxy
  docker run -d -p "$MTPROTO_PORT:443" --name mtproto-proxy --restart=always -v proxy-config:/data telegrammessenger/proxy
  docker logs mtproto-proxy || true
}

add_aliases() {
  local home bashrc
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  bashrc="$home/.bashrc"
  [[ -f "$bashrc" ]] || touch "$bashrc"
  backup_file "$bashrc"

  add_alias() {
    local name="$1" value="$2"
    grep -q "alias $name=" "$bashrc" || echo "alias $name=\"$value\"" >> "$bashrc"
  }

  add_alias update "sudo apt update && sudo apt upgrade -y"
  add_alias clear "sudo docker system prune -a"
  add_alias unban "sudo fail2ban-client unban --all"
  add_alias ctop "sudo docker run --rm -ti -v /var/run/docker.sock:/var/run/docker.sock:ro quay.io/vektorlab/ctop:latest"
  add_alias watchtower "sudo docker run --rm -v /var/run/docker.sock:/var/run/docker.sock nickfedor/watchtower --run-once --cleanup"

  chown "$NEW_USER:$NEW_USER" "$bashrc"
  ok "Алиасы добавлены в .bashrc пользователя $NEW_USER"
}

# ---------------- input ----------------
echo "=== VPS Bootstrap (Ubuntu 24.04) ==="

while true; do
  NEW_USER="$(ask_default "Имя нового пользователя" "user")"
  valid_user "$NEW_USER" && break
  echo "Некорректное имя пользователя."
done

while true; do
  NEW_SSH_PORT="$(ask_default "Новый порт SSH" "4422")"
  is_port "$NEW_SSH_PORT" && break
  echo "Некорректный порт."
done

PUBLIC_KEY="$(ask_optional "Вставьте публичный SSH-ключ одной строкой")"
valid_key "$PUBLIC_KEY" || die "Некорректный SSH-ключ"

ALLOW_IP="$(ask_optional "IP для ignoreip в fail2ban")"

ENABLE_UFW="$(ask_yesno "Включить UFW" y)"
OPEN_443=n; OPEN_22=n
[[ "$ENABLE_UFW" == y ]] && {
  OPEN_443="$(ask_yesno "Открыть порт 443/tcp" y)"
  OPEN_22="$(ask_yesno "Открыть порт 22/tcp (НЕ рекомендуется)" n)"
}

INSTALL_F2B="$(ask_yesno "Установить fail2ban" y)"
INSTALL_DOCKER="$(ask_yesno "Установить Docker" y)"
ADD_DOCKER_GROUP=n
[[ "$INSTALL_DOCKER" == y ]] && ADD_DOCKER_GROUP="$(ask_yesno "Добавить пользователя в группу docker" y)"

INSTALL_MTPROTO="$(ask_yesno "Установить MTProto proxy" n)"
MTPROTO_PORT=1243
[[ "$INSTALL_MTPROTO" == y ]] && {
  while true; do
    MTPROTO_PORT="$(ask_default "Порт для MTProto" "1243")"
    is_port "$MTPROTO_PORT" && break
  done
}

ADD_ALIASES="$(ask_yesno "Добавить полезные алиасы новому пользователю" y)"

echo
echo "=== План ==="
echo "User: $NEW_USER | SSH port: $NEW_SSH_PORT | UFW: $ENABLE_UFW | Fail2ban: $INSTALL_F2B | Docker: $INSTALL_DOCKER | Aliases: $ADD_ALIASES"
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
echo "Рекомендуется проверить вход новым пользователем в новом окне терминала."
