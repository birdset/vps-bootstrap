#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Ubuntu 24.04. Run prepare as root, verify a new SSH session, then run --finalize.
STATE_DIR=/var/lib/vps-bootstrap
STATE_FILE=$STATE_DIR/settings.tsv
MANIFEST=$STATE_DIR/created.tsv
LOG_FILE=/var/log/vps-bootstrap.log
SSH_DROPIN=/etc/ssh/sshd_config.d/00-vps-bootstrap.conf

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
usage() {
  cat <<'EOF'
Usage: bash bootstrap.sh [--prepare | --finalize --confirm-ssh-login]
--prepare: create the user, install services, and listen on both old and new SSH ports.
--finalize: after logging in through a second SSH session on the new port,
            disable root and password SSH login.
EOF
}

MODE=prepare
CONFIRM_LOGIN=false
while (($#)); do
  case "$1" in
    --prepare) MODE=prepare ;;
    --finalize) MODE=finalize ;;
    --confirm-ssh-login) CONFIRM_LOGIN=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done
[[ $(id -u) -eq 0 ]] || die "Run as root: sudo bash bootstrap.sh"
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || die "Only Ubuntu 24.04 is supported."
install -d -m 700 "$STATE_DIR"
touch "$MANIFEST" "$STATE_FILE"
chmod 600 "$MANIFEST" "$STATE_FILE"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

has_record() { grep -qxF "$(printf '%s\t%s' "$1" "$2")" "$MANIFEST"; }
record() {
  has_record "$1" "$2" || printf '%s\t%s\n' "$1" "$2" >> "$MANIFEST"
}
get_setting() { awk -F '\t' -v key="$1" '$1 == key {print $2; exit}' "$STATE_FILE"; }
set_setting() {
  [[ -z $(get_setting "$1") ]] || die "Setting already recorded: $1"
  printf '%s\t%s\n' "$1" "$2" >> "$STATE_FILE"
}
ask() {
  local answer
  read -r -p "$1: " answer || die "Input ended."
  printf '%s' "$answer"
}
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ && "$1" != root ]]; }
valid_domain() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ && "$1" == *.* ]]; }
valid_key() { printf '%s\n' "$1" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1; }
apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}
guard_new_file() {
  local path=$1
  if [[ -e $path || -L $path ]] && ! has_record file "$path"; then
    die "Existing file is not owned by vps-bootstrap: $path"
  fi
}
guard_new_dir() {
  local path=$1
  if [[ -e $path || -L $path ]] && ! has_record dir "$path"; then
    die "Existing directory is not owned by vps-bootstrap: $path"
  fi
}
managed_file() {
  local path=$1 mode=$2 content=$3 temp
  guard_new_file "$path"
  temp=$(mktemp "$STATE_DIR/write.XXXXXX")
  printf '%s' "$content" > "$temp"
  if [[ -e $path ]]; then
    if ! cmp -s "$temp" "$path"; then
      rm -f "$temp"
      die "Managed file changed; inspect it before rerunning: $path"
    fi
    rm -f "$temp"
    return
  fi
  install -m "$mode" "$temp" "$path"
  rm -f "$temp"
  record file "$path"
}
ufw_allow_if_missing() {
  local port=$1
  if ! ufw show added | grep -qF "ufw allow $port/tcp"; then
    ufw allow "$port/tcp"
    record ufw "$port/tcp"
  fi
}
image_digest() {
  local key=$1 tag=$2 saved
  saved=$(get_setting "$key")
  if [[ -n $saved ]]; then printf '%s' "$saved"; return; fi
  docker pull "$tag" >&2
  local digest
  digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$tag")
  [[ $digest == *@sha256:* ]] || die "Could not resolve image digest: $tag"
  set_setting "$key" "$digest"
  printf '%s' "$digest"
}

if [[ $MODE == prepare ]]; then
  if [[ -z $(get_setting user) ]]; then
    NEW_USER=$(ask "New user name")
    valid_user "$NEW_USER" || die "Invalid user name."
    id "$NEW_USER" &>/dev/null && die "User already exists: $NEW_USER"
    PUBLIC_KEY=$(ask "Public SSH key (one line)")
    valid_key "$PUBLIC_KEY" || die "Invalid public SSH key."
    TELEMT_TLS_DOMAIN=$(ask "Telemt TLS domain")
    valid_domain "$TELEMT_TLS_DOMAIN" || die "Invalid domain."
    set_setting user "$NEW_USER"
    set_setting ssh_port 4422
    set_setting telemt_port 1243
    set_setting tls_domain "$TELEMT_TLS_DOMAIN"
  else
    NEW_USER=$(get_setting user)
    PUBLIC_KEY=$(ask "Public SSH key (one line)")
    valid_key "$PUBLIC_KEY" || die "Invalid public SSH key."
    TELEMT_TLS_DOMAIN=$(get_setting tls_domain)
  fi
