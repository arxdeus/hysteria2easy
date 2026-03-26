#!/bin/bash
# hysteria2-easy.sh — One-command Hysteria2 server setup with TLS + QR
set -euo pipefail

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
  ssh_exec "apt-get update && apt-get install -y curl openssl socat net-tools psmisc netcat-openbsd"
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
Usage: hysteria2-easy.sh [OPTIONS]

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

  # Auto-detect public IP from multiple sources
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null) \
      || SERVER_IP=$(curl -s --max-time 5 ipinfo.io/ip 2>/dev/null) \
      || SERVER_IP=""
  fi
  if [[ -z "$SERVER_IP" ]]; then
    read -p "Server public IP: " SERVER_IP
  else
    read -p "Server IP [${SERVER_IP}]: " tmp_ip
    SERVER_IP="${tmp_ip:-$SERVER_IP}"
  fi
  [[ -z "$SERVER_IP" ]] && {
    log_error "Server IP is required"
    exit 1
  }

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
  # netcat-openbsd uses separate flags -z -v -w3 (not -zvw3)
  if ! ssh_exec "nc -zv -w3 localhost 80" &>/dev/null; then
    log_error "Port 80 is not accessible on the server."
    log_error "HTTP-01 ACME challenge requires port 80 to be open."
    log_error "Fix: ufw allow 80 / iptables -A INPUT -p tcp --dport 80 -j ACCEPT"
    exit 1
  fi
  log_ok "Port 80 is accessible"

  if ssh_exec "nc -zv -w3 localhost ${HYSTERIA_PORT}" &>/dev/null; then
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
  curl -s https://api.github.com/repos/${HYSTERIA_REPO}/releases/latest \
    | grep '"tag_name"' | sed 's/.*"tag_name": "\(.*\)"/\1/'
}

install_hysteria_binary() {
  local arch tag url status
  arch=$(detect_arch)
  tag=$(get_latest_hysteria_version)

  # Tag format is: app/v2.x.y — use full tag in download URL
  url="https://github.com/${HYSTERIA_REPO}/releases/download/${tag}/hysteria-linux-${arch}"

  log_info "Installing Hysteria2 ${tag} (${arch})..."
  ssh_exec "mkdir -p ${HYSTERIA_DIR}"

  # Verify URL is reachable before downloading
  status=$(ssh_exec "curl -o /dev/null -sw '%{http_code}' '${url}'")
  if [[ "$status" != "200" ]]; then
    log_error "Failed to download Hysteria2: HTTP ${status}"
    log_error "URL: ${url}"
    exit 1
  fi

  ssh_exec "curl -fSL '${url}' -o ${HYSTERIA_DIR}/hysteria && chmod +x ${HYSTERIA_DIR}/hysteria"

  # Verify binary works
  ssh_exec "${HYSTERIA_DIR}/hysteria --version"
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
  # < /dev/null prevents acme.sh's interactive prompts
  ssh_exec "curl https://get.acme.sh | sh -s email=admin@\${SERVER_IP}.nip.io < /dev/null"
  log_ok "acme.sh installed"
}

issue_certificate() {
  local domain="${SERVER_IP}.nip.io"
  log_info "Issuing certificate for ${domain}..."

  # Free port 80 for acme.sh standalone HTTP-01 challenge
  ssh_exec "fuser -k 80/tcp 2>/dev/null || true"
  sleep 1

  # HTTP-01 standalone challenge — acme.sh starts its own server on port 80
  ssh_exec "~/.acme.sh/acme.sh --issue -d ${domain} --standalone --httpport 80 --force"

  # Install cert to Hysteria2 paths, with auto-reload on renewal
  ssh_exec "~/.acme.sh/acme.sh --install-cert -d ${domain} \
    --key-file '${CERT_DIR}/${domain}_ecc/${domain}.key' \
    --fullchain-file '${CERT_DIR}/${domain}_ecc/fullchain.cer' \
    --reloadcmd 'systemctl restart hysteria2'"

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
