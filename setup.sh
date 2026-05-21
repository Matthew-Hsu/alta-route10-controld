#!/bin/sh
# ControlD DNS installer for Alta Labs Route 10
# Run this script ON the router:
#   wget -O /tmp/setup.sh https://codeberg.org/CookieTyrant/alta-route10-controld/raw/branch/master/setup.sh
#   sh /tmp/setup.sh
#
# Supports: DoH (HTTP/2), DoH3 (HTTP/3), DoQ (QUIC)
# All prompts have defaults in [brackets] — press Enter to accept.

set -e

VERSION="1.5.0"

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║   Alta Labs Route 10 + ControlD DNS Setup               ║"
echo "  ║   Encrypted DNS with per-device visibility               ║"
echo "  ║   Supports DoH / DoH3 (HTTP/3) / DoQ (QUIC)             ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Preflight checks ──

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo "  [!] Expected aarch64, got $ARCH. This may not work."
    printf "  Continue? [y/N]: "
    read -r CONTINUE
    [ "$CONTINUE" = "y" ] || [ "$CONTINUE" = "Y" ] || exit 1
fi

if [ ! -d /cfg ]; then
    echo "  [!] /cfg/ not found. Is this an Alta Labs router?"
    exit 1
fi

# ── Step 1: Get resolver ID ──

echo "  Step 1: ControlD Configuration"
echo "  Get your resolver ID from: https://controld.com -> Dashboard -> Endpoint Resolvers"
echo ""

printf "  Resolver ID: "
read -r RESOLVER_ID
if [ -z "$RESOLVER_ID" ]; then
    echo "  [!] Resolver ID is required."
    exit 1
fi
if [ ${#RESOLVER_ID} -lt 5 ]; then
    echo "  [!] Resolver ID seems too short. Check your ControlD dashboard."
    exit 1
fi

printf "  Bootstrap IP [76.76.2.22]: "
read -r BOOTSTRAP_IP
BOOTSTRAP_IP=${BOOTSTRAP_IP:-76.76.2.22}

echo ""
echo "  DNS Protocol:"
echo "    1) DoH3 (HTTP/3)  — fastest, uses QUIC transport [default]"
echo "    2) DoQ   (QUIC)   — native QUIC, lower overhead"
echo "    3) DoH   (HTTP/2) — most compatible"
echo ""
printf "  Protocol [1]: "
read -r PROTO_CHOICE
PROTO_CHOICE=${PROTO_CHOICE:-1}
case "$PROTO_CHOICE" in
    1) DNS_TYPE="doh3"; PROTO_LABEL="DoH3 (HTTP/3)" ;;
    2) DNS_TYPE="doq";  PROTO_LABEL="DoQ (QUIC)" ;;
    3) DNS_TYPE="doh";  PROTO_LABEL="DoH (HTTP/2)" ;;
    *)  echo "  [!] Invalid choice, defaulting to DoH3"
        DNS_TYPE="doh3"; PROTO_LABEL="DoH3 (HTTP/3)" ;;
esac

echo ""

# ── Step 2: Check for existing config ──

if [ -f /cfg/post-cfg.sh ] || [ -f /cfg/ctrld ]; then
    echo "  [!] Existing ControlD configuration found."
    printf "  Overwrite? [Y/n]: "
    read -r OVERWRITE
    OVERWRITE=${OVERWRITE:-Y}
    if [ "$OVERWRITE" = "n" ] || [ "$OVERWRITE" = "N" ]; then
        echo "  Aborting."
        exit 0
    fi
    kill $(pidof ctrld) 2>/dev/null || true
fi

# ── Step 3: Download ctrld ──

echo "  Step 2: Installing ctrld v${VERSION}..."
wget -O /tmp/ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/v${VERSION}/ctrld_${VERSION}_linux_arm64.tar.gz" || {
    echo "  [!] Download failed. Check internet connectivity."
    exit 1
}
tar xzf /tmp/ctrld.tar.gz -C /tmp
mv /tmp/dist/ctrld_${VERSION}_linux_arm64/ctrld /cfg/ctrld
chmod +x /cfg/ctrld
rm -rf /tmp/dist /tmp/ctrld.tar.gz
echo "  [OK] ctrld binary installed to /cfg/ctrld"

