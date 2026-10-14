# Hardware Verification

What has been watched happen on a real device, and on which one. Everything
here was exercised across repeated install-and-reboot cycles, including a full
pre-release sweep.

| Part | What was running |
|---|---|
| Router | Alta Labs Route 10 (`qcom,ipq9574-alta-route10`) |
| Firmware | Alta `1.5g` on OpenWrt 21.02.1 (`r16325-88151b8303`) |
| Kernel | 5.4.213, aarch64 |
| BusyBox | 1.33.1, stock for OpenWrt 21.02.1 |
| ctrld | 1.5.7 over DoH3 |
| Scripts | 1.10.1 |
| Install | six LAN bridges, forced DNS enabled |

Check what your own router runs:

```sh
grep -E 'DISTRIB_(REVISION|DESCRIPTION)' /etc/openwrt_release
```

Everything below was verified on that combination unless an entry says
otherwise. For the other half, the paths that pass the test suite and have
never run on a device, see [Verification
Status](../README.md#verification-status) in the README.

Entries marked **after 1.11.0** ran later, on the same six-bridge install with
forced DNS on, using the changes that followed 1.11.0, installed from their
branch archive. The fix that makes `audit.sh` read exact counters came out of
that run and was fetched on its own afterwards. The firmware was not re-read
for that run.

Entries also marked **on 1.5h** ran after the router took Alta's 1.5h update
in place, with the same changes installed. `/etc/openwrt_release` then read
`DISTRIB_REVISION='1.5h'` on the same OpenWrt base, `r16325-88151b8303`.
On that router `test.sh` itself ran under the router's own BusyBox, as
`CONTRIBUTING.md` prescribes: 1,061 passed and none failed, its router
integration tests included, once two tests that had been reading the real
`/etc/init.d/https-dns-proxy` were given a stub.

Entries marked **on 1.5i** ran after the router took Alta's 1.5i update in
place, with 1.12.0 and the changes after it installed.
`/etc/openwrt_release` then read `DISTRIB_REVISION='1.5i'`.

Entries marked **on 1.5j** ran after the router took Alta's 1.5j update in
place, with the same changes installed. `/etc/openwrt_release` then read
`DISTRIB_REVISION='1.5j'`.

Entries marked **after 1.12.0, on 1.5j** ran later on the same firmware, with
every change since 1.12.0 merged onto one branch and installed from its
archive. Before the install, `test.sh` from that archive ran under the
router's own BusyBox: 1,197 passed and none failed, with the three
destructive tests skipped, as they are unless asked for.

Entries marked **from master after 1.12.0, on 1.5j** ran later on the same
firmware, with `master` installed by the README's install command, which
carried the changes after 1.12.0 and the polish that followed them.

Entries that time DNS from a client all did it the same way. A Mac on VLAN 10
asked the router's LAN address for a record once a second with
`dig +time=1 +tries=1`, and the `br-lan_10` redirect counter rose with the
queries, which shows the probe went through `ctrld` and not straight to
dnsmasq. An outage below is the span of failed probes.

## Per-Device Visibility

- **Devices appearing individually in ControlD.** Across all six bridges,
  devices resolved through `ctrld` and showed up as separate clients rather
  than the router alone. A bridge reading zero packets in any one audit is
  idle at that moment, not uncovered.

## Install and Upgrade

- Install, and re-install over an existing install, each followed by a reboot

- Two installs back to back with no reboot between them: 24 rules present, 24
  expected, nothing duplicated, and the second run re-downloading `lib.sh`
  rather than reusing the copy the first left in `/tmp`

- **A re-install with `ctrld` ahead of the pin, 1.13.0 on 1.5j.** After the
  weekly update had moved the router to 1.5.8, re-running `setup.sh` from
  `master`, still pinned to 1.5.7, printed `ctrld 1.5.8 is newer than the 1.5.7
  pin — left as it is` and fetched no release. Afterwards `ctrld --version` and
  `CTRLD_VERSION` still read 1.5.8, the redirects were back on all six bridges,
  and `status.sh` and `audit.sh` both exited 0.

- **What a config rewrite keeps.** `write_env_file` run on the device, against
  the router's own `lib.sh` and its BusyBox `awk` and `sed`, carried
  `LAN_IFACES_EXCLUDE="br-lan_40"   # guest wifi` and a commented `DNS_PORT`
  through with their comments stripped and their values intact, and named
  `JUNK=two words` on stderr as it dropped it. Sourcing that file first printed
  `ash: line 12: words: not found`, which is the value being executed rather
  than parsed, and is why that shape is refused.

- **Forced DNS with `uci` unable to answer.** `FORCED_DNS="1"` came back as
  `FORCED_DNS=1` with `uci` replaced by a stub that exits non-zero, which is
  the state a firmware update leaves behind and the only window where the file
  is the sole record. Simulated rather than encountered: no router here has
  been through a firmware update with a quoted flag in place.

- **The same thing through a real protocol change.** With
  `LAN_IFACES_EXCLUDE="br-lan_40"   # guest wifi` in place, `reconfigure.sh
  --protocol --to dot --force` and back to `doh3` left the key in the file with
  its comment stripped, and the redirects it then wrote covered five bridges
  rather than six: `firewall.user DNS redirect rules updated (br-lan br-lan_10
  br-lan_20 br-lan_30 br-lan_50 )`. So the setting survived the rewrite and
  took effect, which is the outcome the key exists for and the one a dropped
  line used to cost. Removing the line and running the watchdog put coverage
  back to six bridges and 24 rules.

  The drop report reaches syslog as well as stderr: `controld: write_env_file
  dropped: JUNK`.

- **Installing from an unpacked archive, after 1.11.0.** The router's own
  `wget` fetched the branch archive, following GitHub's redirect to codeload,
  and `setup.sh` run from the unpacked copy in `/tmp` printed no
  `Downloading lib.sh from repository` line. It used the `lib.sh` and utility
  scripts beside it and fetched nothing from master. The installed library was
  the branch's and the audit was clean. A release archive has the same layout.
  Over a working install, a client lost DNS for about 4 seconds (two failed
  probes) while `ctrld` restarted.

- **The installer's verdict on a resolver ID that does not exist, after
  1.11.0.** ControlD refuses an unknown ID: from the Mac,
  `curl --doh-url https://dns.controld.com/zzbad99` could not resolve (exit
  6), while the real ID answered. Re-installing over a working install with
  `--resolver zzbad99` ended on `Installed, but DNS is not working yet` and
  exit 1. Re-installing with the real ID straight after ended on
  `Setup Complete!` and exit 0, with the audit clean.

  The same run showed what a mistyped ID costs. The https-dns-proxy fallback,
  asked directly on port 5053, timed out, because the installer had already
  pointed it at the bad ID. A client got no answer, because the earlier
  redirects still pointed at a `ctrld` that could not resolve. Nothing
  recovers from that on its own. It cost 40 seconds here only because the
  correct install ran immediately afterwards. The installer's
  `System DNS working` check read `[OK]` throughout, since the router answered
  it from dnsmasq's cache.

- **The resolver checked before the installer changes anything, after
  1.11.0.** A re-install with the real ID printed the check and its answer
  before `Existing ControlD configuration found`. With `zzbad99` it stopped at
  `ControlD did not answer for resolver ID zzbad99 — nothing was changed`,
  exit 1, before reaching that step, and neither `ctrld.toml` nor
  `controld.env` mentioned the ID afterwards. With outbound port 853 rejected,
  `--protocol doq` stopped at `ControlD answers over DoH but not DoQ (QUIC)`,
  naming the protocol rather than the ID. A client probing throughout lost no
  DNS to either, where the same unknown ID had left the LAN without DNS until
  the installer was run again, and no throwaway `ctrld` was left running.

- **The installer's last two lines, after 1.12.0, on 1.5h.** A re-install
  from the branch archive, with Use DoH on and forced DNS on, ended its
  verification on `Fallback DNS answering (https-dns-proxy on port 5053)`.
  That check now asks https-dns-proxy directly, seconds after `post-cfg.sh`
  restarted it, and it answered in time: the whole install took 7 seconds.
  The run ended without the "Smart TVs or IoT gear bypassing DNS?" line,
  which now prints only while forced DNS is off. It exited 0 and `audit.sh`
  exited 0. A run with Use DoH off, where the check asks dnsmasq instead, has
  not been done on a router.

- **The installer's prompts, answered as typed, after 1.12.0, on 1.5j.** At
  `Resolver ID:` the installer took the whole `https://dns.controld.com/<id>`
  link pasted from the dashboard, took the ID out of it, and checked that
  ControlD answered for that ID over DoH3 before going further. The Bootstrap
  IP prompt printed its three lines of explanation first, and Enter took
  `76.76.2.22`. Typing `no` at `Overwrite? [Y/n]` printed `Aborting.`, and
  `ctrld` kept its PID. Run again with `yes`, the installer used the archive's
  own files, printing no `Downloading lib.sh from repository` line and no
  `[!!]`, took `no` at the split-DNS question, and restarted `ctrld` with the
  redirect on all six bridges. `controld.env` came back with the bare ID,
  DoH3 as both the running and the preferred protocol, and `FORCED_DNS=1`.

## Redirect Coverage

- Redirect coverage on all six bridges, the port-853 DoT hijack, and
  `/etc/firewall.user` persistence across a reboot

- **Redirect precedence.** On a first install every redirect is created at the
  head of `PREROUTING`, above all nine of this router's fw3 zone-chain jumps;
  on a router whose rules had been appended *below* `zone_lan_prerouting`, the
  upgrade migrated them in place. This matters because it was a live bug here:
  `https-dns-proxy`'s own zone redirect was taking port 53 on three of six
  bridges and had swallowed 52,061 queries while `status.sh` reported
  per-device visibility working and `audit.sh` reported no drift. One bridge
  went from 0 to 188 intercepted packets the moment the rule moved. Re-checked
  after a reboot, which is the case `/etc/firewall.user` has to get right,
  since it runs after fw3 has rebuilt its chains

- **A redirect pointing at a port nothing listens on.** Caught on all three
  paths: `audit.sh` reporting it as drift and `reconfigure.sh --repair`
  removing it, including a deliberate outage and its repair; and `uninstall.sh`
  sweeping one planted as `--dport 53 -j REDIRECT --to-ports 5399`, a port this
  install had never recorded, while leaving a planted non-DNS rule (`--dport 80
  --to-ports 3128`) untouched

- **A hardcoded port-53 server reaching `ctrld` with forced DNS off, after
  1.12.0, on 1.5j.** None of the changes installed touches the redirect
  rules. After `reconfigure.sh --force-dns --to off`,
  `iptables -t nat -S PREROUTING` listed twelve port-53 redirects and no
  port-853 rules. Each had the shape
  `-i br-lan_10 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354`, with
  no destination match. The Mac on VLAN 10 then ran
  `dig +time=2 +tries=1 @192.0.2.1 example.com`, an address where nothing
  answers DNS, and got both of `example.com`'s addresses back in 10 ms. It
  also ran `nslookup route10-port53-test.example.com 8.8.8.8`, and the
  `br-lan_10` UDP redirect counter rose from 131,542 to 131,544 across the
  two queries. `status.sh` still ended on `Healthy — every check passed` and
  exit 0. Turning forced DNS back on put the twelve port-853 rules back, and
  `192.0.2.1` gave the same two addresses. So a hardcoded plain-DNS server
  reaches `ctrld` with forced DNS off, and the redirect forced DNS adds is the
  one for port 853, which catches DNS-over-TLS.

## DNS Port Changes

- **A DNS port other than 5354, end to end.** 5354 was held by another process
  at install time, so the installer moved to 5355 and recorded it. The port was
  then freed and the installer re-run, which is where this used to come apart:
  it kept 5355 in both `ctrld.toml` and `controld.env` rather than regenerating
  the config on the default. Redirect coverage on all six bridges, `audit.sh`
  reporting no drift, then a reboot, after which `post-cfg.sh` brought ctrld
  back on 5355 with traffic counted on four bridges and `audit.sh` still clean.
  Clearing the recorded port and re-installing returned it to 5354

- **The installer pruning a port it no longer uses.** Run twice from the same
  starting point on a router carrying six bridges and forced DNS: an install
  moved to 5355 and repaired clean, then the recorded port cleared and the
  installer re-run, which is the documented way back to the default. On master
  the install finished reporting success and left redirects to 5355 on all six
  bridges, which `audit.sh` reported as drift and told the reader to fix by
  hand. With this change the same run printed `Removed 24 redirect rule(s) from
  a port no longer in use` and the audit came back clean with nothing run after
  it

- **Recovery without `lib.sh` on an install that had moved off 5354.** With the
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

## Watchdog and Self-Healing

- **The watchdog's whole failure path.** Forced by moving `/cfg/ctrld` aside: a
  binary that will not start, the protocol fallback chain, the redirect
  teardown that hands DNS back to dnsmasq → https-dns-proxy, and the
  single-cycle recovery once the binary returns

- **Self-healing, for real.** `/cfg/ctrld.toml` deleted and rebuilt by
  `post-cfg.sh` from `controld.env`, with DNS still resolving afterwards. These
  are the suite's destructive integration tests; before this release they had
  never executed anywhere, skipped off-router and hanging on-router

- **Re-downloading `ctrld` through `post-cfg.sh`, after 1.11.0.** With
  `/cfg/ctrld` moved to `/tmp`, `post-cfg.sh` logged `ctrld binary missing,
  downloading...` and `ctrld binary restored` with no checksum complaint, and
  `ctrld --version` answered `v1.5.7`. A client lost one probe while it
  restarted. This is the recipe `docs/troubleshooting.md` gives for a binary
  that keeps crashing.

## Boot Persistence and Recovery

- **The recovery path with `/cfg/lib.sh` absent.** With the library moved aside
  and a bridge's redirect deleted, `post-cfg.sh` recreated it at `PREROUTING`
  line 1, thirty-one rules above that bridge's own zone chain, using the
  minimal helper copy it carries for exactly this case

- **The same recovery after 1.11.0, on 1.5h**, once `post-cfg.sh` had been
  rebuilt around Use DoH. With `/cfg/lib.sh` moved aside and `br-lan_40`'s
  udp port-53 redirect deleted, it recreated the rule, taking the count from
  23 back to 24, started all three https-dns-proxy instances because Use DoH
  was on, and logged redirects on all six bridges. `audit.sh` exited 0, which
  includes its check that no redirect sits below a firewall zone chain.

- Cron installation and survival across a reboot, and that our own cron
  operations leave the router's `wireguard_watchdog` job alone

- **The weekly auto-update off switch, across the paths it exists to survive.**
  With `AUTO_UPDATE=0` written by `reconfigure.sh --auto-update`, re-running
  `setup.sh` kept the setting and declined to reinstall the cron, saying so as
  it went. A reboot came back with the crontab still missing that job and the
  boot hook logging why. Planting the job by hand and rebooting again had the
  hook remove it, which is the case a crontab restored from a backup produces.
  Deleting the key from `controld.env` altogether and rebooting put the weekly
  job back, which is the state every install predating the flag is in. The five
  cron jobs on this router that have nothing to do with ControlD were untouched
  throughout.

- **The toggle itself.** `reconfigure.sh --auto-update --force` wrote the key
  and took the cron out in the same run, `--show` gained its weekly-update
  line, and the menu kept items 1 to 6 where they had always been with the
  toggle added as 7.

- **What the readouts say while the two disagree.** With the flag off and the
  cron present, `status.sh` warned about the mismatch and `audit.sh` raised it
  as a review item while still exiting 0, so a hand-edit does not pin the audit
  at failure. The updater run with no arguments declined and reached no
  network. `--now` ignored the flag, queried the GitHub API and found 1.5.7
  already installed. On the build running at the time it then exited 0 in
  silence, which took reading the source to tell apart from a script that never
  ran, since every other path under `--now` either prints or exits non-zero.
  With the fix that shipped in 1.11.0, the same command on the same router
  answered `already on v1.5.7 — nothing to update`.

- **A real weekly update, 1.13.0 on 1.5j.** With the 1.13.0 release installed
  from `master` and `ctrld` at its 1.5.7 pin, the Monday cron moved the router
  to 1.5.8 unattended. The next day `ctrld --version` and `CTRLD_VERSION` both
  read 1.5.8, `/cfg/ctrld.prev` was the 6,877,476-byte 1.5.7 binary it
  replaced, and `status.sh` and `audit.sh` both exited 0. The updater puts the
  old binary back when the new one fails its lookup after the install, so this
  one passed. The job ran at 03:00 by the router's clock, which keeps local
  time, seven hours behind UTC here, so its log lines would have been stamped
  10:00. They had rotated out before anyone looked, which leaves open whether
  the checksum was verified or skipped. `/cfg` held both binaries with 10.4 MB
  of its 26.2 MB free.

- **Where the boot hook's log lines go.** They do reach `/tmp/log/messages`,
  but they carry pre-NTP timestamps, dated `Oct 24 09:02` on this router, and
  sort to the top of the file, so looking for them with `tail` finds nothing.
  The file is recreated at boot: after five reboots in one session it held one
  `ControlD boot hook starting` line, not five. An earlier version of this
  entry said it kept entries from before a reboot, which was wrong. The
  pre-NTP lines are from the same boot as the correctly dated ones, and reading
  them as a previous boot's is what produced the mistake.

  `/root` is cleared by a reboot too, so a backup you mean to restore from goes
  in `/cfg`.

- **A reboot timed from a client, after 1.11.0.** DNS answered again 65
  seconds after the reboot began. The fallback carried it for roughly the
  first 30 of those, until `post-cfg: ctrld started (doh3), DNS redirected to
  5354 on:` all six bridges. Afterwards there were 24 rules, forced DNS with
  its 12 port-853 rules, both cron jobs, and a clean audit. The boot log
  carried the firmware's early `ctrld failed health check` line ahead of the
  hook's success, the sequence `docs/troubleshooting.md` calls benign.

- **The firmware's own line for the hook.** On this router `/etc/rc.local`
  sources the hook as
  `if ! grep -q rescue /proc/cmdline && [ -e /cfg/rc.local ]; then . /cfg/rc.local`,
  which skips it on a rescue boot, followed by `fi` on its own line. The
  same three lines were there on 1.5h. `docs/technical-details.md` offers
  this form for putting the hook back.

- **The log's clock and how far back it reaches.** syslog stamps its lines in
  UTC while `date` on the same router prints local time, seven hours behind
  here. On this router, with 87 DHCP leases, each 200 KB file filled in about
  an hour and a half, so the current file and the two kept beside it hold
  about four to five hours. A healthy watchdog logs nothing, so finding no
  ControlD lines in that window is normal.

- **A firmware update, after 1.11.0, on 1.5h.** The router came back from
  Alta's 1.5h update with all 24 redirect rules, forced DNS with its 12
  port-853 rules, both cron jobs and the boot hook, and `audit.sh` exited 0
  with no drift. The update rewrote the https-dns-proxy instances, adding
  `use_http1='1'` and `polling_interval='3600'` and swapping the listen ports
  of the first two, and added `local_ttl='300'` to dnsmasq. It left dnsmasq's
  three servers, `noresolv` and `leasefile` as they were.

- **dnsmasq left running at boot, after 1.11.0, on 1.5h.** Before
  `post-cfg.sh` compared dnsmasq's servers first, the boot after the update
  started dnsmasq three times: once from the firmware and once from each run
  of `post-cfg.sh`. With the comparison in place, a version since replaced by
  the one under Alta Control's DNS Settings below, re-running `setup.sh` left
  dnsmasq's process ID unchanged, and a reboot showed one start, the
  firmware's own, with both runs of `post-cfg.sh` logging
  `dnsmasq already forwards to https-dns-proxy — left running`. The failed
  probes spanned 38 seconds and `audit.sh` exited 0.

- **What a firewall reload does to the redirects, on 1.5h.** The include
  for `/etc/firewall.user` carries no `reload` option, unlike the five scripts
  Alta's own firmware includes, and a rule inserted by hand into `PREROUTING`
  survived `/etc/init.d/firewall reload` while a line appended to
  `/etc/firewall.user` was never run. So the block runs when the firewall
  starts, at boot or on a restart, and a reload leaves the redirects as they
  are. With `ctrld` killed and the firewall reloaded, all 24 redirects were
  still in place, pointing at the stopped `ctrld`, and a client timed out.
  `post-cfg.sh` put it right; left alone, the watchdog removes them.

- **The firewall block's check that `ctrld` is listening, after 1.11.0, on
  1.5h.** With `ctrld` running, `netstat -lnu` reported it on 5354. Killed,
  it stopped listening within 2 seconds. With the redirects cleared and
  `ctrld` stopped, running the block the way the firewall does added no
  rules, and a client resolved through dnsmasq. `post-cfg.sh` then restored
  all 24 rules and `audit.sh` exited 0.

- **Leases handed out before the clock is set, on 1.5h.** After that reboot
  the four access points on `br-lan` kept working at their addresses but were
  missing from `/cfg/dhcp.leases`. The switch, whose lease predated the
  reboot, was still listed. The boot log showed dnsmasq acknowledging all
  four between `Oct 24 09:01` and `09:02`, before the clock was set, so their
  leases expired in October 2021 and were dropped once the time was right. The
  boot after the firmware update did the same, and one of those addresses
  later went to a second access point. This is the firmware's, and
  `docs/troubleshooting.md` has the check and the workaround.

- **`post-cfg.sh` every minute, on 1.5i.** After the update the firmware ran
  `/cfg/post-cfg.sh` every 60 seconds, at about :21 past the minute, each
  time just after `rc: Re-running dl cfg` and its schedule check. With no
  schedules configured, `/var/run/schedules` was empty and
  `/var/run/.schedules` absent, so `diff -qr` between them failed (rc 2),
  and the firmware stopped its scheduler, deleted `.schedules` and ran the
  hook. Nothing in this project's cron runs it. Each run restarted `ctrld`:
  over three minutes its PID changed every minute, and a Mac probing once a
  second failed one lookup two seconds after each run.

- **Leaving a healthy `ctrld` running, on 1.5i.** A re-install from the
  branch archive recorded what `ctrld` was started with in `/tmp/ctrld.started`.
  Over the next three minutes the firmware ran the hook four times, each run
  logged `ctrld already running (doh3) — left running` about a tenth of a
  second later, the PID stayed the same throughout, https-dns-proxy was not
  restarted, and the probe failed no lookups in 200 seconds. `audit.sh`
  exited 0. An earlier build of this change recorded the config with
  `cksum`, which the router's BusyBox lacks (`command not found`, rc 127),
  so it recorded nothing and changed nothing. An earlier re-install also
  landed on the firmware's run: two runs at once each logged `ctrld
  started`, the installer found no `ctrld` and exited 1, and devices most
  likely had no DNS until the firmware's next run about 50 seconds later.
  The lock added after it has not yet been seen waiting on a router.

- **No more per-minute runs, on 1.5j.** Alta confirmed the per-minute runs
  on its forum and said the next release would fix them. The router took
  1.5j unattended, and 28 hours later its log held no run of
  `/cfg/post-cfg.sh` across the nearly four hours it covered, 01:40 to 05:23
  UTC, where 1.5i would have run it about 220 times. The rotated log held
  none either. The update itself came through intact: `ctrld` running, 24
  redirect rules, and `audit.sh` exited 0.

- **A reboot with the bounded network wait, after 1.12.0, on 1.5j.** The
  router's BusyBox `ping` accepts `-W`: `ping -c1 -W 1 192.0.2.1` gave up
  after one second with rc 1, and `76.76.2.22` answered. After a reboot the
  firmware's own early run of `post-cfg.sh` logged `ctrld failed health
  check, using https-dns-proxy fallback`, and the boot hook's run 0.6 seconds
  later logged `starting` and then `ctrld started (doh3)` with the redirect
  on all six bridges, the order `docs/troubleshooting.md` describes as
  benign. Neither `no ICMP reply` nor `still running after 120s` was logged.
  Forced DNS was restored with its twelve port-853 rules, `status.sh` read 24
  redirect rules and ended Healthy with exit 0, and `audit.sh` reported no
  drift. The install before it, which waits on the same ping, took 2.5
  seconds from `starting` to `ctrld started`.

## Alta Control's DNS Settings

The entries below that see a settings save stop https-dns-proxy and leave it
stopped fit the router's own DOH switch being off. It was found off on 1.5j,
in the last entry of this section, and when it was turned off is not known.

- **A settings save re-runs `post-cfg.sh`, on 1.5h.** Saving any change on
  the DNS page in Alta Control, a local DNS record included, re-applied the
  router's whole config: the firmware stopped https-dns-proxy, reloaded the
  firewall, restarted dnsmasq when its settings differed, and then ran
  `/cfg/post-cfg.sh`. That run restored forced DNS, restarted `ctrld` and
  logged the redirects in place on all six bridges within about 3 seconds.
  The reload had left them there, as the entry on firewall reloads under Boot
  Persistence and Recovery found. Afterwards there were 24 rules and
  `audit.sh` exited 0.

- **Local DNS Records, on 1.5h.** A record saved in the UI, `r10test` at
  `192.0.2.10`, went into dnsmasq's generated config as
  `host-record=r10test,192.0.2.10,300`, not into uci. dnsmasq answered it on
  the router. `ctrld` on 5354 did not, and neither did a Mac on the LAN.
  `ctrld` sends single-label names, and names ending in `.lan`, `.local` or
  `.domain`, to its OS resolver, which leaves out the router's own addresses
  to avoid a loop, so dnsmasq is never asked (`isLanHostname` in
  `cmd/cli/dns_proxy.go` and `availableNameservers` in `resolver.go`, ctrld
  1.5.7).

- **What Use DoH and DoH Servers do, on 1.5h.** The firmware stopped
  https-dns-proxy on every save, with Use DoH on as well, and never started it
  again: with `/cfg/post-cfg.sh` moved aside, a save left it stopped. It wrote
  dnsmasq's servers to match the setting. With Use DoH on they were the three
  local ports. With one URL in DoH Servers there was one instance and dnsmasq
  got `127.0.0.1#5053` alone. With Use DoH off the `server` option was
  emptied and dnsmasq forwarded to the ISP's servers. The `post-cfg.sh` of the
  time wrote the three ports back and started https-dns-proxy after every
  save, which undid Use DoH off within a second and, with one DoH server, left
  dnsmasq forwarding to two ports nothing listened on.

- **Following Use DoH, after 1.11.0, on 1.5h.** With `post-cfg.sh` reading
  Use DoH from dnsmasq's servers instead, turning it off left https-dns-proxy
  stopped, with no processes running. dnsmasq started once, from the firmware.
  `post-cfg.sh` logged `Use DoH is off in Alta — https-dns-proxy left stopped,
  the fallback is the ISP DNS`, and `status.sh` warned rather than failed. A
  Mac on the LAN still resolved through `ctrld`, with 24 rules and a clean
  audit. Turning it back on, the next save's `post-cfg.sh` started all three
  instances, dnsmasq again started once, from the firmware, and `status.sh`
  reported the fallback running. The installer's own run left dnsmasq alone
  as well.

- **One server in DoH Servers, after 1.11.0, on 1.5h.** With
  `https://dns.quad9.net/dns-query` saved in DoH Servers, one https-dns-proxy
  instance ran, dnsmasq started once, from the firmware, forwarding to
  `127.0.0.1#5053` alone, and `post-cfg.sh` logged that it left dnsmasq
  running. The instance's `resolver_url` read back as the ControlD profile,
  the Quad9 URL replaced, and `audit.sh` exited 0.

- **Use DoH off across a reboot, after 1.11.0, on 1.5h.** Both runs of
  `post-cfg.sh` at boot, the firmware's and the boot hook's 25 seconds later,
  logged that Use DoH was off. No https-dns-proxy process ran, `status.sh`
  warned rather than failed, and the router came back with 24 rules, a clean
  audit, and a client resolving. A Mac probing once a second saw one gap of 49
  seconds and 20 failed probes across the reboot, the same count as the 38
  seconds measured before the firewall block checked for `ctrld`, so that check
  did not measurably shorten it.

- **What a settings save costs a client, on 1.5h.** Two settings saves, the
  one before that reboot and the one turning Use DoH back on, each cost the
  probe a single failed lookup, a gap of one to two seconds. So did the
  uninstall and the re-install that followed.

- **A settings save with `ctrld` left running, on 1.5i.** TTL was set to 301
  and saved, then set back to 300 and saved. Each save stopped
  https-dns-proxy, restarted dnsmasq and ran the hook, which restarted
  https-dns-proxy and restored forced DNS's `force_dns` setting that the
  save had reset, and logged `ctrld already running`. The `ctrld` PID was
  the same before and after both. The probe failed one lookup during the
  first save and none during the second. Which part of the firmware's
  re-apply cost that lookup was not found.

- **Force DoH, from master after 1.12.0, on 1.5j.** Alta Control's DNS page
  has Force DoH next to Use DoH and Parallel Queries. Its help text reads
  "Send upstream queries only through DoH, with no unencrypted fallback.
  Requires Use DoH. Proxy bootstrap lookups may still use plain DNS."
  Snapshots of uci, the generated dnsmasq config and `iptables -t nat -S`,
  taken before turning it on and after saving, differed in one value:
  `dhcp.@dnsmasq[0].noresolv` went from 0 to 1, so dnsmasq's config gained
  `no-resolv` and lost its `resolv-file`. The server list, every
  https-dns-proxy option and the firewall were unchanged. The ISP's two
  nameservers stayed in the resolv file, which dnsmasq no longer read. The
  proxies bootstrapped from `76.76.2.22`, which `post-cfg.sh` sets, so their
  own lookups did not go to the ISP either. The save's `post-cfg.sh` run left
  dnsmasq and `ctrld` running and restored `force_dns`, `status.sh` reported
  Healthy with exit 0, and `audit.sh` found no drift. So `noresolv` is the
  firmware's own setting, written from Force DoH.

- **A settings save with Force DoH on, from master after 1.12.0, on 1.5j.**
  The router asked https-dns-proxy on 5053 and dnsmasq for `google.com` once a
  second for two minutes, across one save that changed TTL. Neither failed.
  That save's `post-cfg.sh` run took 0.4 seconds, so any gap in
  https-dns-proxy was shorter than one sample.

- **A reboot with Force DoH on, from master after 1.12.0, on 1.5j.** The
  router has no hardware clock and boots with its firmware's build date, in
  2021, which is too early for TLS. Its clock comes from htpdate, which reads
  the `Date` header of HTTPS servers, and the first server it is given is an
  IP address. It took its first sample a second after starting and set the
  time about 90 seconds into the boot, with no DNS involved. The boot hook's
  `post-cfg.sh` run started on the 2021 clock and started `ctrld` after the
  correction. A minute after the reboot `status.sh` reported Healthy,
  https-dns-proxy, dnsmasq and `ctrld` all answered, and `noresolv` was still
  1.

- **DoH Servers without this project, on 1.5j.** This ran with the project
  uninstalled. Use DoH, Force DoH and Parallel Queries were on, DoH Servers
  held the ControlD profile's URL alone, Bootstrap Servers were at Defaults,
  and a Local DNS Record named `r10test` pointed at `192.0.2.10`. The save ran
  `/etc/init.d/https-dns-proxy stop` from the firmware's `cfg`, and nothing
  started it again in the eleven minutes watched. With Force DoH on, dnsmasq
  had no other server, so the router and every device lost DNS, apart from
  `r10test`, which dnsmasq answers itself. Started by hand, the firmware's one
  instance ran with the profile as its resolver, four bootstrap addresses and
  `-x`, which forces HTTP/1.1. The router's curl 7.76.0 lists no HTTP/2
  library. With the proxy running, queries reached ControlD's activity log
  under the router's endpoint with no client named, where a query through
  `ctrld` also names the device that asked. A Mac got `r10test` from the
  router, and a name the profile blocks came back `0.0.0.0` through the router
  and with its real address from 1.1.1.1 asked directly. No rule in the nat,
  filter or mangle tables matched port 53 or 853, and 1.1.1.1 did not know
  `r10test`, so a device that names its own DNS server bypasses ControlD.

- **The router's own DOH switch, 1.13.0 on 1.5j.** Alta could not reproduce
  the stop in the entry above, which is how this was found. Clicking the
  Route 10 in Alta Control's Network tab opens its own settings, which have a
  DOH switch under Advanced, apart from Use DoH and Force DoH on the DNS page.
  Its help text reads "Disable DNS over HTTPS (DOH) on this device, which may
  break controller DNS resolution. DOH is enabled by default on Alta devices."
  It was off, turned off while troubleshooting at a time no one recorded, and
  `/cfg/config.json` held `"nodoh":true` at its top level. Turning Use DoH off
  and on again, a save each time, wrote and removed `"useDoH":false` and left
  `nodoh` alone. With the switch off, `cfg` ran
  `/etc/init.d/https-dns-proxy stop` early in a save whenever the proxy was
  running, then `diff -q` on the proxy's config, then `stop` again when that
  config had changed. It never ran `start`, and `post-cfg.sh` started the
  proxy again each time. Turned on, `nodoh` was gone, and the first save
  logged afterwards ran `diff -q` and then
  `/etc/init.d/https-dns-proxy restart`, with no `stop` before it. So did the
  last of two TTL saves after that, to 301 and back to 300, and three proxy
  processes were running afterwards. A save with the switch on and this
  project uninstalled was not tried.

## Protocol Reconciliation

- **Protocol reconciliation, end to end.** `ctrld.toml` was retargeted behind
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

- **The switch back with its test port taken, after 1.12.0, on 1.5j.**
  Production was retargeted to DoH behind `controld.env`'s back, and a second
  `ctrld` was started on 5360, the port the switch-back tests on, as a
  running benchmark would hold it. The watchdog was then run by hand with the
  self-upgrade's count one short of the six healthy cycles it waits for. It
  logged `DNS_TYPE corrected to doh (ctrld.toml disagreed)`, then 17 ms later
  `could not test preferred DoH3 (HTTP/3) on port 5360 — staying on DoH
  (HTTP/2)`, and left the other `ctrld` running. With that one stopped, the
  next run logged `preferred DoH3 (HTTP/3) healthy — upgrading back` and,
  2.4 seconds later, `upgraded to DoH3 (HTTP/3)`. `controld.env` read
  `DNS_TYPE=doh3`, the one `ctrld` left was running `/cfg/ctrld.toml`, and
  `status.sh` ended Healthy with exit 0.

## Reconfiguration

- **A resolver ID that does not answer is rolled back, after 1.11.0.**
  `reconfigure.sh --resolver --to zzbad99 --force` printed `ctrld did not
  answer on the new config — restoring the previous one` and `Previous config
  restored`, exited 1, and left neither `ctrld.toml` nor `controld.env`
  mentioning the bad ID, with no `ctrld.toml.bak` behind it. A client lost DNS
  for 19 seconds (18 failed probes), the start timeout plus the restart, and
  it came back with nothing run by hand. It printed
  `Resolver changed to zzbad99` before it had checked anything, which the
  rollback then contradicts.

- **A change checked before it is applied, after 1.11.0.** Once
  `reconfigure.sh` asked a throwaway `ctrld` on the benchmark port first,
  `--resolver --to zzbad99` and, with outbound port 853 rejected,
  `--protocol --to doq` were each refused before anything was written, with
  exit 1, no rollback, and no client DNS lost. Found by the rollback alone,
  each had cost 19 seconds.

- **A protocol the network blocks, after 1.11.0.** With outbound port 853
  rejected in the router's own `OUTPUT` chain, `--protocol --to doq --force`
  rolled back the same way in the same 19 seconds. `DNS_TYPE` and
  `PREFERRED_PROTOCOL` both stayed `doh3`, so the watchdog had nothing to
  switch back to.

- **DoT from the menu, after 1.11.0.** `--protocol` listed five entries, with
  DoT as 4 and Benchmark as 5. Choosing 4 switched to DoT and `--to doh3`
  switched back, each costing a client one failed probe.

- **A quote in a policy name, after 1.11.0.** `Kid "A"` entered through
  `--policy` was refused with `Policy name cannot contain " or \` before
  anything was written, and `ctrld` was not restarted.

- **`--to on` and `--to off`, after 1.11.0, on 1.5h.** With no input and no
  `--force`, `--auto-update --to on` over an update already on said so and
  changed nothing, `--to off` removed the cron, a second `--to off` changed
  nothing, and `--to on` put the cron back, leaving exactly one line.
  `--force-dns --to on` over forced DNS already on changed nothing, and after
  a fresh install had left it off, the same command turned it on and brought
  the rules from 12 to 24. Later, `--force-dns --to off` left the 12 port-53
  rules with `force_dns` at 0 and https-dns-proxy restarted, and `--to on`
  brought back 24 with `force_dns` at 1 and a clean audit. `--to maybe` was
  refused.

## Split DNS

- **Split DNS, end to end.** A device rule keyed on a phone's MAC and a network
  rule keyed on the guest subnet, added in turn against a config that already
  carried a catch-all `[network.0]`, so both allocations had to skip an
  existing table. Each add left the `[upstream.N]` and `[network.N]` indices
  distinct and ctrld running. Two tables of one name make ctrld refuse to
  start, which is what this used to produce. The phone resolved through the
  second ControlD profile and reported that resolver on ControlD's own status
  page, while a machine on another VLAN went on reporting the main one.
  Removing all policies restored a clean single-upstream config with no
  orphaned upstreams

## Readouts and Benchmark

- `audit.sh` reporting no drift before and after a reboot

- **The two readouts run from outside `/cfg`.** `status.sh` and `audit.sh`, each
  fetched on its own into `/tmp` with no `lib.sh` beside it, found the installed
  library and produced a full report against a live install. Before this they
  died on the dot with the shell's own error, while their three siblings in the
  same directory worked

- **`benchmark.sh`'s daemon cleanup.** After a run across all four protocols,
  exactly one `ctrld` process remained

- **Exact packet counts, after 1.11.0.** `audit.sh` reported 1,609 packets
  redirected on `br-lan_10` while `iptables -t nat -L PREROUTING -n -v -x`
  counted 261,417 on its udp rule alone. Without `-x` the listing abbreviates
  that to `261K`, and the audit's awk read it as 261. The fixed `audit.sh`,
  run from its own directory in `/tmp` against the installed library, read
  263,874 for the same bridge, and 135,420 for `br-lan_20` where it had read
  502.

- **A benchmark beside live DNS, after 1.11.0.** All four protocols answered
  15 of 15 at 7 to 8 ms, and a client probing throughout saw no failure. It
  recommended moving from DoH3 to DoQ on a 1 ms difference.

- **The margin a switch has to clear, after 1.11.0, on 1.5h.** The same
  measurement again: DoQ and DoH at 7 ms, DoH3 and DoT at 8. `benchmark.sh`
  now recommended keeping DoH3 and said DoQ was 1 ms faster, less than the
  5 ms and 20% worth switching for.

- **`status.sh`'s verdict, after 1.12.0, on 1.5j.** After the install it
  ended on `Healthy — every check passed` and exited 0, and it did the same
  after the reboot and after each forced-DNS change. With forced DNS off it
  showed that as two `[--]` lines rather than warnings. A run with a failing
  check, which should exit 1, has not been done on a router.

## Uninstall

- **A full `uninstall.sh` run.** Files, cron, redirect rules, the
  `/etc/firewall.user` block and the forced-DNS flag all gone, every
  `https-dns-proxy` instance moved off ControlD and back to the stock resolver,
  the router's own cron jobs and the stock `force_dns_port` list untouched, and
  DNS still resolving afterwards

- **Uninstalling with Use DoH off, after 1.11.0, on 1.5h.** `uninstall.sh
  --force` removed the redirects, the firewall block and the cron jobs, and
  said the fallback was pointed at Quad9 and left stopped because Use DoH was
  off. No https-dns-proxy process ran afterwards, dnsmasq kept the same
  process ID and the empty server list the firmware had given it, and a
  client kept resolving through the ISP. Re-installing over that was a fresh
  install: forced DNS back at its default of off, 12 rules, Use DoH off
  logged, dnsmasq still not restarted, and a clean audit.

- **Uninstalling with Force DoH on, from master after 1.12.0, on 1.5j.** Every
  step of `uninstall.sh` reported `[OK]`, and it closed on `[OK] Uninstall
  complete.` Its own DNS check warned, and minutes later the router and every
  device had no DNS. It had pointed every https-dns-proxy instance at Quad9,
  which answers HTTP/1.1 with `505 HTTP Version Not Supported`, and the
  firmware runs the proxies on HTTP/1.1 only. A Mac got 505 from Quad9 over
  HTTP/1.1 and 200 over HTTP/2. From the router over HTTP/1.1, Quad9 returned
  505 while Cloudflare and Google returned 200. With Force DoH off, the ISP's
  servers in dnsmasq would have answered instead and hidden the failure. Every
  instance set by hand to Cloudflare with bootstrap `1.1.1.1`, which
  `uninstall.sh` now writes, answered on 5053, 5054 and 5055 with `noresolv`
  at 1, and so did dnsmasq. `uninstall.sh` itself has not made that reset on
  a router.

- **Re-installing after that, from master after 1.12.0, on 1.5j.** The
  README's install command with `--resolver` and `--protocol doh3` verified
  the download, checked that ControlD answered over DoH3 before changing
  anything, and reported the fallback answering on 5053. `reconfigure.sh
  --force-dns --to on` turned forced DNS back on, `status.sh` reported Healthy
  with exit 0, and the md5 sums of the six scripts matched `master`. Force DoH
  stayed on.

- **The Force DoH warning, from master after 1.12.0, on 1.5j.** With Force
  DoH on, `lib.sh` and `uninstall.sh` from the change that added the warning
  were downloaded to a scratch directory on the router, and `uninstall.sh` ran
  from there with N piped to its prompt. Between its summary and the prompt it
  printed `[~~] Force DoH is on in Alta Control — turn it off first, or the
  next settings save leaves the LAN without DNS`, under a paragraph naming
  Cloudflare as the fallback. It closed on `[OK] Aborted. No changes made.`
