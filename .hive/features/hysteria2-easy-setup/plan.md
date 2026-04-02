# Hysteria2 Easy Setup

## Discovery

### Original Request
- Создать скрипт, который поднимает сервер Hysteria2, выпускает ACME-сертификаты без доменного имени, выдаёт QR-код и строку подключения.

### Interview Summary
- **Сертификаты**: Let's Encrypt IP-based через nip.io (`<IP>.nip.io`). HTTP-01 challenge на порту 80.
- **Развёртывание**: Скрипт запускается **локально**, подключается по SSH к удалённому серверу (пароль интерактивно), ставит всё на сервер.
- **Аутентификация SSH**: Password-based (`sshpass`), интерактивный ввод пароля. **Note**: `--ssh-password` виден в `ps aux` — использовать только для CI/автоматизации.
- **Язык**: Bash, Linux (Ubuntu/Debian).
- **Клиенты**: Nekobox / v2rayng (Android). hysteria2:// URI + QR.
- **Конфигурация**: Интерактивный ввод + CLI-аргументы.
- **Systemd**: Да, автозапуск.
- **Вывод**: stdout — QR (ASCII) + hysteria2:// URI. Пароль маскируется.
- **OS сервера**: Ubuntu/Debian.

### Research Findings
- Hysteria2 v2: `apernet/hysteria`. Тег: `app/v2.x.y`. YAML: `listen` на **корневом** уровне (НЕ под `server:`).
- nip.io: wildcard DNS, `<IP>.nip.io` → `<IP>`.
- Let's Encrypt: HTTP-01 challenge на порту 80.
- acme.sh: `~/.acme.sh/acme.sh --issue -d <domain> --standalone --httpport 80`.
- Hysteria2 v2 URI: `hysteria2://<base64(JSON_auth)>@<ip>:<port>?sni=<domain>&insecure=0&fp=<sha256>#remark`
- `qrencode -t ANSIUTF8` — QR в терминал.
- `sshpass`, `qrencode`, `curl` — локальные зависимости.
- `netcat-openbsd` (nc), `psmisc` (fuser), `socat` — серверные зависимости.

---

## Non-Goals (What we're NOT building)
- Docker-установка.
- Автоматическая установка SSH-ключей.
- Certificate renewal UI (acme.sh auto-renewal).
- Поддержка macOS как сервера.
- Сохранение артефактов на диск.
- Поддержка IPv6.
- Uninstall / обновление существующей установки.
- Активное маскирование пароля в `ps aux` (ограничение `sshpass`, документировано).

---

## Tasks

### 1. Create project scaffold and README

**Depends on**: none

**Files:**
- Create: `README.md`
- Create: `LICENSE`

**What to do**:
- Step 1: Create `README.md` with:
  - Название: **Hysteria2 Easy** — One-command Hysteria2 server setup with zero-config TLS.
  - Описание: Скрипт подключается по SSH к VPS, устанавливает Hysteria2, выпускает Let's Encrypt сертификат через nip.io, выдаёт QR-код и hysteria2:// URI.
  - Требования (локально): Bash, `sshpass`, `qrencode`, `curl`.
  - Требования (сервер): Ubuntu/Debian, порты 80 и 443 открыты, root/sudo.
  - Установка: `curl -fsSL https://.../hysteria2-easy.sh | bash`
  - CLI-аргументы: `--ssh-host`, `--ssh-port`, `--ssh-user`, `--ssh-password`, `--port`, `--password`, `--remark`, `--ip`, `--help`
  - Без аргументов — интерактивный режим.
  - Пример вывода (ASCII QR).
  - Troubleshooting section.
  - **Security note**: `--ssh-password` передаёт пароль в командной строке, виден в `ps aux`. Для безопасности используйте интерактивный режим.
  - Лицензия MIT.
- Step 2: Create `LICENSE` (MIT).
- Step 3: Commit
  ```bash
  git init
  git add README.md LICENSE
  git commit -m "docs: initial project scaffold"
  ```

**Verify**:
- [ ] `ls README.md LICENSE` → files exist
- [ ] `grep -c "Requirements\|Installation\|Troubleshooting\|CLI\|Security" README.md` → 5+

---

### 2. Write script: Constants, color output, and SSH helper functions

**Depends on**: 1

**Files:**
- Create: `hysteria2-easy.sh`