# ── Step 4: Write recovery config ──

echo "  Step 3: Writing configuration files..."

cat > /cfg/controld.env << EOF
RESOLVER_ID=${RESOLVER_ID}
BOOTSTRAP_IP=${BOOTSTRAP_IP}
CURLD_VERSION=${VERSION}
DNS_TYPE=${DNS_TYPE}
EOF
echo "  [OK] /cfg/controld.env written"

# ── Step 5: Write ctrld.toml ──

# Build upstream endpoint based on protocol
case "${DNS_TYPE}" in
    doq)
        UPSTREAM_ENDPOINT="${RESOLVER_ID}.dns.controld.com"
        ;;
    *)
        UPSTREAM_ENDPOINT="https://dns.controld.com/${RESOLVER_ID}"
        ;;
esac

cat > /cfg/ctrld.toml << EOF
[service]
    log_level = "notice"
    cache_enable = true
    cache_size = 4096
    discover_dhcp = true
    discover_ptr = true
    discover_mdns = false
    discover_arp = true
    discover_hosts = true
    discover_refresh_interval = 60
    dhcp_lease_file_path = "/cfg/dhcp.leases"
    dhcp_lease_file_format = "dnsmasq"
[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "Everyone"
[network.1]
    cidrs = ["192.168.1.0/24"]
    name = "LAN"
[network.2]
    cidrs = ["192.168.2.0/24"]
    name = "LAN2"
[upstream.0]
    bootstrap_ip = "${BOOTSTRAP_IP}"
    endpoint = "${UPSTREAM_ENDPOINT}"
    name = "ControlD"
    timeout = 5000
    type = "${DNS_TYPE}"
    send_client_info = true
[listener.0]
    ip = "0.0.0.0"
    port = 5354
EOF
echo "  [OK] /cfg/ctrld.toml written (${PROTO_LABEL})"

# ── Step 6: Write self-healing post-cfg.sh ──
# NOTE: Single-quoted heredoc prevents variable expansion —
# ${RESOLVER_ID} etc are resolved at runtime when the script sources controld.env

cat > /cfg/post-cfg.sh << 'BOOTSCRIPT'
#!/bin/sh
# Self-healing ControlD setup for Alta Labs Route 10
# Reads /cfg/controld.env and rebuilds everything if missing

[ -f /cfg/controld.env ] || { logger -t post-cfg 'controld.env missing, skipping'; exit 0; }
. /cfg/controld.env

# Default to doh3 for legacy installs without DNS_TYPE
DNS_TYPE=${DNS_TYPE:-doh3}

# Build endpoint from protocol type
case "${DNS_TYPE}" in
    doq) UPSTREAM_ENDPOINT="${RESOLVER_ID}.dns.controld.com" ;;
    *)   UPSTREAM_ENDPOINT="https://dns.controld.com/${RESOLVER_ID}" ;;
esac

logger -t post-cfg "starting with resolver=${RESOLVER_ID} type=${DNS_TYPE}"

# Self-heal: download ctrld binary if missing
if [ ! -x /cfg/ctrld ]; then
    logger -t post-cfg 'ctrld binary missing, downloading...'
    wget -O /tmp/ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/v${CURLD_VERSION}/ctrld_${CURLD_VERSION}_linux_arm64.tar.gz" || { logger -t post-cfg 'ctrld download failed'; exit 1; }
    tar xzf /tmp/ctrld.tar.gz -C /tmp
    mv /tmp/dist/ctrld_${CURLD_VERSION}_linux_arm64/ctrld /cfg/ctrld
    chmod +x /cfg/ctrld
    rm -rf /tmp/dist /tmp/ctrld.tar.gz
    logger -t post-cfg 'ctrld binary restored'
fi

# Self-heal: generate ctrld.toml if missing
if [ ! -f /cfg/ctrld.toml ]; then
    logger -t post-cfg 'ctrld.toml missing, generating from controld.env'
    cat > /cfg/ctrld.toml << TOMLEOF
[service]
    log_level = "notice"
    cache_enable = true
    cache_size = 4096
    discover_dhcp = true
    discover_ptr = true
    discover_mdns = false
    discover_arp = true
    discover_hosts = true
    discover_refresh_interval = 60
    dhcp_lease_file_path = "/cfg/dhcp.leases"
    dhcp_lease_file_format = "dnsmasq"
