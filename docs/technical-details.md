# Technical Details

This document covers how the project works internally: protocol
details, script internals, and the reasoning behind specific implementation
choices.

## Reference

### Supported Protocols

| Type | Protocol | Transport | Port | ISP-blockable? | Default |
|------|----------|-----------|------|----------------|---------|
| `doh3` | DNS-over-HTTPS/3 | HTTP/3 (QUIC) | 443 | No (looks like HTTPS) | Yes |
| `doq` | DNS-over-QUIC | QUIC | 853 | **Yes** (some ISPs/mobile nets) | |
| `doh` | DNS-over-HTTPS/2 | HTTP/2 | 443 | No (looks like HTTPS) | |
| `dot` | DNS-over-TLS | TCP+TLS | 853 | **Yes** (some ISPs/mobile nets) | |

DoH3 and DoQ use the QUIC protocol (UDP-based), which eliminates TCP head-of-line blocking and reduces connection setup latency compared to DoH over HTTP/2. **Port matters for reliability:** 443 (DoH3/DoH) blends with normal HTTPS and is almost never blocked, while 853 (DoQ/DoT) is a dedicated DNS port that some networks block. The automatic fallback chain only ever targets 443 protocols (DoH3 ↔ DoH) for that reason.

### Architecture

DNS traffic can take three different paths, depending on what's healthy and
what mode is enabled. They're kept separate here instead of combined into one
diagram, since each is triggered by a different condition and combining them
was confusing.

**Normal path**: the default for every LAN device, all the time.

```
LAN Devices (router-assigned DNS)
        |
        v  port 53
+--------------------+   port 5354   +----------+   DoH3/DoQ/DoH   +-----------+
| iptables REDIRECT  | -------------> |  ctrld   | ----------------> | ControlD  |
+--------------------+                | :5354    |   (QUIC/TLS)      |  DoH API  |
                                       +----------+                  +-----------+
                                            |
                                            +-- reports client IP/hostname/MAC
```

**Fallback path**: only while `ctrld` is down.

```
LAN Devices --port 53--> +----------+  port 5053/5054/5055  +-----------------+   +-----------+
                          | dnsmasq  | ----------------------> | https-dns-proxy | -> | ControlD  |
                          +----------+                         +-----------------+   +-----------+
                                    (still encrypted, but no per-device visibility)
```

**Forced-DNS path**: only when forced DNS is enabled, for traffic trying to
bypass the router's assigned DNS entirely.

```
Any device hardcoding a DNS server, or using DNS-over-TLS
        |
        v  port 53 or port 853
+------------------------------+   port 5354   +----------+   DoH3/DoQ/DoH   +-----------+
| iptables REDIRECT (forced)   | -------------> |  ctrld   | ----------------> | ControlD  |
+------------------------------+                +----------+                  +-----------+
```

