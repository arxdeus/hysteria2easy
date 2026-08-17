#!/bin/bash
# wlcheck.sh — diagnose why a proxy server is unreachable under RU whitelist filtering
# Copyright (c) 2026 Artemis Kushner
# https://github.com/arxdeus/hysteria2easy
# Licensed under MIT
#
# RUN THIS ON THE CLIENT MACHINE (the one inside the filtered network),
# NOT on the server. It answers one question: why is the connection failing?
#
# The failure MODE is the diagnosis:
#   timeout   → packets are dropped at L3 → the server IP is not whitelisted
#   RST/reset → packets arrive, DPI kills the session → SNI is blacklisted
#   refused   → packets arrive, nothing is listening → server misconfigured
#   connect   → the network path is fine → the problem is in the client config

VERSION="1.0.0"

SERVER_IP="" SERVER_PORT="443" SNI=""
PROBE_TIMEOUT=6

# ─── Color output ───────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Reference points from the TSPU whitelist measurements
# (habr.com/ru/articles/1027276, github.com/openlibrecommunity/twl).
# Whitelisted: reachable even in drop-all mode. Blocked: reachable only
# when the network is NOT filtering.
WHITELISTED_PROBES=(
  "217.20.147.1|MAX (always whitelisted, every operator)"
  "77.88.55.242|Yandex"
  "87.240.132.78|VK"
)
BLOCKED_PROBES=(
  "8.8.8.8|Google DNS"
  "1.1.1.1|Cloudflare DNS"
)

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip)
        SERVER_IP="$2"
        shift 2
        ;;
      --port)
        SERVER_PORT="$2"
        shift 2
        ;;
      --sni)
        SNI="$2"
        shift 2
        ;;
      --timeout)
        PROBE_TIMEOUT="$2"
        shift 2
        ;;
      --help | -h)
        cat <<'HELPEOF'
Usage: wlcheck.sh --ip SERVER_IP [OPTIONS]

Run this ON THE CLIENT MACHINE, inside the filtered network.

  --ip IP           Your proxy server's IP [required]
  --port PORT       Port to test [443]
  --sni HOST        SNI/dest to test (e.g. yastatic.net)
  --timeout SEC     Per-probe timeout [6]
  --help, -h        Show this help

It distinguishes the failure modes that look identical in a client app:
  timeout   the server IP is not in the operator's whitelist (L3 drop)
  reset     the IP passes but the SNI is blacklisted (L7 RST)
  refused   packets arrive but no service is listening (server-side problem)
  connect   the path works; the problem is in the client configuration
HELPEOF
        exit 0
        ;;
      *) shift ;;
    esac
  done
}

# ─── Core probe ──────────────────────────────────────────────────────────────
# Classifies a TCP connection attempt. The distinction between "timeout" and
# "refused" is the whole point: a timeout means the packet never arrived
# anywhere, while "refused" proves it reached the host.
probe_tcp() {
  local ip="$1" port="$2" out rc

  # Prefer nc: it reports refusal and timeout distinctly, and unlike bash's
  # /dev/tcp it exists on hosts whose bash was built without net redirection.
  if command -v nc &>/dev/null; then
    # -v is required: without it macOS/BSD nc prints nothing, so a refusal
    # would be misread as a timeout and invert the whole diagnosis.
    out=$(nc -v -w "$PROBE_TIMEOUT" -z "$ip" "$port" 2>&1)
    # Do not trust the exit status here: BSD nc returns 0 even for a refused
    # connection when -v is used. Classify from the message, and only treat
    # the attempt as successful when nc says it succeeded.
    if printf '%s' "$out" | grep -qiE "succeeded|open$|\[tcp/.*\] succeeded"; then
      echo "connect"
      return
    fi
    # nc exits non-zero for both refusal and timeout, so read its message.
    if printf '%s' "$out" | grep -qi "refused"; then
      echo "refused"
    elif printf '%s' "$out" | grep -qi "reset"; then
      echo "reset"
    elif printf '%s' "$out" | grep -qi "unreachable\|no route"; then
      echo "unreachable"
    else
      # Silence with a non-zero exit after the full timeout means the packets
      # went nowhere, which is exactly the L3-drop signature we look for.
      echo "timeout"
    fi
    return
  fi

  # Fallback: bash network redirection, when available.
  out=$( (exec 3<>"/dev/tcp/${ip}/${port}") 2>&1 )
  rc=$?
  if ((rc == 0)); then
    echo "connect"
  elif printf '%s' "$out" | grep -qi "refused"; then
    echo "refused"
  elif printf '%s' "$out" | grep -qi "reset"; then
    echo "reset"
  elif printf '%s' "$out" | grep -qi "unreachable\|no route"; then
    echo "unreachable"
  else
    echo "timeout"
  fi
}