[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "Everyone"
[network.1]
    cidrs = ["192.168.1.0/24"]
    name = "LAN"
[network.2]
    cidrs = ["192.168.2.0/24"]
    name = "LAN2"
[upstream.0]
    bootstrap_ip = "${BOOTSTRAP_IP}"
    endpoint = "${UPSTREAM_ENDPOINT}"
    name = "ControlD"
    timeout = 5000
    type = "${DNS_TYPE}"
    send_client_info = true
[listener.0]
    ip = "0.0.0.0"
    port = 5354
TOMLEOF
    logger -t post-cfg 'ctrld.toml generated'
fi

# Wait for https-dns-proxy to initialize (kept as fallback)
while ! uci get https-dns-proxy.@https-dns-proxy[0] >/dev/null 2>&1; do sleep 1; done

# Set https-dns-proxy to ControlD as fallback
uci set https-dns-proxy.@https-dns-proxy[0].resolver_url="https://dns.controld.com/${RESOLVER_ID}"
uci set https-dns-proxy.@https-dns-proxy[0].bootstrap_dns="${BOOTSTRAP_IP}"
uci set https-dns-proxy.@https-dns-proxy[1].resolver_url="https://dns.controld.com/${RESOLVER_ID}"
uci set https-dns-proxy.@https-dns-proxy[1].bootstrap_dns="${BOOTSTRAP_IP}"
uci set https-dns-proxy.@https-dns-proxy[2].resolver_url="https://dns.controld.com/${RESOLVER_ID}"
uci set https-dns-proxy.@https-dns-proxy[2].bootstrap_dns="${BOOTSTRAP_IP}"
uci commit https-dns-proxy
/etc/init.d/https-dns-proxy restart

# Restore dnsmasq to use https-dns-proxy (fallback)
uci delete dhcp.@dnsmasq[0].server 2>/dev/null
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5055'
uci set dhcp.@dnsmasq[0].noresolv='0'
uci commit dhcp
/etc/init.d/dnsmasq restart

# Wait for network connectivity
while ! ping -c1 "${BOOTSTRAP_IP}" >/dev/null 2>&1; do sleep 2; done

# Kill any orphaned ctrld from previous boot
kill $(pidof ctrld) 2>/dev/null
sleep 1

# Start ctrld as daemon with config file
nohup /cfg/ctrld run -c /cfg/ctrld.toml -d >/dev/null 2>&1 &

# Wait for ctrld to be ready (up to 15s)
n=0
while [ $n -lt 15 ]; do
    if nslookup google.com 127.0.0.1#5354 >/dev/null 2>&1; then
        break
    fi
    sleep 1
    n=`expr $n + 1`
done

# Only redirect DNS if ctrld is confirmed working
if nslookup google.com 127.0.0.1#5354 >/dev/null 2>&1; then
    iptables -t nat -A PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-port 5354
    iptables -t nat -A PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-port 5354
    iptables -t nat -A PREROUTING -i br-lan_2 -p udp --dport 53 -j REDIRECT --to-port 5354
    iptables -t nat -A PREROUTING -i br-lan_2 -p tcp --dport 53 -j REDIRECT --to-port 5354
    logger -t post-cfg "ctrld started (${DNS_TYPE}) with device discovery, DNS redirected to port 5354"
else
    logger -t post-cfg 'ctrld failed health check, using https-dns-proxy fallback'
fi
BOOTSCRIPT

chmod +x /cfg/post-cfg.sh
echo "  [OK] /cfg/post-cfg.sh written (self-healing)"

# ── Step 6b: Advanced DNS Policy (optional) ──

echo ""
echo "  ── Advanced DNS Policy (optional) ──"
echo "  Route specific devices or networks to different ControlD profiles."
echo "  Requires multiple resolver IDs from your ControlD dashboard."
echo ""
printf "  Configure split DNS policies? [y/N]: "
read -r DO_SPLIT
POLICY_CONF=""

if [ "$DO_SPLIT" = "y" ] || [ "$DO_SPLIT" = "Y" ]; then
    POLICY_UPSTREAMS=""
    POLICY_NETWORKS=""
    POLICY_MACS=""
    UPSTREAM_IDX=1
    NETWORK_IDX=3

    while true; do
        echo ""
        echo "  Adding DNS policy upstream..."
        printf "    Resolver ID (or empty to finish): "
        read -r POLICY_RESOLVER
        [ -z "$POLICY_RESOLVER" ] && break

        printf "    Policy name (e.g. Kids, IoT, Guest): "
        read -r POLICY_NAME
        POLICY_NAME=${POLICY_NAME:-"Policy-${UPSTREAM_IDX}"}

        case "${DNS_TYPE}" in
            doq) POLICY_EP="${POLICY_RESOLVER}.dns.controld.com" ;;
            *)   POLICY_EP="https://dns.controld.com/${POLICY_RESOLVER}" ;;
        esac

        POLICY_UPSTREAMS="${POLICY_UPSTREAMS}
