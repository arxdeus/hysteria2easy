#!/bin/bash
# hysteria2easy.sh — One-command Hysteria2 server setup with TLS + QR
# Copyright (c) 2026 Artemis Kushner
# https://github.com/arxdeus/hysteria2easy
# Licensed under MIT

VERSION="1.0.0"
HYSTERIA_REPO="apernet/hysteria"
# Used only if GitHub cannot be queried for the latest release tag
HYSTERIA_FALLBACK_TAG="app/v2.12.3"
HYSTERIA_DIR="/etc/hysteria2"
CERT_DIR="/root/.acme.sh"

# Default values (overridden by CLI args or prompts)
SSH_HOST="" SSH_PORT="22" SSH_USER="root" SSH_PASSWORD=""
SERVER_IP="" HYSTERIA_PORT="443" AUTH_PASSWORD="" REMARK="Hysteria2"
SNI="web.max.ru"
# Salamander obfuscation: wraps QUIC so the handshake is not recognizable as
# QUIC/TLS by DPI. Empty = disabled. Auto-generated when --obfs auto.
OBFS_PASSWORD=""
# UDP port range for port hopping, e.g. "20000-50000". Empty = disabled.
PORT_HOPPING=""

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
  ssh_exec "apt-get update && apt-get install -y curl openssl socat net-tools psmisc netcat-openbsd tcpdump" || {
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
  cat <<'WARNEOF'
  NOTE: Hysteria2 is UDP-only (QUIC). Under Russian TSPU whitelist filtering
  ("белые списки") nearly all UDP is dropped — only TCP 80/443/22 pass — so
  Hysteria2 CANNOT work there, no matter how it is configured. Neither obfs
  nor port hopping helps: the drop happens at L3/port level, before DPI.

  If your clients are behind whitelist filtering, use VLESS + Reality on a
  whitelisted Russian IP instead:   bash vlessreality.sh --help

WARNEOF
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
      --sni)
        SNI="$2"
        shift 2
        ;;
      --obfs)
        OBFS_PASSWORD="$2"
        shift 2
        ;;
      --port-hopping)
        PORT_HOPPING="$2"
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
  --sni SNI            SNI/hostname to masquerade as [web.max.ru]
  --obfs PASS          Salamander obfuscation password ('auto' = random).
                       Hides the QUIC handshake from DPI. Must match on client.
  --port-hopping RANGE UDP port range, e.g. 20000-50000. Traffic rotates across
                       ports to survive per-port throttling/blocking.
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

  # Never touch the SSH port — fuser -k on it would kill sshd and lock us out
  if [[ "$HYSTERIA_PORT" == "$SSH_PORT" ]]; then
    log_error "Hysteria2 port (${HYSTERIA_PORT}) must differ from the SSH port (${SSH_PORT})."
    exit 1
  fi

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

# ─── Firewall ─────────────────────────────────────────────────────────────────
# Hysteria2 speaks QUIC over UDP. When the server runs a default-deny
# (whitelist) firewall, only SSH/TCP is usually allowed, so the client
# silently fails to connect even though the service is "active".
open_firewall() {
  log_info "Opening firewall for UDP/${HYSTERIA_PORT} and TCP/80..."

  # ufw (Ubuntu/Debian default)
  if ssh_exec "command -v ufw >/dev/null && ufw status | grep -q '^Status: active'" &>/dev/null; then
    ssh_exec "ufw allow ${HYSTERIA_PORT}/udp >/dev/null && ufw allow 80/tcp >/dev/null && ufw reload >/dev/null || true"
    log_ok "ufw rules added (${HYSTERIA_PORT}/udp, 80/tcp)"
  fi

  # firewalld (RHEL family)
  if ssh_exec "command -v firewall-cmd >/dev/null && firewall-cmd --state" &>/dev/null; then
    ssh_exec "firewall-cmd --permanent --add-port=${HYSTERIA_PORT}/udp >/dev/null; firewall-cmd --permanent --add-port=80/tcp >/dev/null; firewall-cmd --reload >/dev/null || true"
    log_ok "firewalld rules added (${HYSTERIA_PORT}/udp, 80/tcp)"
  fi

  # Raw iptables whitelist: default-deny policy OR a trailing "reject everything
  # else" rule (-A INPUT -j DROP/REJECT), which is the common allowlist pattern
  if ssh_exec "iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)|^-A INPUT (-j|.* -j) (DROP|REJECT)'" &>/dev/null; then
    ssh_exec "iptables -C INPUT -p udp --dport ${HYSTERIA_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${HYSTERIA_PORT} -j ACCEPT"
    ssh_exec "iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT"
    # Persist across reboots when the tooling is available
    ssh_exec "command -v netfilter-persistent >/dev/null && netfilter-persistent save 2>/dev/null || command -v iptables-save >/dev/null && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true"
    log_ok "iptables ACCEPT rules inserted (whitelist INPUT chain detected)"
  fi

  # Show what is actually filtering, for diagnosis
  ssh_exec "iptables -S INPUT 2>/dev/null | head -20 || true"
}

