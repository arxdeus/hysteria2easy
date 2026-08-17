#!/bin/bash
# vlessreality.sh — One-command VLESS + Reality server setup with QR
# Copyright (c) 2026 Artemis Kushner
# https://github.com/arxdeus/hysteria2easy
# Licensed under MIT
#
# Why Reality instead of Hysteria2 under IP-whitelist / DPI filtering:
#   * Runs over TCP/443, not UDP — UDP/QUIC is the first thing to be dropped.
#   * The TLS handshake is forwarded to a real, allowed website, so the
#     certificate a censor sees is genuinely that site's certificate.
#   * No own domain and no ACME needed: nothing to fingerprint or expire.

VERSION="1.0.0"
XRAY_REPO="XTLS/Xray-core"
XRAY_DIR="/usr/local/xray"

# Default values (overridden by CLI args or prompts)
SSH_HOST="" SSH_PORT="22" SSH_USER="root" SSH_PASSWORD=""
SERVER_IP="" VLESS_PORT="443" REMARK="VLESS-Reality"
# The site whose TLS handshake we borrow. MUST support TLSv1.3 + HTTP/2 and
# should be a host that is not blocked in the client's network.
#
# There is no universally good default: the strongest dest is one hosted NEAR
# your server (same datacenter/subnet), so that the SNI matches the IP's owner.
# Use --scan-dest to discover those. This default is only a reasonable
# starting point: a CDN-hosted software endpoint, which is rarely blocked and
# plausibly contacted by any machine (OS/software updates).
DEST="cdn.jsdelivr.net"
UUID="" PRIVATE_KEY="" PUBLIC_KEY="" SHORT_ID=""
SCAN_DEST=0

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

# ─── Banner ───────────────────────────────────────────────────────────────────
show_banner() {
  cat <<EOF

╔════════════════════════════════════════════════════╗
║      VLESS + Reality Easy Setup  v${VERSION}           ║
║      TCP/443 · borrowed TLS · no domain needed      ║
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
        VLESS_PORT="$2"
        shift 2
        ;;
      --dest)
        DEST="$2"
        shift 2
        ;;
      --scan-dest)
        SCAN_DEST=1
        shift
        ;;
      --uuid)
        UUID="$2"
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
Usage: vlessreality.sh [OPTIONS]

  --ssh-host HOST       Server IP [required or prompted]
  --ssh-port PORT       SSH port [22]
  --ssh-user USER       SSH user [root]
  --ssh-password PASS   SSH password [prompted]
  --port PORT           VLESS listening port [443]
  --dest HOST           Site to borrow the TLS handshake from
                        [cdn.jsdelivr.net]. Must support TLSv1.3 + HTTP/2
                        and must NOT be blocked in your network.
  --scan-dest           Scan the server's own /24 for TLSv1.3 hosts and print
                        candidates, then exit. A dest in your server's subnet
                        makes the SNI/IP pairing look natural to passive DPI.
  --uuid UUID           Client UUID [auto-generated]
  --remark REMARK       Connection remark [VLESS-Reality]
  --ip IP               Server public IP [defaults to --ssh-host]
  --help, -h            Show this help

Choosing --dest, in order of strength:
  1. BEST: a real site hosted in your server's own subnet (use --scan-dest).
     The SNI then matches the network that owns your IP.
  2. GOOD: a site hosted in the same COUNTRY as your server.
  3. OK:   a widely-contacted CDN/software endpoint that is never blocked,
           e.g. cdn.jsdelivr.net, swcdn.apple.com, dl.google.com
  4. AVOID: the most-copied tutorial dests (www.microsoft.com, www.icloud.com)
     and any site blocked in the CLIENT's network.
Requirements: TLSv1.3, HTTP/2, X25519, no redirect away, low RTT from server.
HELPEOF
        exit 0
        ;;
      *) shift ;;
    esac
  done
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
  # unzip: Xray releases ship as .zip
  # psmisc: fuser (frees busy ports)
  ssh_exec "apt-get update && apt-get install -y curl unzip openssl psmisc ca-certificates" || {
    log_error "Failed to install remote dependencies"
    exit 1
  }
  ssh_exec "command -v curl unzip openssl fuser >/dev/null" || {
    log_error "One or more dependencies failed to install"
    exit 1
  }
  log_ok "Remote dependencies installed"
}

