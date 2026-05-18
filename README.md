# Alta Labs Route 10 + ControlD DNS

Encrypted DNS-over-HTTPS with per-device visibility on the Alta Labs Route 10 router using [ControlD](https://controld.com) and the [ctrld](https://github.com/Control-D-Inc/ctrld) daemon.

## What This Does

- Routes all DNS traffic through ControlD via encrypted DoH
- Shows individual device hostnames and IPs in the ControlD dashboard
- Persists across router reboots via `/cfg/post-cfg.sh`
- Falls back to `https-dns-proxy` if `ctrld` fails to start

## Architecture

```
LAN Devices
    │
    ▼ (port 53)
iptables REDIRECT
    │
    ▼ (port 5354)
┌──────────┐     DoH      ┌───────────┐
│  ctrld   │ ───────────► │ ControlD  │
│  :5354   │              │  DoH API  │
└──────────┘              └───────────┘
    ▲ sends client
    │ IP/hostname/MAC
    │
┌──────────┐
│ dnsmasq  │ (fallback: port 5053/5054/5055)
│  :53     │ ──► https-dns-proxy ──► ControlD
└──────────┘
```

## Prerequisites

- Alta Labs Route 10 router
- [ControlD](https://controld.com) account with a resolver ID
- SSH access to the router (add your key at [manage.alta.inc](https://manage.alta.inc) > Settings > System > SSH Keys)
- `aarch64` architecture (default for Route 10)

## Quick Start

### Option A: Automated Setup

```sh
# SSH into your router and run:
wget -O /tmp/setup.sh https://your-forgejo-url/setup.sh
sh /tmp/setup.sh
```

### Option B: Manual Setup

1. **Download `ctrld` to the router:**

```sh
ssh root@<router-ip>
cd /cfg
wget -O ctrld.tar.gz 'https://github.com/Control-D-Inc/ctrld/releases/download/v1.5.0/ctrld_1.5.0_linux_arm64.tar.gz'
tar xzf ctrld.tar.gz -C /tmp
mv /tmp/dist/ctrld_*/ctrld /cfg/ctrld
chmod +x /cfg/ctrld
rm -rf /tmp/dist ctrld.tar.gz
```

2. **Upload config files:**

Copy `config/ctrld.toml.example` to `/cfg/ctrld.toml` and `config/post-cfg.sh.example` to `/cfg/post-cfg.sh` on the router. Replace `<YOUR_RESOLVER_ID>` with your ControlD resolver ID in both files.

```sh
# Edit the files on the router
vi /cfg/ctrld.toml
vi /cfg/post-cfg.sh
chmod +x /cfg/post-cfg.sh
```

3. **Apply immediately:**

```sh
/cfg/post-cfg.sh
```

4. **Verify:**

```sh
nslookup google.com        # Should resolve
nslookup google.com 127.0.0.1#5354  # Test ctrld directly
pidof ctrld                 # Should return a PID
```

Check your [ControlD dashboard](https://controld.com) — you should see individual devices with hostnames, IPs, and MAC addresses.

## Configuration Files

### ctrld.toml

The `ctrld` daemon config. Key settings:

| Setting | Purpose |
|---|---|
| `discover_dhcp` | Reads dnsmasq lease file for hostnames |
| `discover_arp` | ARP table discovery for MAC addresses |
| `discover_ptr` | Reverse DNS lookups for hostnames |
| `dhcp_lease_file_path` | Path to `/cfg/dhcp.leases` |
| `send_client_info` | Sends device IP/hostname/MAC to ControlD |

### post-cfg.sh

Runs on every boot. Does the following:

1. Configures `https-dns-proxy` with ControlD URLs (fallback)
2. Restores `dnsmasq` to use `https-dns-proxy`
3. Starts `ctrld` as a daemon on port 5354
4. Health checks `ctrld` before redirecting DNS
5. Adds `iptables` PREROUTING rules to redirect LAN DNS (port 53) to `ctrld` (port 5354)
6. If `ctrld` fails the health check, keeps `https-dns-proxy` as the DNS backend

## Fallback Safety

The setup has two layers of protection:

1. **ctrld health check** — `post-cfg.sh` only adds iptables redirect rules if ctrld passes a DNS resolution test
2. **https-dns-proxy fallback** — Even if ctrld fails, dnsmasq still forwards to `https-dns-proxy` → ControlD. DNS stays encrypted, just without per-device visibility.

If DNS breaks, reboot the router. The `post-cfg.sh` will re-evaluate on boot.

## Firmware Updates

Firmware updates **may** wipe `/cfg/`. Keep backups of:

- `/cfg/ctrld.toml`
- `/cfg/ctrld` (binary)
- `/cfg/post-cfg.sh`

After a firmware update, re-upload the files and run `post-cfg.sh`.

## Removing the Setup

```sh
# Remove iptables rules
iptables -t nat -F PREROUTING

# Stop ctrld
kill $(pidof ctrld)

# Remove persistent config
rm /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh

# Restore default DNS (reboot or run)
/etc/init.d/https-dns-proxy restart
/etc/init.d/dnsmasq restart
```

## Credits

- [ControlD](https://controld.com) — DNS resolver service
- [ctrld](https://github.com/Control-D-Inc/ctrld) — DNS forwarding proxy
- [Alta Labs](https://alta.inc) — Route 10 router

## License

MIT