[upstream.${UPSTREAM_IDX}]
    bootstrap_ip = \"${BOOTSTRAP_IP}\"
    endpoint = \"${POLICY_EP}\"
    name = \"ControlD-${POLICY_NAME}\"
    timeout = 5000
    type = \"${DNS_TYPE}\"
    send_client_info = true
"

        echo ""
        echo "    Route to this policy by:"
        echo "      1) Network/subnet (e.g. 192.168.1.200/32)"
        echo "      2) Device MAC address (e.g. AA:BB:CC:DD:EE:FF)"
        echo "      3) Both"
        printf "    Route type [1]: "
        read -r ROUTE_TYPE
        ROUTE_TYPE=${ROUTE_TYPE:-1}

        case "$ROUTE_TYPE" in
            1|3)
                echo ""
                echo "    Enter CIDRs (space-separated). Examples:"
                echo "      192.168.1.200/32       (single device)"
                echo "      192.168.2.0/24         (entire subnet)"
                printf "    CIDRs: "
                read -r CIDR_LIST
                if [ -n "$CIDR_LIST" ]; then
                    CIDR_ARRAY=""
                    for cidr in $CIDR_LIST; do
                        CIDR_ARRAY="${CIDR_ARRAY}\"${cidr}\", "
                    done
                    CIDR_ARRAY=$(echo "$CIDR_ARRAY" | sed 's/, $//')
                    POLICY_NETWORKS="${POLICY_NETWORKS}
[network.${NETWORK_IDX}]
    cidrs = [${CIDR_ARRAY}]
    name = \"${POLICY_NAME}\"
"
                    POLICY_CONF="${POLICY_CONF}
    {\"network.${NETWORK_IDX}\" = [\"upstream.${UPSTREAM_IDX}\"]},"
                    NETWORK_IDX=$(expr $NETWORK_IDX + 1)
                fi
                ;;
        esac

        case "$ROUTE_TYPE" in
            2|3)
                printf "    MAC addresses (space-separated): "
                read -r MAC_LIST
                if [ -n "$MAC_LIST" ]; then
                    for mac in $MAC_LIST; do
                        POLICY_MACS="${POLICY_MACS}
    {\"${mac}\" = [\"upstream.${UPSTREAM_IDX}\"]},"
                    done
                fi
                ;;
        esac

        UPSTREAM_IDX=$(expr $UPSTREAM_IDX + 1)
    done

    # Append policy config to ctrld.toml
    if [ -n "$POLICY_UPSTREAMS" ] || [ -n "$POLICY_NETWORKS" ]; then
        echo "" >> /cfg/ctrld.toml
        echo "# Policy upstreams" >> /cfg/ctrld.toml
        echo "$POLICY_UPSTREAMS" >> /cfg/ctrld.toml
        echo "# Policy networks" >> /cfg/ctrld.toml
        echo "$POLICY_NETWORKS" >> /cfg/ctrld.toml

        if [ -n "$POLICY_CONF" ] || [ -n "$POLICY_MACS" ]; then
            POLICY_CONF=$(echo "$POLICY_CONF" | sed '$ s/,$//')
            POLICY_MACS=$(echo "$POLICY_MACS" | sed '$ s/,$//')

            echo "" >> /cfg/ctrld.toml
            echo "[listener.0.policy]" >> /cfg/ctrld.toml
            echo "    name = \"Split DNS Policy\"" >> /cfg/ctrld.toml
            if [ -n "$POLICY_CONF" ]; then
                echo "    networks = [" >> /cfg/ctrld.toml
                echo "$POLICY_CONF" >> /cfg/ctrld.toml
                echo "    ]" >> /cfg/ctrld.toml
            fi
            if [ -n "$POLICY_MACS" ]; then
                echo "    macs = [" >> /cfg/ctrld.toml
                echo "$POLICY_MACS" >> /cfg/ctrld.toml
                echo "    ]" >> /cfg/ctrld.toml
            fi
        fi

        echo "POLICY_UPSTREAMS=${UPSTREAM_IDX}" >> /cfg/controld.env
        echo "  [OK] Split DNS policy configured"
    fi
fi

# ── Step 6c: Install watchdog ──

cat > /cfg/watchdog.sh << 'WATCHDOG'
#!/bin/sh
# ControlD watchdog with automatic protocol fallback
# Runs via cron every 5 minutes
[ -f /cfg/controld.env ] || exit 0
. /cfg/controld.env
DNS_TYPE=${DNS_TYPE:-doh3}
FALLBACK_CHAIN="doq doh3 doh"
DNS_PORT=5354

get_endpoint() {
    case "$1" in
        doq) echo "${RESOLVER_ID}.dns.controld.com" ;;
        *)   echo "https://dns.controld.com/${RESOLVER_ID}" ;;
    esac
}