check_probe_tooling() {
  if ! command -v nc &>/dev/null; then
    log_warn "nc not found — falling back to bash /dev/tcp."
    log_warn "Install netcat for sharper timeout/refused classification:"
    log_warn "  apt install netcat-openbsd   |   brew install netcat"
  fi
}

describe() {
  case "$1" in
    connect) echo "reachable" ;;
    timeout) echo "TIMEOUT (packets dropped, no reply at all)" ;;
    refused) echo "refused (host reached, nothing listening)" ;;
    reset) echo "RESET (host reached, session killed by DPI)" ;;
    unreachable) echo "unreachable (no route)" ;;
  esac
}

# ─── Step 1: is this network actually filtering? ─────────────────────────────
WHITELIST_MODE="unknown"
check_network_mode() {
  echo -e "\n${BOLD}═══ 1. Is this network in whitelist mode? ═══${NC}"

  local wl_ok=0 wl_total=0 entry ip label res
  for entry in "${WHITELISTED_PROBES[@]}"; do
    ip="${entry%%|*}"
    label="${entry#*|}"
    res=$(probe_tcp "$ip" 443)
    ((wl_total++))
    [[ "$res" == "connect" ]] && ((wl_ok++))
    printf "  %-16s %-46s %s\n" "$ip" "$label" "$(describe "$res")"
  done

  local bl_ok=0 bl_total=0
  for entry in "${BLOCKED_PROBES[@]}"; do
    ip="${entry%%|*}"
    label="${entry#*|}"
    res=$(probe_tcp "$ip" 443)
    ((bl_total++))
    [[ "$res" == "connect" ]] && ((bl_ok++))
    printf "  %-16s %-46s %s\n" "$ip" "$label" "$(describe "$res")"
  done

  echo
  if ((wl_ok > 0 && bl_ok == 0)); then
    WHITELIST_MODE="yes"
    log_warn "WHITELIST MODE CONFIRMED: allowed IPs reachable, others dropped."
  elif ((wl_ok > 0 && bl_ok > 0)); then
    WHITELIST_MODE="no"
    log_ok "This network is NOT in whitelist mode (blocked-by-default IPs answer)."
  elif ((wl_ok == 0)); then
    WHITELIST_MODE="broken"
    log_error "Even always-whitelisted IPs are unreachable — no usable connectivity."
    log_error "Check the connection itself before blaming the server."
  fi
}

# ─── Step 2: the server itself ───────────────────────────────────────────────
SERVER_RESULT=""
check_server() {
  echo -e "\n${BOLD}═══ 2. Your server: ${SERVER_IP}:${SERVER_PORT} ═══${NC}"
  SERVER_RESULT=$(probe_tcp "$SERVER_IP" "$SERVER_PORT")
  printf "  %-16s %-46s %s\n" "$SERVER_IP" "your proxy server" "$(describe "$SERVER_RESULT")"

  # Ports 80/22 tell us whether the whole IP is dropped or just this port:
  # under whitelist filtering only TCP 80/443/22 pass at all.
  if [[ "$SERVER_RESULT" == "timeout" ]]; then
    local r80 r22
    r80=$(probe_tcp "$SERVER_IP" 80)
    r22=$(probe_tcp "$SERVER_IP" 22)
    printf "  %-16s %-46s %s\n" "$SERVER_IP" "same server, port 80" "$(describe "$r80")"
    printf "  %-16s %-46s %s\n" "$SERVER_IP" "same server, port 22 (SSH)" "$(describe "$r22")"
    if [[ "$r80" != "timeout" || "$r22" != "timeout" ]]; then
      log_info "Another port answers, so the IP itself is not fully dropped."
      log_info "Only port ${SERVER_PORT} is being filtered."
    fi
  fi
}