**What to do**:
- Step 1: Shebang and constants:
  ```bash
  #!/bin/bash
  set -euo pipefail

  VERSION="1.0.0"
  HYSTERIA_REPO="apernet/hysteria"
  HYSTERIA_DIR="/etc/hysteria2"
  CERT_DIR="/root/.acme.sh"

  # Default values
  SSH_HOST="" SSH_PORT="22" SSH_USER="root" SSH_PASSWORD=""
  SERVER_IP="" HYSTERIA_PORT="443" AUTH_PASSWORD="" REMARK="Hysteria2"
  ```

- Step 2: Color variables:
  ```bash
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
  ```

- Step 3: Logging functions:
  ```bash
  log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
  log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
  log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
  log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
  ```

- Step 4: `ssh_exec()`:
  ```bash
  ssh_exec() {
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o BatchMode=no \
      -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" "$1"
  }
  ```

- Step 5: `ssh_test()`:
  ```bash
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
  ```

- Step 6: `check_local_deps()`:
  - Проверить `sshpass`, `qrencode`, `curl` — если отсутствуют, вывести install command и exit.

- Step 7: `check_remote_deps()`:
  ```bash
  check_remote_deps() {
    log_info "Installing remote dependencies..."
    ssh_exec "apt-get update && apt-get install -y \
      curl openssl socat net-tools psmisc netcat-openbsd"
    # Verify all tools exist
    ssh_exec "command -v curl openssl socat nc fuser >/dev/null" || {
      log_error "One or more dependencies failed to install"
      exit 1
    }
  }
  ```

- Step 8: Commit
  ```bash
  git add hysteria2-easy.sh
  git commit -m "feat: add constants, color output, SSH helper functions"
  ```

**Verify**:
- [ ] `bash -n hysteria2-easy.sh` → no syntax errors
- [ ] `grep "netcat-openbsd\|psmisc" hysteria2-easy.sh` → both present

---

### 3. Write script: CLI argument parsing and interactive prompts

**Depends on**: 2

**Files:**
- Modify: `hysteria2-easy.sh`

**What to do**:
- Step 1: Write `parse_args()`:
  ```bash
  parse_args() {
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ssh-host)     SSH_HOST="$2";     shift 2 ;;
        --ssh-port)     SSH_PORT="$2";     shift 2 ;;
        --ssh-user)     SSH_USER="$2";     shift 2 ;;
        --ssh-password) SSH_PASSWORD="$2"; shift 2 ;;
        --port)         HYSTERIA_PORT="$2"; shift 2 ;;
        --password)     AUTH_PASSWORD="$2"; shift 2 ;;
        --remark)       REMARK="$2";       shift 2 ;;
        --ip)           SERVER_IP="$2";    shift 2 ;;
        --help|-h)
          cat << 'HELPEOF'
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
  ```

- Step 2: Write `prompt_ssh_config()`:
  ```bash
  prompt_ssh_config() {
    echo -e "\n${BOLD}═══ SSH Connection ═══${NC}"
    [[ -z "$SSH_HOST" ]] && read -p "Server IP: " SSH_HOST
    [[ -z "$SSH_PORT" ]] && read -p "SSH Port [22]: " SSH_PORT; SSH_PORT="${SSH_PORT:-22}"
    [[ -z "$SSH_USER" ]] && read -p "SSH User [root]: " SSH_USER; SSH_USER="${SSH_USER:-root}"
    [[ -z "$SSH_PASSWORD" ]] && {
      read -r -s -p "SSH Password: " SSH_PASSWORD; echo
    }
    [[ -z "$SSH_PASSWORD" ]] && { log_error "Password cannot be empty"; exit 1; }
  }
  ```

- Step 3: Write `prompt_server_config()`:
  ```bash
  prompt_server_config() {
    echo -e "\n${BOLD}═══ Hysteria2 Configuration ═══${NC}"

    # Auto-detect public IP
    if [[ -z "$SERVER_IP" ]]; then
      SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null) || \
      SERVER_IP=$(curl -s --max-time 5 ipinfo.io/ip 2>/dev/null) || \
      SERVER_IP=""
    fi
    if [[ -z "$SERVER_IP" ]]; then
      read -p "Server public IP: " SERVER_IP
    else
      read -p "Server IP [${SERVER_IP}]: " tmp; SERVER_IP="${tmp:-$SERVER_IP}"
    fi
    [[ -z "$SERVER_IP" ]] && { log_error "Server IP required"; exit 1; }

    [[ -z "$HYSTERIA_PORT" ]] && read -p "Hysteria2 Port [443]: " HYSTERIA_PORT
    HYSTERIA_PORT="${HYSTERIA_PORT:-443}"

    [[ -z "$AUTH_PASSWORD" ]] && {
      read -r -s -p "Auth Password: " AUTH_PASSWORD; echo
    }
    [[ -z "$AUTH_PASSWORD" ]] && { log_error "Password cannot be empty"; exit 1; }

    [[ -z "$REMARK" ]] && read -p "Connection Remark [Hysteria2]: " REMARK
    REMARK="${REMARK:-Hysteria2}"
  }
  ```

