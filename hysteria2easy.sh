#!/bin/bash
# hysteria2easy.sh — One-command Hysteria2 server setup with TLS + QR
# Copyright (c) 2026 Artemis Kushner
# https://github.com/arxdeus/hysteria2easy
# Licensed under MIT

VERSION="1.0.0"
HYSTERIA_REPO="apernet/hysteria"
HYSTERIA_DIR="/etc/hysteria2"
CERT_DIR="/root/.acme.sh"

# Default values (overridden by CLI args or prompts)
SSH_HOST="" SSH_PORT="22" SSH_USER="root" SSH_PASSWORD=""
SERVER_IP="" HYSTERIA_PORT="443" AUTH_PASSWORD="" REMARK="Hysteria2"

# ─── Color output ───────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Logging ──────────────────────────────────────────────────────────────────
log_info() { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── SSH helpers ──────────────────────────────────────────────────────────────
ssh_exec() {
  sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o BatchMode=no \
    -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" "$1"
}

ssh_test() {
  local retries=3
  for i in $(seq 1 $retries); do
    if ssh_exec "echo ok" &>/dev/null; then
      log_ok "SSH connection to ${SSH_HOST}:${SSH_PORT} established"
      return 0
    fi
    log_warn "SSH attempt $i/$retries failed. Retrying..."
    sleep 2
  done
  log_error "Cannot connect to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
  log_error "Check host, port, and password."
  exit 1
}

# ─── Dependency checks ───────────────────────────────────────────────────────
check_local_deps() {
  local missing=()
  for cmd in sshpass qrencode curl; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if ((${#missing[@]} > 0)); then
    log_error "Missing local dependencies: ${missing[*]}"
    echo -e "${BOLD}Install with:${NC}"
    echo "  Ubuntu/Debian: sudo apt install ${missing[*]}"
    echo "  macOS:         brew install ${missing[*]}"
    exit 1
  fi
}

check_remote_deps() {
  log_info "Installing remote dependencies..."
  # netcat-openbsd: nc command
  # psmisc: fuser command (kills processes on ports)
  # socat: needed for acme.sh HTTP-01 challenge
  # Use || true to allow error handling with set -e
  ssh_exec "apt-get update && apt-get install -y curl openssl socat net-tools psmisc netcat-openbsd" || {
    log_error "Failed to install remote dependencies"
    exit 1
  }
  # Verify all tools exist
  ssh_exec "command -v curl openssl socat nc fuser >/dev/null" || {
    log_error "One or more dependencies failed to install"
    exit 1
  }
  log_ok "Remote dependencies installed"
}

# ─── Banner ───────────────────────────────────────────────────────────────────
show_banner() {
  cat <<EOF

╔════════════════════════════════════════════════════╗
║        Hysteria2 Easy Setup  v${VERSION}              ║
║        One-command Hysteria2 + TLS + QR         ║
╚════════════════════════════════════════════════════╝

EOF
}

# ─── CLI argument parsing ──────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-host)
        SSH_HOST="$2"
        shift 2
        ;;
      --ssh-port)
        SSH_PORT="$2"
        shift 2
        ;;
      --ssh-user)
        SSH_USER="$2"
        shift 2
        ;;
      --ssh-password)
        SSH_PASSWORD="$2"
        shift 2
        ;;
      --port)
        HYSTERIA_PORT="$2"
        shift 2
        ;;
      --password)
        AUTH_PASSWORD="$2"
        shift 2
        ;;
      --remark)
        REMARK="$2"
        shift 2
        ;;
      --ip)
        SERVER_IP="$2"
        shift 2
        ;;
      --help | -h)
        cat <<'HELPEOF'
Usage: hysteria2easy.sh [OPTIONS]

  --ssh-host HOST       Server IP [required or prompted]
  --ssh-port PORT       SSH port [22]
  --ssh-user USER       SSH user [root]
  --ssh-password PASS   SSH password [prompted]
  --port PORT           Hysteria2 port [443]
  --password PASS       Auth password [prompted]
  --remark REMARK       Connection remark [Hysteria2]
  --ip IP              Server public IP [auto-detected]
  --help, -h           Show this help