check_root() {
  local uid
  uid=$(ssh_exec "id -u")
  if [[ "$uid" != "0" ]]; then
    log_error "Must be root on remote server. Current UID: $uid"
    exit 1
  fi
}

# ─── Interactive prompts ──────────────────────────────────────────────────────
prompt_ssh_config() {
  echo -e "\n${BOLD}═══ SSH Connection ═══${NC}"
  [[ -z "$SSH_HOST" ]] && read -p "Server IP: " SSH_HOST
  [[ -z "$SSH_HOST" ]] && {
    log_error "Server IP cannot be empty"
    exit 1
  }
  SSH_PORT="${SSH_PORT:-22}"
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
  echo -e "\n${BOLD}═══ VLESS + Reality Configuration ═══${NC}"
  [[ -z "$SERVER_IP" ]] && SERVER_IP="$SSH_HOST"
  VLESS_PORT="${VLESS_PORT:-443}"
  REMARK="${REMARK:-VLESS-Reality}"
  log_info "Server IP: ${SERVER_IP}"
  log_info "Borrowed TLS host (dest/SNI): ${DEST}"
}

# ─── Pre-flight checks ────────────────────────────────────────────────────────
check_ports() {
  log_info "Checking port availability..."

  # Never touch the SSH port — fuser -k on it would kill sshd and lock us out
  if [[ "$VLESS_PORT" == "$SSH_PORT" ]]; then
    log_error "VLESS port (${VLESS_PORT}) must differ from the SSH port (${SSH_PORT})."
    exit 1
  fi

  ssh_exec "systemctl stop xray 2>/dev/null || true"
  ssh_exec "fuser -k ${VLESS_PORT}/tcp 2>/dev/null || true"
  sleep 2

  if ssh_exec "ss -tlnp | grep -q ':${VLESS_PORT} '" &>/dev/null; then
    log_error "Port ${VLESS_PORT} is still in use. Choose another port with --port."
    exit 1
  fi
  log_ok "Port ${VLESS_PORT}/tcp is free"
}

# ─── Reality dest validation ─────────────────────────────────────────────────
# Reality only works if the borrowed site really speaks TLSv1.3 and HTTP/2.
# A dest that fails these checks produces a handshake that looks wrong to DPI,
# which is exactly the fingerprint we are trying to avoid.
validate_dest() {
  log_info "Validating dest ${DEST} (TLSv1.3 + HTTP/2 + X25519)..."

  if ! ssh_exec "timeout 10 openssl s_client -connect ${DEST}:443 -tls1_3 -servername ${DEST} </dev/null 2>/dev/null | grep -q 'TLSv1.3'" &>/dev/null; then
    log_error "${DEST} does not negotiate TLSv1.3 from the server — Reality will not work."
    log_error "Pick another --dest (e.g. www.icloud.com, dl.google.com)."
    exit 1
  fi
  log_ok "${DEST} supports TLSv1.3"

  if ssh_exec "timeout 10 curl -sI --http2 https://${DEST} -o /dev/null -w '%{http_version}'" 2>/dev/null | grep -q '^2'; then
    log_ok "${DEST} supports HTTP/2"
  else
    log_warn "${DEST} may not support HTTP/2 — Reality prefers h2 dests. Continuing anyway."
  fi

  # X25519 key exchange is required by Reality's handshake forwarding
  if ssh_exec "timeout 10 openssl s_client -connect ${DEST}:443 -servername ${DEST} -curves X25519 </dev/null 2>/dev/null | grep -q 'TLSv1.3'" &>/dev/null; then
    log_ok "${DEST} supports X25519"
  else
    log_warn "${DEST} may not support X25519 — consider another dest if clients fail."
  fi

  # No redirect to a different domain: a dest that 301s elsewhere means the
  # "site" we impersonate does not actually serve content on this hostname.
  local code
  code=$(ssh_exec "timeout 10 curl -sI -o /dev/null -w '%{http_code}' https://${DEST}" 2>/dev/null | tr -d '\r')
  if [[ "$code" =~ ^(301|302|307|308)$ ]]; then
    log_warn "${DEST} answers HTTP ${code} (redirect). A site that redirects away is a weaker disguise."
  elif [[ "$code" == "200" ]]; then
    log_ok "${DEST} answers HTTP 200 directly"
  fi

  # Latency matters: the TLS handshake is really forwarded to dest, so its RTT
  # is added to every client connection.
  local rtt
  rtt=$(ssh_exec "timeout 10 curl -sI -o /dev/null -w '%{time_connect}' https://${DEST}" 2>/dev/null | tr -d '\r')
  if [[ -n "$rtt" ]]; then
    log_info "TCP connect time from server to ${DEST}: ${rtt}s (lower is better; <0.05s ideal)"
  fi

  # The decisive check that most guides omit: does the SNI plausibly belong
  # near our IP? A censor can passively flag "SNI of a US CDN, IP of a random
  # VPS in another country" without any active probing.
  local dest_ip our_net dest_net
  dest_ip=$(ssh_exec "getent hosts ${DEST} | awk '{print \$1; exit}'" 2>/dev/null | tr -d '\r')
  if [[ -n "$dest_ip" ]]; then
    our_net="${SERVER_IP%.*}"
    dest_net="${dest_ip%.*}"
    if [[ "$our_net" == "$dest_net" ]]; then
      log_ok "${DEST} (${dest_ip}) is in the same /24 as your server — ideal disguise"
    else
      log_warn "${DEST} resolves to ${dest_ip}, your server is ${SERVER_IP} (different network)."
      log_warn "Traffic claiming SNI=${DEST} toward an unrelated IP is a passive fingerprint."
      log_warn "Run with --scan-dest to find TLSv1.3 sites hosted in your server's own subnet."
    fi
  fi
}

