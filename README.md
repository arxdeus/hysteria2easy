# Hysteria2 Easy Setup

One-command [Hysteria2](https://github.com/apernet/hysteria) server deployment over SSH — with automatic TLS certificates and a QR code for instant mobile connection.

```
bash hysteria2easy.sh
```

## What it does

1. Connects to your VPS via SSH
2. Installs Hysteria2 binary (latest release)
3. Obtains a free TLS certificate from Let's Encrypt (via [acme.sh](https://github.com/acmesh-official/acme.sh))
4. Generates server config + systemd service
5. Starts the server
6. Outputs a `hysteria2://` URI and a QR code — scan it with your client and go

## Requirements

### Local machine (where you run the script)

| Tool | Install |
|------|---------|
| `sshpass` | `brew install sshpass` / `apt install sshpass` |
| `qrencode` | `brew install qrencode` / `apt install qrencode` |
| `curl` | pre-installed on most systems |

### Remote server (VPS)

- Linux (amd64 or arm64)
- Root access via SSH with password
- **Port 80 open** — required for ACME HTTP-01 certificate challenge
- **Port 443 open** (or custom) — Hysteria2 listening port

## Usage

### Interactive mode

```bash
bash hysteria2easy.sh
```

You'll be prompted for:
- **Server IP** — your VPS IP address
- **SSH password**
- **Auth password** — the password clients use to connect

Everything else has sensible defaults (port 22, root, port 443).

### CLI mode (non-interactive)

```bash
bash hysteria2easy.sh \
  --ssh-host 1.2.3.4 \
  --ssh-password 'my-ssh-pass' \
  --password 'my-auth-pass' \
  --port 443 \
  --remark 'My VPN'
```

### All options

| Flag | Description | Default |
|------|-------------|---------|
| `--ssh-host` | Server IP | prompted |
| `--ssh-port` | SSH port | `22` |
| `--ssh-user` | SSH user | `root` |
| `--ssh-password` | SSH password | prompted |
| `--port` | Hysteria2 listen port | `443` |
| `--password` | Client auth password | prompted |
| `--ip` | Override server public IP | `ssh-host` value |
| `--remark` | Connection name | `Hysteria2` |

## Client setup

Scan the QR code or copy the `hysteria2://` URI into any compatible client:

| Platform | Client |
|----------|--------|
| Android | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid), [Hiddify](https://github.com/hiddify/hiddify-app) |
| iOS | [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118), [Stash](https://apps.apple.com/app/stash/id1596063349) |
| Windows | [v2rayN](https://github.com/2dust/v2rayN), [NekoRay](https://github.com/MatsuriDayo/nekoray) |
| macOS | [NekoRay](https://github.com/MatsuriDayo/nekoray), [Hiddify](https://github.com/hiddify/hiddify-app) |
| Linux | [NekoRay](https://github.com/MatsuriDayo/nekoray), [Hysteria2 CLI](https://github.com/apernet/hysteria) |

## Server management

After setup, run these on your VPS:

```bash
# Check status
systemctl status hysteria2

# View logs
journalctl -u hysteria2 -f --no-pager

# Restart
systemctl restart hysteria2

# Stop
systemctl stop hysteria2

# Config location
cat /etc/hysteria2/config.yaml
```

## Re-running the script

Running the script again on the same server is safe — it will:
- Stop the existing Hysteria2 service
- Re-download the latest binary
- Re-issue the TLS certificate
- Overwrite the config and restart

## TLS certificates

- Certificates are issued by **Let's Encrypt** via `acme.sh`
- Valid for **90 days**, auto-renewed via cron
- Stored at `/root/.acme.sh/<ip>.nip.io_ecc/`
- On renewal, Hysteria2 restarts automatically

## How it works

The script uses [nip.io](https://nip.io) for automatic DNS — `1.2.3.4.nip.io` resolves to `1.2.3.4`. This lets us get a real TLS certificate without owning a domain.

Traffic masquerades as HTTPS to `web.max.ru`, making the connection look like normal web browsing.

## License

MIT — [Artemis Kushner](https://github.com/arxdeus) © 2026
