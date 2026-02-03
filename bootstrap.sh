#!/usr/bin/env bash
set -Eeuo pipefail

# bootstrap.sh — автоматизированная версия инструкции start_2.md (старт: root по SSH на Ubuntu 24.04)
# Цели: максимум автоматизации для новичка + минимизация риска потери доступа.
#
# Делает:
# - создаёт нового sudo-пользователя
# - добавляет публичный SSH-ключ в authorized_keys нового пользователя
# - настраивает SSH: новый порт, PermitRootLogin no, PasswordAuthentication no, PubkeyAuthentication yes
# - (опц.) UFW
# - (опц.) fail2ban
# - (опц.) Docker (и опц. добавляет пользователя в группу docker)
# - (опц.) MTProto proxy (Docker)
#
# ВАЖНО:
# - Скрипт меняет SSH. Если вы введёте неверный ключ/порт, доступ может потребовать консоль провайдера (VNC/Rescue).
# - Скрипт сохраняет бэкап sshd_config и делает проверку sshd -t перед рестартом.
# - Для снижения риска "самоблокировки" AllowUsers НЕ устанавливается (можно включить позже вручную).

LOG_FILE="/var/log/bootstrap_start2.log"
exec > >(tee -a "$LOG_FILE") 2>&1

die() { echo "ОШИБКА: $*" >&2; exit 1; }
ok()  { echo "OK: $*"; }
warn(){ echo "WARN: $*"; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Запустите скрипт от root."
}

# ---------- input helpers ----------
ask_default() {
  local prompt="$1" default="$2" var
  read -r -p "$prompt [$default]: " var || true
  if [[ -z "${var}" ]]; then echo "$default"; else echo "$var"; fi
}

ask_optional() {
  # Может вернуть пустую строку
  local prompt="$1" var
  read -r -p "$prompt (можно Enter чтобы пропустить): " var || true
  echo "${var}"
}

ask_yesno() {
  local prompt="$1" default="$2" ans
  while true; do
    read -r -p "$prompt (y/n) [$default]: " ans || true
    ans="${ans:-$default}"
    case "$ans" in
      y|Y) echo "y"; return 0 ;;
      n|N) echo "n"; return 0 ;;
      *) echo "Введите y или n." ;;
    esac
  done
}

ask_single_line() {
  local prompt="$1" var
  echo "$prompt"
  read -r var || true
  echo "$var"
}

is_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

