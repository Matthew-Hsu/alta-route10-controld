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
- **Quick reconfigure**: change protocol, resolver, or policies without re-running setup
- **Forced DNS**: hijack all outbound DNS (port 53 + 853) so smart TVs and IoT devices can't bypass ControlD
- **Built-in test suite**: 70+ tests covering all functions, run locally or on-router

## Supported Protocols

| Type | Protocol | Transport | Port | ISP-blockable? | Default |
|------|----------|-----------|------|----------------|---------|
| `doh3` | DNS-over-HTTPS/3 | HTTP/3 (QUIC) | 443 | No (looks like HTTPS) | Yes |
| `doq` | DNS-over-QUIC | QUIC | 853 | **Yes** (some ISPs/mobile nets) | |
| `doh` | DNS-over-HTTPS/2 | HTTP/2 | 443 | No (looks like HTTPS) | |
| `dot` | DNS-over-TLS | TCP+TLS | 853 | **Yes** (some ISPs/mobile nets) | |

DoH3 and DoQ use the QUIC protocol (UDP-based) which eliminates TCP head-of-line blocking and reduces connection setup latency compared to DoH over HTTP/2. **Port matters for reliability:** 443 (DoH3/DoH) blends with normal HTTPS and is almost never blocked, while 853 (DoQ/DoT) is a dedicated DNS port that some networks block — so the automatic fallback chain only ever targets 443 protocols (DoH3 ↔ DoH).

## Architecture

```
LAN Devices
    |
    v (port 53 / port 853)
iptables REDIRECT (forced DNS)
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
- [ControlD](https://controld.com) account with a resolver id
- SSH access to the router (add your key at [manage.alta.inc](https://manage.alta.inc) > Settings > System > SSH Keys)
- `aarch64` architecture (default for Route 10)

## Quick Start

```sh
# SSH into your router and run:
wget -O /tmp/setup.sh https://codeberg.org/CookieTyrant/alta-route10-controld/raw/branch/master/setup.sh
sh /tmp/setup.sh
```

The installer will:
1. Prompt for your **Resolver ID** (from your ControlD dashboard)
2. Offer guided **protocol selection** with descriptions of each option
3. Optionally run an **inline benchmark** to auto-detect the fastest protocol
4. Handle everything else: binary download, config generation, iptables, cron jobs

### Non-Interactive Setup

```sh
sh setup.sh --resolver abc123 --protocol doh3
```

## Scripts

| Script | Purpose | Key Flags |
|---|---|---|
| `setup.sh` | Interactive installer with guided protocol selection and inline benchmark | `--help` `--version` `--protocol <type>` `--resolver <id>` |
| `status.sh` | Health check: services, upstreams, policies, watchdog activity | `--help` |
| `reconfigure.sh` | Change protocol, resolver, or policies without re-running setup | `--help` `--show` `--protocol` `--resolver` `--benchmark` `--policy` `--force-dns` `--to <value>` `--force` |
| `benchmark.sh` | Test DNS query latency across DoQ, DoH3, and DoH | `--help` `--queries N` |
| `watchdog.sh` | 5-min health monitor with automatic protocol fallback | `--help` `--dry-run` |
| `uninstall.sh` | Removes everything, restores default DNS | `--help` `--force` |
| `test.sh` | Comprehensive test suite (70+ tests) | — |

Every script supports `--help` with full usage documentation.

## What Gets Installed

| File | Purpose |
|---|---|
| `/cfg/controld.env` | Resolver ID, version, bootstrap IP, protocol type, preferred protocol, forced-DNS flag |
| `/cfg/ctrld` | DNS proxy binary (arm64) |
| `/cfg/ctrld.toml` | DNS proxy config (upstreams, policies, routing rules) |
| `/cfg/lib.sh` | Shared function library used by all scripts |
| `/cfg/rc.local` | Boot persistence hook (sourced by `/etc/rc.local`) |
| `/cfg/post-cfg.sh` | Self-healing boot script |
| `/cfg/controld-update.sh` | Weekly auto-update script |
| `/cfg/watchdog.sh` | 5-min health check with protocol fallback |
| `/cfg/benchmark.sh` | Protocol benchmark tool |
| `/cfg/reconfigure.sh` | Quick reconfiguration tool |
| `/cfg/status.sh` | Status reporting tool |

## Key Features

### Guided Protocol Selection

During setup, each protocol is presented with detailed information:

```
  1) DoH3 (HTTP/3)   — Port 443, UDP/QUIC. Stealthy, fast, widely compatible.
  2) DoQ  (QUIC)     — Port 853, UDP/QUIC. Dedicated DNS port, lower overhead.
  3) DoH  (HTTP/2)   — Port 443, TCP+TLS. Most compatible fallback.
  4) Benchmark       — Test all protocols and auto-select the fastest.