- Step 4: Write `check_ports()`:
  ```bash
  check_ports() {
    log_info "Checking port availability..."
    # netcat-openbsd: separate flags -z -v -w3
    if ! ssh_exec "nc -zv -w3 localhost 80" &>/dev/null; then
      log_error "Port 80 not accessible on server."
      log_error "HTTP-01 ACME challenge requires port 80."
      log_error "Fix: ufw allow 80 / iptables -A INPUT -p tcp --dport 80 -j ACCEPT"
      exit 1
    fi
    log_ok "Port 80 is accessible"

    if ssh_exec "nc -zv -w3 localhost ${HYSTERIA_PORT}" &>/dev/null; then
      log_error "Port ${HYSTERIA_PORT} is in use. Choose another port."
      exit 1
    fi
    log_ok "Port ${HYSTERIA_PORT} is free"
  }
  ```

- Step 5: Write `check_root()`:
  ```bash
  check_root() {
    local uid
    uid=$(ssh_exec "id -u")
    [[ "$uid" != "0" ]] && { log_error "Must be root on remote server"; exit 1; }
  }
  ```

- Step 6: Write `show_banner()` — unquoted heredoc:
  ```bash
  show_banner() {
    cat << EOF

  ╔════════════════════════════════════════════════════╗
  ║        Hysteria2 Easy Setup  v${VERSION}              ║
  ║        One-command Hysteria2 + TLS + QR         ║
  ╚════════════════════════════════════════════════════╝

  EOF
  }
  ```

- Step 7: Commit
  ```bash
  git add hysteria2-easy.sh
  git commit -m "feat: add CLI argument parsing and interactive prompts"
  ```

**Verify**:
- [ ] `bash -n hysteria2-easy.sh` → no syntax errors
- [ ] `grep "nc -zv -w3" hysteria2-easy.sh` → separate flags present
- [ ] `grep "<< EOF" hysteria2-easy.sh` → heredocs unquoted

---

### 4. Write script: Hysteria2 binary installation and systemd service

**Depends on**: 3

**Files:**
- Modify: `hysteria2-easy.sh`

**What to do**:
- Step 1: Write `detect_arch()`:
  ```bash
  detect_arch() {
    local arch
    arch=$(ssh_exec "uname -m")
    case "$arch" in
      x86_64)       echo "amd64" ;;
      aarch64|arm64) echo "arm64" ;;
      *)
        log_error "Unsupported architecture: $arch"
        exit 1
        ;;
    esac
  }
  ```

- Step 2: Write `get_latest_hysteria_version()`:
  ```bash
  get_latest_hysteria_version() {
    curl -s https://api.github.com/repos/${HYSTERIA_REPO}/releases/latest | \
      grep '"tag_name"' | sed 's/.*"tag_name": "\(.*\)"/\1/'
  }
  ```

- Step 3: Write `install_hysteria_binary()`:
  ```bash
  install_hysteria_binary() {
    local arch tag url status
    arch=$(detect_arch)
    tag=$(get_latest_hysteria_version)
    # Tag format: app/v2.x.y — use full tag in download URL
    url="https://github.com/${HYSTERIA_REPO}/releases/download/${tag}/hysteria-linux-${arch}"

    log_info "Installing Hysteria2 ${tag} (${arch})..."
    ssh_exec "mkdir -p ${HYSTERIA_DIR}"

    # Verify URL exists before downloading
    status=$(ssh_exec "curl -o /dev/null -sw '%{http_code}' '${url}'")
    if [[ "$status" != "200" ]]; then
      log_error "Download failed: HTTP ${status} for ${url}"
      exit 1
    fi

    ssh_exec "curl -fSL '${url}' -o ${HYSTERIA_DIR}/hysteria && chmod +x ${HYSTERIA_DIR}/hysteria"
    ssh_exec "${HYSTERIA_DIR}/hysteria --version"
    log_ok "Hysteria2 binary installed"
  }
  ```