HELPEOF
        exit 0
        ;;
      *) shift ;;
    esac
  done
}

# ─── Interactive prompts ──────────────────────────────────────────────────────
prompt_ssh_config() {
  echo -e "\n${BOLD}═══ SSH Connection ═══${NC}"
  [[ -z "$SSH_HOST" ]] && read -p "Server IP: " SSH_HOST
  [[ -z "$SSH_PORT" ]] && read -p "SSH Port [22]: " SSH_PORT
  SSH_PORT="${SSH_PORT:-22}"
  [[ -z "$SSH_USER" ]] && read -p "SSH User [root]: " SSH_USER
  SSH_USER="${SSH_USER:-root}"
  [[ -z "$SSH_PASSWORD" ]] && {
    read -r -s -p "SSH Password: " SSH_PASSWORD
    echo
  }
  [[ -z "$SSH_PASSWORD" ]] && {
    log_error "Password cannot be empty"
    exit 1
  }
}

prompt_server_config() {
  echo -e "\n${BOLD}═══ Hysteria2 Configuration ═══${NC}"

  # Server IP = SSH_HOST (the IP we're already connected to)
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$SSH_HOST"
  fi
  log_info "Server IP: ${SERVER_IP}"

  [[ -z "$HYSTERIA_PORT" ]] && read -p "Hysteria2 Port [443]: " HYSTERIA_PORT
  HYSTERIA_PORT="${HYSTERIA_PORT:-443}"

  [[ -z "$AUTH_PASSWORD" ]] && {
    read -r -s -p "Auth Password: " AUTH_PASSWORD
    echo
  }
  [[ -z "$AUTH_PASSWORD" ]] && {
    log_error "Password cannot be empty"
    exit 1
  }

  [[ -z "$REMARK" ]] && read -p "Connection Remark [Hysteria2]: " REMARK
  REMARK="${REMARK:-Hysteria2}"
}

# ─── Pre-flight checks ────────────────────────────────────────────────────────
check_ports() {
  log_info "Checking port availability..."

  # Stop existing Hysteria2 if running (re-install scenario)
  ssh_exec "systemctl stop hysteria2 2>/dev/null || true"
  ssh_exec "fuser -k ${HYSTERIA_PORT}/tcp ${HYSTERIA_PORT}/udp 2>/dev/null || true"
  sleep 2

  # Port 80 must be FREE (not in use) — acme.sh will start its own listener
  if ssh_exec "ss -tlnp | grep -q ':80 '" &>/dev/null; then
    log_warn "Port 80 is occupied. Attempting to free it..."
    ssh_exec "fuser -k 80/tcp 2>/dev/null || true"
    sleep 1
    if ssh_exec "ss -tlnp | grep -q ':80 '" &>/dev/null; then
      log_error "Port 80 is still in use. acme.sh needs port 80 for HTTP-01 challenge."
      log_error "Free it manually: fuser -k 80/tcp"
      exit 1
    fi
  fi
  log_ok "Port 80 is free for ACME challenge"

  # Hysteria port must also be free
  if ssh_exec "ss -tlnup | grep -q ':${HYSTERIA_PORT} '" &>/dev/null; then
    log_error "Port ${HYSTERIA_PORT} is already in use. Choose another port."
    exit 1
  fi
  log_ok "Port ${HYSTERIA_PORT} is free"
}

check_root() {
  local uid
  uid=$(ssh_exec "id -u")
  if [[ "$uid" != "0" ]]; then
    log_error "Must be root on remote server. Current UID: $uid"
    exit 1
  fi
}

# ─── Hysteria2 installation ──────────────────────────────────────────────────
detect_arch() {
  local arch
  arch=$(ssh_exec "uname -m")
  case "$arch" in
    x86_64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    *)
      log_error "Unsupported architecture: $arch"
      exit 1
      ;;
  esac
}

get_latest_hysteria_version() {
  # Tag format: app/v2.x.y — must return the FULL tag for download URL
  # [^"]* stops at the closing quote; trailing .* consumes the comma and rest of line
  curl -s https://api.github.com/repos/${HYSTERIA_REPO}/releases/latest \
    | grep '"tag_name"' | sed 's/.*"tag_name": "\([^"]*\)".*/\1/'
}