```

Option 4 runs a quick benchmark (10 queries per protocol) and automatically configures the winner.

### Quick Reconfigure

Change your setup without re-running the full installer:

```sh
# See current configuration
sh reconfigure.sh --show

# Switch protocol
sh reconfigure.sh --protocol --to doq

# Switch with interactive menu
sh reconfigure.sh --protocol

# Change resolver
sh reconfigure.sh --resolver --to abc123

# Benchmark and auto-apply fastest
sh reconfigure.sh --benchmark --force

# Manage split DNS policies
sh reconfigure.sh --policy

# Toggle forced DNS hijacking
sh reconfigure.sh --force-dns

# Interactive menu (no flags)
sh reconfigure.sh
```

### Boot Persistence

`/cfg/` is a persistent ext4 partition on the Alta Labs Route 10 that survives firmware updates and reboots. The router's built-in `/etc/rc.local` sources `/cfg/rc.local` on every boot, which:

1. Runs `post-cfg.sh` — starts ctrld, restores iptables redirect rules, configures fallback DNS
2. Reinstalls cron jobs — adds watchdog (5-min) and auto-update (weekly) to crontab, since crontab lives in `/etc/` and may be wiped by firmware updates
3. Writes `firewall.user` rules — ensures iptables redirects survive mid-session firewall restarts

After a firmware update or reboot, ControlD is fully operational within ~30 seconds. No manual intervention required.

### Self-Healing

`post-cfg.sh` runs on every boot and:

1. Re-downloads the `ctrld` binary if missing
2. Regenerates `ctrld.toml` from `/cfg/controld.env` if missing
3. Configures `https-dns-proxy` as a fallback
4. Starts `ctrld` on port 5354
5. Health checks before adding iptables redirect rules
6. Restores forced-DNS state (uci + port-853 rules + firewall.user) if `FORCED_DNS=1`
7. If `ctrld` fails, keeps `https-dns-proxy` as the DNS backend

### Auto-Update

A cron job runs weekly (Monday 3 AM) to check for new `ctrld` releases and update automatically.

### Watchdog (Health Monitor)

`watchdog.sh` runs every 5 minutes via cron and:

1. Checks if `ctrld` is running — restarts if dead
2. Tests DNS resolution through `ctrld`
3. If DNS is healthy, self-heals forced-DNS state, warns if `dhcp.leases` is stale, and **self-upgrades back to your preferred protocol** if currently on a fallback
4. If DNS fails, **waits for a second consecutive failure** before acting (debounce — avoids restarting ctrld or churning the protocol on a single transient blip)
5. Restores iptables redirect rules if they disappeared
6. Logs all actions to syslog

Protocol fallback is automatic but debounced — transient blips are ignored; a sustained failure (2 consecutive checks) triggers the fallback chain. **The chain is 443-only** (`DoH3 ↔ DoH`) — it never falls *back to* the blockable 853 protocols (DoQ/DoT), though those can still be your primary. The debounce threshold is `FAIL_THRESHOLD` (default 2).

**Self-upgrade / preferred protocol:** the protocol chosen at setup (or via `reconfigure.sh --protocol`/`--benchmark`) is stored as `PREFERRED_PROTOCOL`. If the watchdog ever falls back to a different protocol, it periodically (every ~30 min) re-tests the preferred one on a throwaway port and switches back automatically once it's healthy again — so a transient outage doesn't permanently leave you on a slower fallback. `status.sh` shows both the active and preferred protocol.

Use `--dry-run` to check health without making changes:

```sh
sh watchdog.sh --dry-run
```

### Split DNS and Per-Device Policy

During setup or via `reconfigure.sh --policy`, configure multiple ControlD resolver profiles and route traffic by:

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

### Forced DNS Hijacking

Smart TVs (Panasonic, Samsung, LG), IoT devices, and some browsers can bypass the router's DHCP DNS setting by using hardcoded DNS servers or DNS-over-TLS (DoT, port 853). Forced DNS intercepts all outbound DNS and redirects it through ControlD.

```sh
# Enable (interactive prompt)
sh reconfigure.sh --force-dns

# Enable non-interactively
sh reconfigure.sh --force-dns --force