next_protocol() {
    current="$1"; found=0
    for proto in $FALLBACK_CHAIN; do
        if [ "$found" = "1" ]; then echo "$proto"; return; fi
        [ "$proto" = "$current" ] && found=1
    done
    echo "$FALLBACK_CHAIN" | awk '{print $1}'
}

restart_ctrld() {
    kill $(pidof ctrld) 2>/dev/null; sleep 1
    nohup /cfg/ctrld run -c /cfg/ctrld.toml -d >/dev/null 2>&1 &
    n=0
    while [ $n -lt 10 ]; do
        nslookup google.com 127.0.0.1#${DNS_PORT} >/dev/null 2>&1 && return 0
        sleep 1; n=$(expr $n + 1)
    done
    return 1
}

# Check if ctrld is running
if ! pidof ctrld >/dev/null 2>&1; then
    logger -t watchdog "ctrld not running, restarting"
    restart_ctrld && logger -t watchdog "ctrld restarted (${DNS_TYPE})"
    exit 0
fi

# Check DNS resolution
if nslookup google.com 127.0.0.1#${DNS_PORT} >/dev/null 2>&1; then
    exit 0
fi

# DNS failing — try protocol fallback
logger -t watchdog "DNS failed on ${DNS_TYPE}, starting fallback"

# Restore iptables if missing
RULES=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c ${DNS_PORT})
if [ "$RULES" -eq 0 ]; then
    iptables -t nat -A PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-port ${DNS_PORT}
    iptables -t nat -A PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-port ${DNS_PORT}
    iptables -t nat -A PREROUTING -i br-lan_2 -p udp --dport 53 -j REDIRECT --to-port ${DNS_PORT}
    iptables -t nat -A PREROUTING -i br-lan_2 -p tcp --dport 53 -j REDIRECT --to-port ${DNS_PORT}
    logger -t watchdog "restored iptables rules"
fi

proto="$DNS_TYPE"; attempt=0
while [ $attempt -lt 3 ]; do
    proto=$(next_protocol "$proto"); attempt=$(expr $attempt + 1)
    logger -t watchdog "trying ${proto} (attempt ${attempt}/3)"
    endpoint=$(get_endpoint "$proto")
    sed -i "s/endpoint = \".*\"/endpoint = \"${endpoint}\"/" /cfg/ctrld.toml
    sed -i "s/type = \"[a-z0-9]*\"/type = \"${proto}\"/" /cfg/ctrld.toml
    if restart_ctrld; then
        sed -i "s/DNS_TYPE=.*/DNS_TYPE=${proto}/" /cfg/controld.env
        logger -t watchdog "fallback to ${proto} succeeded"
        exit 0
    fi
done
logger -t watchdog "all protocols failed"
WATCHDOG
chmod +x /cfg/watchdog.sh

