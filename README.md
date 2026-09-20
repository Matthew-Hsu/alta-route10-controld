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

> This project is developed and exercised on an Alta Route 10 running firmware
> `1.5g`, across six LAN bridges;
> [docs/hardware-verification.md](docs/hardware-verification.md) records what
> was watched happen. A few paths pass the test suite but have not been run on
> a real router, a real auto-update among them. See [Verification
> Status](#verification-status) before relying on them. **DNS interception is
> IPv4-only**, and that plus the project's other limits are in [Not
> Supported](#not-supported).

### Prerequisites

- Alta Labs Route 10 router
- A [ControlD](https://controld.com) account with a resolver ID. ControlD's
  [getting started guide](https://docs.controld.com/docs/getting-started)
  covers creating one.
- SSH access to the router as `root` (add your key at [manage.alta.inc](https://manage.alta.inc) > Settings > System > SSH Keys)

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

A healthy run is not all `[OK]`. `[~~]` marks something worth a glance rather
than something broken, and the Summary line is the verdict:

    Packets Actually Intercepted
    [OK]  br-lan: 510 packet(s) redirected
    [OK]  br-lan_10: 69234 packet(s) redirected
    [OK]  br-lan_20: 36248 packet(s) redirected
    [OK]  br-lan_30: 2536 packet(s) redirected
    [~~] br-lan_40: 0 packets — nothing has queried through this bridge yet
    [OK]  br-lan_50: 449 packet(s) redirected

    Leftovers
    [~~] /etc/controld — created by ctrld while running; uninstall removes it
    [OK]  Nothing unexpected in /cfg

    Device Discovery
    [OK]  dhcp.leases is current (88 lease(s)) — ctrld can name devices

    Summary
    [OK]  No drift. 2 item(s) to review above.

That is a clean install. The idle bridge and `/etc/controld` are the two items
it asks you to review.

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

A bridge without a redirect is the usual reason a device resolves fine but never
appears in the ControlD dashboard: its queries never reach `ctrld`, so ControlD
only ever sees the router. `sh /cfg/status.sh` lists per-bridge coverage and
subnets, and `sh /cfg/reconfigure.sh --repair` re-applies it and prunes rules
for bridges that no longer exist, as above.

To leave a VLAN alone (a guest network with its own DNS, say), set either of
these in `/cfg/controld.env`:

```sh
LAN_IFACES_EXCLUDE="br-lan_40"              # cover everything except these
LAN_IFACES="br-lan br-lan_10 br-lan_20"     # or pin the list exactly
```

The setting survives; the comment does not. `controld.env` is rewritten in full
by `setup.sh` and several `reconfigure.sh` flags, and it keeps no comments. See
[A hand-edited setting disappeared from
controld.env](docs/troubleshooting.md#a-hand-edited-setting-disappeared-from-controldenv)
for which shapes come back.

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

One case a reboot cannot resolve: if the update dropped the line in
`/etc/rc.local` that sources `/cfg/rc.local`, nothing is restored at any future
boot, and re-running the installer will not put it back either. You add that
line by hand. [Firmware Updates](docs/technical-details.md#firmware-updates)
lists each item an audit can report, what it costs you, and how to recover it.

Anything still reported after a reboot is worth raising as an issue, since it
means a firmware change moved something this project relies on, and the fix
belongs here rather than in your router.

### Change the Resolver ID

```sh
sh /cfg/reconfigure.sh --resolver --to <new-id>
```

This rewrites `ctrld.toml` and `controld.env`, preserves any split-DNS policy,
moves the `https-dns-proxy` fallback onto the same new profile, restarts
`ctrld`, and checks DNS before returning. Confirm with `sh /cfg/status.sh`,
then delete the old profile in the ControlD dashboard. Until you do, the old
ID keeps resolving for anyone who has it. A failed change can leave a rollback
copy carrying the old ID behind; [How to change your resolver
ID](docs/troubleshooting.md#how-to-change-your-resolver-id) covers that and
what `audit.sh` says about it.

### Change Protocol

```sh
sh /cfg/reconfigure.sh --protocol --to doh3   # or doq, doh, dot
sh /cfg/benchmark.sh                          # measure first
sh /cfg/reconfigure.sh --benchmark --force    # measure, then apply the winner
```

Use `reconfigure.sh` rather than editing the config by hand. Regenerating
`ctrld.toml` from `controld.env` discards any split-DNS policy, since the extra
upstreams are not in the env file. [How to switch
protocols](docs/troubleshooting.md#how-to-switch-protocols) has the detail.

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

### Turn Off the Weekly Auto-Update

A cron job at 03:00 every Monday checks for a newer `ctrld` and installs it.
The binary it replaces is the one answering DNS for every device on the
network, so if you would rather decide when that happens, turn the job off:

```sh
sh /cfg/reconfigure.sh --auto-update            # interactive prompt
sh /cfg/reconfigure.sh --auto-update --force    # no confirmation
sh /cfg/controld-update.sh --now                # update by hand, any time
```

It is on by default, and the choice holds across reboots, firmware updates and
re-running `setup.sh`. Use the command rather than editing `/cfg/controld.env`
by hand.

`--now` runs the identical check, checksum and rollback the weekly job does,
and is the only way to reach them once the flag is off. Re-running `setup.sh`
is not the same thing: it installs the version this project pins, which may be
older than the newest release.

The tradeoff is the obvious one. A `ctrld` release that fixes something you
care about waits until you go and get it.

See [Auto-Update](docs/technical-details.md#auto-update) for what makes the
choice survive a firmware update, and what `status.sh` and `audit.sh` report
while it is off.

### Send a Device to a Different Profile

Put a device or a whole subnet on a second ControlD profile, so a kid's tablet
gets a filtered resolver while everything else does not.

```sh
sh /cfg/reconfigure.sh --policy      # lists your VLAN subnets to pick from
sh /cfg/status.sh                    # shows the upstreams and policies in use
```

Devices are matched by MAC address or by subnet, not by name. Policies survive
protocol changes, resolver changes and re-running the installer. See [Split DNS
and Per-Device Policy](docs/technical-details.md#split-dns-and-per-device-policy)
for how the rules are stored and what a config with two profiles looks like.

### Uninstall

```sh
sh /cfg/uninstall.sh            # --force skips the confirmation
```

It verifies its own removal on the way out. **Before a factory reset,
uninstall first.** See [Uninstalling](docs/technical-details.md#uninstalling) for exactly what gets
removed and what doesn't.

## Troubleshooting

Each of these has a worked fix in
[docs/troubleshooting.md](docs/troubleshooting.md):

- [DNS not working after setup](docs/troubleshooting.md#dns-not-working-after-setup)
- [Devices on a VLAN never appear in ControlD](docs/troubleshooting.md#devices-on-a-vlan-never-appear-in-controld)
- [Devices showing as MAC addresses only (no hostnames)](docs/troubleshooting.md#devices-showing-as-mac-addresses-only-no-hostnames)
- [LAN DNS dies after the port moved, but everything reports healthy](docs/troubleshooting.md#lan-dns-dies-after-the-port-moved-but-everything-reports-healthy)
- [status.sh says the DNS redirects were removed](docs/troubleshooting.md#statussh-says-the-dns-redirects-were-removed)
- [ctrld keeps crashing](docs/troubleshooting.md#ctrld-keeps-crashing)
- [QUIC / DoQ / DoH3 not connecting](docs/troubleshooting.md#quic--doq--doh3-not-connecting)
- [Changes not persisting after reboot](docs/troubleshooting.md#changes-not-persisting-after-reboot)
- [Firmware update wiped everything](docs/troubleshooting.md#firmware-update-wiped-everything)

## Verification Status

This project is developed against one router. The test suite runs anywhere,
but iptables, cron and boot persistence can only be proven on a device, so
it's worth being explicit about which is which. This section is about
confidence in what is here. For capabilities and workflows this project
doesn't support at all, see [Not Supported](#not-supported) near the top of
this document.

**Verified on hardware.** [docs/hardware-verification.md](docs/hardware-verification.md)
records what has been watched happen on a real device and on which firmware,
grouped by area: per-device visibility, install and upgrade, redirect
coverage, DNS port changes, the watchdog, boot persistence, protocol
reconciliation, split DNS, the readouts, and uninstall.

**Not exercised on hardware.** These pass the test suite and are believed
correct, but no one has run them on a real device:

| Area | What that means for you |
|---|---|
| **An uninstall on more than three `https-dns-proxy` instances** | `uninstall.sh` loops on uci instead of naming instances 0, 1 and 2, so a fourth is no longer left pointing at your ControlD profile. A full uninstall is verified on the three a Route 10 ships, which is the case the loop replaced; no router here has carried a fourth for the loop itself to be proven on. |
| **The watchdog lock under contention** | Two cycles overlapping. The fix that makes overlap unlikely also makes it hard to observe: every hardware run took and released the lock cleanly, but no two ever raced. |
| **Keeping a `ctrld` newer than the pin** | A re-install must not roll a newer binary back to `CTRLD_PIN`. Unit-tested; no router has been ahead of the pin to try it on. |
| **A real auto-update** | `controld-update.sh`'s version comparison, checksum verification and rollback are unit-tested. No router has taken an actual upgrade through it. |
| **A quoted `FORCED_DNS` through a real firmware update** | Config rewriting is verified on a Route 10, protocol change included. The one case standing in for the real thing is `uci` being unable to answer, which was a stub rather than a router that had just been updated. |
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

Every push to `master` and every pull request runs a `betterleaks` secrets
scan, shellcheck over every script, and `test.sh` three times: under GNU awk,
under BusyBox awk, and under BusyBox `ash` as well. The router runs BusyBox
throughout, and both its awk and its shell differ from the runner's in ways
that have silently broken on-device behavior while CI was green. Integration
tests run only on the router. [CONTRIBUTING.md](CONTRIBUTING.md) has the
workflow layout and the commands to run the same checks yourself.

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