# ─── Step 3: SNI behaviour ───────────────────────────────────────────────────
check_sni() {
  [[ -z "$SNI" ]] && return 0
  [[ "$SERVER_RESULT" != "connect" ]] && return 0
  command -v openssl &>/dev/null || return 0

  echo -e "\n${BOLD}═══ 3. TLS handshake with SNI=${SNI} ═══${NC}"
  local out
  out=$(timeout "$PROBE_TIMEOUT" openssl s_client -connect "${SERVER_IP}:${SERVER_PORT}" \
    -servername "$SNI" </dev/null 2>&1)

  if printf '%s' "$out" | grep -q 'Verify return code\|subject='; then
    local subject
    subject=$(printf '%s' "$out" | sed -n 's/^subject=//p' | head -1)
    log_ok "TLS handshake succeeded. Server presents: ${subject:-<none>}"
    log_ok "The SNI '${SNI}' passes the L7 filter."
  elif printf '%s' "$out" | grep -qi 'reset'; then
    log_error "Connection RESET during the TLS handshake."
    log_error "The SNI '${SNI}' is blacklisted by the operator. Choose another dest."
  else
    log_warn "Handshake did not complete cleanly:"
    printf '%s\n' "$out" | grep -iE 'error|reset|timeout|alert' | head -3
  fi
}

# ─── Verdict ─────────────────────────────────────────────────────────────────
verdict() {
  echo -e "\n${BOLD}═══ Verdict ═══${NC}"

  case "$SERVER_RESULT" in
    connect)
      log_ok "The network path to ${SERVER_IP}:${SERVER_PORT} WORKS."
      echo
      echo "  The blockage is not at the network level, so check the client config:"
      echo "    * UUID, publicKey (pbk), shortId (sid) and SNI must match the server"
      echo "    * flow must be xtls-rprx-vision, fp must be chrome"
      echo "    * on the server: systemctl status xray; journalctl -u xray -n 50"
      ;;
    refused)
      log_error "Packets REACH the server, but nothing listens on port ${SERVER_PORT}."
      echo
      echo "  Good news: the IP passes the whitelist. This is a server-side problem:"
      echo "    ssh root@${SERVER_IP} systemctl status xray"
      echo "    ssh root@${SERVER_IP} journalctl -u xray -n 50 --no-pager"
      echo "    ssh root@${SERVER_IP} ss -tlnp | grep ${SERVER_PORT}"
      ;;
    reset)
      log_error "Packets reach the server, but the session is RESET by DPI."
      echo
      echo "  The IP passes; the SNI is the problem. Redeploy with an allowed dest:"
      echo "    bash vlessreality.sh --ssh-host ${SERVER_IP} --dest yastatic.net"
      echo "  Never use twitter.com / x.com / youtube.com / telegram.org as dest."
      ;;
    timeout | unreachable)
      log_error "TIMEOUT: packets to ${SERVER_IP} are dropped before reaching it."
      echo
      if [[ "$WHITELIST_MODE" == "yes" ]]; then
        echo "  Whitelist mode is confirmed and your server IP is NOT in the list."
        echo "  This CANNOT be fixed by configuration: no protocol, port, obfuscation"
        echo "  or SNI helps, because the packet never leaves the operator's network."
        echo
        echo "  Two real options:"
        echo
        echo "  A) Move the server to a whitelisted Russian provider, then use Reality:"
        echo "       Yandex.Cloud (~1/5 of all whitelisted IPs), Timeweb, VK Cloud,"
        echo "       Selectel, Beget, REG.RU"
        echo "       bash vlessreality.sh --ssh-host <NEW_IP> --dest yastatic.net"
        echo
        echo "  B) Keep this server and tunnel through a whitelisted video-call SFU."
        echo "     The client never contacts your IP, so it need not be whitelisted:"
        echo "       bash olcrtceasy.sh --ssh-host ${SERVER_IP}"
      else
        echo "  Whitelist mode was not confirmed, so also check:"
        echo "    * the provider's firewall / security group allows inbound TCP ${SERVER_PORT}"
        echo "    * the service is running:  systemctl status xray"
        echo "    * the server is actually powered on and has this IP"
      fi
      ;;
  esac
  echo
}

main() {
  cat <<EOF

╔════════════════════════════════════════════════════╗
║       Whitelist Reachability Diagnosis v${VERSION}      ║
║       run this on the CLIENT, not the server        ║
╚════════════════════════════════════════════════════╝
EOF

  parse_args "$@"
  if [[ -z "$SERVER_IP" ]]; then
    log_error "--ip is required (your proxy server's IP)"
    echo "Try: bash wlcheck.sh --ip 1.2.3.4 --sni yastatic.net"
    exit 1
  fi

  check_probe_tooling
  check_network_mode
  check_server
  check_sni
  verdict
}

main "$@"