install_hysteria_binary() {
  local arch tag url status
  arch=$(detect_arch)
  tag=$(get_latest_hysteria_version)

  # Tag format is: app/v2.x.y — use full tag in download URL
  url="https://github.com/${HYSTERIA_REPO}/releases/download/${tag}/hysteria-linux-${arch}"

  log_info "Installing Hysteria2 ${tag} (${arch})..."
  ssh_exec "mkdir -p ${HYSTERIA_DIR}"

  # Verify URL is reachable before downloading (-L follows GitHub's 302 redirect to CDN)
  status=$(ssh_exec "curl -o /dev/null -sLw '%{http_code}' '${url}'")
  if [[ "$status" != "200" ]]; then
    log_error "Failed to download Hysteria2: HTTP ${status}"
    log_error "URL: ${url}"
    exit 1
  fi

  ssh_exec "curl -fSL '${url}' -o ${HYSTERIA_DIR}/hysteria && chmod +x ${HYSTERIA_DIR}/hysteria"

  # Verify binary works
  ssh_exec "${HYSTERIA_DIR}/hysteria version"
  log_ok "Hysteria2 binary installed"
}

# ─── Server configuration ────────────────────────────────────────────────────
create_server_config() {
  local domain yaml_password
  domain="${SERVER_IP}.nip.io"
  # Escape double quotes for YAML string value: " → \"
  yaml_password="${AUTH_PASSWORD//\"/\\\"}"

  log_info "Creating Hysteria2 config..."
  # NOTE: Hysteria2 v2 YAML — 'listen' is at ROOT level (NOT under 'server:')
  ssh_exec "cat > ${HYSTERIA_DIR}/config.yaml << EOF
listen: :${HYSTERIA_PORT}

tls:
  cert: ${CERT_DIR}/${domain}_ecc/fullchain.cer
  key: ${CERT_DIR}/${domain}_ecc/${domain}.key

auth:
  type: password
  password: \"${yaml_password}\"

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF"
  log_ok "Config written to ${HYSTERIA_DIR}/config.yaml"
}

# ─── Systemd service ─────────────────────────────────────────────────────────
setup_systemd() {
  local svc="/etc/systemd/system/hysteria2.service"
  log_info "Setting up systemd service..."
  # NOTE: heredoc is unquoted so ${HYSTERIA_DIR} and ${HYSTERIA_PORT} expand on the remote
  ssh_exec "cat > ${svc} << EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=${HYSTERIA_DIR}/hysteria server -c ${HYSTERIA_DIR}/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF"
  ssh_exec "systemctl daemon-reload"
  ssh_exec "systemctl enable hysteria2"
  log_ok "Systemd service enabled"
}

# ─── ACME / TLS certificates ────────────────────────────────────────────────
install_acme_sh() {
  log_info "Installing acme.sh..."
  # Download first, then run — avoids < /dev/null killing the pipe
  ssh_exec "curl -fsSL https://get.acme.sh -o /tmp/install-acme.sh"
  ssh_exec "sh /tmp/install-acme.sh email=admin@${SERVER_IP}.nip.io < /dev/null"
  # Verify installation
  ssh_exec "test -f ~/.acme.sh/acme.sh" || {
    log_error "acme.sh installation failed — ~/.acme.sh/acme.sh not found"
    exit 1
  }
  log_ok "acme.sh installed"
}

issue_certificate() {
  local domain="${SERVER_IP}.nip.io"
  log_info "Issuing certificate for ${domain}..."

  # Free port 80 for acme.sh standalone HTTP-01 challenge
  ssh_exec "fuser -k 80/tcp 2>/dev/null || true"
  sleep 1

  # Use Let's Encrypt (ZeroSSL default requires EAB registration which often fails)
  ssh_exec "~/.acme.sh/acme.sh --set-default-ca --server letsencrypt"

  # HTTP-01 standalone challenge — acme.sh starts its own server on port 80
  ssh_exec "~/.acme.sh/acme.sh --issue -d ${domain} --standalone --httpport 80 --force"

  # Install cert to Hysteria2 paths
  # reloadcmd uses "|| true" because hysteria2 service may not exist yet during first setup;
  # the reloadcmd matters for future automatic renewals
  ssh_exec "~/.acme.sh/acme.sh --install-cert -d ${domain} \
    --key-file '${CERT_DIR}/${domain}_ecc/${domain}.key' \
    --fullchain-file '${CERT_DIR}/${domain}_ecc/fullchain.cer' \
    --reloadcmd 'systemctl restart hysteria2 || true'"

  # Verify cert was created
  local cert_path="${CERT_DIR}/${domain}_ecc/fullchain.cer"
  ssh_exec "[[ -f ${cert_path} ]]" || {
    log_error "Certificate not found: ${cert_path}"
    exit 1
  }
  log_ok "Certificate issued for ${domain}"
}