See [Forced DNS Hijacking](#forced-dns-hijacking) for when and why you'd
enable that third path.

#### Why ctrld Does Not Bind Port 53

Running a DNS daemon on port 53 conflicts with dnsmasq, which is a known way
to lock this router up. This setup avoids it by:

- Running ctrld on port 5354 (not 53)
- Using iptables REDIRECT (not replacing dnsmasq)
- Health checking before switching DNS

If your router locks up, the only fix is a physical reboot. The lockup won't persist since iptables rules don't survive reboots without post-cfg.sh.

### Scripts

| Script | Purpose | Key Flags |
|---|---|---|
| `setup.sh` | Interactive installer with guided protocol selection and inline benchmark | `--help` `--version` `--protocol <type>` `--resolver <id>` |
| `status.sh` | Health check: services, upstreams, policies, watchdog activity | `--help` `--version` |
| `reconfigure.sh` | Change protocol, resolver, or policies without re-running setup | `--help` `--version` `--show` `--protocol` `--resolver` `--benchmark` `--policy` `--force-dns` `--repair` `--to <value>` `--force` |
| `benchmark.sh` | Test DNS query latency across DoQ, DoH3, DoH and DoT | `--help` `--version` `--queries N` |
| `audit.sh` | Read-only drift check: installed versions, duplicates, stale references, leftovers, packets actually intercepted | `--help` `--version` `--raw` |
| `uninstall.sh` | Removes everything, restores default DNS | `--help` `--version` `--force` |
| `test.sh` | Test suite: unit tests anywhere, integration tests on-router | none |

Every script except `test.sh` supports `--help` with full usage documentation, and `--version` (or `-v`), which answers without needing an install.

### What Gets Installed

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

### Shared Library

All scripts source `lib.sh` which provides:

- Colored output helpers (`print_ok`, `print_fail`, `print_warn`, `print_info`)
- Config generation (`write_ctrld_config`, `get_endpoint`)
- Process management (`start_ctrld`, `stop_ctrld`, `restart_ctrld`)
- Health checks (`check_dns`, `ensure_iptables`)
- Release verification (`verify_ctrld_download`, `checksum_for_asset`)
- LAN bridge discovery (`lan_ifaces`, `lan_cidr`, `lan_net_name`) and redirect rules (`ensure_redirect_rule`, `ensure_firewall_user_rules`)
- Forced DNS (`ensure_forced_dns`, `disable_forced_dns`, `set_forced_dns_flag`)
- Fallback resolver (`set_fallback_resolver`, `reset_fallback_resolver`): keeps https-dns-proxy on the same ControlD profile as ctrld, and points every instance back at a public resolver on uninstall
- Input validation (`valid_resolver`, `valid_mac`, `valid_cidr`, `valid_proto`)
- Protocol utilities (`proto_label`, `next_proto`) and per-upstream protocol switching (`retarget_upstreams`, `resolver_from_endpoint`)
- Degraded-mode handling (`remove_dns_redirects`) and config editing (`toml_blocks`, `next_toml_index`)
- Cron entries matched by script path (`cron_has`, `cron_remove`) and rule hygiene (`dns_redirect_rules`, `redirect_rule_port`, `redirect_rule_iface`, `prune_stale_redirects`): `--repair` removes a redirect on a bridge that is gone **and** one pointing at a port this install does not listen on, which `PREROUTING` would otherwise evaluate ahead of the working rules
- Split-DNS writing (`policy_add_rule`) and preservation across a config rewrite (`carry_policy_blocks`)
- Config reporting (`list_upstreams`, `policy_rule_count`, `policy_rules`, `format_policy_rules`): what `status.sh` and `reconfigure.sh --show` print, and the split-DNS rules `reconfigure.sh --policy` lists, each resolved to the upstream it routes to
- Env file rewriting (`write_env_file`), which carries keys it does not manage rather than truncating them, and reading back the one key an installer must not lose (`installed_dns_port`)
- Benchmarking (`bench_protocol`, `bench_stop`), shared by all three entry points and never run against production DNS
- Version comparison (`version_gt`), so a re-install does not roll `ctrld` back to the pin

## How It Works

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

### Boot Persistence

`/cfg/` is a persistent ext4 partition on the Alta Labs Route 10 that survives firmware updates and reboots. The router's built-in `/etc/rc.local` sources `/cfg/rc.local` on every boot, which:

1. Runs `post-cfg.sh`, which starts ctrld, restores iptables redirect rules, and configures fallback DNS
2. Reinstalls cron jobs: adds watchdog (5-min) and auto-update (weekly) to crontab, since crontab lives in `/etc/` and may be wiped by firmware updates. Jobs are matched by script path, never by keyword: the router ships its own `wireguard_watchdog` entry, and matching the bare word made the reinstall skip our job after every reboot while leaving the health check silently dead
3. Refreshes `firewall.user` rules, regenerated from the current LAN bridge list, so iptables redirects survive mid-session firewall restarts

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

The binary it replaces is the only thing answering DNS for every client on every LAN bridge, since port 53 is redirected to it, bypassing dnsmasq. The update is guarded at both ends:

1. **Verified**: the download is checked against the SHA-256 in the release's `checksums.txt`. A mismatch aborts before anything is swapped.
2. **Proven**: the current binary is kept as `/cfg/ctrld.prev`, and the new one must answer a real DNS query within 15 seconds.
3. **Rolled back**: if it does not, `ctrld.prev` is restored and `CTRLD_VERSION` is left untouched, so the next run retries. Recovery needs no network, since the old binary is already on disk.

### Watchdog (Health Monitor)

`/cfg/watchdog.sh`, generated by `setup.sh`, runs every 5 minutes via cron and:

1. Takes a lock, so only one instance runs at a time. Concurrent cycles share the debounce counter and rewrite `ctrld.toml` under each other; a lock whose owner is gone is cleared, so an interrupted run cannot wedge the watchdog
2. Checks whether `ctrld` is running and restarts it if dead. The cycle continues either way: if it will not start at all (a corrupt binary, a config a new release cannot parse), it falls into the fallback chain below, so step 7 is reached; and if it does start, it falls into the health path, so a restart after a teardown restores the redirects in the same cycle rather than five minutes later
3. Tests DNS resolution through `ctrld`
4. If DNS is healthy, re-asserts redirect coverage for any LAN bridge added since install (new VLANs), self-heals forced-DNS state, corrects the recorded protocol if it disagrees with what `ctrld.toml` is actually running, warns if `dhcp.leases` is stale, and **self-upgrades back to your preferred protocol** if currently on a fallback
5. If DNS fails, **waits for a second consecutive failure** before acting (debounce, to avoid restarting ctrld or churning the protocol on a single transient blip). On the second, it reconciles the recorded protocol against `ctrld.toml` before walking the fallback chain, so the chain starts from what the router is really running
6. Restores iptables redirect rules if they disappeared
7. As a last resort, if every protocol fails and ctrld cannot be revived, **removes the DNS redirects.** Otherwise port 53 points at a dead port and every client loses DNS entirely. Resolution falls back to dnsmasq → https-dns-proxy (still encrypted, no per-device visibility), and the rules go back automatically once ctrld answers again
8. Logs all actions to syslog

If no protocol works, `ctrld.toml` is restored to the one `controld.env` still names, so the two never disagree about what the router is running. A full recovery cycle (one restart plus three fallback attempts) takes about a minute; give a manual run time to finish rather than interrupting it.

That restore only covers the fallback loop running to completion. Something external cutting the watchdog off mid-loop (a reboot is the case this was found from) can still leave `ctrld.toml` on one protocol while the recorded one names another, since the loop only commits the recorded value once a retry succeeds. Every healthy cycle now checks the two against each other and corrects the record if they disagree (step 4 above), so this cannot stay wrong for more than one 5-minute tick; `reconfigure.sh` does the same check immediately, for anyone who cannot wait that long. The fallback path checks as well, before it walks the chain (step 5), and it is the one path a healthy cycle never reaches, and a chain seeded from a stale record spends attempts re-trying the protocol that just failed. `status.sh`, `audit.sh` and `benchmark.sh` each read the protocol `ctrld.toml` is actually running rather than the recorded one, so they report correctly even inside that one-cycle window, and `audit.sh` names the disagreement as a finding of its own.

Protocol switches (fallback and self-upgrade alike) rewrite each upstream's transport in place, keeping every split-DNS profile pointed at its own resolver. See [Split DNS and Per-Device Policy](#split-dns-and-per-device-policy).

Protocol fallback is automatic but debounced: transient blips are ignored, and a sustained failure (2 consecutive checks) triggers the fallback chain. **The chain is 443-only** (`DoH3 ↔ DoH`): it never falls back to the blockable 853 protocols (DoQ/DoT), though those can still be your primary. The debounce threshold is `FAIL_THRESHOLD` (default 2).

**Self-upgrade / preferred protocol:** the protocol chosen at setup (or via `reconfigure.sh --protocol`/`--benchmark`) is stored as `PREFERRED_PROTOCOL`. If the watchdog ever falls back to a different protocol, it periodically (every ~30 min) re-tests the preferred one on a throwaway port and switches back automatically once it's healthy again, so a transient outage doesn't permanently leave you on a slower fallback. `status.sh` shows both the active and preferred protocol.

### Split DNS and Per-Device Policy

During setup or via `reconfigure.sh --policy`, configure multiple ControlD resolver profiles and route traffic by:

- **Network/subnet**: for example, route `192.168.2.0/24` to a filtered resolver (`reconfigure.sh --policy` lists your VLAN subnets to pick from)
- **MAC address**: for example, route a kid's device to a safe-search resolver
- **Both**: combine network and device rules

Policies survive protocol changes, resolver changes, and re-running the installer. Every rewrite carries the extra upstreams, the network blocks and the policy that references them across whole, then moves each ControlD upstream onto the new transport while it keeps the resolver it points at. A profile's resolver is its identity: it is never rewritten to another profile's, and non-ControlD upstreams are left alone entirely.

Re-running `setup.sh` over an install that has policies preserves them and skips the policy wizard, since a second `[listener.0.policy]` table would be invalid TOML. Use `reconfigure.sh --policy` to change them.

Example config with per-device routing:

```toml
[upstream.0]
    name = "ControlD-Unfiltered"
    endpoint = "abc123.dns.controld.com"
    type = "doq"

[upstream.1]
    name = "ControlD-Kids"
    endpoint = "xyz789.dns.controld.com"
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
- **Port 53** (plain DNS): redirected to ControlD via iptables
- **Port 853** (DoT): redirected to ControlD via iptables
- State is recorded as `FORCED_DNS=1` in `/cfg/controld.env` (the persistent source of truth), and re-running `setup.sh` preserves it, falling back to the live uci state for installs predating the flag
- **Self-healing persistence**: the uci config, port-853 iptables rules, and `/etc/firewall.user` entries are restored automatically: at boot by `post-cfg.sh`, every 5 minutes by `/cfg/watchdog.sh`, and instantly on firewall reload via `firewall.user`. This survives reboots **and** firmware updates (which can wipe `/etc/config`).
- `status.sh` reports the forced DNS state and active hijack rules

**Note:** DNS-over-HTTPS (DoH, port 443) cannot be redirected without breaking all HTTPS traffic. Most TVs and IoT devices use DoT rather than DoH, so forced DNS catches the majority of bypass attempts.

**Also not caught: DNS over IPv6.** Both redirects are IPv4-only, so a device
pointed at a hardcoded IPv6 resolver reaches it directly whether forced DNS is
on or not. See [Not Supported](../README.md#not-supported).

### Benchmark

Run `benchmark.sh` on the router to test which DNS protocol performs best on your connection:

```sh
sh benchmark.sh              # default: 15 queries per protocol
sh benchmark.sh --queries 30 # more queries for accuracy
```

Tests every protocol that can be a primary (DoQ, DoH3, DoH and DoT) with real DNS lookups on a separate port (5360) so production DNS is not disrupted. Outputs a formatted table and recommends the fastest protocol.

`reconfigure.sh --benchmark` and the installer's menu option 5 run the same
code over the same four protocols. The installer prints no "switch to X"
recommendation, because nothing is installed yet and there is no running
protocol to compare against — it simply selects the winner. None of the three
entry points interrupts DNS for the LAN.

### Fallback Safety

Two layers of protection:

1. **ctrld health check**: iptables redirect rules are only added if ctrld passes a DNS resolution test
2. **https-dns-proxy fallback**: even if ctrld fails, dnsmasq still forwards to https-dns-proxy, which routes to ControlD. DNS stays encrypted, just without per-device visibility.

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
- Env file parsing with defaults, and rewriting without dropping unmanaged keys
- Split-DNS rule writing against every shape a policy table can be in, and policy preservation across a config rewrite
- Config readouts: upstream names and protocols, MAC and network rule counts
- Benchmark domain selection and version comparison
- The generated `watchdog.sh` and the installer's config step, extracted from `setup.sh` and executed against a sandbox, confirming that a `ctrld` which will not start still reaches the redirect teardown, that only one watchdog runs at a time and an interrupted one releases its lock, that a failed fallback restores the config rather than leaving it disagreeing with `controld.env`, and that a re-install carries a split-DNS policy across and retargets it
- That `start_ctrld`'s timeout is seconds of wall clock, and that it makes no DNS query while the port is closed
- That the recorded protocol is corrected when it disagrees with what `ctrld.toml` is actually running, on every healthy watchdog cycle and immediately in `reconfigure.sh`, and that `status.sh` reads the truth directly rather than the possibly-stale record
- That `lib.sh` carries no function without a caller
- That `benchmark.sh` and `reconfigure.sh --benchmark` really do probe every protocol that can be the running one, run against a stubbed prober, so neither recommends switching away from one it did not time
- `--help` and `--version` flags on all scripts, including that each renders its colours rather than printing the escape sequences
- Invalid input rejection

**Integration tests** (run on-router only):
- DNS resolution through ctrld
- ctrld process running
- iptables redirect rules present
- Cron jobs installed
- Self-healing config regeneration
- Benchmark completion

## Maintenance

### Uninstalling

`sh /cfg/uninstall.sh` removes everything this project installs, in all four
places it writes:

| Location | What is removed |
|---|---|
| `/cfg/` | every file `setup.sh` installed, including the boot hook |
| `/etc/firewall.user` | our marker block, and any legacy lines |
| crontab | our two jobs, matched by script path |
| uci | forced DNS turned off; dnsmasq and https-dns-proxy pointed back at defaults |

Only our own iptables rules are deleted, one at a time. The firewall's zone
jumps are left alone, so port forwards and UPnP keep working and no reboot is
needed.

**What it does not restore:** your original `https-dns-proxy` resolver. Nothing
records what it was before install, so uninstall points it at a public
resolver (Quad9) and says so. Set it to whatever you want afterwards. The
dnsmasq lease time is likewise left at 24h.

`force_dns` is set to 0, which is the entire disable: the https-dns-proxy init
script drops its whole forcing block unless `force_dns` is 1, so the port list
is never read while it is 0.

`force_dns_port` still lists 53 and 853 afterwards, and that is correct.
Those are the ports the package ships in its own `/etc/config/https-dns-proxy`,
and the same pair is the init script's built-in fallback when the option is
absent. It was never ours to delete, and the Route 10 rewrites the option on
the next boot regardless. Uninstall says so rather than trying.

`/cfg/rc.local` is only removed if it carries this project's marker. Because
`/etc/rc.local` sources that path only when it exists, it is also where a user's
own boot hooks would live: `setup.sh` copies a foreign one to
`/cfg/rc.local.pre-controld` before writing its own, and uninstall puts it back.

**Before a factory reset, uninstall first.** `/cfg` is a persistent partition and
survives a reset, so the boot hook would otherwise re-apply ControlD to your
freshly reset router.

### Versioning

Two versions live in `lib.sh` and move independently:

| Variable | Means | Moves when |
|---|---|---|
| `VERSION` | version of these scripts | a release is cut on `master`, and tagged |
| `CTRLD_PIN` | the `ctrld` release a fresh install gets | you deliberately adopt a newer upstream release |

**Branches never bump `VERSION`.** Unmerged work is not released, so a branch that raises it claims a version that does not exist. Two branches that both bump collide on the one line guaranteed to conflict. It moves in a release commit on `master`, paired with a tag, and that tag is what makes the number real. See [CONTRIBUTING.md](../CONTRIBUTING.md#releases).

`VERSION` follows semver: **MAJOR** for a change an existing install cannot upgrade into (a config key or file layout that older state cannot be read into), **MINOR** for new capability that upgrades cleanly, **PATCH** for fixes that add no behavior. Pick the number from everything that accumulated since the last tag, not from a single branch.

They used to be one variable, which meant bumping the tools version silently repointed `setup.sh` at a `ctrld` release that does not exist. `test.sh` now asserts they are distinct and that no download URL is built from `VERSION`.

**A tag doesn't pin an install.** `setup.sh` and every utility script it downloads always come from `master`, tag or no tag, since there's no `--ref` flag, so pointing the installer's URL at `v1.10.0` would only fetch the entry script from that tag; everything it pulls afterward still comes from current `master`. The one place a tag actually pins something is [Manual Setup](#manual-setup): a `git checkout v1.10.0` there gets you exactly that version, since it skips `setup.sh`'s downloader entirely. Tags and GitHub Releases exist to anchor the `VERSION` number to real history, not as an install target.

`CTRLD_PIN` is only the starting point. The version actually installed is recorded as `CTRLD_VERSION` in `/cfg/controld.env`, and the weekly updater moves it forward from there, so pinning gives reproducible installs without leaving routers stranded on an old release.

### Manual Setup

If you prefer not to use the automated installer, see `config/ctrld.toml.example` and `config/post-cfg.sh.example`. Replace `<YOUR_RESOLVER_ID>` in both files, upload to `/cfg/`, and run `post-cfg.sh`.

**This is not the same install, and the difference matters at the next reboot.**
The example gets `ctrld` running and redirects DNS on every LAN bridge, which
is the part you can see working. It writes no `/cfg/controld.env`, no
`/cfg/rc.local`, no cron jobs and no `/etc/firewall.user` block, so nothing
runs it again: the redirects are gone after a reboot or a firewall reload, and
nothing puts them back. You also get no watchdog, so no protocol fallback and
no teardown if `ctrld` dies, no weekly `ctrld` update, no forced DNS, and none
of `status.sh`, `audit.sh` or `reconfigure.sh`.

That combination has a history here. It is what the old `backup.sh` restored,
and restoring from it "produced a router with no watchdog, no boot hook and no
cron jobs" while looking healthy, which is why that script was removed. Use
this path to read what the pieces do, or to pin an exact version with
`git checkout`, and re-run `setup.sh` when you want an install that maintains
itself.

### Firmware Updates

**Automatic recovery:** Firmware updates typically preserve `/cfg/` (persistent ext4 partition). The boot persistence layer (`/cfg/rc.local`) automatically restores all services, cron jobs, and iptables rules on reboot. No manual intervention needed.

**What an update can actually take with it.** Everything the install owns lives
in `/cfg/`, which survives. What does not survive is the state this project
writes outside `/cfg/`: the root crontab, the managed block in
`/etc/firewall.user`, the uci forced-DNS entries, and `/etc/rc.local`'s line
sourcing `/cfg/rc.local`. An update may reset any of them. `/cfg/rc.local`
re-establishes all of it at the next boot, so a firmware update that ends in a
reboot usually self-heals before you look.

The quiet failure is the one to watch for. `ctrld` is still running from
before the update, so DNS resolves and the dashboard looks healthy, while the
crontab is empty and the firewall block is gone. Nothing is visibly wrong until
something reloads the firewall, or the next reboot happens without the
`rc.local` hook to restore things.

`audit.sh` reports each of those as drift and exits non-zero, so a clean
`sh /cfg/audit.sh` after an update actually tells you something:

| Missing after an update | Consequence, if left | Recovery |
| --- | --- | --- |
| `watchdog.sh` / `controld-update.sh` cron entries | no health checks, no weekly `ctrld` update | reboot (the boot hook reinstalls both) |
| managed block in `/etc/firewall.user` | redirects vanish on the next firewall reload | reboot, or `sh /cfg/reconfigure.sh --repair` |
| `/etc/rc.local` sourcing `/cfg/rc.local` | nothing above is restored at any future boot | add the line by hand (below) |

The third one is the only one a reboot cannot fix, because it is what makes
reboots fix the others. This project never writes `/etc/rc.local`. The stock
firmware sources `/cfg/rc.local` from it on its own, which is what makes the
boot hook work at all. Re-running the installer will not put that back either.
If an update resets the file, add the line back yourself, above any trailing
`exit 0`:

```sh
[ -f /cfg/rc.local ] && . /cfg/rc.local
```

Because an orphaned boot hook leaves the install looking healthy right up until
the next boot, `audit.sh` grades it as drift rather than a review note.

`audit.sh` also compares the protocol recorded in `controld.env` against the one
`ctrld.toml` is actually configured with, so a watchdog failover that an update
interrupted mid-write shows up here instead of staying hidden until the next
protocol change silently does nothing.

**If `/cfg/` is wiped** (rare, but possible on major updates), just re-run the
installer. It is faster than restoring by hand and cannot produce a partial
install:

```sh
sh setup.sh --resolver <your-id> --protocol doh3
```

Earlier versions shipped a `backup.sh` that copied a handful of files into
`/cfg/controld-backup`. It has been removed: it stored the backup on the very
partition it existed to protect, and its file list had fallen five files behind
what an install actually needs, so restoring from it produced a broken install.
`uninstall.sh` deletes the directory if an old run left one.