else
  [[ $CONFIRM_LOGIN == true ]] || die "First verify a second SSH login, then pass --confirm-ssh-login."
  [[ -n $(get_setting user) ]] || die "Run --prepare first."
fi
NEW_USER=$(get_setting user)
NEW_SSH_PORT=$(get_setting ssh_port)
TELEMT_PORT=$(get_setting telemt_port)
TELEMT_TLS_DOMAIN=$(get_setting tls_domain)

# ---------------- actions ----------------
install_basics() {
  apt_install curl git nano openssl ca-certificates gnupg jq ufw
  ok "Basic packages installed; system packages were not upgraded."
}
create_user() {
  if has_record user "$NEW_USER"; then
    id "$NEW_USER" &>/dev/null || die "Managed user is missing: $NEW_USER"
    return
  fi
  id "$NEW_USER" &>/dev/null && die "Refusing to modify pre-existing user: $NEW_USER"
  useradd -m -s /bin/bash "$NEW_USER"
  record user "$NEW_USER"
  usermod -aG sudo "$NEW_USER"
  passwd "$NEW_USER"
  ok "Created sudo user: $NEW_USER"
}
setup_keys() {
  local home ak
  home=$(getent passwd "$NEW_USER" | cut -d: -f6)
  [[ -d $home ]] || die "Home directory missing for $NEW_USER"
  ak=$home/.ssh/authorized_keys
  if [[ -n $PUBLIC_KEY ]]; then
    install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$home/.ssh"
    touch "$ak"
    chown "$NEW_USER:$NEW_USER" "$ak"
    chmod 600 "$ak"
    grep -qxF "$PUBLIC_KEY" "$ak" || printf '%s\n' "$PUBLIC_KEY" >> "$ak"
  fi
  [[ -s $ak ]] || die "authorized_keys is missing or empty: $ak"
  ok "SSH key present for $NEW_USER"
}
prepare_ssh() {
  guard_new_file "$SSH_DROPIN"
  local ports content='' port
  ports=$(get_setting old_ssh_ports)
  for port in $ports; do content+="Port $port"$'\n'; done
  case " $ports " in *" $NEW_SSH_PORT "*) ;; *) content+="Port $NEW_SSH_PORT"$'\n' ;; esac
  content+="# Managed by vps-bootstrap; finalize only after a real SSH login."$'\n'
  managed_file "$SSH_DROPIN" 600 "$content"
  if ! sshd -t || ! sshd -T | awk '$1=="port" {print $2}' | grep -qx "$NEW_SSH_PORT"; then
    die "New SSH configuration is invalid. Keep the current session and inspect $SSH_DROPIN"
  fi
  systemctl reload ssh
  ss -lnt | awk '{print $4}' | grep -qE ":$NEW_SSH_PORT$" ||
    die "New SSH port is not listening. Keep the current session."
  ok "SSH listens on old port(s) and $NEW_SSH_PORT; root login remains unchanged."
}

