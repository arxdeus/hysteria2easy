#!/bin/bash
# olcrtceasy.sh — One-command olcRTC server setup over SSH
# Copyright (c) 2026 Artemis Kushner
# https://github.com/arxdeus/hysteria2easy
# Licensed under MIT
#
# olcRTC (https://github.com/openlibrecommunity/olcrtc) tunnels TCP over
# WebRTC, disguised as an ordinary video call on an allowed conferencing
# service (Jitsi / Yandex Telemost / WB Stream).
#
# WHY THIS WORKS ON A FOREIGN VPS, unlike VLESS/Reality:
#   Under RU whitelist filtering the client may only reach whitelisted IPs.
#   Here the client never connects to your server at all. BOTH sides dial OUT
#   to the conferencing SFU, which is whitelisted, and the SFU relays between
#   them. Your server's own IP is never a destination for the client, so it
#   does not need to be whitelisted — it only needs plain outbound internet.
#
#     client ──SOCKS5──> olcrtc cnc ──> [whitelisted SFU] <── olcrtc srv ──> internet
#
# Trade-off: throughput and latency are far worse than Reality, because every
# byte is smuggled through a video-call channel.

VERSION="1.0.0"
OLCRTC_REPO="https://github.com/openlibrecommunity/olcrtc"
OLCRTC_DIR="/opt/olcrtc"
GO_VERSION="1.26.3" # must satisfy go.mod (go 1.26.3)

# Default values (overridden by CLI args or prompts)
SSH_HOST="" SSH_PORT="22" SSH_USER="root" SSH_PASSWORD=""
PROVIDER="jitsi" TRANSPORT="datachannel"
JITSI_HOST="" ROOM_ID="" CRYPTO_KEY="" DNS_SERVER="8.8.8.8:53"
WB_TOKEN="" REMARK="olcRTC"
# vp8channel tuning (only used when TRANSPORT=vp8channel)
VP8_FPS="25" VP8_BATCH="1"

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
║          olcRTC Easy Setup  v${VERSION}                ║
║   TCP-over-WebRTC · works on a FOREIGN VPS          ║
╚════════════════════════════════════════════════════╝

  Both sides dial OUT to a whitelisted video-call SFU, so your server's
  IP never needs to be in the whitelist. Slower than VLESS+Reality, but
  it works where Reality cannot (no whitelisted RU IP available).

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
      --provider)
        PROVIDER="$2"
        shift 2
        ;;
      --transport)
        TRANSPORT="$2"
        shift 2
        ;;
      --jitsi-host)
        JITSI_HOST="$2"
        shift 2
        ;;
      --room)
        ROOM_ID="$2"
        shift 2
        ;;
      --key)
        CRYPTO_KEY="$2"
        shift 2
        ;;
      --dns)
        DNS_SERVER="$2"
        shift 2
        ;;
      --wb-token)
        WB_TOKEN="$2"
        shift 2
        ;;
      --remark)
        REMARK="$2"
        shift 2
        ;;
      --help | -h)
        cat <<'HELPEOF'
Usage: olcrtceasy.sh [OPTIONS]

  --ssh-host HOST       Server IP [required or prompted]
  --ssh-port PORT       SSH port [22]
  --ssh-user USER       SSH user [root]
  --ssh-password PASS   SSH password [prompted]
  --provider NAME       jitsi | telemost | wbstream [jitsi]
  --transport NAME      datachannel | vp8channel | seichannel | videochannel
                        [datachannel]
  --jitsi-host HOST     Jitsi instance hostname (provider=jitsi).
                        Auto-picked from the repo's instance list if omitted.
  --room ID             Room ID or full room URL. Auto-generated if omitted.
  --key HEX             64-char hex encryption key. Generated if omitted.
  --dns ADDR:PORT       DNS used by the server [8.8.8.8:53]
  --wb-token TOKEN      WB Stream account token (needed for
                        wbstream + datachannel; guest tokens cannot carry data)
  --remark TEXT         Comment shown in the client URI [olcRTC]
  --help, -h            Show this help

