# Troubleshooting

> **First, check which port your install uses.** Every command below says 5354,
> which is the default and almost certainly yours. It is not guaranteed:
> `setup.sh` moves to the next free port when something already holds 5354, and
> records the choice.
>
> ```sh
> grep DNS_PORT /cfg/controld.env      # nothing printed means 5354
> ```
>
> If it prints something else, substitute that number everywhere 5354 appears
> on this page. On a moved install the commands below return nothing at all,
> which reads exactly like ctrld being dead when it is running normally.

## DNS not working after setup

**Symptom:** Devices can't resolve hostnames, internet appears down.

**Fix:**

1. Check if ctrld is running:
   ```sh
   pidof ctrld
   ```
   If no PID returned, ctrld crashed.

2. Check if iptables rules are in place:
   ```sh
   iptables -t nat -L PREROUTING -n | grep 5354
   ```
   If rules exist but ctrld is dead, DNS is being redirected to nothing.

3. **Quick fix**: remove only this project's redirects so DNS falls back to dnsmasq:
   ```sh
   . /cfg/lib.sh && load_env && remove_dns_redirects
   /etc/init.d/dnsmasq restart
   ```
   This restores DNS via https-dns-proxy (still encrypted, just no per-device
   visibility). The watchdog puts the redirects back automatically once ctrld
   answers again.

   > **Never run `iptables -t nat -F PREROUTING`.** That flushes the entire
   > chain: your port forwards, UPnP mappings and the firewall's own zone jumps
   > are deleted along with ours, and only a firewall restart or reboot brings
   > them back. `remove_dns_redirects` deletes our rules one at a time and
   > leaves everything else in place.

4. **Full reset** - reboot the router. If post-cfg.sh has issues, hold off and re-examine the script.

## ctrld keeps crashing

**Possible causes:**

- ctrld binary is corrupted or wrong architecture. Verify with:
  ```sh
  uname -m  # Should show aarch64
  /cfg/ctrld --help  # Should print usage
  ```

- Port 5354 is already in use:
  ```sh
  netstat -tlnp | grep 5354
  ```

- Network not ready when ctrld starts. The `post-cfg.sh` waits for network, but if the WAN link is slow, you may need to increase the wait.

**Fix:** Re-download the ctrld binary:
```sh
cd /cfg
. /cfg/controld.env          # CTRLD_VERSION = the release this install runs
rm ctrld
wget -O ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/v${CTRLD_VERSION}/ctrld_${CTRLD_VERSION}_linux_arm64.tar.gz"
tar xzf ctrld.tar.gz -C /tmp
mv /tmp/dist/ctrld_*/ctrld /cfg/ctrld
chmod +x /cfg/ctrld
rm -rf /tmp/dist ctrld.tar.gz
```

## status.sh says the DNS redirects were removed

**Symptom:** `status.sh` reports no redirect rules and a warning that ctrld was
unrecoverable. DNS still works for everyone, but no device appears in ControlD.

**Cause:** this is deliberate. If ctrld can't be revived on any protocol
(whether it died and won't restart, or never started because the binary or its
config is broken), the watchdog removes the redirects. Leaving them in place
would point port 53 at a closed port and take DNS down for every client on
every bridge. Removing them hands resolution back to dnsmasq → https-dns-proxy,
which is still encrypted ControlD, just without per-device visibility.

Look for `ctrld will not start` in the log below: that means the binary or
`/cfg/ctrld.toml` is the problem, not the upstream protocol.

**Fix:** get ctrld running again. The rules restore themselves within 5 minutes.

> **Reading the logs on a Route 10.** `logread` does not work on this firmware:
> it reads the shared-memory buffer that `syslogd -C` creates, and Alta runs
> `syslogd -n -b 2 -t -u` without it, so it fails with *"can't find syslogd
> buffer"*. Nothing is lost. syslogd still writes to a file:
>
> ```sh
> cat /tmp/log/messages.1 /tmp/log/messages.0 /tmp/log/messages 2>/dev/null \
>   | grep -E 'ctrld|watchdog|post-cfg|controld-update|forced-dns' | tail -30
> ```
>
> `/var/log/messages` is the same file via a symlink, and `-b 2` keeps
> `messages.0` and `messages.1` as rotated history. `status.sh` handles this
> automatically and shows recent watchdog entries either way.

