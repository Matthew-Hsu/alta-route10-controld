# Alta Labs Route 10 + ControlD DNS

Encrypted DNS with per-device visibility on the Alta Labs Route 10 router using [ControlD](https://controld.com) and the [ctrld](https://github.com/Control-D-Inc/ctrld) daemon.

> **This is a fork.** The original project was created by **CookieTyrant** at
> [codeberg.org/CookieTyrant/alta-route10-controld](https://codeberg.org/CookieTyrant/alta-route10-controld)
> and has since been archived. All of the design — the self-healing boot hooks, the
> watchdog with protocol fallback, split DNS policies, the forced-DNS hijack — is
> their work. This fork exists to keep it maintained; see the commit history for
> what has changed since.

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
- **Built-in test suite**: unit tests run anywhere, integration tests on-router, both under GNU and BusyBox awk

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
wget -O /tmp/setup.sh https://raw.githubusercontent.com/Matthew-Hsu/alta-route10-controld/master/setup.sh
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

## Common Workflows

Every command below is run over SSH on the router. After install the scripts
live in `/cfg/`; before install, run them from wherever you unpacked the repo.

### Install

```sh
wget -O /tmp/setup.sh https://raw.githubusercontent.com/Matthew-Hsu/alta-route10-controld/master/setup.sh
sh /tmp/setup.sh                                   # interactive
sh /tmp/setup.sh --resolver abc123 --protocol doh3 # non-interactive
```

Re-running `setup.sh` over an existing install is safe: it preserves your
forced-DNS choice and resolver, and re-downloads only what is missing.

### Verify an install

Two questions, two tools. Run both after installing, and after any firmware
update or reboot you want to be sure about.

```sh
sh /cfg/status.sh    # is it working?  services, DNS, per-bridge coverage, cron
sh /cfg/audit.sh     # is it clean?    duplicates, stale references, leftovers
```

`status.sh` confirms the redirect rules exist. `audit.sh` goes further and
reports how many packets each bridge has actually redirected — rules can be
present and still never match. A VLAN with active devices and zero packets is
the one to investigate; an idle VLAN reading zero is expected.

`audit.sh` opens with the versions actually on the router. Because it can be
run from a checkout in `/tmp` as well as from `/cfg`, it compares the library
it sourced against the one installed and says so when they differ — an audit
that silently describes a version the router is not running is worse than no
audit.

`audit.sh` exits non-zero when it finds drift, so it can gate a script:

```sh
sh /cfg/audit.sh >/dev/null || echo "drift found — run it again for detail"
sh /cfg/audit.sh --raw    # add crontab, firewall.user, uci and nat dumps
```

If it reports rules for a bridge that no longer exists, or a bridge with no
rules, `sh /cfg/reconfigure.sh --repair` re-applies coverage and prunes the
stale entries.

### Change the resolver ID

```sh
sh /cfg/reconfigure.sh --resolver --to <new-id>
```

This rewrites `ctrld.toml` and `controld.env`, preserves any split-DNS policy,
moves the `https-dns-proxy` fallback onto the same new profile, restarts
`ctrld`, and checks DNS before returning. Confirm with `sh /cfg/status.sh`,
then delete the old profile in the ControlD dashboard — until you do, the old
ID keeps resolving for anyone who has it.

### Change protocol

```sh
sh /cfg/reconfigure.sh --protocol --to doh3   # or doq, doh, dot
sh /cfg/benchmark.sh                          # measure first
sh /cfg/reconfigure.sh --benchmark --force    # measure, then apply the winner
```

### Uninstall

```sh
sh /cfg/uninstall.sh            # --force skips the confirmation
```

It verifies its own removal on the way out. Audit it independently by running
`audit.sh` from a repo checkout rather than `/cfg` — uninstall removes `/cfg`
entirely, `lib.sh` included, so the installed copy is gone by then:

```sh
sh /tmp/controld/audit.sh
```

**Before a factory reset, uninstall first** — see [Uninstalling](#uninstalling).

## Scripts

| Script | Purpose | Key Flags |
|---|---|---|
| `setup.sh` | Interactive installer with guided protocol selection and inline benchmark | `--help` `--version` `--protocol <type>` `--resolver <id>` |
| `status.sh` | Health check: services, upstreams, policies, watchdog activity | `--help` |
| `reconfigure.sh` | Change protocol, resolver, or policies without re-running setup | `--help` `--show` `--protocol` `--resolver` `--benchmark` `--policy` `--force-dns` `--repair` `--to <value>` `--force` |
| `benchmark.sh` | Test DNS query latency across DoQ, DoH3, and DoH | `--help` `--queries N` |
| `audit.sh` | Read-only drift check: installed versions, duplicates, stale references, leftovers, packets actually intercepted | `--help` `--raw` |
| `uninstall.sh` | Removes everything, restores default DNS | `--help` `--force` |
| `test.sh` | Test suite: unit tests anywhere, integration tests on-router | — |

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
| `/cfg/audit.sh` | Drift and leftover audit |
| `/cfg/uninstall.sh` | Uninstaller |

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

# Re-apply DNS redirects to every LAN bridge (picks up new VLANs)
sh reconfigure.sh --repair

# Interactive menu (no flags)
sh reconfigure.sh
```

### VLAN Coverage

Per-device visibility depends on DNS being intercepted on every LAN bridge. Alta
names the default LAN bridge `br-lan` and each VLAN `br-lan_<vlan-id>`
(`br-lan_10`, `br-lan_20`, …), so the bridge list is discovered at runtime — a
VLAN added after install is picked up by the watchdog within 5 minutes.

```sh
sh status.sh                  # per-bridge redirect coverage + subnets
sh reconfigure.sh --repair    # re-apply redirects, and prune rules for bridges that no longer exist
```

A bridge without a redirect is the usual reason a device resolves fine but never
appears in the ControlD dashboard: its queries never reach `ctrld`, so ControlD
only ever sees the router. To leave a VLAN alone (a guest network with its own
DNS, say), set either of these in `/cfg/controld.env`:

```sh
LAN_IFACES_EXCLUDE="br-lan_40"              # cover everything except these
LAN_IFACES="br-lan br-lan_10 br-lan_20"     # or pin the list exactly
```

### Boot Persistence

`/cfg/` is a persistent ext4 partition on the Alta Labs Route 10 that survives firmware updates and reboots. The router's built-in `/etc/rc.local` sources `/cfg/rc.local` on every boot, which:

1. Runs `post-cfg.sh` — starts ctrld, restores iptables redirect rules, configures fallback DNS
2. Reinstalls cron jobs — adds watchdog (5-min) and auto-update (weekly) to crontab, since crontab lives in `/etc/` and may be wiped by firmware updates. Jobs are matched by script path, never by keyword: the router ships its own `wireguard_watchdog` entry, and matching the bare word made the reinstall skip our job after every reboot while leaving the health check silently dead
3. Refreshes `firewall.user` rules — regenerated from the current LAN bridge list, so iptables redirects survive mid-session firewall restarts

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

The binary it replaces is the only thing answering DNS for every client on every LAN bridge — port 53 is redirected to it, bypassing dnsmasq — so the update is guarded at both ends:

1. **Verified** — the download is checked against the SHA-256 in the release's `checksums.txt`. A mismatch aborts before anything is swapped.
2. **Proven** — the current binary is kept as `/cfg/ctrld.prev`, and the new one must answer a real DNS query within 15 seconds.
3. **Rolled back** — if it does not, `ctrld.prev` is restored and `CTRLD_VERSION` is left untouched, so the next run retries. Recovery needs no network, since the old binary is already on disk.

### Watchdog (Health Monitor)

`/cfg/watchdog.sh`, generated by `setup.sh`, runs every 5 minutes via cron and:

1. Checks if `ctrld` is running — restarts if dead
2. Tests DNS resolution through `ctrld`
3. If DNS is healthy, re-asserts redirect coverage for any LAN bridge added since install (new VLANs), self-heals forced-DNS state, warns if `dhcp.leases` is stale, and **self-upgrades back to your preferred protocol** if currently on a fallback
4. If DNS fails, **waits for a second consecutive failure** before acting (debounce — avoids restarting ctrld or churning the protocol on a single transient blip)
5. Restores iptables redirect rules if they disappeared
6. As a last resort, if every protocol fails and ctrld cannot be revived, **removes the DNS redirects** — otherwise port 53 points at a dead port and every client loses DNS entirely. Resolution falls back to dnsmasq → https-dns-proxy (still encrypted, no per-device visibility), and the rules go back automatically once ctrld answers again
7. Logs all actions to syslog

Protocol switches (fallback and self-upgrade alike) rewrite each upstream's transport in place, keeping every split-DNS profile pointed at its own resolver — see [Split DNS and Per-Device Policy](#split-dns-and-per-device-policy).

Protocol fallback is automatic but debounced — transient blips are ignored; a sustained failure (2 consecutive checks) triggers the fallback chain. **The chain is 443-only** (`DoH3 ↔ DoH`) — it never falls *back to* the blockable 853 protocols (DoQ/DoT), though those can still be your primary. The debounce threshold is `FAIL_THRESHOLD` (default 2).

**Self-upgrade / preferred protocol:** the protocol chosen at setup (or via `reconfigure.sh --protocol`/`--benchmark`) is stored as `PREFERRED_PROTOCOL`. If the watchdog ever falls back to a different protocol, it periodically (every ~30 min) re-tests the preferred one on a throwaway port and switches back automatically once it's healthy again — so a transient outage doesn't permanently leave you on a slower fallback. `status.sh` shows both the active and preferred protocol.

### Split DNS and Per-Device Policy

During setup or via `reconfigure.sh --policy`, configure multiple ControlD resolver profiles and route traffic by:

- **Network/subnet** — e.g. route `192.168.2.0/24` to a filtered resolver (`reconfigure.sh --policy` lists your VLAN subnets to pick from)
- **MAC address** — e.g. route a kid's device to a safe-search resolver
- **Both** — combine network and device rules

Policies survive protocol changes. Switching protocol — by hand, by benchmark, or automatically via the watchdog's fallback and self-upgrade — moves every ControlD upstream onto the new transport while each one keeps the resolver it points at. A profile's resolver is its identity: it is never rewritten to another profile's, and non-ControlD upstreams are left alone entirely.

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
- State is recorded as `FORCED_DNS=1` in `/cfg/controld.env` (the persistent source of truth), and re-running `setup.sh` preserves it — falling back to the live uci state for installs predating the flag
- **Self-healing persistence** — the uci config, port-853 iptables rules, and `/etc/firewall.user` entries are restored automatically: at boot by `post-cfg.sh`, every 5 minutes by `/cfg/watchdog.sh`, and instantly on firewall reload via `firewall.user`. This survives reboots **and** firmware updates (which can wipe `/etc/config`).
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
- TOML config generation and table index allocation
- LAN bridge discovery, subnet math, and generated redirect rules
- Env file parsing with defaults
- `--help` and `--version` flags on all scripts
- Invalid input rejection

**Integration tests** (run on-router only):
- DNS resolution through ctrld
- ctrld process running
- iptables redirect rules present
- Cron jobs installed
- Self-healing config regeneration
- Benchmark completion

## Uninstalling

`sh /cfg/uninstall.sh` removes everything this project installs, in all four
places it writes:

| Location | What is removed |
|---|---|
| `/cfg/` | every file `setup.sh` installed, including the boot hook |
| `/etc/firewall.user` | our marker block, and any legacy lines |
| crontab | our two jobs, matched by script path |
| uci | forced DNS turned off; dnsmasq and https-dns-proxy pointed back at defaults |

Only our own iptables rules are deleted, one at a time — the firewall's zone
jumps are left alone, so port forwards and UPnP keep working and no reboot is
needed.

**What it does not restore:** your original `https-dns-proxy` resolver. Nothing
records what it was before install, so uninstall points it at a public
resolver (Quad9) and says so. Set it to whatever you want afterwards. The
dnsmasq lease time is likewise left at 24h.

`force_dns` is set to 0, which is the entire disable: the https-dns-proxy init
script drops its whole forcing block unless `force_dns` is 1, so the port list
is never read while it is 0.

`force_dns_port` still lists 53 and 853 afterwards, and that is correct — those
are the ports the package ships in its own `/etc/config/https-dns-proxy`, and
the same pair is the init script's built-in fallback when the option is absent.
It was never ours to delete, and the Route 10 rewrites the option on the next
boot regardless. Uninstall says so rather than trying.

`/cfg/rc.local` is only removed if it carries this project's marker. Because
`/etc/rc.local` sources that path only when it exists, it is also where a user's
own boot hooks would live: `setup.sh` copies a foreign one to
`/cfg/rc.local.pre-controld` before writing its own, and uninstall puts it back.

**Before a factory reset, uninstall first.** `/cfg` is a persistent partition and
survives a reset, so the boot hook would otherwise re-apply ControlD to your
freshly reset router.

## Versioning

Two versions live in `lib.sh` and move independently:

| Variable | Means | Moves when |
|---|---|---|
| `VERSION` | version of these scripts | you change the scripts |
| `CTRLD_PIN` | the `ctrld` release a fresh install gets | you deliberately adopt a newer upstream release |

`VERSION` follows semver: **MAJOR** for a change an existing install cannot upgrade into (a config key or file layout that older state cannot be read into), **MINOR** for new capability that upgrades cleanly, **PATCH** for fixes that add no behavior.

They used to be one variable, which meant bumping the tools version silently repointed `setup.sh` at a `ctrld` release that does not exist. `test.sh` now asserts they are distinct and that no download URL is built from `VERSION`.

`CTRLD_PIN` is only the starting point. The version actually installed is recorded as `CTRLD_VERSION` in `/cfg/controld.env`, and the weekly updater moves it forward from there — so pinning gives reproducible installs without leaving routers stranded on an old release.

## Shared Library

All scripts source `lib.sh` which provides:

- Colored output helpers (`print_ok`, `print_fail`, `print_warn`, `print_info`)
- Config generation (`write_ctrld_config`, `get_endpoint`)
- Process management (`start_ctrld`, `stop_ctrld`, `restart_ctrld`)
- Health checks (`check_dns`, `ensure_iptables`, `check_port_in_use`)
- Release verification (`verify_ctrld_download`, `checksum_for_asset`)
- LAN bridge discovery (`lan_ifaces`, `lan_cidr`, `lan_net_name`) and redirect rules (`ensure_redirect_rule`, `ensure_firewall_user_rules`)
- Forced DNS (`ensure_forced_dns`, `disable_forced_dns`, `set_forced_dns_flag`)
- Fallback resolver (`set_fallback_resolver`) — keeps https-dns-proxy on the same ControlD profile as ctrld
- Input validation (`valid_resolver`, `valid_mac`, `valid_cidr`, `valid_proto`)
- Protocol utilities (`proto_label`, `next_proto`) and per-upstream protocol switching (`retarget_upstreams`, `resolver_from_endpoint`)
- Degraded-mode handling (`remove_dns_redirects`) and config editing (`toml_blocks`, `next_toml_index`)
- Cron entries matched by script path (`cron_has`, `cron_remove`) and rule hygiene (`prune_stale_redirects`)

## Fallback Safety

Two layers of protection:

1. **ctrld health check** — iptables redirect rules are only added if ctrld passes a DNS resolution test
2. **https-dns-proxy fallback** — even if ctrld fails, dnsmasq still forwards to https-dns-proxy which routes to ControlD. DNS stays encrypted, just without per-device visibility.

## Manual Setup

If you prefer not to use the automated installer, see `config/ctrld.toml.example` and `config/post-cfg.sh.example`. Replace `<YOUR_RESOLVER_ID>` in both files, upload to `/cfg/`, and run `post-cfg.sh`.

## Firmware Updates

**Automatic recovery:** Firmware updates typically preserve `/cfg/` (persistent ext4 partition). The boot persistence layer (`/cfg/rc.local`) automatically restores all services, cron jobs, and iptables rules on reboot. No manual intervention needed.

**If `/cfg/` is wiped** (rare, but possible on major updates), just re-run the
installer — it is faster than restoring by hand and cannot produce a partial
install:

```sh
sh setup.sh --resolver <your-id> --protocol doh3
```

Earlier versions shipped a `backup.sh` that copied a handful of files into
`/cfg/controld-backup`. It has been removed: it stored the backup on the very
partition it existed to protect, and its file list had fallen five files behind
what an install actually needs, so restoring from it produced a broken install.
`uninstall.sh` deletes the directory if an old run left one.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Security

Found a way to bypass or spoof the DNS routing, or another security issue?
See [SECURITY.md](SECURITY.md) for how to report it privately rather than
opening a public issue.

## CI

CI runs on every push/PR to `master` via **GitHub Actions** (`.github/workflows/ci.yml`), this fork's canonical home. The original `.forgejo/workflows/` definitions are kept in step for anyone running this on a Forgejo instance, but GitHub does not read them.

1. **shellcheck** — lints all shell scripts
2. **test suite** — runs `test.sh` under both GNU awk and BusyBox awk, since the router runs BusyBox and its awk differs in ways that have silently broken on-device behavior while CI was green (integration tests run only on-router)
Secret scanning (`betterleaks`) exists only as `.forgejo/workflows/secrets-scan.yml` and therefore does **not** run on GitHub — treat it as Forgejo-only until it is ported.

## Credits

- **CookieTyrant** — original author of this project
  ([codeberg.org/CookieTyrant/alta-route10-controld](https://codeberg.org/CookieTyrant/alta-route10-controld), now archived).
  This fork continues their work.
- [ControlD](https://controld.com) — DNS resolver service
- [ctrld](https://github.com/Control-D-Inc/ctrld) — DNS forwarding proxy
- [Alta Labs](https://alta.inc) — Route 10 router

## License

BSD Zero Clause License (0BSD) — see [LICENSE](LICENSE). Same permissive terms
as the original project; the copyright line now credits both the original
author and this fork's maintainer.