Compatibility matrix (from upstream docs):
  transport      telemost  wbstream  jitsi
  datachannel       -         ~        +      fastest, lowest ping
  vp8channel        +         +        +      fast, high ping
  seichannel        -         +        +      slow, low ping
  videochannel      +         +        +      slowest, highest ping
  ( + works | ~ unstable | - unsupported )

RECOMMENDED: jitsi + datachannel (no registration, most stable).
Alternative:  wbstream + vp8channel.

IMPORTANT: the chosen service must be whitelisted AND reachable in the
CLIENT's network. Verify by opening the Jitsi host in a browser there.

After the server starts, run the client on your own machine:
  git clone https://github.com/openlibrecommunity/olcrtc --recurse-submodules
  cd olcrtc && ./scripts/cnc.sh
Answer with the SAME provider, transport, room and key printed here.
Or paste the olcrtc:// URI into a client that supports it (owenclave, veil,
olcbox).
HELPEOF
        exit 0
        ;;
      *) shift ;;
    esac
  done
}

# ─── Validation ──────────────────────────────────────────────────────────────
validate_choices() {
  case "$PROVIDER" in
    jitsi | telemost | wbstream) ;;
    *)
      log_error "Unknown provider: ${PROVIDER} (use jitsi, telemost or wbstream)"
      exit 1
      ;;
  esac

  case "$TRANSPORT" in
    datachannel | vp8channel | seichannel | videochannel) ;;
    *)
      log_error "Unknown transport: ${TRANSPORT}"
      exit 1
      ;;
  esac

  # Combinations that upstream marks as broken — fail fast instead of leaving
  # the user with a tunnel that connects and then silently carries nothing.
  if [[ "$PROVIDER" == "telemost" && "$TRANSPORT" == "datachannel" ]]; then
    log_error "telemost + datachannel does not work: Telemost removed DataChannel."
    log_error "Use --transport vp8channel with telemost."
    exit 1
  fi
  if [[ "$PROVIDER" == "telemost" && "$TRANSPORT" == "seichannel" ]]; then
    log_error "telemost + seichannel is unsupported. Use --transport vp8channel."
    exit 1
  fi
  if [[ "$PROVIDER" == "wbstream" && "$TRANSPORT" == "datachannel" && -z "$WB_TOKEN" ]]; then
    log_error "wbstream + datachannel needs a moderator/account token."
    log_error "Guest tokens carry canPublishData=false: the tunnel builds but moves no data."
    log_error "Pass --wb-token TOKEN, or use --transport vp8channel for the guest flow."
    exit 1
  fi

  if [[ "$CRYPTO_KEY" != "" && ! "$CRYPTO_KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
    log_error "--key must be exactly 64 hex characters (openssl rand -hex 32)"
    exit 1
  fi

  log_ok "Provider/transport combination is valid: ${PROVIDER} + ${TRANSPORT}"
}

# ─── Dependency checks ───────────────────────────────────────────────────────
check_local_deps() {
  local missing=()
  for cmd in sshpass curl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    log_error "Missing local dependencies: ${missing[*]}"
    echo -e "${BOLD}Install with:${NC}"
    echo "  Ubuntu/Debian: sudo apt install ${missing[*]}"
    echo "  macOS:         brew install ${missing[*]}"
    exit 1
  fi
  command -v qrencode &>/dev/null || log_warn "qrencode not found — QR output will be skipped"
}

check_root() {
  local uid
  uid=$(ssh_exec "id -u" | tr -d '\r')
  if [[ "$uid" != "0" ]]; then
    log_error "Must be root on remote server. Current UID: $uid"
    exit 1
  fi
}

check_remote_deps() {
  log_info "Installing remote dependencies..."
  ssh_exec "apt-get update && apt-get install -y git curl openssl ca-certificates tar" || {
    log_error "Failed to install remote dependencies"
    exit 1
  }
  log_ok "Remote dependencies installed"
}

# ─── Outbound connectivity ───────────────────────────────────────────────────
# olcRTC needs no inbound ports at all: the server dials out to the SFU.
# What it does need is working outbound HTTPS and UDP (WebRTC media).
check_outbound() {
  log_info "Checking the server's OUTBOUND connectivity..."

  if ssh_exec "curl -sI --max-time 10 https://github.com -o /dev/null"; then
    log_ok "Outbound HTTPS works"
  else
    log_error "Server cannot reach the internet over HTTPS — cannot build or connect."
    exit 1
  fi

  # WebRTC media needs outbound UDP. Most VPS allow it; a strict egress
  # firewall would break the tunnel in a way that is hard to diagnose later.
  if ssh_exec "command -v nc >/dev/null && timeout 5 nc -uz 8.8.8.8 53" &>/dev/null; then
    log_ok "Outbound UDP appears to work (needed for WebRTC media)"
  else
    log_warn "Could not confirm outbound UDP. If the tunnel never connects,"
    log_warn "check the provider's EGRESS rules and allow outbound UDP."
  fi
}

# ─── Go toolchain ────────────────────────────────────────────────────────────
# Built directly with Go rather than upstream's Podman flow: on a VPS the
# container layer only adds weight, and this keeps the systemd unit simple.
install_go() {
  local arch have
  arch=$(ssh_exec "uname -m" | tr -d '\r')
  case "$arch" in
    x86_64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
      log_error "Unsupported architecture: $arch"
      exit 1
      ;;
  esac

  # Reuse an existing toolchain if it is new enough for go.mod
  have=$(ssh_exec "/usr/local/go/bin/go version 2>/dev/null || go version 2>/dev/null" | tr -d '\r')
  if [[ -n "$have" ]]; then
    log_info "Go already present: ${have}"
    local v
    v=$(printf '%s' "$have" | sed -n 's/.*go\([0-9][0-9.]*\).*/\1/p')
    # Compare as version numbers; sort -V puts the smaller first
    if [[ "$(printf '%s\n%s\n' "$GO_VERSION" "$v" | sort -V | head -1)" == "$GO_VERSION" ]]; then
      log_ok "Existing Go ${v} satisfies the required ${GO_VERSION}"
      return 0
    fi
    log_warn "Go ${v} is older than required ${GO_VERSION} — installing a newer toolchain"
  fi

  log_info "Installing Go ${GO_VERSION} (${arch})..."
  local url="https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz"
  local status
  status=$(ssh_exec "curl -o /dev/null -sLw '%{http_code}' '${url}'" | tr -d '\r')
  if [[ "$status" != "200" ]]; then
    log_error "Go ${GO_VERSION} tarball not available for ${arch} (HTTP ${status})"
    log_error "URL: ${url}"
    exit 1
  fi
  ssh_exec "curl -fsSL '${url}' -o /tmp/go.tar.gz && rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz && rm -f /tmp/go.tar.gz" || {
    log_error "Failed to install Go"
    exit 1
  }
  ssh_exec "/usr/local/go/bin/go version" || {
    log_error "Go installation is broken"
    exit 1
  }
  log_ok "Go ${GO_VERSION} installed"
}

# ─── Build olcRTC ────────────────────────────────────────────────────────────
build_olcrtc() {
  log_info "Cloning and building olcRTC (this takes a few minutes)..."

  # A build with <4GB RAM can be OOM-killed; add swap when memory is tight.
  local mem_mb
  mem_mb=$(ssh_exec "free -m | awk '/^Mem:/{print \$2}'" | tr -d '\r')
  local swap_mb
  swap_mb=$(ssh_exec "free -m | awk '/^Swap:/{print \$2}'" | tr -d '\r')
  if [[ -n "$mem_mb" ]] && ((mem_mb < 4000)) && [[ -n "$swap_mb" ]] && ((swap_mb < 1000)); then
    log_warn "Only ${mem_mb}MB RAM and ${swap_mb}MB swap — the Go build may be OOM-killed."
    log_info "Adding a 4GB swapfile..."
    ssh_exec "fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile" \
      && log_ok "Swap enabled" \
      || log_warn "Could not enable swap — continuing, but the build may fail"
  fi

  ssh_exec "rm -rf ${OLCRTC_DIR} && git clone --depth 1 --recurse-submodules ${OLCRTC_REPO} ${OLCRTC_DIR}" || {
    log_error "Failed to clone ${OLCRTC_REPO}"
    exit 1
  }

  ssh_exec "cd ${OLCRTC_DIR} && PATH=/usr/local/go/bin:\$PATH GOFLAGS=-mod=mod go build -trimpath -ldflags='-s -w' -o olcrtc ./cmd/olcrtc" || {
    log_error "Build failed. Check the output above (most often: out of memory)."
    exit 1
  }
  ssh_exec "test -x ${OLCRTC_DIR}/olcrtc" || {
    log_error "Binary not found after build"
    exit 1
  }
  log_ok "olcRTC built at ${OLCRTC_DIR}/olcrtc"
}

# ─── Jitsi instance selection ────────────────────────────────────────────────
# Upstream ships a list of instances; they come and go, so verify reachability
# from the server and let the user confirm it works in the client's browser.
pick_jitsi_host() {
  [[ "$PROVIDER" != "jitsi" ]] && return 0
  [[ -n "$JITSI_HOST" ]] && {
    log_info "Using Jitsi host: ${JITSI_HOST}"
    return 0
  }

  log_info "Picking a reachable Jitsi instance from the repo list..."
  local hosts
  hosts=$(ssh_exec "sed -n 's/^[[:space:]]*-[[:space:]]*//p' ${OLCRTC_DIR}/docs/jitsi.instances.yaml" | tr -d '\r')
  if [[ -z "$hosts" ]]; then
    log_error "Could not read docs/jitsi.instances.yaml"
    log_error "Pass --jitsi-host HOST explicitly."
    exit 1
  fi

  local h
  for h in $hosts; do
    if ssh_exec "curl -sI --max-time 6 https://${h} -o /dev/null -w '%{http_code}'" 2>/dev/null | grep -qE '^(200|30[0-9])$'; then
      JITSI_HOST="$h"
      log_ok "Selected Jitsi instance: ${JITSI_HOST}"
      break
    fi
  done

  if [[ -z "$JITSI_HOST" ]]; then
    log_error "No Jitsi instance from the list responded from the server."
    log_error "Pass one explicitly with --jitsi-host."
    exit 1
  fi

  log_warn "Verify that https://${JITSI_HOST} also opens in the CLIENT's browser."
  log_warn "If it does not, that instance is not whitelisted there — pick another."
}

# ─── Room and key ────────────────────────────────────────────────────────────
generate_room_and_key() {
  if [[ -z "$CRYPTO_KEY" ]]; then
    CRYPTO_KEY=$(ssh_exec "openssl rand -hex 32" | tr -d '\r')
    if [[ ! "$CRYPTO_KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
      log_error "Failed to generate a valid encryption key"
      exit 1
    fi
    log_ok "Encryption key generated"
  else
    log_info "Using the provided encryption key"
  fi

  if [[ -n "$ROOM_ID" ]]; then
    # Accept a bare room name for jitsi and expand it to a full URL
    if [[ "$PROVIDER" == "jitsi" && "$ROOM_ID" != http* ]]; then
      ROOM_ID="https://${JITSI_HOST}/${ROOM_ID}"
    fi
    log_info "Using room: ${ROOM_ID}"
    return 0
  fi

  if [[ "$PROVIDER" == "jitsi" ]]; then
    # A random room name on the chosen instance, mirroring upstream's scheme
    local suffix
    suffix=$(ssh_exec "openssl rand -hex 4" | tr -d '\r')
    ROOM_ID="https://${JITSI_HOST}/olcrtc-${suffix}"
    log_ok "Generated room: ${ROOM_ID}"
    return 0
  fi

  # telemost / wbstream: rooms are created by the provider, so use mode: gen
  log_info "Generating a ${PROVIDER} room via olcRTC (mode: gen)..."
  ssh_exec "cat > ${OLCRTC_DIR}/gen.yaml" <<REMOTEEOF || { log_error "Failed to write gen.yaml"; exit 1; }
mode: gen
auth:
  provider: "${PROVIDER}"
net:
  dns: "${DNS_SERVER}"
gen:
  amount: 1
REMOTEEOF

  ROOM_ID=$(ssh_exec "cd ${OLCRTC_DIR} && ./olcrtc gen.yaml" | tr -d '\r' | tail -1)
  if [[ -z "$ROOM_ID" ]]; then
    log_error "Room generation failed for provider ${PROVIDER}."
    log_error "Create a room manually (telemost.yandex.ru / stream.wb.ru) and pass --room ID."
    exit 1
  fi
  log_ok "Generated room: ${ROOM_ID}"
}

# ─── Server configuration ────────────────────────────────────────────────────
create_config() {
  log_info "Writing olcRTC server config..."

  # Piped via a quoted heredoc so the remote shell never re-parses the values
  {
    echo "mode: srv"
    echo "auth:"
    echo "  provider: \"${PROVIDER}\""
    [[ -n "$WB_TOKEN" ]] && echo "  token: \"${WB_TOKEN}\""
    echo "room:"
    echo "  id: \"${ROOM_ID}\""
    echo "crypto:"
    echo "  key: \"${CRYPTO_KEY}\""
    echo "net:"
    echo "  transport: \"${TRANSPORT}\""
    echo "  dns: \"${DNS_SERVER}\""
    if [[ "$TRANSPORT" == "vp8channel" ]]; then
      echo "vp8:"
      echo "  fps: ${VP8_FPS}"
      echo "  batch_size: ${VP8_BATCH}"
    fi
    # Keep the session healthy unattended: ping the peer, rebuild when it dies,
    # and recycle every 6h so a stale SFU session cannot wedge the tunnel.
    echo "liveness:"
    echo "  interval: 10s"
    echo "  timeout: 15s"
    echo "  failures: 4"
    echo "lifecycle:"
    echo "  max_session_duration: 6h"
    echo "debug: false"
  } | ssh_exec "cat > ${OLCRTC_DIR}/server.yaml" || {
    log_error "Failed to write server.yaml"
    exit 1
  }

  ssh_exec "chmod 600 ${OLCRTC_DIR}/server.yaml"
  log_ok "Config written to ${OLCRTC_DIR}/server.yaml"
}

# ─── Systemd service ─────────────────────────────────────────────────────────
setup_systemd() {
  local svc="/etc/systemd/system/olcrtc.service"
  log_info "Setting up systemd service..."
  ssh_exec "cat > ${svc}" <<REMOTEEOF || { log_error "Failed to write systemd unit"; exit 1; }
[Unit]
Description=olcRTC server (TCP over WebRTC)
Documentation=${OLCRTC_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${OLCRTC_DIR}
ExecStart=${OLCRTC_DIR}/olcrtc ${OLCRTC_DIR}/server.yaml
Restart=always
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
REMOTEEOF
  ssh_exec "systemctl daemon-reload" || {
    log_error "systemctl daemon-reload failed"
    exit 1
  }
  ssh_exec "systemctl enable olcrtc" || {
    log_error "Failed to enable the olcrtc service"
    exit 1
  }
  log_ok "Systemd service enabled (auto-restart on failure and at boot)"
}

# ─── Startup ─────────────────────────────────────────────────────────────────
start_olcrtc() {
  log_info "Starting olcRTC server..."
  ssh_exec "systemctl restart olcrtc"
  # Joining an SFU room takes noticeably longer than binding a local port
  sleep 8

  local status
  status=$(ssh_exec "systemctl is-active olcrtc" | tr -d '\r')
  if [[ "$status" != "active" ]]; then
    log_error "olcRTC failed to start."
    log_info "Server logs:"
    ssh_exec "journalctl -u olcrtc -n 40 --no-pager"
    exit 1
  fi
  log_ok "olcRTC service is active"

  # "active" only means the process lives; confirm it actually joined the room.
  log_info "Checking whether the server joined the room..."
  local logs
  logs=$(ssh_exec "journalctl -u olcrtc -n 60 --no-pager" 2>/dev/null)
  if printf '%s' "$logs" | grep -qiE 'error|failed|panic|refused|timeout'; then
    log_warn "The log contains errors — review it before trusting the tunnel:"
    printf '%s\n' "$logs" | grep -iE 'error|failed|panic|refused|timeout' | tail -5
    log_warn "Full log: ssh ${SSH_USER}@${SSH_HOST} journalctl -u olcrtc -f"
  else
    log_ok "No errors in the startup log"
  fi
}

# ─── Output ───────────────────────────────────────────────────────────────────
generate_uri() {
  local payload="" encoded_remark
  # Transport payload block, per docs/uri.md (omitted when defaults are used)
  if [[ "$TRANSPORT" == "vp8channel" ]]; then
    payload="<vp8-fps=${VP8_FPS}&vp8-batch=${VP8_BATCH}>"
  fi
  encoded_remark="${REMARK}"
  echo "olcrtc://${PROVIDER}?${TRANSPORT}${payload}@${ROOM_ID}#${CRYPTO_KEY}\$${encoded_remark}"
}

show_qr() {
  local uri="$1"
  if command -v qrencode &>/dev/null; then
    echo -e "\n${BOLD}QR Code — scan with owenclave / veil / olcbox:${NC}"
    qrencode -t ANSIUTF8 "$uri"
  fi
}

show_summary() {
  local uri="$1"
  cat <<EOF

═════════════════════════════════════════════════════
   olcRTC Server Setup Complete!
═════════════════════════════════════════════════════
  Server:       ${SSH_HOST}
  Provider:     ${PROVIDER}
  Transport:    ${TRANSPORT}
  Room:         ${ROOM_ID}
  Key:          ${CRYPTO_KEY}
  DNS:          ${DNS_SERVER}

  olcrtc:// URI:
  ${uri}

  ─── Connect from your machine ─────────────────────
  Option A — native client:
    git clone ${OLCRTC_REPO} --recurse-submodules
    cd olcrtc && ./scripts/cnc.sh
    Use the SAME provider, transport, room and key as above.
    A SOCKS5 proxy will listen on 127.0.0.1:8808.

  Option B — app that understands olcrtc:// URIs:
    owenewans/owenclave (Android), venterum/veil, alananisimov/olcbox

  Then verify:
    curl --socks5-hostname 127.0.0.1:8808 https://icanhazip.com
    (it must print ${SSH_HOST})

  ─── Server Commands ───────────────────────────────
  Status:       systemctl status olcrtc
  Logs:         journalctl -u olcrtc -f --no-pager
  Config:       ${OLCRTC_DIR}/server.yaml
  Restart:      systemctl restart olcrtc

  ─── Notes ─────────────────────────────────────────
  * No inbound port is needed: the server dials out to the SFU.
  * Both sides must use the SAME provider, transport, room and key,
    and both must run a build with the same wire format — update
    both sides together.
  * Throughput is far below VLESS+Reality. Use this when no
    whitelisted RU IP is available.
═════════════════════════════════════════════════════

EOF
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

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  show_banner
  parse_args "$@"
  validate_choices
  check_local_deps

  prompt_ssh_config
  ssh_test
  check_root
  check_remote_deps
  check_outbound

  install_go
  build_olcrtc
  pick_jitsi_host
  generate_room_and_key
  create_config
  setup_systemd
  start_olcrtc

  local uri
  uri=$(generate_uri)
  show_summary "$uri"
  show_qr "$uri"
}

main "$@"
