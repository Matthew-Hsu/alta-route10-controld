# Hardware Verification

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