finalize_ssh() {
  [[ -f $SSH_DROPIN ]] && has_record file "$SSH_DROPIN" ||
    die "Managed SSH drop-in is missing."
  local backup effective
  backup=$(mktemp "$STATE_DIR/ssh-prepare.XXXXXX")
  cp -a "$SSH_DROPIN" "$backup"
  printf 'Port %s\nPermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\n' "$NEW_SSH_PORT" > "$SSH_DROPIN"
  chmod 600 "$SSH_DROPIN"
  if ! sshd -t; then
    cp -a "$backup" "$SSH_DROPIN"
    die "sshd -t failed; prepare configuration restored."
  fi
  effective=$(sshd -T)
  if ! grep -qx "permitrootlogin no" <<< "$effective" ||
     ! grep -qx "passwordauthentication no" <<< "$effective" ||
     ! grep -qx "kbdinteractiveauthentication no" <<< "$effective" ||
     ! grep -qx "port $NEW_SSH_PORT" <<< "$effective" ||
     [[ $(awk '$1=="port" {n++} END {print n+0}' <<< "$effective") -ne 1 ]]; then
    cp -a "$backup" "$SSH_DROPIN"
    die "Effective SSH settings differ from expected; prepare configuration restored."
  fi
  if ! systemctl reload ssh; then
    cp -a "$backup" "$SSH_DROPIN"
    systemctl reload ssh || true
    die "SSH reload failed; prepare configuration restored."
  fi
  if ! ss -lnt | awk '{print $4}' | grep -qE ":$NEW_SSH_PORT$"; then
    cp -a "$backup" "$SSH_DROPIN"
    systemctl reload ssh || true
    die "New SSH port is not listening; prepare configuration restored."
  fi
  for port in $(get_setting old_ssh_ports); do
    if [[ $port != "$NEW_SSH_PORT" ]] && has_record ufw "$port/tcp"; then
      ufw delete allow "$port/tcp" || warn "Could not close old port $port in UFW."
    fi
  done
  record finalized yes
}
setup_ufw() {
  local old_ports port
  old_ports=$(get_setting old_ssh_ports)
  if [[ -z $old_ports ]]; then
    old_ports=$(sshd -T | awk '$1=="port" {print $2}' | sort -u | xargs)
    [[ -n $old_ports ]] || die "Could not determine current SSH port."
    set_setting old_ssh_ports "$old_ports"
  fi
  for port in $old_ports; do ufw_allow_if_missing "$port"; done
  ufw_allow_if_missing "$NEW_SSH_PORT"
  ufw_allow_if_missing "$TELEMT_PORT"
  if ! ufw status | grep -q '^Status: active'; then
    ufw --force enable
    record ufw_enabled yes
  fi
  ok "UFW allows existing SSH, new SSH and Telemt ports."
}
setup_fail2ban() {
  apt_install fail2ban
  local f=/etc/fail2ban/jail.d/vps-bootstrap-sshd.local content
  content=$(cat <<EOF
[DEFAULT]
banaction = ufw

[sshd]
enabled = true
maxretry = 3
findtime = 1d
bantime = 1w
port = $NEW_SSH_PORT
EOF
)
  managed_file "$f" 600 "$content"
  if ! systemctl is-enabled --quiet fail2ban; then
    systemctl enable fail2ban
    record service fail2ban
  fi
  systemctl restart fail2ban
  fail2ban-client ping >/dev/null || die "Fail2ban did not start."
}
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    docker compose version >/dev/null 2>&1 ||
      die "Existing Docker has no Compose plugin. Install it before rerunning."
    ok "Using existing Docker installation."
    return
  fi
  local conflict
  for conflict in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg-query -W -f='${Status}' "$conflict" 2>/dev/null | grep -qx 'install ok installed'; then
      die "Conflicting pre-existing package $conflict; resolve manually before Docker installation."
    fi
  done
  install -d -m 755 /etc/apt/keyrings
  local key
  key=$(curl -fsSL https://download.docker.com/linux/ubuntu/gpg)
  managed_file /etc/apt/keyrings/docker.asc 644 "$key"
  local source
  source=$(cat <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
)
  managed_file /etc/apt/sources.list.d/docker.sources 644 "$source"
  apt-get update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker compose version >/dev/null || die "Docker Compose plugin is not working."
  record docker_installed yes
  ok "Docker installed from the official apt repository."
}
install_telemt() {
  ok "Шаг: install_telemt"
  command -v docker >/dev/null 2>&1 || die "Telemt требует Docker (docker не найден)."
  docker compose version >/dev/null 2>&1 || die "Telemt требует docker compose plugin (docker compose не найден)."

  if docker ps -a --format '{{.Names}}' | grep -qx telemt-proxy; then
    has_record container telemt-proxy ||
      die "Existing telemt-proxy container is not managed by vps-bootstrap."
    docker start telemt-proxy >/dev/null || true
    ok "Using managed Telemt container."
    return
  fi

  # проверка порта на занятость на хосте
  if ss -lnt | awk '{print $4}' | grep -qE ":${TELEMT_PORT}\$"; then
    die "Порт $TELEMT_PORT занят на хосте. Выберите другой."
  fi

  local telemt_dir="/opt/telemt"
  local config_dir="$telemt_dir/config"
  local config_file="$config_dir/config.toml"
  local compose_file="$telemt_dir/docker-compose.yml"
  local telemt_secret="" telemt_api_secret=""

  guard_new_dir "$telemt_dir"
  guard_new_file "$config_file"
  guard_new_file "$compose_file"
  if [[ ! -e "$telemt_dir" ]]; then
    install -d -m 700 "$telemt_dir"
    record dir "$telemt_dir"
  fi
  install -d -m 700 "$config_dir"
  telemt_secret="$(openssl rand -hex 16)"
  telemt_api_secret="$(openssl rand -hex 24)"
  local TELEMT_IMAGE
  TELEMT_IMAGE=$(image_digest telemt_image ghcr.io/telemt/telemt:latest)

  if [[ ! -e "$config_file" ]]; then
  cat > "$config_file" <<EOF
[general]
use_middle_proxy = true
log_level = "normal"
tg_connect = 10
client_mss_bulk = "1400"

[timeouts]
client_handshake = 15
client_keepalive = 60

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"

[server]
port = 443
[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.1/32", "172.16.0.0/12"]
auth_header = "Bearer ${telemt_api_secret}"

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${TELEMT_TLS_DOMAIN}"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
hello = "${telemt_secret}"
EOF
  chmod 600 "$config_file"
  record file "$config_file"
  fi

  if [[ ! -e "$compose_file" ]]; then
  cat > "$compose_file" <<EOF
services:
  telemt:
    image: ${TELEMT_IMAGE}
    container_name: telemt-proxy
    restart: unless-stopped
    ports:
      - "0.0.0.0:${TELEMT_PORT}:443"
      - "127.0.0.1:9091:9091"
    working_dir: /run/telemt
    command: ["/etc/telemt/config.toml"]
    volumes:
      - ./config:/etc/telemt:rw
    tmpfs:
      - /run/telemt:rw,mode=1777,size=4m
    environment:
      - RUST_LOG=info
    healthcheck:
      test: ["CMD", "/app/telemt", "healthcheck", "/etc/telemt/config.toml", "--mode", "liveness"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 65536
        hard: 262144
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
EOF
  chmod 600 "$compose_file"
  record file "$compose_file"
  fi

  docker compose -f "$compose_file" pull
  docker compose -f "$compose_file" up -d
  record container telemt-proxy

  if docker ps --format '{{.Names}}' | grep -qx 'telemt-proxy'; then
    ok "Telemt контейнер запущен (порт ${TELEMT_PORT} -> 443, TLS domain: ${TELEMT_TLS_DOMAIN})"
  else
    warn "Контейнер telemt-proxy не запущен. Проверь: docker logs telemt-proxy"
  fi

  ok "Telemt diagnostics: docker ps --filter name=telemt-proxy"
}

setup_telemt_tuning() {
  command -v iptables >/dev/null 2>&1 || die "Telemt limiter requires iptables."
  iptables -S DOCKER-USER >/dev/null 2>&1 ||
    die "Docker's DOCKER-USER chain is unavailable; limiter was not installed."
  docker ps --format '{{.Names}}' | grep -qx telemt-proxy ||
    die "Telemt is not running; limiter cannot be verified."
  local limit=/usr/local/sbin/telemt-in-syn-limit.sh
  local watch=/usr/local/sbin/telemt-in-syn-watch.sh
  local unit=/etc/systemd/system/telemt-in-syn-watch.service
  if [[ -e $limit || -e $watch || -e $unit ]]; then
    has_record file "$limit" && has_record file "$watch" && has_record file "$unit" ||
      die "Existing Telemt limiter files are not fully managed."
    record iptables_chain VPS-TELEMT
    "$limit" telemt-proxy
    systemctl is-active --quiet telemt-in-syn-watch.service ||
      systemctl start telemt-in-syn-watch.service
    return
  fi
  if iptables -S VPS-TELEMT >/dev/null 2>&1 &&
     ! has_record iptables_chain VPS-TELEMT; then
    die "Existing VPS-TELEMT firewall chain is not managed."
  fi
  cat > "$limit" <<'EOF'
#!/bin/sh
set -eu
CONTAINER="${1:-telemt-proxy}"
IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' "$CONTAINER" | awk 'NF {print; exit}')"
[ -n "$IP" ] || { echo "Telemt container IP not found" >&2; exit 1; }
iptables -N VPS-TELEMT 2>/dev/null || true
iptables -C DOCKER-USER -j VPS-TELEMT 2>/dev/null ||
  iptables -I DOCKER-USER 1 -j VPS-TELEMT
iptables -F VPS-TELEMT
iptables -A VPS-TELEMT -d "$IP" -p tcp --dport 443 --tcp-flags SYN,ACK SYN \
  -m hashlimit --hashlimit-above 1/second --hashlimit-burst 1 \
  --hashlimit-mode srcip --hashlimit-name vps_telemt_syn \
  --hashlimit-htable-expire 60000 -j DROP
iptables -A VPS-TELEMT -j RETURN
EOF
  cat > "$watch" <<'EOF'
#!/bin/sh
set -u
CONTAINER="${1:-telemt-proxy}"
LAST_IP=""
while true; do
  RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)"
  if [ "$RUNNING" = true ]; then
    IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' "$CONTAINER" 2>/dev/null | awk 'NF {print; exit}')"
    if [ -n "$IP" ] && [ "$IP" != "$LAST_IP" ]; then
      if /usr/local/sbin/telemt-in-syn-limit.sh "$CONTAINER"; then
        LAST_IP="$IP"
      fi
    fi
  else
    LAST_IP=""
  fi
  sleep 5
done
EOF
  chmod 700 "$limit" "$watch"
  record file "$limit"
  record file "$watch"
  cat > "$unit" <<'EOF'
[Unit]
Description=Refresh Telemt per-client SYN limiter in DOCKER-USER
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/telemt-in-syn-watch.sh telemt-proxy
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  chmod 600 "$unit"
  record file "$unit"
  systemctl daemon-reload
  record iptables_chain VPS-TELEMT
  "$limit" telemt-proxy
  systemctl enable --now telemt-in-syn-watch.service
  record service telemt-in-syn-watch.service
  systemctl is-active --quiet telemt-in-syn-watch.service ||
    die "Telemt limiter watcher did not start."
}

install_3x_ui() {
  if docker ps -a --format '{{.Names}}' | grep -qx 3x-ui; then
    has_record container 3x-ui ||
      die "Existing 3x-ui container is not managed by vps-bootstrap."
    docker start 3x-ui >/dev/null || true
    return
  fi
  local dir image
  for dir in /etc/x-ui /usr/local/x-ui; do
    guard_new_dir "$dir"
    if [[ ! -e $dir ]]; then
      install -d -m 700 "$dir"
      record dir "$dir"
    fi
  done
  image=$(image_digest xui_image ghcr.io/mhsanaei/3x-ui:latest)
  docker run -d \
    --name 3x-ui \
    --restart unless-stopped \
    --network host \
    --cap-drop ALL \
    --cap-add NET_BIND_SERVICE \
    --security-opt no-new-privileges:true \
    -e XUI_ENABLE_FAIL2BAN=false \
    -v /etc/x-ui:/etc/x-ui \
    -v /usr/local/x-ui:/usr/local/x-ui \
    "$image"
  record container 3x-ui
  docker ps --format '{{.Names}}' | grep -qx 3x-ui ||
    die "3x-ui container did not stay running; inspect docker logs 3x-ui."
  ok "3x-ui started without privileged mode."
}

add_aliases() {
  local home aliases_file bashrc
  home=$(getent passwd "$NEW_USER" | cut -d: -f6)
  aliases_file=$home/.bash_aliases
  bashrc=$home/.bashrc
  [[ -e $aliases_file ]] || install -m 600 -o "$NEW_USER" -g "$NEW_USER" /dev/null "$aliases_file"
  grep -q '^alias update=' "$aliases_file" ||
    printf '%s\n' "alias update='sudo apt update && sudo apt upgrade'" >> "$aliases_file"
  grep -q '^alias dps=' "$aliases_file" ||
    printf '%s\n' "alias dps='sudo docker ps'" >> "$aliases_file"
  chown "$NEW_USER:$NEW_USER" "$aliases_file"
  chmod 600 "$aliases_file"
  if ! grep -qF 'bootstrap: load .bash_aliases' "$bashrc"; then
    cat >> "$bashrc" <<'EOF'
# bootstrap: load .bash_aliases
if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi
EOF
  fi
  chown "$NEW_USER:$NEW_USER" "$bashrc"
}

# ---------------- run ----------------
if [[ $MODE == finalize ]]; then
  finalize_ssh
  apt-get update
  install_basics
  setup_fail2ban
  install_docker
  install_3x_ui
  install_telemt
  setup_telemt_tuning
  add_aliases
  ok "SSH and services configured. Verify one more login before closing the original session."
  exit 0
fi

apt-get update
apt_install ufw
create_user
setup_keys
setup_ufw
prepare_ssh

cat <<EOF
SSH preparation complete. Do NOT close this root session yet.
From a second terminal, run: ssh -p $NEW_SSH_PORT $NEW_USER@<SERVER_ADDRESS>
Confirm that sudo works, then on the VPS run:
  sudo bash /tmp/vps-bootstrap.sh --finalize --confirm-ssh-login
Finalization hardens SSH and installs the remaining services.
Log: $LOG_FILE
EOF