is_valid_pubkey() {
  local k="$1"
  [[ "$k" =~ ^ssh-(ed25519|rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

valid_username() {
  local u="$1"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
  [[ "$u" != "root" ]] || return 1
  return 0
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || die "Файл не найден: $f"
  local b="${f}.bak.$(date +%F_%H%M%S)"
  cp -a "$f" "$b"
  echo "$b"
}

ensure_line_kv() {
  # Обеспечивает наличие "Key Value" (заменяет существующую строку Key, иначе добавляет в конец).
  local file="$1" key="$2" value="$3"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|g" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
}

install_basics() {
  apt update
  apt upgrade -y
  apt install -y curl mc openssl nano git bash
  ok "Базовые пакеты установлены/обновлены"
}

create_user_and_sudo() {
  if id "$NEW_USER" &>/dev/null; then
    ok "Пользователь уже существует: $NEW_USER"
  else
    # adduser интерактивен — новичку проще явно задать пароль (можно потом не использовать)
    adduser "$NEW_USER"
    ok "Создан пользователь: $NEW_USER"
  fi

  usermod -aG sudo "$NEW_USER"
  ok "Пользователь добавлен в sudo: $NEW_USER"
}

setup_authorized_keys() {
  local home_dir
  home_dir="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  [[ -n "$home_dir" && -d "$home_dir" ]] || die "Не найден home для пользователя $NEW_USER"

  install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$home_dir/.ssh"

  local ak="$home_dir/.ssh/authorized_keys"
  touch "$ak"
  chown "$NEW_USER:$NEW_USER" "$ak"
  chmod 600 "$ak"

  if grep -qxF "$PUBLIC_KEY" "$ak"; then
    ok "Ключ уже присутствует в authorized_keys"
  else
    echo "$PUBLIC_KEY" >> "$ak"
    ok "Ключ добавлен в $ak"
  fi
}

configure_sshd() {
  local sshd="/etc/ssh/sshd_config"
  local backup
  backup="$(backup_file "$sshd")"
  ok "Бэкап sshd_config: $backup"

  # Важно: не ставим AllowUsers, чтобы не “запереть” пользователя неожиданно.
  ensure_line_kv "$sshd" "PermitRootLogin" "no"
  ensure_line_kv "$sshd" "PubkeyAuthentication" "yes"
  ensure_line_kv "$sshd" "AuthorizedKeysFile" ".ssh/authorized_keys"
  ensure_line_kv "$sshd" "PasswordAuthentication" "no"
  ensure_line_kv "$sshd" "Port" "$NEW_SSH_PORT"

  # Проверка синтаксиса
  if ! sshd -t; then
    cp -a "$backup" "$sshd"
    die "sshd_config некорректен. Откат выполнен."
  fi

  # Перезапуск
  if ! systemctl restart ssh; then
    cp -a "$backup" "$sshd"
    die "Не удалось перезапустить SSH. Откат выполнен."
  fi

  if ss -lntp | grep -qE ":${NEW_SSH_PORT}\b"; then
    ok "sshd слушает порт ${NEW_SSH_PORT}"
  else
    warn "Не вижу прослушивание порта ${NEW_SSH_PORT}. Проверь: ss -lntp | grep sshd"
  fi
}

setup_ufw() {
  apt install -y ufw

  # Политики
  ufw default deny incoming
  ufw default allow outgoing

  # Важно: сначала открыть новый SSH порт
  ufw allow "${NEW_SSH_PORT}/tcp"

  # Опционально открываем 443
  if [[ "$OPEN_443" == "y" ]]; then
    ufw allow 443/tcp
  fi

  # Порт 22 — только по явному подтверждению
  if [[ "$OPEN_22" == "y" ]]; then
    ufw allow 22/tcp
  fi

  ufw --force enable
  ufw status
  ok "UFW настроен"
}

setup_fail2ban() {
  apt install -y fail2ban
  systemctl start fail2ban
  systemctl enable fail2ban

  local f="/etc/fail2ban/jail.d/sshd.local"
  cat > "$f" <<EOF
[DEFAULT]
bantime  = 1d
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled  = true
maxretry = 3
findtime = 1d
bantime  = 1w
port     = ssh
EOF

  if [[ -n "${ALLOW_IP}" ]]; then
    echo "ignoreip = ${ALLOW_IP}" >> "$f"
  fi

  systemctl restart fail2ban
  fail2ban-client ping
  if fail2ban-client status sshd >/dev/null 2>&1; then
    ok "Fail2ban активен для sshd"
  else
    warn "Fail2ban установлен, но статус sshd не читается. Проверь: fail2ban-client status"
  fi
}

install_docker() {
  # Официальный установщик Docker (как в исходной логике)
  bash <(curl -sSL https://get.docker.com)
  systemctl is-active docker >/dev/null 2>&1 && ok "Docker daemon активен" || warn "Docker установлен, но daemon не активен"

  if [[ "$ADD_USER_TO_DOCKER" == "y" ]]; then
    usermod -aG docker "$NEW_USER" || warn "Не удалось добавить $NEW_USER в группу docker"
    ok "Пользователь добавлен в группу docker (вступит после нового входа)"
  fi

  # Как в инструкции: docker.io + docker-compose (может поставить docker-compose v1)
  apt update
  apt upgrade -y
  apt install -y docker.io docker-compose git curl bash openssl nano
  ok "docker.io и docker-compose установлены (как в инструкции)"
}

install_mtproto() {
  [[ "$INSTALL_DOCKER_OPT" == "y" ]] || die "MTProto требует Docker. Включите установку Docker."

  # Проверка порта
  if ss -lnt | awk '{print $4}' | grep -qE ":${MTPROTO_PORT}\$"; then
    die "Порт ${MTPROTO_PORT} уже занят. Выберите другой."
  fi

  docker pull telegrammessenger/proxy
  docker run -d -p"${MTPROTO_PORT}:443" --name=mtproto-proxy --restart=always -v proxy-config:/data telegrammessenger/proxy:latest

  docker ps | grep -q mtproto-proxy && ok "MTProto контейнер запущен" || warn "Контейнер mtproto-proxy не виден в docker ps"
  echo
  echo "Логи MTProto (ищите secret/link):"
  docker logs mtproto-proxy || true
}

# ---------- main ----------
require_root

echo "=== VPS Bootstrap (Ubuntu 24.04, старт: root) ==="
echo "Лог будет записан в: $LOG_FILE"
echo

# Ввод
while true; do
  NEW_USER="$(ask_default "Имя нового пользователя" "user")"
  valid_username "$NEW_USER" && break
  echo "Некорректное имя. Допустимо: латиница/цифры/_/-, не root. Пример: user, admin, vpsuser"
done

while true; do
  NEW_SSH_PORT="$(ask_default "Новый порт SSH" "4422")"
  is_port "$NEW_SSH_PORT" || { echo "Некорректный порт."; continue; }
  break
done

PUBLIC_KEY="$(ask_single_line "Вставьте публичный SSH-ключ одной строкой (ssh-ed25519 ... или ssh-rsa ...):")"
is_valid_pubkey "$PUBLIC_KEY" || die "Публичный ключ не похож на корректный ssh-ed25519/ssh-rsa."

ALLOW_IP="$(ask_optional "IP для ignoreip в fail2ban")"

ENABLE_UFW="$(ask_yesno "Включить UFW (firewall)" "y")"
OPEN_443="n"
OPEN_22="n"
if [[ "$ENABLE_UFW" == "y" ]]; then
  OPEN_443="$(ask_yesno "Открыть порт 443/tcp" "y")"
  OPEN_22="$(ask_yesno "Открыть порт 22/tcp (НЕ рекомендуется)" "n")"
fi

INSTALL_FAIL2BAN="$(ask_yesno "Установить fail2ban" "y")"

INSTALL_DOCKER_OPT="$(ask_yesno "Установить Docker" "y")"
ADD_USER_TO_DOCKER="n"
if [[ "$INSTALL_DOCKER_OPT" == "y" ]]; then
  ADD_USER_TO_DOCKER="$(ask_yesno "Добавить нового пользователя в группу docker (чтобы можно было без sudo)" "y")"
fi

INSTALL_MTPROTO_OPT="$(ask_yesno "Установить MTProto proxy (Docker)" "n")"
MTPROTO_PORT="1243"
if [[ "$INSTALL_MTPROTO_OPT" == "y" ]]; then
  while true; do
    MTPROTO_PORT="$(ask_default "Порт на хосте для MTProto (проброс на 443 в контейнер)" "1243")"
    is_port "$MTPROTO_PORT" && break
    echo "Некорректный порт."
  done
fi

echo
echo "=== План ==="
echo "Новый пользователь: $NEW_USER"
echo "Новый SSH порт: $NEW_SSH_PORT"
echo "UFW: $ENABLE_UFW (443: $OPEN_443, 22: $OPEN_22)"
echo "Fail2ban: $INSTALL_FAIL2BAN (ignoreip: ${ALLOW_IP:-нет})"
echo "Docker: $INSTALL_DOCKER_OPT (docker group: $ADD_USER_TO_DOCKER)"
echo "MTProto: $INSTALL_MTPROTO_OPT (порт: $MTPROTO_PORT)"
echo

CONTINUE="$(ask_yesno "Продолжить выполнение" "y")"
[[ "$CONTINUE" == "y" ]] || die "Остановлено пользователем."

echo
echo "[1/7] Обновление системы и базовые пакеты"
install_basics

echo
echo "[2/7] Создание пользователя и права sudo"
create_user_and_sudo

echo
echo "[3/7] Добавление SSH-ключа новому пользователю"
setup_authorized_keys

echo
echo "[4/7] Настройка SSH (Port, PermitRootLogin no, PasswordAuthentication no) + проверка sshd -t"
configure_sshd

echo
if [[ "$ENABLE_UFW" == "y" ]]; then
  echo "[5/7] Настройка UFW"
  setup_ufw
else
  echo "[5/7] UFW пропущен"
fi

echo
if [[ "$INSTALL_FAIL2BAN" == "y" ]]; then
  echo "[6/7] Установка и настройка fail2ban"
  setup_fail2ban
else
  echo "[6/7] fail2ban пропущен"
fi

echo
if [[ "$INSTALL_DOCKER_OPT" == "y" ]]; then
  echo "[7/7] Установка Docker"
  install_docker
else
  echo "[7/7] Docker пропущен"
fi

if [[ "$INSTALL_MTPROTO_OPT" == "y" ]]; then
  echo
  echo "[extra] Установка MTProto proxy"
  install_mtproto
fi

echo
echo "=== Готово ==="
echo "Новый пользователь: $NEW_USER"
echo "Новый SSH порт: $NEW_SSH_PORT"
echo "Следующий вход: ssh -p ${NEW_SSH_PORT} ${NEW_USER}@<IP_СЕРВЕРА>"
echo "Лог: $LOG_FILE"
echo
echo "Рекомендация: откройте новое окно терминала и проверьте вход новым пользователем ДО закрытия текущей сессии root."
