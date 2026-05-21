# Alta Labs Route 10 + ControlD DNS

Encrypted DNS with per-device visibility on the Alta Labs Route 10 router using [ControlD](https://controld.com) and the [ctrld](https://github.com/Control-D-Inc/ctrld) daemon.

## What This Does

- Routes all DNS traffic through ControlD via encrypted DNS (DoH, DoH3, or DoQ)
- **DoH3 (HTTP/3)** default — uses QUIC transport for faster handshakes and lower latency
- Shows individual device hostnames and IPs in the ControlD dashboard
- Self-healing: survives reboots, auto-downloads missing binaries
- Falls back to `https-dns-proxy` if `ctrld` fails to start
- **Watchdog**: 5-minute health check with automatic protocol fallback
- **Split DNS**: route different devices/networks to different ControlD profiles
- **Per-device policy**: assign specific MAC addresses to filtered DNS resolvers
- **Benchmark tool**: test which protocol is fastest on your ISP

## Supported Protocols

| Type | Protocol | Transport | Default |
|------|----------|-----------|---------|
| `doh3` | DNS-over-HTTPS/3 | HTTP/3 (QUIC) | Yes |
| `doq` | DNS-over-QUIC | QUIC | |
| `doh` | DNS-over-HTTPS/2 | HTTP/2 | |
| `dot` | DNS-over-TLS | TCP+TLS | |

DoH3 and DoQ use the QUIC protocol (UDP-based) which eliminates TCP head-of-line blocking and reduces connection setup latency compared to DoH over HTTP/2.

## Architecture

```
LAN Devices
    |
    v (port 53)
iptables REDIRECT
    |
    v (port 5354)
+----------+  DoH3/DoQ/DoH  +-----------+
|  ctrld   | --------------> | ControlD  |
|  :5354   |    (QUIC)       |  DoH API  |
+----------+                 +-----------+
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

The installer will prompt for:
- **Resolver ID** — from your ControlD dashboard
- **Bootstrap IP** — defaults to `76.76.2.22`
- **Protocol** — choose DoH3 (HTTP/3), DoQ (QUIC), or DoH (HTTP/2)

It handles everything else: downloading the binary, writing configs, setting up iptables redirects, and installing a weekly auto-update cron job.

## Scripts

| Script | Purpose |
|---|---|
| `setup.sh` | Interactive installer with protocol selection and split DNS setup |
| `status.sh` | Health check. Shows services, upstreams, policies, watchdog activity. |
| `benchmark.sh` | Test DNS query latency across DoQ, DoH3, and DoH. |
| `uninstall.sh` | Removes everything. Restores default DNS. |

## What Gets Installed

| File | Purpose |
|---|---|
| `/cfg/controld.env` | Resolver ID, version, bootstrap IP, protocol type |
| `/cfg/ctrld` | DNS proxy binary (arm64) |
| `/cfg/ctrld.toml` | DNS proxy config (upstreams, policies, routing rules) |
| `/cfg/post-cfg.sh` | Self-healing boot script |
| `/cfg/controld-update.sh` | Weekly auto-update script |
| `/cfg/watchdog.sh` | 5-min health check with protocol fallback |

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

### Watchdog (Health Monitor)

`watchdog.sh` runs every 5 minutes via cron and:

1. Checks if `ctrld` is running — restarts if dead
2. Tests DNS resolution through `ctrld`
3. If DNS fails, tries the next protocol in the fallback chain (DoQ -> DoH3 -> DoH)
4. Restores iptables redirect rules if they disappeared
5. Logs all actions to syslog

Protocol fallback is automatic — if your ISP blocks port 853 (DoQ), the watchdog switches to DoH3 or DoH within minutes.

### Split DNS & Per-Device Policy

During setup, you can configure multiple ControlD resolver profiles and route traffic by:

- **Network/subnet** — e.g. route `192.168.2.0/24` to a filtered resolver
- **MAC address** — e.g. route a kid's device to a safe-search resolver
- **Both** — combine network and device rules

Example config with per-device routing:

```toml
[upstream.0]
    name = "ControlD-Unfiltered"
    endpoint = "https://dns.controld.com/abc123"
    type = "doq"

[upstream.1]
    name = "ControlD-Kids"
    endpoint = "https://dns.controld.com/xyz789"
    type = "doq"

[listener.0.policy]
    macs = [
        {"AA:BB:CC:DD:EE:01" = ["upstream.1"]},
        {"AA:BB:CC:DD:EE:02" = ["upstream.1"]},
    ]
```

### Benchmark

Run `benchmark.sh` on the router to test which DNS protocol performs best on your connection:

```sh
sh benchmark.sh
```

Tests DoQ, DoH3, and DoH with 15 queries each and recommends the fastest.

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