```sh
sh /cfg/status.sh            # includes the last few watchdog entries
/cfg/ctrld --version          # is the binary intact?
sh /cfg/watchdog.sh           # force a health cycle
```

A forced cycle on a broken ctrld is not instant: it restarts once, then walks
the whole fallback chain, which takes roughly a minute in total. It is not
hung. Let it finish. Interrupting it stops the run before the redirect
teardown, which is the part that gets DNS back for your clients. Two cycles
are needed in all, because the first only increments the debounce counter.

Note that `nslookup` **from the router** proves nothing about your LAN: the
router's own queries never traverse `PREROUTING`, so they resolve through
dnsmasq whatever state the redirects are in. Test from a client, or aim at
ctrld directly:

```sh
nslookup google.com 127.0.0.1#5354   # is ctrld itself answering?
```

If a bad auto-update caused it, `/cfg/ctrld.prev` is the previously working
binary; the updater restores it automatically, but you can do it by hand:

```sh
mv /cfg/ctrld.prev /cfg/ctrld && chmod +x /cfg/ctrld && sh /cfg/post-cfg.sh
```

## LAN DNS dies after the port moved, but everything reports healthy

**Symptom:** clients cannot resolve anything. `ping 1.1.1.1` works, so it is
not the link. `status.sh` reports every bridge covered, `audit.sh` reports no
drift, and ctrld is answering when you ask it directly:

```sh
nslookup google.com 127.0.0.1#5354   # fine
```

**Cause:** a redirect left over from a port this install no longer uses.
`PREROUTING` is evaluated in order, so a rule sending port 53 to the old port
sits above the working ones and takes the traffic first — into a port nothing
is listening on. Moving the port and moving it back is enough to leave one.

This was invisible to every check until recently, because each of them selected
rules by the current port before counting, so a rule on the wrong port was
never in the set being examined. Find it by counting packets rather than rules:

```sh
iptables -t nat -L PREROUTING -n -v --line-numbers | grep REDIRECT
```

A rule with a large packet count pointing at a port that is not the one in
`/cfg/controld.env` is the culprit:

```sh
grep '^DNS_PORT=' /cfg/controld.env
```

**Fix:**

```sh
sh /cfg/reconfigure.sh --repair
```

`--repair` now removes a redirect pointing at a port this install does not use,
not only one on a bridge that is gone, and `audit.sh` reports such a rule as
drift. To take them out by hand instead, with `5355` being the port that moved:

```sh
iptables-save -t nat | grep '\-\-to-ports 5355' | while read -r r; do
  # shellcheck disable=SC2086
  iptables -t nat -D PREROUTING ${r#-A PREROUTING }
done
```

Then re-run `sh /cfg/status.sh` and resolve from a client again. Queries from
the router itself never traverse `PREROUTING`, so they kept working throughout
and prove nothing here.

## Devices on a VLAN never appear in ControlD

**Symptom:** The router itself (and anything on the default LAN) shows up in the
ControlD dashboard, but phones, laptops, and other clients on a VLAN never do.
Their DNS works. It just isn't going through ctrld.

There are two causes, and they look identical from a client. Check for the
second even when the first does not apply: a bridge can have a redirect and
still be bypassed.

**Cause 1 — the bridge has no redirect.** DNS is intercepted per bridge
interface. Alta names the default LAN bridge `br-lan` and every VLAN
`br-lan_<vlan-id>` (`br-lan_10`, `br-lan_20`, …). Installs from before VLAN
discovery existed only ever redirected `br-lan` and `br-lan_2`, so every other
VLAN resolved around ctrld.

**Cause 2 — the redirect exists but something takes port 53 first.**
`PREROUTING` is evaluated in order, and a firewall zone chain can carry a DNS
redirect of its own — `https-dns-proxy`'s, if it is configured to hijack DNS. A
redirect *appended* to `PREROUTING` sits below that zone jump and never sees
the packet. The bridge is covered, the rule is right, and it is dead.