- Step 4: Write `create_server_config()` — YAML `listen` at root level, password escaped for YAML:
  ```bash
  create_server_config() {
    local domain yaml_password
    domain="${SERVER_IP}.nip.io"
    # Escape double quotes for YAML string quoting
    yaml_password="${AUTH_PASSWORD//\"/\\\"}"
    log_info "Creating Hysteria2 config..."
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
      url: https://web.max.ru
      rewriteHost: true
  EOF"
    log_ok "Config written to ${HYSTERIA_DIR}/config.yaml"
  }
  ```

- Step 5: Write `setup_systemd()` — unquoted heredoc, reasonable ulimit:
  ```bash
  setup_systemd() {
    local svc="/etc/systemd/system/hysteria2.service"
    log_info "Setting up systemd service..."
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
  ```

- Step 6: Commit
  ```bash
  git add hysteria2-easy.sh
  git commit -m "feat: add Hysteria2 binary install and systemd service"
  ```

**Verify**:
- [ ] `bash -n hysteria2-easy.sh` → no syntax errors
- [ ] `grep "^  listen:" hysteria2-easy.sh` → `listen` at root level (2-space indent, not under `server:`)
- [ ] `grep "LimitNOFILE=65536" hysteria2-easy.sh` → reasonable ulimit value
- [ ] `grep 'yaml_password="${AUTH_PASSWORD' hysteria2-easy.sh` → password escaped for YAML

---

### 5. Write script: ACME certificate acquisition with acme.sh + nip.io

**Depends on**: 4

**Files:**
- Modify: `hysteria2-easy.sh`

**What to do**:
- Step 1: Write `install_acme_sh()`:
  ```bash
  install_acme_sh() {
    log_info "Installing acme.sh..."
    # < /dev/null prevents interactive prompts from acme.sh installer
    ssh_exec "curl https://get.acme.sh | sh -s email=admin@\${SERVER_IP}.nip.io < /dev/null"
    log_ok "acme.sh installed"
  }
  ```

- Step 2: Write `issue_certificate()`:
  ```bash
  issue_certificate() {
    local domain="${SERVER_IP}.nip.io"
    log_info "Issuing certificate for ${domain}..."

    # Free port 80 for acme.sh standalone challenge
    ssh_exec "fuser -k 80/tcp 2>/dev/null || true"
    sleep 1

    # HTTP-01 standalone challenge — uses port 80
    ssh_exec "~/.acme.sh/acme.sh --issue -d ${domain} --standalone --httpport 80 --force"

    # Install cert to Hysteria2 paths with auto-reload
    ssh_exec "~/.acme.sh/acme.sh --install-cert -d ${domain} \
      --key-file '${CERT_DIR}/${domain}_ecc/${domain}.key' \
      --fullchain-file '${CERT_DIR}/${domain}_ecc/fullchain.cer' \
      --reloadcmd 'systemctl restart hysteria2'"

    # Verify cert exists
    local cert_path="${CERT_DIR}/${domain}_ecc/fullchain.cer"
    ssh_exec "[[ -f ${cert_path} ]]" || {
      log_error "Certificate not found: ${cert_path}"
      exit 1
    }
    log_ok "Certificate issued for ${domain}"
  }
  ```

- Step 3: Write `get_cert_fingerprint()`:
  ```bash
  get_cert_fingerprint() {
    local domain="${SERVER_IP}.nip.io"
    local cert="${CERT_DIR}/${domain}_ecc/fullchain.cer"
    # OpenSSL output: "sha256 Fingerprint=BA:A2:..." (note: SPACE, not "Fingerprint=")
    # Extract value after '=', strip colons
    ssh_exec "openssl x509 -in ${cert} -noout -fingerprint -sha256 | \
      sed 's/.*sha256 Fingerprint=//' | tr -d ':'"
  }
  ```

- Step 4: Commit
  ```bash
  git add hysteria2-easy.sh
  git commit -m "feat: add acme.sh certificate issuance with nip.io HTTP-01"
  ```

**Verify**:
- [ ] `bash -n hysteria2-easy.sh` → no syntax errors
- [ ] `grep "sha256 Fingerprint=" hysteria2-easy.sh` → space in field name
- [ ] `grep "fuser -k 80/tcp" hysteria2-easy.sh` → port 80 freed

---

### 6. Write script: QR code, URI generation, main() orchestration

**Depends on**: 5

**Files:**
- Modify: `hysteria2-easy.sh`