# Install watchdog cron (every 5 minutes)
crontab -l 2>/dev/null | grep -v watchdog | crontab -
(crontab -l 2>/dev/null; echo '*/5 * * * * /cfg/watchdog.sh') | crontab - 2>/dev/null || {
    echo "  [!] Could not install watchdog cron"
}
echo "  [OK] Watchdog installed (5-min health check + protocol fallback)"

# ── Step 7: Write auto-update script ──

cat > /cfg/controld-update.sh << 'UPDATESCRIPT'
#!/bin/sh
# Weekly auto-update for ctrld
[ -f /cfg/controld.env ] || exit 0
. /cfg/controld.env

LATEST=$(wget -qO- 'https://api.github.com/repos/Control-D-Inc/ctrld/releases/latest' | grep '"tag_name"' | grep -o 'v[0-9.]*')
[ -z "$LATEST" ] && exit 0
CURRENT="v${CURLD_VERSION}"

if [ "$LATEST" != "$CURRENT" ]; then
    VER=${LATEST#v}
    logger -t controld-update "Updating ctrld from ${CURRENT} to ${LATEST}"
    wget -O /tmp/ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/${LATEST}/ctrld_${VER}_linux_arm64.tar.gz" || exit 1
    tar xzf /tmp/ctrld.tar.gz -C /tmp || exit 1
    kill $(pidof ctrld) 2>/dev/null
    mv /tmp/dist/ctrld_${VER}_linux_arm64/ctrld /cfg/ctrld
    chmod +x /cfg/ctrld
    rm -rf /tmp/dist /tmp/ctrld.tar.gz
    sed -i "s/CURLD_VERSION=.*/CURLD_VERSION=${VER}/" /cfg/controld.env
    /cfg/ctrld run -c /cfg/ctrld.toml -d >/dev/null 2>&1 &
    logger -t controld-update "ctrld updated to ${LATEST}"
fi
UPDATESCRIPT

chmod +x /cfg/controld-update.sh
echo "  [OK] /cfg/controld-update.sh written"

# ── Step 8: Install cron job for weekly updates ──

crontab -l 2>/dev/null | grep -v controld-update | crontab -
(crontab -l 2>/dev/null; echo '0 3 * * 1 /cfg/controld-update.sh') | crontab - 2>/dev/null || {
    echo "  [!] Could not install cron job (non-fatal, auto-update won't run)"
}
echo "  [OK] Weekly auto-update cron installed"

# ── Step 9: Apply configuration ──

echo ""
echo "  Step 3: Applying configuration..."

/cfg/post-cfg.sh || {
    echo "  [!] post-cfg.sh reported errors. DNS may still be stabilizing."
}

# ── Step 10: Verify ──

echo ""
echo "  Step 4: Verification..."
echo ""

if pidof ctrld >/dev/null; then
    echo "  [OK] ctrld is running (PID $(pidof ctrld))"
else
    echo "  [!] ctrld is NOT running"
fi

if nslookup google.com 127.0.0.1#5354 >/dev/null 2>&1; then
    echo "  [OK] ctrld DNS responding on port 5354"
else
    echo "  [!] ctrld not responding on port 5354 (may need a moment)"
fi

RULES=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c 5354)
if [ "$RULES" -gt 0 ]; then
    echo "  [OK] iptables redirect rules active (${RULES} rules)"
else
    echo "  [!] No iptables redirect rules"
fi

if nslookup google.com >/dev/null 2>&1; then
    echo "  [OK] System DNS working"
else
    echo "  [!] System DNS not working"
fi

# ── Done ──

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║                    Setup Complete!                       ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Your DNS is now routed through ControlD via ${PROTO_LABEL}."
echo ""
echo "  Check your dashboard: https://controld.com"
echo "  Individual devices should appear within a few minutes."
echo ""
echo "  Installed on router:"
echo "    /cfg/controld.env         Recovery config (self-healing)"
echo "    /cfg/ctrld                DNS proxy binary"
echo "    /cfg/ctrld.toml           DNS proxy configuration"
echo "    /cfg/post-cfg.sh          Self-healing boot script"
echo "    /cfg/controld-update.sh   Weekly auto-update"
echo "    /cfg/watchdog.sh          5-min health check + protocol fallback"
echo ""
echo "  To check:      sh status.sh"
echo "  To benchmark:  sh benchmark.sh"
echo "  To uninstall:  sh uninstall.sh"
echo ""
