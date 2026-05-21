#!/bin/sh
# ControlD watchdog with automatic protocol fallback
# Runs via cron every 5 minutes
# 1. Checks ctrld is alive and DNS resolves
# 2. If failing, tries next protocol in fallback chain
# 3. Logs all actions via syslog

[ -f /cfg/controld.env ] || exit 0
. /cfg/controld.env

# Default protocol for legacy installs
DNS_TYPE=${DNS_TYPE:-doh3}

# Fallback order: each protocol tries the next on failure
FALLBACK_CHAIN="doq doh3 doh"

DNS_PORT=5354
MAX_RESTART_ATTEMPTS=3

# ── Helpers ──

get_endpoint() {
    case "$1" in
        doq) echo "${RESOLVER_ID}.dns.controld.com" ;;
        *)   echo "https://dns.controld.com/${RESOLVER_ID}" ;;
    esac
}

next_protocol() {
    current="$1"
    found=0
    for proto in $FALLBACK_CHAIN; do
        if [ "$found" = "1" ]; then
            echo "$proto"
            return
        fi
        if [ "$proto" = "$current" ]; then
            found=1
        fi
    done
    # Wrap around to first protocol
    echo "$FALLBACK_CHAIN" | awk '{print $1}'
}

write_config() {
    proto="$1"
    endpoint=$(get_endpoint "$proto")
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
    endpoint = "${endpoint}"
    name = "ControlD"
    timeout = 5000
    type = "${proto}"
    send_client_info = true
[listener.0]
    ip = "0.0.0.0"
    port = ${DNS_PORT}
EOF
}

restart_ctrld() {
    kill $(pidof ctrld) 2>/dev/null
    sleep 1
    nohup /cfg/ctrld run -c /cfg/ctrld.toml -d >/dev/null 2>&1 &
    # Wait for ctrld to be ready
    n=0
    while [ $n -lt 10 ]; do
        if nslookup google.com 127.0.0.1#${DNS_PORT} >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        n=$(expr $n + 1)
    done
    return 1
}

# ── Health check ──

# Check 1: Is ctrld running?
if ! pidof ctrld >/dev/null 2>&1; then
    logger -t watchdog "ctrld not running, restarting"
    if restart_ctrld; then
        logger -t watchdog "ctrld restarted successfully (${DNS_TYPE})"
    else
        logger -t watchdog "ctrld restart failed"
    fi
    exit 0
fi

# Check 2: Does DNS resolve through ctrld?
if nslookup google.com 127.0.0.1#${DNS_PORT} >/dev/null 2>&1; then
    # All good, nothing to do
    exit 0
fi

# DNS is failing — try protocol fallback
logger -t watchdog "DNS resolution failed on ${DNS_TYPE}, starting protocol fallback"

# Restore iptables rules if they disappeared
RULES=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c ${DNS_PORT})
if [ "$RULES" -eq 0 ] && pidof ctrld >/dev/null; then
    iptables -t nat -A PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-port ${DNS_PORT}
    iptables -t nat -A PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-port ${DNS_PORT}
    iptables -t nat -A PREROUTING -i br-lan_2 -p udp --dport 53 -j REDIRECT --to-port ${DNS_PORT}
    iptables -t nat -A PREROUTING -i br-lan_2 -p tcp --dport 53 -j REDIRECT --to-port ${DNS_PORT}
    logger -t watchdog "restored missing iptables rules"
fi

# Try each protocol in the fallback chain
attempt=0
proto="$DNS_TYPE"
while [ $attempt -lt 3 ]; do
    proto=$(next_protocol "$proto")
    attempt=$(expr $attempt + 1)

    logger -t watchdog "trying protocol: ${proto} (attempt ${attempt}/3)"
    write_config "$proto"

    if restart_ctrld; then
        # Save working protocol
        sed -i "s/DNS_TYPE=.*/DNS_TYPE=${proto}/" /cfg/controld.env
        logger -t watchdog "fallback to ${proto} succeeded"
        exit 0
    fi
    logger -t watchdog "protocol ${proto} failed"
done

logger -t watchdog "all protocols failed, ctrld may be down. Using https-dns-proxy fallback."