# ─── Dest discovery ──────────────────────────────────────────────────────────
# Scans the server's own /24 for hosts that serve TLSv1.3 and reports the
# certificate hostname of each. A dest inside your own subnet makes the
# SNI/IP pairing look natural, which is the property a censor checks passively.
scan_dest_candidates() {
  local base="${SERVER_IP%.*}"
  log_info "Scanning ${base}.0/24 for TLSv1.3 hosts (this takes ~1 minute)..."
  echo -e "${BOLD}Candidates (use one as --dest):${NC}"

  # Run the scan remotely: connectivity from the SERVER is what matters, and
  # neighbours are one hop away. Parallelised with xargs.
  ssh_exec "seq 1 254 | xargs -P 40 -I{} sh -c '
    ip=${base}.{}
    out=\$(timeout 3 openssl s_client -connect \$ip:443 -tls1_3 -servername \$ip </dev/null 2>/dev/null)
    echo \"\$out\" | grep -q TLSv1.3 || exit 0
    cn=\$(echo \"\$out\" | sed -n \"s/^subject=.*CN[ ]*=[ ]*//p\" | head -1)
    alpn=\$(echo \"\$out\" | sed -n \"s/^ALPN protocol: //p\" | head -1)
    [ -n \"\$cn\" ] && echo \"  \$ip  CN=\$cn  ALPN=\${alpn:-none}\"
  ' 2>/dev/null" || log_warn "Scan failed or found nothing"

  cat <<'EOF'

How to pick from the list above:
  * Prefer a real, well-known site over a hosting panel or a blank default page.
  * It must be reachable from YOUR network too (test: curl -sI https://<name>).
  * ALPN=h2 is preferred.
Then re-run:  vlessreality.sh --ssh-host <IP> --dest <chosen-hostname>
EOF
}

# ─── Xray installation ───────────────────────────────────────────────────────
detect_arch() {
  local arch
  arch=$(ssh_exec "uname -m")
  case "$arch" in
    x86_64) echo "64" ;;
    aarch64 | arm64) echo "arm64-v8a" ;;
    *)
      log_error "Unsupported architecture: $arch"
      exit 1
      ;;
  esac
}

get_latest_xray_version() {
  local tag
  tag=$(curl -s "https://api.github.com/repos/${XRAY_REPO}/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"tag_name": "\([^"]*\)".*/\1/')
  # GitHub API is rate-limited (60/hour per IP) — fall back to the redirect,
  # which is not rate-limited
  if [[ -z "$tag" ]]; then
    tag=$(curl -sI "https://github.com/${XRAY_REPO}/releases/latest" \
      | tr -d '\r' | sed -n 's|^[Ll]ocation:.*/releases/tag/||p')
  fi
  echo "$tag"
}

install_xray() {
  local arch tag url status
  arch=$(detect_arch)
  tag=$(get_latest_xray_version)
  if [[ -z "$tag" ]]; then
    log_error "Could not determine the latest Xray version (GitHub unreachable or rate-limited)."
    exit 1
  fi

  url="https://github.com/${XRAY_REPO}/releases/download/${tag}/Xray-linux-${arch}.zip"
  log_info "Installing Xray ${tag} (${arch})..."
  ssh_exec "mkdir -p ${XRAY_DIR}"

  status=$(ssh_exec "curl -o /dev/null -sLw '%{http_code}' '${url}'")
  if [[ "$status" != "200" ]]; then
    log_error "Failed to download Xray: HTTP ${status}"
    log_error "URL: ${url}"
    exit 1
  fi

  ssh_exec "curl -fSL '${url}' -o /tmp/xray.zip && unzip -o /tmp/xray.zip -d ${XRAY_DIR} >/dev/null && chmod +x ${XRAY_DIR}/xray && rm -f /tmp/xray.zip" || {
    log_error "Failed to unpack Xray"
    exit 1
  }
  ssh_exec "${XRAY_DIR}/xray version" || {
    log_error "Xray binary does not run"
    exit 1
  }
  log_ok "Xray binary installed"
}

# ─── Reality keys and identifiers ────────────────────────────────────────────
generate_credentials() {
  log_info "Generating Reality keypair and identifiers..."

  # UUID: prefer xray's own generator, fall back to the kernel
  if [[ -z "$UUID" ]]; then
    UUID=$(ssh_exec "${XRAY_DIR}/xray uuid" 2>/dev/null | tr -d '\r')
    [[ -z "$UUID" ]] && UUID=$(ssh_exec "cat /proc/sys/kernel/random/uuid" | tr -d '\r')
  fi
  if [[ ! "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    log_error "Failed to obtain a valid UUID (got: '${UUID}')"
    exit 1
  fi

  # x25519 keypair. Output format changed across Xray versions:
  #   older: "Private key: ..." / "Public key: ..."
  #   newer: "PrivateKey: ..."  / "Password: ..."
  local keys
  keys=$(ssh_exec "${XRAY_DIR}/xray x25519" | tr -d '\r')
  PRIVATE_KEY=$(printf '%s\n' "$keys" | sed -n 's/^[Pp]rivate[ ]*[Kk]ey:[[:space:]]*//p' | head -1)
  PUBLIC_KEY=$(printf '%s\n' "$keys" | sed -n 's/^[Pp]ublic[ ]*[Kk]ey:[[:space:]]*//p' | head -1)
  [[ -z "$PUBLIC_KEY" ]] && PUBLIC_KEY=$(printf '%s\n' "$keys" | sed -n 's/^[Pp]assword:[[:space:]]*//p' | head -1)

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    log_error "Failed to parse the x25519 keypair. Raw output:"
    printf '%s\n' "$keys"
    exit 1
  fi

  # shortId: 0-8 bytes hex. 8 hex chars is a common, safe choice.
  SHORT_ID=$(ssh_exec "openssl rand -hex 4" | tr -d '\r')
  if [[ ! "$SHORT_ID" =~ ^[0-9a-f]{8}$ ]]; then
    log_error "Failed to generate shortId (got: '${SHORT_ID}')"
    exit 1
  fi

  log_ok "UUID, x25519 keypair and shortId generated"
}

# ─── Server configuration ────────────────────────────────────────────────────
create_server_config() {
  log_info "Creating Xray config..."
  # Content is piped via stdin with a QUOTED local heredoc, so the remote shell
  # never re-parses it and nothing can be injected through the values.
  ssh_exec "mkdir -p ${XRAY_DIR}"
  ssh_exec "cat > ${XRAY_DIR}/config.json" <<REMOTEEOF || { log_error "Failed to write config.json"; exit 1; }
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "xver": 0,
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
REMOTEEOF

  # Validate before we try to start, so failures are explained by Xray itself
  ssh_exec "${XRAY_DIR}/xray run -test -c ${XRAY_DIR}/config.json" || {
    log_error "Xray rejected the generated config (see output above)"
    exit 1
  }
  log_ok "Config written and validated: ${XRAY_DIR}/config.json"
}

# ─── Systemd service ─────────────────────────────────────────────────────────
setup_systemd() {
  local svc="/etc/systemd/system/xray.service"
  log_info "Setting up systemd service..."
  ssh_exec "cat > ${svc}" <<REMOTEEOF || { log_error "Failed to write systemd unit"; exit 1; }
[Unit]
Description=Xray (VLESS + Reality)
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${XRAY_DIR}/xray run -c ${XRAY_DIR}/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
# Allow binding to :443 without full root privileges
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
REMOTEEOF
  ssh_exec "systemctl daemon-reload" || {
    log_error "systemctl daemon-reload failed"
    exit 1
  }
  ssh_exec "systemctl enable xray" || {
    log_error "Failed to enable xray service"
    exit 1
  }
  log_ok "Systemd service enabled"
}

# ─── Firewall ────────────────────────────────────────────────────────────────
# Reality uses TCP only. A default-deny (whitelist) firewall on the server
# would otherwise silently drop client connections while the service looks fine.
open_firewall() {
  log_info "Opening firewall for TCP/${VLESS_PORT}..."

  if ssh_exec "command -v ufw >/dev/null && ufw status | grep -q '^Status: active'" &>/dev/null; then
    ssh_exec "ufw allow ${VLESS_PORT}/tcp >/dev/null && ufw reload >/dev/null || true"
    log_ok "ufw rule added (${VLESS_PORT}/tcp)"
  fi

  if ssh_exec "command -v firewall-cmd >/dev/null && firewall-cmd --state" &>/dev/null; then
    ssh_exec "firewall-cmd --permanent --add-port=${VLESS_PORT}/tcp >/dev/null; firewall-cmd --reload >/dev/null || true"
    log_ok "firewalld rule added (${VLESS_PORT}/tcp)"
  fi

  # Whitelist chain: default-deny policy OR a trailing catch-all DROP/REJECT
  if ssh_exec "iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)|^-A INPUT (-j|.* -j) (DROP|REJECT)'" &>/dev/null; then
    ssh_exec "iptables -C INPUT -p tcp --dport ${VLESS_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${VLESS_PORT} -j ACCEPT"
    ssh_exec "command -v netfilter-persistent >/dev/null && netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true"
    log_ok "iptables ACCEPT rule inserted (whitelist INPUT chain detected)"
  fi
}

# ─── Startup ─────────────────────────────────────────────────────────────────
start_xray() {
  log_info "Starting Xray..."
  ssh_exec "systemctl restart xray"
  sleep 3

  local status
  status=$(ssh_exec "systemctl is-active xray" | tr -d '\r')
  if [[ "$status" != "active" ]]; then
    log_error "Xray failed to start."
    log_info "Server logs:"
    ssh_exec "journalctl -u xray -n 30 --no-pager"
    exit 1
  fi

  if ! ssh_exec "ss -tlnp | grep -q ':${VLESS_PORT} '" &>/dev/null; then
    log_error "Xray is active but not listening on TCP/${VLESS_PORT}"
    ssh_exec "journalctl -u xray -n 30 --no-pager"
    exit 1
  fi
  log_ok "Xray is running and listening on TCP/${VLESS_PORT}"
}

# ─── Verification ────────────────────────────────────────────────────────────
# The decisive test: from the CLIENT network, the server must look like an
# ordinary TLS site serving the dest's certificate. If the TCP connection is
# refused, the port is blocked upstream (provider or state-level filtering).
verify_reachable() {
  echo -e "\n${BOLD}═══ Reachability check (client → server) ═══${NC}"

  if command -v nc &>/dev/null; then
    if nc -z -w 8 "${SERVER_IP}" "${VLESS_PORT}" &>/dev/null; then
      log_ok "TCP/${VLESS_PORT} is reachable from this machine"
    else
      log_warn "TCP/${VLESS_PORT} is NOT reachable from this machine."
      log_warn "Open inbound TCP/${VLESS_PORT} in your provider's panel (Security Group / Cloud Firewall),"
      log_warn "or the port is filtered upstream — try --port 8443 or another port."
      return
    fi
  fi

  # Reality should present the dest's real certificate to any prober
  if command -v openssl &>/dev/null; then
    local subject
    subject=$(timeout 12 openssl s_client -connect "${SERVER_IP}:${VLESS_PORT}" \
      -servername "${DEST}" </dev/null 2>/dev/null \
      | sed -n 's/^subject=//p' | head -1)
    if [[ -n "$subject" ]]; then
      log_ok "Server presents a TLS certificate for: ${subject}"
      log_ok "To an observer this is indistinguishable from browsing ${DEST}"
    else
      log_warn "Could not read a certificate — the handshake may be interfered with."
    fi
  fi

  # Is the dest itself reachable from the client network? If the borrowed site
  # is blocked locally, the disguise points at a suspicious destination.
  if command -v curl &>/dev/null; then
    if curl -sI --max-time 8 "https://${DEST}" -o /dev/null 2>/dev/null; then
      log_ok "${DEST} is reachable from this network — good disguise target"
    else
      log_warn "${DEST} is NOT reachable from this network. Traffic to a blocked site looks suspicious."
      log_warn "Re-run with --dest set to a site that IS allowed here."
    fi
  fi
}

# ─── URI generation ──────────────────────────────────────────────────────────
generate_uri() {
  local encoded_remark
  # Fragment: encode %, # and spaces so remarks like "My Server #1" stay valid
  encoded_remark=$(printf '%s' "$REMARK" | sed 's/%/%25/g; s/#/%23/g; s/ /%20/g')
  # fp=chrome makes the TLS ClientHello match a real Chrome fingerprint
  echo "vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${DEST}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#${encoded_remark}"
}

# ─── Output ───────────────────────────────────────────────────────────────────
show_qr() {
  local uri="$1"
  if command -v qrencode &>/dev/null; then
    echo -e "\n${BOLD}QR Code — scan with v2rayNG / Nekobox / Streisand:${NC}"
    qrencode -t ANSIUTF8 "$uri"
  else
    log_warn "qrencode not found. Install: sudo apt install qrencode"
  fi
}

show_summary() {
  local uri="$1"
  cat <<EOF

═════════════════════════════════════════════════════
   VLESS + Reality Setup Complete!
═════════════════════════════════════════════════════
  Server IP:    ${SERVER_IP}
  Port:         ${VLESS_PORT}/tcp
  Protocol:     VLESS + Reality (xtls-rprx-vision)
  Disguised as: ${DEST}
  UUID:         ${UUID}
  PublicKey:    ${PUBLIC_KEY}
  ShortId:      ${SHORT_ID}

  vless:// URI:
  ${uri}

  ─── Client notes ──────────────────────────────────
  Compatible: v2rayNG, Nekobox, Streisand, Hiddify,
              sing-box, Xray-core, FoXray
  No 'insecure' flag needed — Reality validates by pbk.

  ─── Server Commands ───────────────────────────────
  Status:       systemctl status xray
  Logs:         journalctl -u xray -f --no-pager
  Config:       ${XRAY_DIR}/config.json
  Restart:      systemctl restart xray
═════════════════════════════════════════════════════

EOF
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

  if ((SCAN_DEST)); then
    scan_dest_candidates
    exit 0
  fi

  check_ports

  install_xray
  validate_dest
  generate_credentials
  create_server_config
  setup_systemd
  open_firewall
  start_xray

  local uri
  uri=$(generate_uri)
  verify_reachable
  show_summary "$uri"
  show_qr "$uri"
}

main "$@"
