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

---

## Alternative: VLESS + Reality (`vlessreality.sh`)

Hysteria2 is UDP-only. In networks where UDP/QUIC is throttled or dropped
(common under IP-whitelist filtering), it cannot work at all. `vlessreality.sh`
deploys VLESS + Reality instead:

```bash
bash vlessreality.sh --ssh-host <IP> --dest www.microsoft.com
```

### Why it survives DPI

| | Hysteria2 | VLESS + Reality |
|---|---|---|
| Transport | UDP/QUIC (blocked first) | **TCP/443** (looks like normal HTTPS) |
| Certificate | own (self-signed / ACME) | **the real certificate of `--dest`** |
| Own domain | needed for ACME | **not needed** |
| Inbound TCP/80 | needed for ACME | **not needed** |
| Active probing | reveals a proxy | forwards to the real site, indistinguishable |

Reality terminates only authenticated clients; anyone else (including a
censor's prober) is transparently proxied to `--dest`, so the server behaves
exactly like a mirror of that site.

### Under RU whitelist filtering, read this first

The Russian TSPU whitelist mode ("белые списки") filters on **two layers**
([measurements](https://habr.com/ru/articles/1027276/),
[data](https://github.com/openlibrecommunity/twl)):

- **L3:** packets to any IP outside the allowed CIDR list are dropped silently.
  ~63k IPs out of 46M Russian addresses pass, i.e. **0.14%**.
- **L7:** for allowed IPs, the SNI in the ClientHello is inspected;
  blacklisted SNI values get an RST.
- **Ports:** only TCP **80 / 443 / 22** pass. Nearly all UDP is dropped —
  QUIC, WireGuard, and external DNS (UDP:53) included.

Two consequences that override any configuration tuning:

1. **A foreign VPS cannot work at all.** Hetzner, DigitalOcean, Oracle: the IP
   is not in the whitelist, so packets never leave the operator's network.
   The server must sit on a whitelisted Russian IP — Yandex.Cloud (which alone
   holds ~1/5 of all whitelisted addresses), Timeweb, VK Cloud, Selectel,
   Beget, REG.RU.
2. **Hysteria2 cannot work at all**, being UDP-only. Neither obfuscation nor
   port hopping helps: the drop happens before DPI ever runs.

### Choosing `--dest`

The requirement is not "a popular site" but **"a domain whose SNI is
explicitly allowed"**. Test the built-in candidates against your server:

```bash
bash vlessreality.sh --ssh-host <IP> --scan-dest
```

Known-good whitelisted SNI: `yastatic.net`, `storage.yandex.net`,
`userapi.com`, `vkuser.net`, `vkuservideo.ru`, `cdnvideo.ru`, `okcdn.ru`,
`hosting.reg.ru`.

**Never** use `twitter.com`, `x.com`, `youtube.com` or `telegram.org` — those
SNI values are actively checked and reset. The script refuses them outright.

Whitelists differ per operator, region, and even per cell tower, and they
change weekly. If one dest stops working for your clients, try the next.

`fp=chrome` is included in the generated URI and is mandatory: the ordinary
TSPU still fingerprints TLS on top of the whitelist layer, so Reality without
a browser fingerprint is detectable.

### Clients

v2rayNG, Nekobox, Streisand, Hiddify, sing-box, FoXray. Scan the QR code or
paste the `vless://` URI. No `insecure` flag is needed.