# Check current state
sh status.sh   # shows forced DNS status and DoT hijack rules
```

When enabled:
- **Port 53** (plain DNS) — redirected to ControlD via iptables
- **Port 853** (DoT) — redirected to ControlD via iptables
- State is recorded as `FORCED_DNS=1` in `/cfg/controld.env` (the persistent source of truth)
- **Self-healing persistence** — the uci config, port-853 iptables rules, and `/etc/firewall.user` entries are restored automatically: at boot by `post-cfg.sh`, every 5 minutes by `watchdog.sh`, and instantly on firewall reload via `firewall.user`. This survives reboots **and** firmware updates (which can wipe `/etc/config`).
- `status.sh` reports the forced DNS state and active hijack rules

**Note:** DNS-over-HTTPS (DoH, port 443) cannot be redirected without breaking all HTTPS traffic. Most TVs and IoT devices use DoT rather than DoH, so forced DNS catches the majority of bypass attempts.

### Benchmark

Run `benchmark.sh` on the router to test which DNS protocol performs best on your connection:

```sh
sh benchmark.sh              # default: 15 queries per protocol
sh benchmark.sh --queries 30 # more queries for accuracy
```

Tests DoQ, DoH3, and DoH with real DNS lookups on a separate port (5360) so production DNS is not disrupted. Outputs a formatted table and recommends the fastest protocol.

### Test Suite

Run `test.sh` to verify everything works:

```sh
sh test.sh    # works locally and on-router
```

**Unit tests** (run everywhere):
- Endpoint URL generation for all protocols
- Protocol labels and fallback chain ordering
- Input validation (resolver IDs, MACs, CIDRs, protocols)
- TOML config generation
- Env file parsing with defaults
- `--help` and `--version` flags on all scripts
- Invalid input rejection

**Integration tests** (run on-router only):
- DNS resolution through ctrld
- ctrld process running
- iptables redirect rules present
- Cron jobs installed
- Self-healing config regeneration
- Watchdog dry-run
- Benchmark completion

## Shared Library

All scripts source `lib.sh` which provides:

- Colored output helpers (`print_ok`, `print_fail`, `print_warn`, `print_info`)
- Config generation (`write_ctrld_config`, `get_endpoint`)
- Process management (`start_ctrld`, `stop_ctrld`, `restart_ctrld`)
- Health checks (`check_dns`, `ensure_iptables`, `check_port_in_use`)
- Forced DNS (`ensure_forced_dns`, `disable_forced_dns`, `set_forced_dns_flag`)
- Input validation (`valid_resolver`, `valid_mac`, `valid_cidr`, `valid_proto`)
- Protocol utilities (`proto_label`, `next_proto`)

## Fallback Safety

Two layers of protection:

1. **ctrld health check** — iptables redirect rules are only added if ctrld passes a DNS resolution test
2. **https-dns-proxy fallback** — even if ctrld fails, dnsmasq still forwards to https-dns-proxy which routes to ControlD. DNS stays encrypted, just without per-device visibility.

## Manual Setup

If you prefer not to use the automated installer, see `config/ctrld.toml.example` and `config/post-cfg.sh.example`. Replace `<YOUR_RESOLVER_ID>` in both files, upload to `/cfg/`, and run `post-cfg.sh`.

## Firmware Updates

**Automatic recovery:** Firmware updates typically preserve `/cfg/` (persistent ext4 partition). The boot persistence layer (`/cfg/rc.local`) automatically restores all services, cron jobs, and iptables rules on reboot. No manual intervention needed.

**If `/cfg/` is wiped** (rare, but possible on major updates), restore from backup:

```sh
scp controld.env ctrld ctrld.toml post-cfg.sh root@<router-ip>:/cfg/
ssh root@<router-ip> "chmod +x /cfg/ctrld /cfg/post-cfg.sh && /cfg/post-cfg.sh"
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

## CI

CI runs via Forgejo Actions on every push/PR to `master`. (Codeberg is a backup mirror and does not run CI.)

1. **shellcheck** — lints all shell scripts (`.forgejo/workflows/ci.yml`)
2. **test suite** — runs `test.sh` (unit tests; integration tests run only on-router)
3. **gitleaks** + **betterleaks** — scan for leaked secrets (`ci.yml` + `secrets-scan.yml`)

## Credits

- [ControlD](https://controld.com) — DNS resolver service
- [ctrld](https://github.com/Control-D-Inc/ctrld) — DNS forwarding proxy
- [Alta Labs](https://alta.inc) — Route 10 router

## License

MIT