get_cert_fingerprint() {
  local domain="${SERVER_IP}.nip.io"
  local cert="${CERT_DIR}/${domain}_ecc/fullchain.cer"
  # OpenSSL output: "sha256 Fingerprint=BA:A2:..." (note the SPACE, not "sha256Fingerprint=")
  # Extract the hex value after '=' and strip colons
  ssh_exec "openssl x509 -in ${cert} -noout -fingerprint -sha256 | \
    sed 's/.*sha256 Fingerprint=//' | tr -d ':'"
}

# ─── URI generation ──────────────────────────────────────────────────────────
generate_uri() {
  local fp domain uri encoded_pass
  domain="${SERVER_IP}.nip.io"
  fp=$(get_cert_fingerprint)
  # URL-encode only chars that break URI parsing: @ : # ? %
  encoded_pass=$(printf '%s' "$AUTH_PASSWORD" | sed 's/%/%25/g; s/@/%40/g; s/:/%3A/g; s/#/%23/g; s/?/%3F/g')
  # hysteria2:// URI format (note: /? not just ?)
  uri="hysteria2://${encoded_pass}@${SERVER_IP}:${HYSTERIA_PORT}/?sni=${domain}&insecure=1&pinSHA256=${fp}#${REMARK}"
  echo "$uri"
}

# ─── Output ───────────────────────────────────────────────────────────────────
show_qr() {
  local uri="$1"
  if command -v qrencode &>/dev/null; then
    echo -e "\n${BOLD}QR Code — scan with Nekobox / v2rayN:${NC}"
    qrencode -t ANSIUTF8 "$uri"
  else
    log_warn "qrencode not found. Install: sudo apt install qrencode"
  fi
}

show_summary() {
  local uri="$1"
  local domain="${SERVER_IP}.nip.io"
  cat <<EOF

═════════════════════════════════════════════════════
   Hysteria2 Server Setup Complete!
═════════════════════════════════════════════════════
  Server IP:    ${SERVER_IP}
  Domain:       ${domain}
  Port:         ${HYSTERIA_PORT}
  Auth:         [hidden]

  hysteria2:// URI:
  ${uri}

  ─── Server Commands ───────────────────────────────
  Status:       systemctl status hysteria2
  Logs:         journalctl -u hysteria2 -f --no-pager
  Config:       ${HYSTERIA_DIR}/config.yaml
  Cert:         ${CERT_DIR}/${domain}_ecc/
═════════════════════════════════════════════════════

EOF
}

start_hysteria() {
  log_info "Starting Hysteria2..."
  ssh_exec "systemctl restart hysteria2"
  sleep 3

  local status
  status=$(ssh_exec "systemctl is-active hysteria2")
  if [[ "$status" != "active" ]]; then
    log_error "Hysteria2 failed to start."
    log_info "Server logs:"
    ssh_exec "journalctl -u hysteria2 -n 20 --no-pager"
    exit 1
  fi
  log_ok "Hysteria2 is running"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  show_banner
  parse_args "$@"
  check_local_deps

  prompt_ssh_config
  ssh_test
  check_remote_deps
  check_root
  prompt_server_config
  check_ports

  log_info "Server IP: ${SERVER_IP}"

  install_hysteria_binary
  install_acme_sh
  issue_certificate
  create_server_config
  setup_systemd
  start_hysteria

  local uri
  uri=$(generate_uri)
  show_summary "$uri"
  show_qr "$uri"
}

main "$@"
