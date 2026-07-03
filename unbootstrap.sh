#!/usr/bin/env bash
set -Eeuo pipefail

# unbootstrap.sh — revert changes made by bootstrap.sh
# Goal: return system to a clean state with only root user.

LOG_FILE="/var/log/unbootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

die() { echo "ОШИБКА: $*" >&2; exit 1; }
ok()  { echo "OK: $*"; }
warn(){ echo "WARN: $*"; }

ROOT_SWITCH_FLAG="--as-root"
if [[ "$(id -u)" -ne 0 ]]; then
  if [[ " ${*:-} " == *" ${ROOT_SWITCH_FLAG} "* ]]; then
    die "Не удалось переключиться на root (скрипт всё ещё не root)."
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    die "Для переключения на root требуется sudo."
  fi

  echo "Требуется включить root и разрешить вход под root."
  echo "Введите новый пароль для root (будет запрошен sudo)."
  sudo passwd root
  sudo passwd -u root >/dev/null 2>&1 || true

  echo "Разрешаем вход под root через SSH."
  sudo sed -i -E "s|^[#[:space:]]*PermitRootLogin[[:space:]]+.*|PermitRootLogin yes|" /etc/ssh/sshd_config
  sudo sed -i -E "s|^[#[:space:]]*PasswordAuthentication[[:space:]]+.*|PasswordAuthentication yes|" /etc/ssh/sshd_config
  sudo systemctl restart ssh || warn "Не удалось перезапустить ssh"

  exec sudo -E bash "$0" "$ROOT_SWITCH_FLAG" "$@"
fi

TARGET_USER=""

usage() {
  cat <<USAGE
Usage: $0 [--user <name>]

If --user is omitted, the script will try to auto-detect exactly one
non-root user with UID >= 1000. If multiple users are found, you must
specify --user.
If started as a non-root user, the script will enable root login,
prompt to set a root password, then re-run itself as root.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      shift
      TARGET_USER="${1:-}"
      [[ -n "$TARGET_USER" ]] || die "--user требует имя пользователя"
      shift
      ;;
    --as-root)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Неизвестный аргумент: $1"
      ;;
  esac
done

resolve_target_user() {
  if [[ -n "$TARGET_USER" ]]; then
    return 0
  fi

  local users
  users=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd)
  local count
  count=$(wc -l <<<"$users")

  if [[ -z "$users" ]]; then
    TARGET_USER=""
    warn "Пользователь с UID >= 1000 не найден (удаление пропущено)."
  elif [[ "$count" -eq 1 ]]; then
    TARGET_USER="$users"
    ok "Автообнаружен пользователь: $TARGET_USER"
  else
    die "Найдено несколько пользователей. Укажите --user. Список: $users"
  fi
}

apt_update_once() {
  if [[ -z "${APT_UPDATED:-}" ]]; then
    apt-get update
    APT_UPDATED=1
  fi
}

apt_purge_if_installed() {
  local pkg
  for pkg in "$@"; do
    if dpkg -l "$pkg" >/dev/null 2>&1; then
      ok "Удаляем пакет: $pkg"
      apt-get purge -y "$pkg" || true
    fi
  done
}

remove_user() {
  resolve_target_user

  if [[ -n "$TARGET_USER" ]] && id "$TARGET_USER" &>/dev/null; then
    ok "Удаляем пользователя: $TARGET_USER"
    pkill -u "$TARGET_USER" >/dev/null 2>&1 || true
    userdel -r "$TARGET_USER" || true
    ok "Пользователь удалён: $TARGET_USER"
  else
    warn "Пользователь для удаления не найден."
  fi
}

restore_sshd_config() {
  ok "Восстановление SSH конфигурации"
  local f="/etc/ssh/sshd_config"
  local latest_backup
  latest_backup=$(ls -1t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -n1 || true)

  if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
    cp -a "$latest_backup" "$f"
    rm -f /etc/ssh/sshd_config.bak.*
    ok "Восстановлен бэкап sshd_config: $latest_backup"
  else
    warn "Бэкапы sshd_config не найдены. Возвращаем базовые настройки."
    if [[ -f "$f" ]]; then
      sed -i -E "s|^[#[:space:]]*Port[[:space:]]+.*|Port 22|" "$f" || true
      sed -i -E "s|^[#[:space:]]*PermitRootLogin[[:space:]]+.*|PermitRootLogin yes|" "$f" || true
      sed -i -E "s|^[#[:space:]]*PasswordAuthentication[[:space:]]+.*|PasswordAuthentication yes|" "$f" || true
      sed -i -E "s|^[#[:space:]]*PubkeyAuthentication[[:space:]]+.*|PubkeyAuthentication yes|" "$f" || true
      sed -i -E "s|^[#[:space:]]*AuthorizedKeysFile[[:space:]]+.*|AuthorizedKeysFile .ssh/authorized_keys|" "$f" || true
    fi
  fi

  if sshd -t; then
    systemctl restart ssh || warn "Не удалось перезапустить ssh"
    ok "SSH восстановлен"
  else
    warn "sshd -t не прошёл. Проверьте конфигурацию вручную."
  fi
}

remove_ufw() {
  if command -v ufw >/dev/null 2>&1; then
    ok "Отключаем UFW"
    ufw --force reset || true
    ufw --force disable || true
  fi

  apt_purge_if_installed ufw
  rm -rf /etc/ufw || true
  ok "UFW удалён"
}

remove_fail2ban() {
  if systemctl list-unit-files | grep -q '^fail2ban.service'; then
    systemctl disable --now fail2ban || true
  fi
  rm -f /etc/fail2ban/jail.d/sshd.local || true
  apt_purge_if_installed fail2ban
  rm -rf /etc/fail2ban || true
  ok "Fail2ban удалён"
}

remove_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Останавливаем Docker и контейнеры"
    if [[ -f /opt/telemt/docker-compose.yml ]] && docker compose version >/dev/null 2>&1; then
      docker compose -f /opt/telemt/docker-compose.yml down >/dev/null 2>&1 || true
    fi
    docker rm -f telemt-proxy >/dev/null 2>&1 || true
    docker rm -f 3x-ui >/dev/null 2>&1 || true
    rm -rf /opt/telemt /etc/x-ui /usr/local/x-ui || true
    systemctl disable --now docker || true
  else
    rm -rf /opt/telemt /etc/x-ui /usr/local/x-ui || true
  fi

  apt_purge_if_installed docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras

  rm -rf /var/lib/docker /var/lib/containerd || true
  rm -f /etc/apt/sources.list.d/docker.list || true
  rm -f /etc/apt/keyrings/docker.gpg || true
  rm -f /etc/apt/trusted.gpg.d/docker.gpg || true
  ok "Docker удалён"
}

cleanup_logs() {
  rm -f /var/log/bootstrap_start2.log || true
  ok "Логи bootstrap удалены"
}

final_cleanup() {
  apt_update_once
  apt-get autoremove -y || true
  apt-get clean || true
}

ok "Старт удаления изменений bootstrap.sh"
remove_user
restore_sshd_config
remove_ufw
remove_fail2ban
remove_docker
cleanup_logs
final_cleanup

ok "Готово: система приведена к состоянию с одним пользователем root."
