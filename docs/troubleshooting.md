# Troubleshooting

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

3. **Quick fix** - remove iptables rules to fall back to dnsmasq:
   ```sh
   iptables -t nat -F PREROUTING
   /etc/init.d/dnsmasq restart
   ```
   This restores DNS via https-dns-proxy (still encrypted, just no per-device visibility).

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

**Cause:** this is deliberate. When ctrld dies and the watchdog cannot revive it
on any protocol, it removes the redirects. Leaving them in place would point
port 53 at a closed port and take DNS down for every client on every bridge;
removing them hands resolution back to dnsmasq → https-dns-proxy, which is still
encrypted ControlD, just without per-device visibility.

**Fix:** get ctrld running again — the rules restore themselves within 5 minutes.

```sh
logread | grep -E 'ctrld|watchdog|controld-update' | tail -30
/cfg/ctrld --version          # is the binary intact?
sh /cfg/watchdog.sh           # force a health cycle
```

If a bad auto-update caused it, `/cfg/ctrld.prev` is the previously working
binary; the updater restores it automatically, but you can do it by hand:

```sh
mv /cfg/ctrld.prev /cfg/ctrld && chmod +x /cfg/ctrld && sh /cfg/post-cfg.sh
```

## Devices on a VLAN never appear in ControlD

**Symptom:** The router itself (and anything on the default LAN) shows up in the
ControlD dashboard, but phones, laptops, and other clients on a VLAN never do.
Their DNS works — it just is not going through ctrld.

**Cause:** DNS is intercepted per bridge interface. Alta names the default LAN
bridge `br-lan` and every VLAN `br-lan_<vlan-id>` (`br-lan_10`, `br-lan_20`, …).
Installs from before VLAN discovery existed only ever redirected `br-lan` and
`br-lan_2`, so every other VLAN resolved around ctrld.

**Check** which bridges are covered:

```sh
sh /cfg/status.sh          # lists each bridge and whether it has a redirect
iptables -t nat -L PREROUTING -n --line-numbers | grep 5354
```

If `iptables-save -t nat` shows `-i br-lan` and `-i br-lan_2` rules but nothing
for your VLAN bridges, that is the problem.

**Fix:**

```sh
sh /cfg/reconfigure.sh --repair
```

This re-applies the redirect to every LAN bridge that exists right now, updates
`/etc/firewall.user` so the rules survive a firewall reload, and re-applies the
port-853 (DoT) hijack if forced DNS is on. It is safe to run repeatedly.

If `/cfg/reconfigure.sh` predates this fix, update the tooling first — re-running
`setup.sh` reinstalls `/cfg/lib.sh` and the helper scripts:

```sh
wget -O /tmp/setup.sh https://raw.githubusercontent.com/Matthew-Hsu/alta-route10-controld/master/setup.sh
sh /tmp/setup.sh
```

New VLANs added later are picked up automatically: the watchdog re-checks
coverage every 5 minutes and adds the missing rules.

**Excluding a VLAN** (e.g. a guest network that should keep its own DNS) — add to
`/cfg/controld.env`:

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

Devices with `*` as their hostname in the lease file will never show a name — they didn't report one to DHCP.

## Changes not persisting after reboot

The Route 10's `/etc/config/` is reset on boot. Only `/cfg/` persists. Make sure:
- `/cfg/post-cfg.sh` exists and is executable (`chmod +x`)
- `/cfg/ctrld.toml` exists
- `/cfg/ctrld` binary exists

## Firmware update wiped everything

Re-upload your backed-up files:
```sh
scp ctrld ctrld.toml post-cfg.sh root@<router-ip>:/cfg/
ssh root@<router-ip> "chmod +x /cfg/ctrld /cfg/post-cfg.sh && /cfg/post-cfg.sh"
```

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
   sed -i 's/type = "doq"/type = "doh"/' /cfg/ctrld.toml
   sed -i 's/endpoint = ".*"/endpoint = "https:\/\/dns.controld.com\/<YOUR_RESOLVER_ID>"/' /cfg/ctrld.toml
   kill $(pidof ctrld); sleep 1
   /cfg/ctrld run -c /cfg/ctrld.toml -d &
   ```

4. If DoH works but QUIC doesn't, your ISP may be blocking UDP. Stick with DoH or DoH3 which can fall back to TCP.

## How to switch protocols

Edit `/cfg/ctrld.env` and `/cfg/ctrld.toml`, then restart:

```sh
# Change protocol in env
vi /cfg/controld.env  # Edit DNS_TYPE=doq|doh3|doh

# Regenerate config from env
kill $(pidof ctrld)
rm /cfg/ctrld.toml
/cfg/post-cfg.sh
```

## How to uninstall

```sh
# Stop ctrld
kill $(pidof ctrld)

# Remove iptables redirect rules
iptables -t nat -F PREROUTING

# Remove files
rm /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh

# Restore default DNS
/etc/init.d/https-dns-proxy restart
/etc/init.d/dnsmasq restart

# Or just reboot
reboot
```

## ctrld locking up the router

This was a known issue when ctrld binds to port 53, conflicting with dnsmasq. This setup avoids that by:

- Running ctrld on port 5354 (not 53)
- Using iptables REDIRECT (not replacing dnsmasq)
- Health checking before switching DNS

If your router locks up, the only fix is a physical reboot. The lockup won't persist since iptables rules don't survive reboots without post-cfg.sh.
