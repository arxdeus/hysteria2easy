# Hysteria2 Easy

> One-command Hysteria2 server setup with zero-config TLS + QR code.

## What it does

1. Connects to your VPS via SSH (password or interactive)
2. Installs Hysteria2 binary (latest release, amd64/arm64)
3. Issues a Let's Encrypt certificate for `<YOUR_IP>.nip.io` via HTTP-01 challenge
4. Configures and starts Hysteria2 as a systemd service
5. Outputs a ready-to-scan `hysteria2://` URI + QR code

No domain name required — nip.io provides wildcard DNS for your IP.

## Requirements

**Local machine (where you run the script):**
- Bash
- `sshpass` — `apt install sshpass` (or `brew install hudochenkov/sshpass/sshpass`)
- `qrencode` — `apt install qrencode` (for QR code output)
- `curl`

**Remote server (VPS):**
- Ubuntu / Debian
- Ports **80** and **443** open (TCP)
- Root or sudo access

## Installation

```bash
# Interactive mode (recommended for first-time use)
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/hysteria2-easy/main/hysteria2-easy.sh | bash
bash hysteria2-easy.sh

# Non-interactive / scripted mode
bash hysteria2-easy.sh \
  --ssh-host 1.2.3.4 \
  --ssh-user root \
  --ssh-password "your-password" \
  --port 443 \
  --password "your-auth-password"
```

## CLI Options

| Option | Description | Default |
|--------|-------------|---------|
| `--ssh-host` | Server IP address | prompted |
| `--ssh-port` | SSH port | 22 |
| `--ssh-user` | SSH username | root |
| `--ssh-password` | SSH password | prompted |
| `--port` | Hysteria2 listening port | 443 |
| `--password` | Authentication password | prompted |
| `--remark` | Connection remark/label | Hysteria2 |
| `--ip` | Server public IP | auto-detected |
| `--help, -h` | Show help | — |

## How it works

```
1. Detect public IP via ifconfig.me
2. Generate nip.io domain: <IP>.nip.io
3. HTTP-01 ACME challenge on port 80 → Let's Encrypt certificate
4. Hysteria2 config with TLS cert + password auth
5. Systemd service with auto-restart
6. hysteria2:// URI + QR code output
```

## Example output

```
  ════════════════════════════════════════════════════
     Hysteria2 Server Setup Complete!
  ════════════════════════════════════════════════════
    Server IP:    1.2.3.4
    Domain:       1.2.3.4.nip.io
    Port:         443
    Auth:         [hidden]

    hysteria2:// URI:
    hysteria2://eyJ...@1.2.3.4:443?sni=1.2.3.4.nip.io&insecure=0&fp=...#Hysteria2

    ─── Server Commands ───────────────────────────────
    Status:       systemctl status hysteria2
    Logs:         journalctl -u hysteria2 -f --no-pager
    Config:       /etc/hysteria2/config.yaml
  ════════════════════════════════════════════════════

  QR Code — scan with Nekobox / v2rayN:
  ┌──────────────────────┐
  │ ████████████████████ │
  │ ████████████████████ │
  └──────────────────────┘
```

## Client Setup

### Android: Nekobox / v2rayNG
1. Open the app
2. Import → Scan QR code (or paste URI manually)
3. Enable TLS verification (insecure=0)
4. Connect

### Client Configuration (manual)
```json
{
  "server": "1.2.3.4:443",
  "auth": "your-password",
  "tls": {
    "sni": "1.2.3.4.nip.io",
    "insecure": false
  }
}
```

## Troubleshooting

### "Port 80 is not accessible"
```bash
# On the server:
sudo ufw allow 80
sudo ufw allow 443
# Or for iptables:
sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
```

### "Certificate issuance failed"
- Ensure port 80 is open and reachable from the internet
- Ensure no other service is running on port 80
- Check server firewall: `sudo ufw status`

### "SSH connection refused"
- Verify the server IP and SSH port
- Try with: `ssh -p PORT user@IP` manually first
- Ensure PasswordAuthentication is enabled on the server

### "Certificate fingerprint is empty"
- The certificate may not have been issued yet
- Check logs: `journalctl -u hysteria2 -n 50 --no-pager`
- Check cert files: `ls /root/.acme.sh/<IP>.nip.io_ecc/`

### Certificate renewal
Certificates auto-renew via acme.sh cron job. No manual action needed.
To check renewal cron: `sudo crontab -l | grep acme`

### Uninstall
```bash
# On the server:
sudo systemctl stop hysteria2
sudo systemctl disable hysteria2
sudo rm /etc/systemd/system/hysteria2.service
sudo rm -rf /etc/hysteria2
sudo ~/.acme.sh/acme.sh --remove
```

## License

MIT