This is the more confusing of the two, because every count agrees with you. It
was found here on a router where three of six bridges were affected and the
zone chain had taken 52,061 queries.

**Check.** `status.sh` and `audit.sh` now name cause 2 directly:

```sh
sh /cfg/status.sh          # "has a redirect, but a firewall zone takes DNS first"
sh /cfg/audit.sh           # "redirect sits below a firewall zone chain"
```

If your tooling predates those messages, look at the chain yourself. Position
is what matters, so keep the line numbers and do not filter out the zone jumps:

```sh
iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E 'redir ports|zone_'
```

Every redirect must appear **above** the first `zone_*_prerouting` line. A
redirect below one is cause 2. A bridge with no redirect line at all, or
`iptables-save -t nat` showing `-i br-lan` and `-i br-lan_2` but nothing for
your VLAN bridges, is cause 1.

The packet counters settle it either way: a bridge with active devices and `0`
packets on its redirect is not intercepting anything, whatever the rule says.

**Fix:**

```sh
sh /cfg/reconfigure.sh --repair
```

This re-applies the redirect to every LAN bridge that exists right now, updates
`/etc/firewall.user` so the rules survive a firewall reload, and re-applies the
port-853 (DoT) hijack if forced DNS is on. It is safe to run repeatedly.

The same command fixes cause 2: rules are inserted at the head of `PREROUTING`,
and one found below a zone chain is deleted and re-inserted above it. Because
`/etc/firewall.user` is rewritten to insert rather than append, the correction
survives a firewall reload and a reboot — which is the part that matters, since
`firewall.user` runs after fw3 has rebuilt its zone chains.

If `/cfg/reconfigure.sh` predates this fix, update the tooling first. Re-running
`setup.sh` reinstalls `/cfg/lib.sh` and the helper scripts:

```sh
wget -O /tmp/setup.sh https://raw.githubusercontent.com/Matthew-Hsu/alta-route10-controld/master/setup.sh
sh /tmp/setup.sh
```

New VLANs added later are picked up automatically: the watchdog re-checks
coverage every 5 minutes and adds the missing rules.

**Excluding a VLAN**, such as a guest network that should keep its own DNS: add
these to `/cfg/controld.env`:

```sh
LAN_IFACES_EXCLUDE="br-lan_40"     # skip these bridges
# or pin the list exactly:
LAN_IFACES="br-lan br-lan_10 br-lan_20"
```

Clients cache DNS answers, so reconnect a device (or wait out its cache) before
expecting it in the dashboard.

## Devices showing as MAC addresses only (no hostnames)

**Cause:** ctrld's DHCP discovery isn't reading the lease file.

**Check:**
```sh
# Verify lease file exists and has hostnames
cat /cfg/dhcp.leases
```

If the file exists with hostnames, check ctrld.toml has:
```toml
discover_dhcp = true
dhcp_lease_file_path = "/cfg/dhcp.leases"
dhcp_lease_file_format = "dnsmasq"
```

Devices with `*` as their hostname in the lease file will never show a name. They never reported one to DHCP.

## Changes not persisting after reboot

The Route 10's `/etc/config/` is reset on boot. Only `/cfg/` persists. Make sure:
- `/cfg/post-cfg.sh` exists and is executable (`chmod +x`)
- `/cfg/ctrld.toml` exists
- `/cfg/ctrld` binary exists

## Firmware update wiped everything

Re-run the installer. It is faster than restoring by hand and cannot leave a
partial install behind:

```sh
wget -O /tmp/setup.sh https://raw.githubusercontent.com/Matthew-Hsu/alta-route10-controld/master/setup.sh
sh /tmp/setup.sh --resolver <your-id> --protocol doh3
```

The old `backup.sh` used to copy a handful of files across, but its list had
fallen five files behind what an install actually needs. Restoring from it
produced a router with no watchdog, no boot hook and no cron jobs. A
re-install keeps your forced-DNS setting and any split-DNS policy.

## QUIC / DoQ / DoH3 not connecting

**Symptom:** ctrld starts but DNS resolution fails, or ctrld logs connection errors.

**Check:**