**What to do**:
- Step 1: Write `escape_json()` helper for JSON injection safety:
  ```bash
  escape_json() {
    # Escape backslashes first, then double quotes, then newlines
    local s="$1"
    s="${s//\\/\\\\}"   # \ → \\
    s="${s//\"/\\\"}"   # " → \"
    s="${s//$'\n'/\\n}" # literal newline → \n
    s="${s//$'\r'/\\r}" # carriage return → \r
    s="${s//$'\t'/\\t}" # tab → \t
    printf '%s' "$s"
  }
  ```

- Step 2: Write `generate_auth_json()`:
  ```bash
  generate_auth_json() {
    local password="$1"
    local escaped
    escaped=$(escape_json "$password")
    printf '{"auth_type":"password","password":"%s"}' "$escaped"
  }
  ```

- Step 3: Write `generate_uri()`:
  ```bash
  generate_uri() {
    local auth_json auth_b64 fp domain uri
    domain="${SERVER_IP}.nip.io"
    auth_json=$(generate_auth_json "$AUTH_PASSWORD")
    auth_b64=$(printf '%s' "$auth_json" | base64 | tr -d '=\n')
    fp=$(get_cert_fingerprint)
    # Hysteria2 v2 URI: sni (required for TLS), insecure=0 (verify cert), fp (pin)
    uri="hysteria2://${auth_b64}@${SERVER_IP}:${HYSTERIA_PORT}?sni=${domain}&insecure=0&fp=${fp}#${REMARK}"
    echo "$uri"
  }
  ```

- Step 4: Write `show_qr()`:
  ```bash
  show_qr() {
    local uri="$1"
    if command -v qrencode &>/dev/null; then
      echo -e "\n${BOLD}QR Code — scan with Nekobox / v2rayN:${NC}"
      qrencode -t ANSIUTF8 "$uri"
    else
      log_warn "qrencode not found. Install: sudo apt install qrencode"
    fi
  }
  ```

- Step 5: Write `show_summary()` — password masked:
  ```bash
  show_summary() {
    local uri="$1"
    local domain="${SERVER_IP}.nip.io"
    cat << EOF

  ════════════════════════════════════════════════════
     Hysteria2 Server Setup Complete!
  ════════════════════════════════════════════════════
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
  ════════════════════════════════════════════════════

  EOF
  }
  ```

- Step 6: Write `start_hysteria()`:
  ```bash
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
  ```

- Step 7: Write `main()`:
  ```bash
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
  ```

- Step 8: Commit
  ```bash
  git add hysteria2-easy.sh
  git commit -m "feat: add QR output, URI generation, and main orchestration"
  ```

**Verify**:
- [ ] `bash -n hysteria2-easy.sh` → no syntax errors
- [ ] `grep "escape_json" hysteria2-easy.sh` → JSON injection fix present
- [ ] `grep 's="${s//\\"/\\\\\\\\}"' hysteria2-easy.sh` → backslash + quote escaping present
- [ ] `grep "hysteria2://" hysteria2-easy.sh` → URI with sni, insecure, fp
- [ ] `grep "Auth:.*hidden" hysteria2-easy.sh` → password masked

---

### 7. Final verification: syntax check, shellcheck, function completeness

**Depends on**: 6

**Files:**
- `hysteria2-easy.sh`

**What to do**:
- Step 1: `bash -n hysteria2-easy.sh` → must pass.
- Step 2: `shellcheck hysteria2-easy.sh --severity=error --color=always` → fix all SC errors.
- Step 3: Verify all functions:
  ```bash
  for fn in show_banner parse_args prompt_ssh_config prompt_server_config \
    check_ports check_root ssh_exec ssh_test check_local_deps check_remote_deps \
    detect_arch get_latest_hysteria_version install_hysteria_binary \
    create_server_config setup_systemd install_acme_sh issue_certificate \
    get_cert_fingerprint escape_json generate_auth_json generate_uri \
    show_qr show_summary start_hysteria main; do
    grep -q "^${fn}()" hysteria2-easy.sh || echo "MISSING: $fn"
  done
  ```
- Step 4: Final commit
  ```bash
  git add hysteria2-easy.sh
  git commit -m "chore: final syntax verification and polish"
  ```

**Verify**:
- [ ] `bash -n hysteria2-easy.sh` → exit 0
- [ ] `shellcheck hysteria2-easy.sh` → no errors
- [ ] All 24 functions defined
- [ ] `git log --oneline` → 7 commits

