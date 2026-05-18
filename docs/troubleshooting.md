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
rm ctrld
wget -O ctrld.tar.gz 'https://github.com/Control-D-Inc/ctrld/releases/download/v1.5.0/ctrld_1.5.0_linux_arm64.tar.gz'
tar xzf ctrld.tar.gz -C /tmp
mv /tmp/dist/ctrld_*/ctrld /cfg/ctrld
chmod +x /cfg/ctrld
rm -rf /tmp/dist ctrld.tar.gz
```

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