1. Verify the protocol type matches the endpoint format:
   ```sh
   grep -E '(endpoint|type)' /cfg/ctrld.toml
   ```
   - DoQ: `type = "doq"` with `endpoint = "<ID>.dns.controld.com"` (no https://)
   - DoH/DoH3: `type = "doh"` or `doh3` with `endpoint = "https://dns.controld.com/<ID>"`

2. Check if UDP port 443 (DoH3) or 853 (DoQ) is blocked outbound:
   ```sh
   # Test connectivity to ControlD
   ping -c3 76.76.2.22
   ```

3. Switch to DoH as a fallback test:
   ```sh
   sh /cfg/reconfigure.sh --protocol --to doh
   ```

   Do not do this with `sed`. An unanchored `s/endpoint = ".*"/.../` rewrites
   *every* upstream in the file to one resolver, so on a config with split DNS
   the kids and guest profiles are silently repointed at the unfiltered one,
   with nothing failing and nothing logged. `reconfigure.sh` switches each
   upstream's transport while keeping the resolver it points at.

4. If DoH works but QUIC doesn't, your ISP may be blocking UDP. Stick with DoH or DoH3 which can fall back to TCP.

## How to switch protocols

```sh
sh /cfg/reconfigure.sh --protocol --to doh3    # or doq, doh, dot
sh /cfg/reconfigure.sh --protocol              # interactive menu
sh /cfg/reconfigure.sh --benchmark --force     # measure, then apply the fastest
```

`reconfigure.sh` also records the choice as `PREFERRED_PROTOCOL`, so if the
watchdog ever falls back it knows what to return to.

Do not do this by hand. Deleting `/cfg/ctrld.toml` and re-running `post-cfg.sh`
regenerates the config from `/cfg/controld.env` alone, which **discards any
split-DNS policy**: the extra upstreams and the rules pointing at them aren't
in the env file. `reconfigure.sh` carries them across the rewrite instead and
moves each one onto the new transport while keeping its own resolver.

## How to change your resolver ID

Maybe it leaked, or you switched ControlD profiles. Either way, rotating a
resolver ID is a single command:

```sh
sh /cfg/reconfigure.sh --resolver --to <new-id>
sh /cfg/reconfigure.sh --resolver --to <new-id> --force   # no confirmation
```

It rewrites `/cfg/ctrld.toml` and `/cfg/controld.env`, preserves any split-DNS
policy, restarts `ctrld`, and confirms DNS still resolves before returning.

Nothing else on the router refers to the old ID, so there is no stale state to
clean up afterwards, with two things worth knowing:

- **The `https-dns-proxy` fallback moves with it.** `reconfigure.sh --resolver`
  points it at the new profile and restarts it, so the retired ID stops
  answering everywhere on the router. (Earlier versions left this to
  `setup.sh`; since 2dbfa2a it is part of the resolver change.)
- **A failed change can leave `/cfg/ctrld.toml.bak`**, the rollback copy, which
  still contains the old ID. It is removed automatically on success;
  `audit.sh` reports it if one survives. An interrupted watchdog recovery can
  leave `/cfg/ctrld.toml.fallback` the same way; the next healthy cycle removes
  it, and `audit.sh` names it meanwhile.

Verify with `sh /cfg/status.sh` (shows the active resolver ID) and then delete
the old profile in the ControlD dashboard. Until you do, the old ID still
resolves for anyone who has it.

## How to uninstall

```sh
sh /cfg/uninstall.sh          # add --force to skip the confirmation
```

That is the whole procedure. It removes every file, cron job and firewall rule
the project installs, turns forced DNS back off, and restores dnsmasq and
https-dns-proxy. It deletes only our own iptables rules, one at a time, so
port forwards and UPnP keep working, and it verifies the result. No reboot
needed.

Do not tear it down by hand. Earlier versions of this page suggested
`iptables -t nat -F PREROUTING` and removing three files. That flushed the
firewall's own rules and left the boot hook, cron jobs and `firewall.user`
entries behind, so the redirects came back on the next reboot, pointing at a
binary that was no longer there.

See the [Uninstalling](technical-details.md#uninstalling) section of the
technical details for exactly what is removed from where, and what is
deliberately left alone.
