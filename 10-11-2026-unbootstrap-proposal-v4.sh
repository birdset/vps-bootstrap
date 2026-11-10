#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE_DIR=/var/lib/vps-bootstrap
STATE_FILE=$STATE_DIR/settings.tsv
MANIFEST=$STATE_DIR/created.tsv
LOG_FILE=/var/log/vps-unbootstrap.log

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
usage() {
  cat <<'EOF'
Usage: sudo bash unbootstrap.sh [--dry-run | --apply]
Default: show managed resources and exit without changing the server.
--apply: stop managed services and remove managed containers and their rules.
User, SSH, Docker, UFW, packages and application data are retained.
EOF
}

MODE=dry-run
while (($#)); do
  case "$1" in
    --dry-run) MODE=dry-run ;;
    --apply) MODE=apply ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done
[[ $(id -u) -eq 0 ]] || die "Run with sudo. No SSH authentication settings were changed."
[[ -f $MANIFEST && -f $STATE_FILE ]] || die "Managed installation state is missing."
chmod 600 "$MANIFEST" "$STATE_FILE"

has_record() { grep -qxF "$(printf '%s\t%s' "$1" "$2")" "$MANIFEST"; }
get_setting() { awk -F '\t' -v key="$1" '$1 == key {print $2; exit}' "$STATE_FILE"; }
USER_NAME=$(get_setting user)
[[ $USER_NAME =~ ^[a-z_][a-z0-9_-]*$ && $USER_NAME != root ]] ||
  die "Invalid user recorded in installation state."

show_plan() {
  printf 'Will stop/remove when managed and present:\n'
  local path
  for path in telemt-in-syn-watch.service fail2ban; do
    if has_record service "$path"; then printf '  service: %s\n' "$path"; fi
  done
  for path in telemt-proxy 3x-ui; do
    if has_record container "$path"; then printf '  container: %s\n' "$path"; fi
  done
  for path in \
    /etc/systemd/system/telemt-in-syn-watch.service \
    /usr/local/sbin/telemt-in-syn-limit.sh \
    /usr/local/sbin/telemt-in-syn-watch.sh \
    /etc/fail2ban/jail.d/vps-bootstrap-sshd.local; do
    if has_record file "$path" && [[ -e $path ]]; then
      printf '  file: %s\n' "$path"
    fi
  done
  if has_record iptables_chain VPS-TELEMT; then
    printf '  firewall chain: VPS-TELEMT\n'
  fi
  if has_record ufw "$(get_setting telemt_port)/tcp"; then
    printf '  UFW allow rule: %s/tcp\n' "$(get_setting telemt_port)"
  fi
  cat <<EOF

Will retain: user $USER_NAME, SSH configuration, SSH firewall rules, UFW,
Docker, installed packages, images, volumes, application data and $STATE_DIR.
EOF
}
show_plan
[[ $MODE == apply ]] || exit 0

read -r -p 'Type CLEANUP to apply this plan: ' answer || die "Input ended."
[[ $answer == CLEANUP ]] || die "Cancelled."
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# These exact names are the only resources this script can remove.
if has_record service telemt-in-syn-watch.service; then
  systemctl disable --now telemt-in-syn-watch.service || true
fi
if has_record file /etc/systemd/system/telemt-in-syn-watch.service; then
  rm -f -- /etc/systemd/system/telemt-in-syn-watch.service
  systemctl daemon-reload
fi
if has_record file /usr/local/sbin/telemt-in-syn-limit.sh; then
  rm -f -- /usr/local/sbin/telemt-in-syn-limit.sh
fi
if has_record file /usr/local/sbin/telemt-in-syn-watch.sh; then
  rm -f -- /usr/local/sbin/telemt-in-syn-watch.sh
fi
if has_record iptables_chain VPS-TELEMT && command -v iptables >/dev/null 2>&1; then
  iptables -D DOCKER-USER -j VPS-TELEMT 2>/dev/null || true
  iptables -F VPS-TELEMT 2>/dev/null || true
  iptables -X VPS-TELEMT 2>/dev/null || true
fi
if command -v docker >/dev/null 2>&1; then
  if has_record container telemt-proxy; then
    docker rm -f telemt-proxy || true
  fi
  if has_record container 3x-ui; then
    docker rm -f 3x-ui || true
  fi
fi
if has_record service fail2ban; then
  systemctl disable --now fail2ban || true
fi
if has_record file /etc/fail2ban/jail.d/vps-bootstrap-sshd.local; then
  rm -f -- /etc/fail2ban/jail.d/vps-bootstrap-sshd.local
  if ! has_record service fail2ban && systemctl is-active --quiet fail2ban; then
    systemctl restart fail2ban || warn "Could not reload pre-existing Fail2ban."
  fi
fi

if command -v ufw >/dev/null 2>&1; then
  port=$(get_setting telemt_port)
  if has_record ufw "$port/tcp"; then
    ufw delete allow "$port/tcp" || warn "Could not remove managed UFW rule: $port/tcp"
  fi
fi

cat <<EOF
Cleanup complete. Retained:
  user: $USER_NAME
  SSH configuration and SSH firewall rules
  UFW, Docker and installed packages
  /opt/telemt, /etc/x-ui and /usr/local/x-ui
  state: $STATE_DIR
  log: $LOG_FILE
Verify SSH in a new session before making any further changes.
EOF
