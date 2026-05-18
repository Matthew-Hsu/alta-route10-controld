# Alta Labs Route 10 + ControlD DNS

Encrypted DNS-over-HTTPS with per-device visibility on the Alta Labs Route 10 router using [ControlD](https://controld.com) and the [ctrld](https://github.com/Control-D-Inc/ctrld) daemon.

## What This Does

- Routes all DNS traffic through ControlD via encrypted DoH
- Shows individual device hostnames and IPs in the ControlD dashboard
- Self-healing: survives reboots, auto-downloads missing binaries
- Falls back to `https-dns-proxy` if `ctrld` fails to start

## Architecture

```
LAN Devices
    |
    v (port 53)
iptables REDIRECT
    |
    v (port 5354)
+----------+     DoH      +-----------+
|  ctrld   | -----------> | ControlD  |
|  :5354   |              |  DoH API  |
+----------+              +-----------+
    ^ sends client
    | IP/hostname/MAC
    |
+----------+
| dnsmasq  | (fallback: port 5053/5054/5055)
|  :53     | --> https-dns-proxy --> ControlD
+----------+
```

## Prerequisites

- Alta Labs Route 10 router
- [ControlD](https://controld.com) account with a resolver ID
- SSH access to the router (add your key at [manage.alta.inc](https://manage.alta.inc) > Settings > System > SSH Keys)
- `aarch64` architecture (default for Route 10)

## Quick Start

```sh
# SSH into your router and run:
wget -O /tmp/setup.sh https://codeberg.org/CookieTyrant/alta-route10-controld/raw/branch/master/setup.sh
sh /tmp/setup.sh
```

The installer will prompt for your resolver ID (from the ControlD dashboard) and handle everything else: downloading the binary, writing configs, setting up iptables redirects, and installing a weekly auto-update cron job.

## Scripts

| Script | Purpose |
|---|---|
| `setup.sh` | Interactive installer. Run once on the router. |
| `status.sh` | Health check. Shows service status, DNS resolution, iptables rules. |
| `uninstall.sh` | Removes everything. Restores default DNS. |

## What Gets Installed

| File | Purpose |
|---|---|
| `/cfg/controld.env` | Resolver ID, version, bootstrap IP |
| `/cfg/ctrld` | DNS proxy binary (arm64) |
| `/cfg/ctrld.toml` | DNS proxy config |
| `/cfg/post-cfg.sh` | Self-healing boot script |
| `/cfg/controld-update.sh` | Weekly auto-update script |

### Self-Healing

`post-cfg.sh` runs on every boot and:

1. Re-downloads the `ctrld` binary if missing
2. Regenerates `ctrld.toml` from `/cfg/controld.env` if missing
3. Configures `https-dns-proxy` as a fallback
4. Starts `ctrld` on port 5354
5. Health checks before adding iptables redirect rules
6. If `ctrld` fails, keeps `https-dns-proxy` as the DNS backend

### Auto-Update

A cron job runs weekly (Monday 3 AM) to check for new `ctrld` releases and update automatically.

## Fallback Safety

Two layers of protection:

1. **ctrld health check** -- iptables redirect rules are only added if ctrld passes a DNS resolution test
2. **https-dns-proxy fallback** -- even if ctrld fails, dnsmasq still forwards to https-dns-proxy which routes to ControlD. DNS stays encrypted, just without per-device visibility.

## Manual Setup

If you prefer not to use the automated installer, see `config/ctrld.toml.example` and `config/post-cfg.sh.example`. Replace `<YOUR_RESOLVER_ID>` in both files, upload to `/cfg/`, and run `post-cfg.sh`.

## Firmware Updates

Firmware updates may wipe `/cfg/`. After updating, re-run `setup.sh` or restore your backed-up files:

```sh
scp controld.env ctrld ctrld.toml post-cfg.sh root@<router-ip>:/cfg/
ssh root@<router-ip> "chmod +x /cfg/ctrld /cfg/post-cfg.sh && /cfg/post-cfg.sh"
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Credits

- [ControlD](https://controld.com) -- DNS resolver service
- [ctrld](https://github.com/Control-D-Inc/ctrld) -- DNS forwarding proxy
- [Alta Labs](https://alta.inc) -- Route 10 router

## License

MIT