# End-to-end UDP reachability check: capture on the server with tcpdump while
# sending probes from this machine. This catches provider/cloud whitelist
# firewalls that local rules cannot open.
verify_udp_reachable() {
  log_info "Verifying UDP/${HYSTERIA_PORT} reachability from this machine..."
  if ssh_exec "ss -lnup | grep -q ':${HYSTERIA_PORT} '" &>/dev/null; then
    log_ok "Server is listening on UDP/${HYSTERIA_PORT}"
  else
    log_error "Server is NOT listening on UDP/${HYSTERIA_PORT} — check: journalctl -u hysteria2 -n 50"
    return
  fi

  if ! ssh_exec "command -v tcpdump >/dev/null" &>/dev/null; then
    log_warn "tcpdump not available on server — skipping end-to-end UDP check"
    return
  fi

  local cap
  cap=$(mktemp)
  ssh_exec "timeout 8 tcpdump -c 1 -n -l udp dst port ${HYSTERIA_PORT} 2>/dev/null" > "$cap" &
  local cap_pid=$!
  sleep 2
  # Send a few probes (nc if present, else bash /dev/udp)
  local i
  for i in 1 2 3; do
    if command -v nc &>/dev/null; then
      printf 'probe' | nc -u -w 1 "${SERVER_IP}" "${HYSTERIA_PORT}" &>/dev/null || true
    else
      (echo probe > "/dev/udp/${SERVER_IP}/${HYSTERIA_PORT}") 2>/dev/null || true
    fi
    sleep 1
  done
  wait "$cap_pid" 2>/dev/null || true

  if grep -q "\.${HYSTERIA_PORT}" "$cap"; then
    log_ok "UDP/${HYSTERIA_PORT} is reachable end-to-end — probe packet arrived at the server"
  else
    log_warn "UDP probe did NOT reach the server. A provider/cloud firewall whitelist is blocking it."
    log_warn "Add an inbound rule for UDP ${HYSTERIA_PORT} in the provider panel (Security Group / Cloud Firewall)."
  fi
  rm -f "$cap"
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
  local tag
  # 1) GitHub API (rate-limited to 60/hour per IP). Tolerate any spacing in JSON.
  tag=$(curl -fsSL --max-time 15 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${HYSTERIA_REPO}/releases/latest" 2>/dev/null \
    | tr ',' '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  tag=$(printf '%s' "$tag" | tr -d '[:space:]')

  # 2) Fall back to the redirect of /releases/latest (not rate-limited).
  if [[ -z "$tag" ]]; then
    tag=$(curl -sIL --max-time 15 "https://github.com/${HYSTERIA_REPO}/releases/latest" \
      | tr -d '\r' | sed -n 's|.*/releases/tag/||p' | head -n1 | sed 's|%2F|/|g')
    tag=$(printf '%s' "$tag" | tr -d '[:space:]')
  fi

  # 3) Fall back to the tag list on the releases atom feed.
  if [[ -z "$tag" ]]; then
    tag=$(curl -fsSL --max-time 15 "https://github.com/${HYSTERIA_REPO}/releases.atom" 2>/dev/null \
      | sed -n 's|.*/releases/tag/\([^"<]*\).*|\1|p' | head -n1 | sed 's|%2F|/|g')
    tag=$(printf '%s' "$tag" | tr -d '[:space:]')
  fi

  # Only accept a plausible app/vX.Y.Z (or vX.Y.Z) tag
  if [[ ! "$tag" =~ ^(app/)?v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    return 1
  fi
  printf '%s' "$tag"
}

# Same lookup, but executed on the remote server (useful when the local machine
# has no GitHub access or is API rate-limited)
get_latest_hysteria_version_remote() {
  local tag
  tag=$(ssh_exec "curl -sIL --max-time 15 'https://github.com/${HYSTERIA_REPO}/releases/latest' | tr -d '\r' | sed -n 's|.*/releases/tag/||p' | head -n1" 2>/dev/null || true)
  tag=$(printf '%s' "$tag" | tr -d '[:space:]' | sed 's|%2F|/|g')
  [[ "$tag" =~ ^(app/)?v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
  printf '%s' "$tag"
}

install_hysteria_binary() {
  local arch tag url status
  arch=$(detect_arch)
  tag=$(get_latest_hysteria_version || true)
  if [[ -z "$tag" ]]; then
    tag=$(get_latest_hysteria_version_remote || true)
  fi
  if [[ -z "$tag" ]]; then
    log_warn "Could not determine the latest Hysteria2 version (GitHub unreachable or rate-limited)."
    tag="$HYSTERIA_FALLBACK_TAG"
    log_warn "Falling back to pinned version ${tag}"
  fi

  # Tag format is: app/v2.x.y — use full tag in download URL
  url="https://github.com/${HYSTERIA_REPO}/releases/download/${tag}/hysteria-linux-${arch}"

  log_info "Installing Hysteria2 ${tag} (${arch})..."
  ssh_exec "mkdir -p ${HYSTERIA_DIR}"

  # Verify URL is reachable before downloading (-L follows GitHub's 302 redirect to CDN)
  status=$(ssh_exec "curl -o /dev/null -sLw '%{http_code}' '${url}'")
  # Some tags are published without the app/ prefix — retry the other form
  if [[ "$status" != "200" ]]; then
    local alt_tag alt_url
    if [[ "$tag" == app/* ]]; then alt_tag="${tag#app/}"; else alt_tag="app/${tag}"; fi
    alt_url="https://github.com/${HYSTERIA_REPO}/releases/download/${alt_tag}/hysteria-linux-${arch}"
    if [[ "$(ssh_exec "curl -o /dev/null -sLw '%{http_code}' '${alt_url}'")" == "200" ]]; then
      tag="$alt_tag"; url="$alt_url"; status="200"
    fi
  fi
  # Last resort: the pinned known-good release
  if [[ "$status" != "200" && "$tag" != "$HYSTERIA_FALLBACK_TAG" ]]; then
    log_warn "Release ${tag} not downloadable (HTTP ${status}); trying pinned ${HYSTERIA_FALLBACK_TAG}"
    tag="$HYSTERIA_FALLBACK_TAG"
    url="https://github.com/${HYSTERIA_REPO}/releases/download/${tag}/hysteria-linux-${arch}"
    status=$(ssh_exec "curl -o /dev/null -sLw '%{http_code}' '${url}'")
  fi
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
  local domain yaml_password obfs_block=""
  domain="${SERVER_IP}.nip.io"
  # Escape for a YAML double-quoted scalar: \ → \\ first, then " → \"
  yaml_password="${AUTH_PASSWORD//\\/\\\\}"
  yaml_password="${yaml_password//\"/\\\"}"

  # Salamander obfuscation makes the QUIC handshake unrecognizable to DPI.
  # Without it, a censor can fingerprint the QUIC Initial packet and drop it
  # even when the port is reachable.
  if [[ -n "$OBFS_PASSWORD" ]]; then
    local yaml_obfs="${OBFS_PASSWORD//\\/\\\\}"
    yaml_obfs="${yaml_obfs//\"/\\\"}"
    obfs_block="
obfs:
  type: salamander
  salamander:
    password: \"${yaml_obfs}\"
"
  fi

  log_info "Creating Hysteria2 config..."
  # NOTE: Hysteria2 v2 YAML — 'listen' is at ROOT level (NOT under 'server:')
  # Content is piped via stdin with a QUOTED local heredoc, so the remote shell
  # never re-parses it: $, backticks etc. in the password cannot be injected.
  ssh_exec "cat > ${HYSTERIA_DIR}/config.yaml" <<REMOTEEOF || { log_error "Failed to write config.yaml"; exit 1; }
listen: :${HYSTERIA_PORT}
${obfs_block}
tls:
  cert: ${CERT_DIR}/${domain}_ecc/fullchain.cer
  key: ${CERT_DIR}/${domain}_ecc/${domain}.key

auth:
  type: password
  password: "${yaml_password}"

masquerade:
  type: proxy
  proxy:
    url: https://${SNI}
    rewriteHost: true
REMOTEEOF
  log_ok "Config written to ${HYSTERIA_DIR}/config.yaml"
  [[ -n "$OBFS_PASSWORD" ]] && log_ok "Salamander obfuscation enabled"
}

# ─── Port hopping ────────────────────────────────────────────────────────────
# Redirects a whole UDP port range to the listening port. The client rotates
# source/destination ports, which defeats per-port blocking and QoS throttling
# that targets a single well-known port.
setup_port_hopping() {
  [[ -z "$PORT_HOPPING" ]] && return 0

  if [[ ! "$PORT_HOPPING" =~ ^[0-9]+-[0-9]+$ ]]; then
    log_error "Invalid --port-hopping range: '${PORT_HOPPING}' (expected e.g. 20000-50000)"
    exit 1
  fi
  local lo="${PORT_HOPPING%-*}" hi="${PORT_HOPPING#*-}"
  if ((lo >= hi)) || ((hi > 65535)) || ((lo < 1024)); then
    log_error "Invalid range ${PORT_HOPPING}: need 1024 <= low < high <= 65535"
    exit 1
  fi
  # Guard: an SSH port inside the redirected range would break remote access
  if ((SSH_PORT >= lo && SSH_PORT <= hi)); then
    log_error "SSH port ${SSH_PORT} falls inside the hopping range ${PORT_HOPPING}. Choose a different range."
    exit 1
  fi

  log_info "Setting up UDP port hopping ${lo}-${hi} → ${HYSTERIA_PORT}..."
  ssh_exec "iptables -t nat -C PREROUTING -p udp --dport ${lo}:${hi} -j DNAT --to-destination :${HYSTERIA_PORT} 2>/dev/null || \
    iptables -t nat -A PREROUTING -p udp --dport ${lo}:${hi} -j DNAT --to-destination :${HYSTERIA_PORT}" || {
    log_warn "Failed to add DNAT rule — port hopping disabled"
    PORT_HOPPING=""
    return 0
  }
  # Allow the range through a whitelist firewall as well
  ssh_exec "command -v ufw >/dev/null && ufw status | grep -q '^Status: active' && ufw allow ${lo}:${hi}/udp >/dev/null 2>&1 || true"
  ssh_exec "command -v netfilter-persistent >/dev/null && netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true"
  log_ok "Port hopping active: UDP ${lo}-${hi} → ${HYSTERIA_PORT}"
}

# ─── Censorship diagnostics ──────────────────────────────────────────────────
# Distinguishes the failure modes people hit under IP-whitelist regimes, where
# only approved destinations are reachable and everything else is dropped.
diagnose_censorship() {
  echo -e "\n${BOLD}═══ Reachability diagnosis (client → server) ═══${NC}"

  # 1. TCP to the SSH port works by definition (we are connected), so the IP
  #    itself is routable. If UDP fails while TCP works, UDP/QUIC is filtered.
  log_ok "TCP to ${SERVER_IP}:${SSH_PORT} works (SSH is connected) — the IP is routable"

  # 2. Is TCP/443 to the server reachable? Tells us whether TCP-based
  #    fallbacks (VLESS/Reality, WireGuard-over-TCP, shadowsocks) are viable.
  if command -v nc &>/dev/null; then
    if nc -z -w 5 "${SERVER_IP}" 443 &>/dev/null; then
      log_ok "TCP/443 to the server is reachable"
    else
      log_warn "TCP/443 is not reachable (nothing listens there yet, or it is filtered)"
    fi
  fi

  # 3. Can we reach ANY external QUIC service? If public QUIC is dead too, the
  #    network blocks UDP/443 wholesale rather than targeting this server.
  if command -v curl &>/dev/null; then
    if curl --http3-only -s -o /dev/null --max-time 8 https://www.google.com 2>/dev/null; then
      log_ok "Outbound QUIC/HTTP3 works on this network"
    else
      log_warn "Outbound QUIC/HTTP3 to public sites fails → this network blocks or throttles UDP/443 generally."
      log_warn "Hysteria2 is UDP-only, so it cannot work here. Use a TCP-based protocol (VLESS+Reality, Shadowsocks, WireGuard-over-TCP)."
    fi
  fi
}

# ─── Systemd service ─────────────────────────────────────────────────────────
setup_systemd() {
  local svc="/etc/systemd/system/hysteria2.service"
  log_info "Setting up systemd service..."
  # Variables expand locally; content is piped via stdin so the remote shell
  # does not re-parse it
  ssh_exec "cat > ${svc}" <<REMOTEEOF || { log_error "Failed to write systemd unit"; exit 1; }
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
REMOTEEOF
  ssh_exec "systemctl daemon-reload"
  ssh_exec "systemctl enable hysteria2"
  log_ok "Systemd service enabled"
}

# ─── ACME / TLS certificates ────────────────────────────────────────────────
install_acme_sh() {
  log_info "Installing acme.sh..."
  # Download first, then run — avoids < /dev/null killing the pipe
  ssh_exec "curl -fsSL https://get.acme.sh -o /tmp/install-acme.sh" || return 1
  ssh_exec "sh /tmp/install-acme.sh email=admin@${SERVER_IP}.nip.io < /dev/null" || return 1
  # Verify installation
  ssh_exec "test -f ~/.acme.sh/acme.sh" || {
    log_warn "acme.sh installation failed — ~/.acme.sh/acme.sh not found"
    return 1
  }
  log_ok "acme.sh installed"
}

# Self-signed fallback. The client URI already uses insecure=1 + pinSHA256, so
# a self-signed certificate is functionally identical to a Let's Encrypt one.
# This is essential for whitelist firewalls where inbound TCP/80 is blocked
# and HTTP-01 validation can never succeed.
generate_self_signed_cert() {
  local domain="${SERVER_IP}.nip.io"
  local dir="${CERT_DIR}/${domain}_ecc"
  log_warn "Using a self-signed certificate (works identically: client pins the cert by SHA256)"
  ssh_exec "mkdir -p '${dir}' && openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout '${dir}/${domain}.key' -out '${dir}/fullchain.cer' \
    -subj '/CN=${domain}' -days 3650" || {
    log_error "Failed to generate self-signed certificate"
    exit 1
  }
  log_ok "Self-signed certificate generated for ${domain}"
}

issue_certificate() {
  local domain="${SERVER_IP}.nip.io"
  log_info "Issuing certificate for ${domain}..."

  # Free port 80 for acme.sh standalone HTTP-01 challenge
  ssh_exec "fuser -k 80/tcp 2>/dev/null || true"
  sleep 1

  # Use Let's Encrypt (ZeroSSL default requires EAB registration which often fails)
  ssh_exec "~/.acme.sh/acme.sh --set-default-ca --server letsencrypt"

  # HTTP-01 standalone challenge — acme.sh starts its own server on port 80.
  # This REQUIRES inbound TCP/80 from the internet; under a provider whitelist
  # firewall it will fail, so fall back to a self-signed cert.
  if ! ssh_exec "~/.acme.sh/acme.sh --issue -d ${domain} --standalone --httpport 80 --force"; then
    log_warn "ACME HTTP-01 failed. Inbound TCP/80 is likely blocked (whitelist firewall) or the nip.io Let's Encrypt rate limit was hit."
    generate_self_signed_cert
    return 0
  fi

  # Install cert to Hysteria2 paths
  # reloadcmd uses "|| true" because hysteria2 service may not exist yet during first setup;
  # the reloadcmd matters for future automatic renewals
  ssh_exec "~/.acme.sh/acme.sh --install-cert -d ${domain} \
    --key-file '${CERT_DIR}/${domain}_ecc/${domain}.key' \
    --fullchain-file '${CERT_DIR}/${domain}_ecc/fullchain.cer' \
    --reloadcmd 'systemctl restart hysteria2 || true'"
  log_ok "Certificate issued for ${domain}"
}

verify_certificate() {
  local domain="${SERVER_IP}.nip.io"
  local cert_path="${CERT_DIR}/${domain}_ecc/fullchain.cer"
  ssh_exec "[[ -f ${cert_path} ]]" || {
    log_error "Certificate not found: ${cert_path}"
    exit 1
  }
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
  local fp domain uri encoded_pass encoded_remark hostport obfs_params=""
  domain="${SERVER_IP}.nip.io"
  fp=$(get_cert_fingerprint)
  # URL-encode only chars that break URI parsing: @ : # ? %
  encoded_pass=$(printf '%s' "$AUTH_PASSWORD" | sed 's/%/%25/g; s/@/%40/g; s/:/%3A/g; s/#/%23/g; s/?/%3F/g')
  # Fragment: encode %, # and spaces so remarks like "My Server #1" stay valid
  encoded_remark=$(printf '%s' "$REMARK" | sed 's/%/%25/g; s/#/%23/g; s/ /%20/g')

  # With port hopping the client must be told the range: host:port,range
  if [[ -n "$PORT_HOPPING" ]]; then
    hostport="${SERVER_IP}:${HYSTERIA_PORT},${PORT_HOPPING}"
  else
    hostport="${SERVER_IP}:${HYSTERIA_PORT}"
  fi

  # obfs must match the server or the client cannot complete a handshake
  if [[ -n "$OBFS_PASSWORD" ]]; then
    local encoded_obfs
    encoded_obfs=$(printf '%s' "$OBFS_PASSWORD" | sed 's/%/%25/g; s/&/%26/g; s/#/%23/g; s/?/%3F/g; s/ /%20/g')
    obfs_params="&obfs=salamander&obfs-password=${encoded_obfs}"
  fi

  # hysteria2:// URI format (note: /? not just ?)
  uri="hysteria2://${encoded_pass}@${hostport}/?sni=${domain}&insecure=1&pinSHA256=${fp}${obfs_params}#${encoded_remark}"
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
  Port hopping: ${PORT_HOPPING:-disabled}
  Obfuscation:  $([[ -n "$OBFS_PASSWORD" ]] && echo "salamander (enabled)" || echo "disabled")
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

  # 'auto' generates a random obfs password
  if [[ "$OBFS_PASSWORD" == "auto" ]]; then
    OBFS_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
    log_info "Generated random obfs password"
  fi

  check_ports
  open_firewall

  log_info "Server IP: ${SERVER_IP}"

  install_hysteria_binary
  if install_acme_sh; then
    issue_certificate
  else
    log_warn "Skipping ACME (installation failed) — outbound access may be restricted too."
    generate_self_signed_cert
  fi
  verify_certificate
  create_server_config
  setup_systemd
  setup_port_hopping
  start_hysteria
  verify_udp_reachable
  diagnose_censorship

  local uri
  uri=$(generate_uri)
  show_summary "$uri"
  show_qr "$uri"
}

main "$@"
