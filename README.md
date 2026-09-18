# Alta Labs Route 10 + ControlD DNS

[![Version](https://img.shields.io/github/v/tag/Matthew-Hsu/alta-route10-controld?label=version)](https://github.com/Matthew-Hsu/alta-route10-controld/tags)
[![CI](https://github.com/Matthew-Hsu/alta-route10-controld/actions/workflows/ci.yml/badge.svg)](https://github.com/Matthew-Hsu/alta-route10-controld/actions/workflows/ci.yml)
[![Last commit](https://img.shields.io/github/last-commit/Matthew-Hsu/alta-route10-controld)](https://github.com/Matthew-Hsu/alta-route10-controld/commits/master)
[![License: 0BSD](https://img.shields.io/badge/license-0BSD-blue.svg)](LICENSE)

Encrypted DNS with per-device visibility on the Alta Labs Route 10 router using [ControlD](https://controld.com) and the [ctrld](https://github.com/Control-D-Inc/ctrld) daemon.

> **This is a fork.** The original project was created by **CookieTyrant** at
> [codeberg.org/CookieTyrant/alta-route10-controld](https://codeberg.org/CookieTyrant/alta-route10-controld)
> and has since been archived. All of the design, including the self-healing
> boot hooks, the watchdog with protocol fallback, split DNS policies, and the
> forced-DNS hijack, is their work.
>
> This fork started because the original didn't support VLANs at all: DNS
> interception was hardcoded to two interfaces, so any device on a bridge
> outside those two never got routed through ControlD. Its queries resolved,
> but not through ControlD, and the device never showed up in the dashboard.
> Fixing that led to fixing several related bugs found along the way, and to
> keeping the project maintained since the original was archived. See the
> commit history for what has changed since.

## Table of Contents

- [Get Started](#get-started)
- [Not Supported](#not-supported)
- [Installing via an AI Agent](#installing-via-an-ai-agent)
- [Everyday Use](#everyday-use)
- [Troubleshooting](#troubleshooting)
- [Verification Status](#verification-status)
- [Security](#security)
- [Technical Details](#technical-details)
- [CI](#ci)
- [Credits](#credits)
- [License](#license)

## Get Started

**What you get:** encrypted DNS (DoH3 by default) routed through
[ControlD](https://controld.com). Every device on your network shows up
individually in the ControlD dashboard, including devices on VLANs, not just
the router as a whole. It survives reboots and firmware updates without
help, and falls back to a still-encrypted resolver if something goes wrong.

> A few paths pass the test suite but have not been run on a real router — a
> real auto-update among them. See [Verification
> Status](#verification-status) before relying on them. **DNS interception is
> IPv4-only**, and that plus the project's other limits are in [Not
> Supported](#not-supported).

### Prerequisites

- Alta Labs Route 10 router
- A [ControlD](https://controld.com) account with a resolver ID
- SSH access to the router (add your key at [manage.alta.inc](https://manage.alta.inc) > Settings > System > SSH Keys)

### Install

```sh
# SSH into your router and run:
wget -O /tmp/setup.sh https://raw.githubusercontent.com/Matthew-Hsu/alta-route10-controld/master/setup.sh
sh /tmp/setup.sh
```

The installer asks for your **Resolver ID** (from your ControlD dashboard),
walks you through picking a protocol (or benchmarks all of them and picks the
fastest for you), and handles everything else: binary download, config,
firewall rules, scheduled jobs.

#### Guided Protocol Selection

During setup, each protocol is presented with detailed information:

```
  1) DoH3 (HTTP/3)   : Port 443, UDP/QUIC. Stealthy, fast, widely compatible.
  2) DoQ  (QUIC)     : Port 853, UDP/QUIC. Dedicated DNS port, lower overhead.
  3) DoH  (HTTP/2)   : Port 443, TCP+TLS. Most compatible fallback.
  4) DoT  (TLS)      : Port 853, TCP+TLS. Oldest, most widely supported.
  5) Benchmark       : Test all four and auto-select the fastest.
```

Option 5 runs a quick benchmark (10 queries per protocol, about 40 seconds) and automatically configures the winner.

All four protocols the project supports are offered here, and option 5 measures all four — the same set `benchmark.sh` and `reconfigure.sh --benchmark` measure. The two have to match in both directions: a protocol the benchmark measures but the menu does not list is one the installer could select for someone who never saw it, and a protocol the menu lists but the benchmark skips is one "pick the fastest for me" could never pick.

**The port is the tradeoff, not the encryption.** All four encrypt your DNS. DoH3 and DoH ride port 443 and blend with ordinary HTTPS, so they are almost never blocked. DoQ and DoT use port 853, a dedicated DNS port some ISPs and mobile networks block outright — which is why the automatic fallback chain only ever targets 443. If you are unsure, option 1 or option 5.

For non-interactive setup:

```sh
sh /tmp/setup.sh --resolver abc123 --protocol doh3
```

Re-running the installer later is the documented upgrade path, and it's safe
over an existing install: it keeps your forced-DNS choice and any split-DNS
policy, and it leaves a `ctrld` newer than the pinned release alone, provided
that binary still runs. One that doesn't gets replaced, so a re-install
remains the way to repair a damaged install. You'll be asked for your
resolver ID again (it's not read back from the existing install), so have it
to hand, or pass `--resolver`.

DNS is running through ControlD within about a minute. For split DNS per
device, blocking smart-TV DNS bypass, or benchmarking protocols, see
[Technical Details](docs/technical-details.md). If something isn't working, see
[Troubleshooting](#troubleshooting).

## Not Supported

[Verification Status](#verification-status) covers what has not been *proven*.
This covers what is not *there*. Check here before filing a bug: one of these
may already explain what you're seeing.

### IPv6

**DNS interception is IPv4-only.** Everything this project redirects, it
redirects over IPv4.

- **IPv6 sites work normally.** AAAA lookups resolve like any other record.
  This is about DNS *carried over* IPv6, not IPv6 addresses in answers.
- **A device that asks the router for DNS over IPv6 loses its identity.** Its
  queries still reach ControlD encrypted and on your profile, but they arrive
  attributed to the router rather than the device, and they skip any split-DNS
  rule you set for it. Nothing warns you: `status.sh` and `audit.sh` do not
  look at IPv6, so a clean report does not rule this out.
- **A device hardcoded to an IPv6 resolver bypasses ControlD entirely.**
  Forced DNS cannot catch it. This is the only case here where a query leaves
  your network to somewhere that is not ControlD.

To close it, stop the router handing clients an IPv6 resolver. That is a
router setting this project does not manage.

### Everything else

| You might want | What actually happens |
|---|---|
| **Routing a device by name** | Devices are matched by MAC address or by subnet. The names in the ControlD dashboard come from discovery and cannot be used as a rule target. Watch for phones using a private or randomised Wi-Fi address: the MAC changes and the device silently stops matching its rule. |
| **Catching a device that uses DoH** | Forced DNS catches plain DNS (port 53) and DoT (port 853). DoH is indistinguishable from ordinary HTTPS on port 443 and cannot be redirected without breaking the web. Most TVs and IoT gear use DoT, so this is a minority, but a browser set to DoH is out of reach. |
| **Encrypted DNS from your devices to the router** | Clients speak plain DNS to the router; encryption starts there, on the way out to ControlD. You cannot point a laptop at the router over DoH or DoT. |
| **Coverage of something that is not a LAN bridge** | Interception follows the router's LAN and VLAN bridges. A WireGuard tunnel, or anything else the router does not present as a LAN bridge, is not intercepted. |
| **Hand-tuning `/cfg/ctrld.toml`** | Extra upstreams and your split-DNS policy are preserved, but the rest of the file is regenerated on every protocol change, watchdog fallback and re-install. Edits to cache size, log level or the listener will not survive. |

## Installing via an AI Agent

If you're using an AI agent with SSH access to your router to run this
installer, a few things matter before you hand it off:

- **The resolver ID comes from you, not the agent.** It's from your ControlD
  dashboard. An agent should ask for it, not invent one.
- **Forced DNS affects every device on the network, not just one.** Enabling
  it (`reconfigure.sh --force-dns`) redirects DNS for the whole LAN. An agent
  should only turn this on if you asked for it specifically, separate from a
  basic DoH setup request.
- **`--force` skips confirmation prompts.** That's for you to decide, not
  something an agent should use by default to avoid asking a question.
- **Check the result.** Run `sh status.sh` after any install, reconfigure, or
  protocol change, and look at the output. Don't take "it worked" on faith.
- **Uninstalling is destructive.** `uninstall.sh` removes everything this
  project installs and resets DNS to defaults. Only run it if asked.

These are the same precautions a careful human should already take before
changing DNS and firewall rules on a live network. They're written down here
because an agent can move through them faster than a human reads a prompt.

## Everyday Use

Every command below is run over SSH on the router. After install the scripts
live in `/cfg/`; before install, run them from wherever you unpacked the repo.

### Verify an Install

Two questions, two tools. Run both after installing, and after any firmware
update or reboot you want to be sure about.

```sh
sh /cfg/status.sh    # is it working?  services, DNS, per-bridge coverage, cron
sh /cfg/audit.sh     # is it clean?    duplicates, stale references, leftovers
```

`status.sh` confirms the redirect rules exist. `audit.sh` goes further and
reports how many packets each bridge has actually redirected. Rules can be
present and still never match. A VLAN with active devices and zero packets is
the one to investigate; an idle VLAN reading zero is expected.

`audit.sh` opens with the versions actually on the router. Because it can be
run from a checkout in `/tmp` as well as from `/cfg`, it compares the library
it sourced against the one installed and says so when they differ. An audit
that silently describes a version the router is not running is worse than no
audit.

`audit.sh` exits non-zero when it finds drift, so it can gate a script:

```sh
sh /cfg/audit.sh >/dev/null || echo "drift found, run it again for detail"
sh /cfg/audit.sh --raw    # add crontab, firewall.user, uci and nat dumps
```

If it reports rules for a bridge that no longer exists, or a bridge with no
rules, `sh /cfg/reconfigure.sh --repair` re-applies coverage and prunes the
stale entries.

### VLAN Coverage

Per-device visibility depends on DNS being intercepted on every LAN bridge. Alta
names the default LAN bridge `br-lan` and each VLAN `br-lan_<vlan-id>`
(`br-lan_10`, `br-lan_20`, …), so the bridge list is discovered at runtime. A
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

### After a Firmware Update

Expect nothing to break. Updates keep `/cfg/` intact, the boot hook restores
what lives outside it, and the firmware update an install here has been through
came out clean.

The reason to look anyway is that a few pieces of the install rest on firmware
behaviour this project does not own. The clearest example is the boot hook:
`/etc/rc.local` runs `/cfg/rc.local` because the stock firmware already does
that, not because anything here puts the line in. If a future release drops it,
the hook stops running and nothing announces it. DNS keeps working, so the
ControlD dashboard stays green, and the gap only shows up at some later reboot.

So the same two commands are a spot check:

```sh
sh /cfg/status.sh
sh /cfg/audit.sh
```

Clean output means the update moved nothing this install depends on. If
`audit.sh` reports drift, reboot and run it again, which resolves most of it.
Anything still reported after that is worth raising as an issue, since it means
a firmware change moved something this project relies on, and the fix belongs
here rather than in your router. [Firmware Updates](docs/technical-details.md#firmware-updates) explains
each item it can report.

### Change the Resolver ID

```sh
sh /cfg/reconfigure.sh --resolver --to <new-id>
```

This rewrites `ctrld.toml` and `controld.env`, preserves any split-DNS policy,
moves the `https-dns-proxy` fallback onto the same new profile, restarts
`ctrld`, and checks DNS before returning. Confirm with `sh /cfg/status.sh`,
then delete the old profile in the ControlD dashboard. Until you do, the old
ID keeps resolving for anyone who has it.

### Change Protocol

```sh
sh /cfg/reconfigure.sh --protocol --to doh3   # or doq, doh, dot
sh /cfg/benchmark.sh                          # measure first
sh /cfg/reconfigure.sh --benchmark --force    # measure, then apply the winner
```

### Turn On Forced DNS

Catches smart TVs, IoT gear, and browsers that bypass the router's assigned
DNS with a hardcoded server or DNS-over-TLS. It's off by default because it
redirects every device on the network at once, not just the one you're
chasing down.

```sh
sh /cfg/reconfigure.sh --force-dns            # interactive prompt
sh /cfg/reconfigure.sh --force-dns --force    # no confirmation
sh /cfg/status.sh                             # shows forced-DNS status and DoT hijack rules
```

See [Forced DNS Hijacking](docs/technical-details.md#forced-dns-hijacking) for exactly what it catches
and what it can't.

### Uninstall

```sh
sh /cfg/uninstall.sh            # --force skips the confirmation
```

It verifies its own removal on the way out. **Before a factory reset,
uninstall first.** See [Uninstalling](docs/technical-details.md#uninstalling) for exactly what gets
removed and what doesn't.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Verification Status

This project is developed against one router. The test suite runs anywhere,
but iptables, cron and boot persistence can only be proven on a device, so
it's worth being explicit about which is which. This section is about
confidence in what is here. For capabilities and workflows this project
doesn't support at all, see [Not Supported](#not-supported) near the top of
this document.

**Verified on hardware.** An Alta Labs Route 10 (BusyBox v1.33.1), six LAN
bridges, forced DNS enabled, `ctrld` 1.5.7 over DoH3, across repeated
install-and-reboot cycles including a full pre-release sweep:

- Install, and re-install over an existing install, each followed by a reboot
- Redirect coverage on all six bridges, the port-853 DoT hijack, and
  `/etc/firewall.user` persistence across a reboot
- The watchdog's whole failure path, forced by moving `/cfg/ctrld` aside: a
  binary that will not start, the protocol fallback chain, the redirect
  teardown that hands DNS back to dnsmasq → https-dns-proxy, and the
  single-cycle recovery once the binary returns
- Cron installation and survival across a reboot, and that our own cron
  operations leave the router's `wireguard_watchdog` job alone
- `audit.sh` reporting no drift before and after a reboot
- A full `uninstall.sh` run: files, cron, redirect rules, the `/etc/firewall.user`
  block and the forced-DNS flag all gone, every `https-dns-proxy` instance moved
  off ControlD and back to the stock resolver, the router's own cron jobs and the
  stock `force_dns_port` list untouched, and DNS still resolving afterwards
- The two readouts run from outside `/cfg`. `status.sh` and `audit.sh`, each
  fetched on its own into `/tmp` with no `lib.sh` beside it, found the installed
  library and produced a full report against a live install. Before this they
  died on the dot with the shell's own error, while their three siblings in the
  same directory worked
- Recovery without `lib.sh` on an install that had moved off 5354. With the
  port on 5355 and `/cfg/lib.sh` renamed aside, a reboot brought `ctrld` up on
  5355 and created all twelve port-53 redirects at `PREROUTING` positions 1 to
  12, above the fw3 zone chains, with the boot log naming every bridge. Before
  this fix that boot added no redirects at all and logged a failed health
  check, so DNS kept working through `https-dns-proxy` while every device was
  missing from the dashboard. Forced DNS is not restored on that path, by
  design: `ensure_forced_dns` and `ensure_firewall_user_rules` sit behind
  `command -v` guards and are not in the minimal helper set, so the port-853
  rules stayed down until `lib.sh` came back, and a single watchdog cycle then
  restored the uci flag, the twelve 853 rules and the `firewall.user` block.
  Returning the port to 5354 pruned the 5355 rules the same way it had pruned
  the 5354 ones on the way out, which is the round trip that once left 27,338
  packets going to a closed port, and a second reboot came back with no drift
- The installer pruning a port it no longer uses. Run twice from the same
  starting point on a router carrying six bridges and forced DNS: an install
  moved to 5355 and repaired clean, then the recorded port cleared and the
  installer re-run, which is the documented way back to the default. On master
  the install finished reporting success and left redirects to 5355 on all six
  bridges, which `audit.sh` reported as drift and told the reader to fix by
  hand. With this change the same run printed `Removed 24 redirect rule(s) from
  a port no longer in use` and the audit came back clean with nothing run after
  it
- A DNS port other than 5354, end to end. 5354 was held by another process at
  install time, so the installer moved to 5355 and recorded it. The port was
  then freed and the installer re-run, which is where this used to come apart:
  it kept 5355 in both `ctrld.toml` and `controld.env` rather than regenerating
  the config on the default. Redirect coverage on all six bridges, `audit.sh`
  reporting no drift, then a reboot, after which `post-cfg.sh` brought ctrld
  back on 5355 with traffic counted on four bridges and `audit.sh` still clean.
  Clearing the recorded port and re-installing returned it to 5354
- Protocol reconciliation, end to end. `ctrld.toml` was retargeted behind
  `controld.env`'s back to reproduce the divergence, and from there:
  `status.sh`, `audit.sh` and `benchmark.sh` each reported the protocol the
  config actually carried and named the mismatch; the watchdog corrected the
  record within one 5-minute cycle, unprompted; the self-upgrade that
  correction re-arms then counted six healthy cycles, probed the preferred
  protocol on its test port, and switched production back about thirty
  minutes later with nothing asked of anyone; `reconfigure.sh` corrected the
  record on its next run and stayed silent on the one after; and
  `--protocol --to <preferred>` worked in a single step, where it used to
  no-op. A reboot afterwards came back with the two files in agreement and no
  spurious correction logged.
- Redirect precedence. On a first install every redirect is created at the head
  of `PREROUTING`, above all nine of this router's fw3 zone-chain jumps; on a
  router whose rules had been appended *below* `zone_lan_prerouting`, the
  upgrade migrated them in place. This matters because it was a live bug here:
  `https-dns-proxy`'s own zone redirect was taking port 53 on three of six
  bridges and had swallowed 52,061 queries while `status.sh` reported
  per-device visibility working and `audit.sh` reported no drift. One bridge
  went from 0 to 188 intercepted packets the moment the rule moved. Re-checked
  after a reboot, which is the case `/etc/firewall.user` has to get right,
  since it runs after fw3 has rebuilt its chains
- The recovery path with `/cfg/lib.sh` absent. With the library moved aside and
  a bridge's redirect deleted, `post-cfg.sh` recreated it at `PREROUTING` line
  1 — thirty-one rules above that bridge's own zone chain — using the minimal
  helper copy it carries for exactly this case
- Self-healing, for real. `/cfg/ctrld.toml` deleted and rebuilt by
  `post-cfg.sh` from `controld.env`, with DNS still resolving afterwards. These
  are the suite's destructive integration tests; before this release they had
  never executed anywhere, skipped off-router and hanging on-router
- Two installs back to back with no reboot between them: 24 rules present, 24
  expected, nothing duplicated, and the second run re-downloading `lib.sh`
  rather than reusing the copy the first left in `/tmp`
- Split DNS, end to end. A device rule keyed on a phone's MAC and a network
  rule keyed on the guest subnet, added in turn against a config that already
  carried a catch-all `[network.0]`, so both allocations had to skip an
  existing table. Each add left the `[upstream.N]` and `[network.N]` indices
  distinct and ctrld running — two tables of one name make ctrld refuse to
  start, which is what this used to produce. The phone resolved through the
  second ControlD profile and reported that resolver on ControlD's own status
  page, while a machine on another VLAN went on reporting the main one.
  Removing all policies restored a clean single-upstream config with no
  orphaned upstreams
- A redirect pointing at a port nothing listens on, on all three paths:
  `audit.sh` reporting it as drift and `reconfigure.sh --repair` removing it,
  including a deliberate outage and its repair; and `uninstall.sh` sweeping one
  planted as `--dport 53 -j REDIRECT --to-ports 5399`, a port this install had
  never recorded, while leaving a planted non-DNS rule
  (`--dport 80 --to-ports 3128`) untouched
- `benchmark.sh`'s daemon cleanup. After a run across all four protocols,
  exactly one `ctrld` process remained

**Not exercised on hardware.** These pass the test suite and are believed
correct, but no one has run them on a real device:

| Area | What that means for you |
|---|---|
| **An uninstall on more than three `https-dns-proxy` instances** | `uninstall.sh` loops on uci instead of naming instances 0, 1 and 2, so a fourth is no longer left pointing at your ControlD profile. A full uninstall is verified on the three a Route 10 ships, which is the case the loop replaced; no router here has carried a fourth for the loop itself to be proven on. |
| **The watchdog lock under contention** | Two cycles overlapping. The fix that makes overlap unlikely also makes it hard to observe: every hardware run took and released the lock cleanly, but no two ever raced. |
| **Keeping a `ctrld` newer than the pin** | A re-install must not roll a newer binary back to `CTRLD_PIN`. Unit-tested; no router has been ahead of the pin to try it on. |
| **A real auto-update** | `controld-update.sh`'s version comparison, checksum verification and rollback are unit-tested. No router has taken an actual upgrade through it. |
| **Reconciliation on the paths that only run while DNS is failing** | The divergence and every repair for it are now verified on hardware, but two paths there are not, because both need DNS to actually fail on the device: the fallback loop seeding its chain from the reconciled protocol rather than the recorded one, and a reboot landing between a retarget and the record of its result, the interruption that produces the divergence in the first place. |

Every defect in this project's history that CI could not see appeared on a
router first: a BusyBox awk regex, a cron guard matching another service's
job, `logread` failing on firmware with no syslog buffer, and a wait loop that
was instant in a container and six times too slow on the device. So if you hit
a problem in one of the areas above, that is the most useful bug report this
project can receive. Please include the output of `sh /cfg/audit.sh` and the
relevant lines from `/tmp/log/messages`.

## Security

Found a way to bypass or spoof the DNS routing, or another security issue?
See [SECURITY.md](SECURITY.md) for how to report it privately rather than
opening a public issue.

## Technical Details

How the project works internally lives in
[docs/technical-details.md](docs/technical-details.md): the protocol reference
and architecture, what each script does, VLAN discovery, boot persistence, the
watchdog, split DNS, forced DNS, what an uninstall removes, versioning and
firmware updates.

## CI

CI runs on every push to `master` and on **every** pull request, whatever branch it targets, via **GitHub Actions** (`.github/workflows/ci.yml`), this fork's canonical home. The original `.forgejo/workflows/` definitions are kept in step for anyone running this on a Forgejo instance, but GitHub does not read them.

The `pull_request` trigger deliberately carries no branch filter. Filtered to `master`, a PR based on another branch got no checks at all — not pending, not failing, simply absent — so a stack of PRs could be reviewed and merged without CI ever having run on it.

1. **secrets-scan**: runs `betterleaks` over the tree so no credential or key gets committed
2. **shellcheck**: lints all shell scripts
3. **test suite**: runs `test.sh` three times, under GNU awk, under BusyBox awk, and under BusyBox `ash` as well as BusyBox awk. The router runs BusyBox throughout, and both its awk and its shell differ from the runner's in ways that have silently broken on-device behavior while CI was green (integration tests run only on-router)

## Credits

- **CookieTyrant**: original author of this project
  ([codeberg.org/CookieTyrant/alta-route10-controld](https://codeberg.org/CookieTyrant/alta-route10-controld), now archived).
  This fork continues their work.
- [ControlD](https://controld.com): DNS resolver service
- [ctrld](https://github.com/Control-D-Inc/ctrld): DNS forwarding proxy
- [Alta Labs](https://alta.inc): Route 10 router

## License

BSD Zero Clause License (0BSD). See [LICENSE](LICENSE) for the full text.
Same permissive terms as the original project; the copyright line now credits
both the original author and this fork's maintainer.
