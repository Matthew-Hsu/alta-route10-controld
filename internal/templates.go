package internal

import "strings"

const CtrlDVersion = "1.5.0"

// ControldEnv is the tiny recovery config stored on the router.
// If this file survives, everything else self-heals on boot.
const ControldEnv = `RESOLVER_ID=PLACEHOLDER_RESOLVER_ID
BOOTSTRAP_IP=PLACEHOLDER_BOOTSTRAP
CURLD_VERSION=PLACEHOLDER_VERSION
`

// ControldUpdateSh is the weekly auto-update cron script.
// Checks GitHub for new ctrld releases and updates in-place.
const ControldUpdateSh = `#!/bin/sh
[ -f /cfg/controld.env ] || exit 0
. /cfg/controld.env

LATEST=$(wget -qO- 'https://api.github.com/repos/Control-D-Inc/ctrld/releases/latest' | grep '"tag_name"' | grep -o 'v[0-9.]*')
[ -z "$LATEST" ] && exit 0
CURRENT="v${CURLD_VERSION}"

if [ "$LATEST" != "$CURRENT" ]; then
    VERSION=${LATEST#v}
    logger -t controld-update "Updating ctrld from ${CURRENT} to ${LATEST}"
    wget -O /tmp/ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/${LATEST}/ctrld_${VERSION}_linux_arm64.tar.gz" || exit 1
    tar xzf /tmp/ctrld.tar.gz -C /tmp || exit 1
    kill $(pidof ctrld) 2>/dev/null
    mv /tmp/dist/ctrld_${VERSION}_linux_arm64/ctrld /cfg/ctrld
    chmod +x /cfg/ctrld
    rm -rf /tmp/dist /tmp/ctrld.tar.gz
    sed -i "s/CURLD_VERSION=.*/CURLD_VERSION=${VERSION}/" /cfg/controld.env
    /cfg/ctrld run -c /cfg/ctrld.toml -d >/dev/null 2>&1 &
    logger -t controld-update "ctrld updated to ${LATEST}"
fi
`

// PostCfgShTemplate is the self-healing boot script.
// Uses BKTICK as placeholder for backtick (can't use backtick in Go raw string).
// The init() function replaces BKTICK with actual backticks at startup.
var PostCfgShTemplate = `#!/bin/sh
# Self-healing ControlD setup for Alta Labs Route 10
# Reads /cfg/controld.env and rebuilds everything if missing

[ -f /cfg/controld.env ] || { logger -t post-cfg 'controld.env missing, skipping'; exit 0; }
. /cfg/controld.env

logger -t post-cfg "starting with resolver=${RESOLVER_ID}"

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
    logger -t post-cfg 'ctrld.toml missing, generating...'
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
    endpoint = "https://dns.controld.com/${RESOLVER_ID}"
    name = "ControlD"
    timeout = 5000
    type = "doh"
    send_client_info = true
[listener.0]
    ip = "0.0.0.0"
    port = 5354
EOF
    logger -t post-cfg 'ctrld.toml generated'
fi

# Wait for https-dns-proxy to initialize (kept as fallback)
while ! uci get https-dns-proxy.@https-dns-proxy[0] >/dev/null 2>&1; do sleep 1; done

# Set https-dns-proxy to ControlD as fallback
uci set https-dns-proxy.@https-dns-proxy[0].resolver_url='https://dns.controld.com/PLACEHOLDER_RESOLVER_ID'
uci set https-dns-proxy.@https-dns-proxy[0].bootstrap_dns='PLACEHOLDER_BOOTSTRAP'
uci set https-dns-proxy.@https-dns-proxy[1].resolver_url='https://dns.controld.com/PLACEHOLDER_RESOLVER_ID'
uci set https-dns-proxy.@https-dns-proxy[1].bootstrap_dns='PLACEHOLDER_BOOTSTRAP'
uci set https-dns-proxy.@https-dns-proxy[2].resolver_url='https://dns.controld.com/PLACEHOLDER_RESOLVER_ID'
uci set https-dns-proxy.@https-dns-proxy[2].bootstrap_dns='PLACEHOLDER_BOOTSTRAP'
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
while ! ping -c1 PLACEHOLDER_BOOTSTRAP >/dev/null 2>&1; do sleep 2; done

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
    n=BKTICKexpr $n + 1BKTICK
done

# Only redirect DNS if ctrld is confirmed working
if nslookup google.com 127.0.0.1#5354 >/dev/null 2>&1; then
    iptables -t nat -A PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-port 5354
    iptables -t nat -A PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-port 5354
    iptables -t nat -A PREROUTING -i br-lan_2 -p udp --dport 53 -j REDIRECT --to-port 5354
    iptables -t nat -A PREROUTING -i br-lan_2 -p tcp --dport 53 -j REDIRECT --to-port 5354
    logger -t post-cfg 'ctrld started with device discovery, DNS redirected to port 5354'
else
    logger -t post-cfg 'ctrld failed health check, using https-dns-proxy fallback'
fi
`

func init() {
	PostCfgShTemplate = strings.ReplaceAll(PostCfgShTemplate, "BKTICK", "`")
}

// RenderCtrlDTOML generates the ctrld.toml config from template.
func RenderCtrlDTOML(resolverID, bootstrapIP string) string {
	// Build TOML using shell heredoc style for the self-healing script
	return `[service]
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
    bootstrap_ip = "` + bootstrapIP + `"
    endpoint = "https://dns.controld.com/` + resolverID + `"
    name = "ControlD"
    timeout = 5000
    type = "doh"
    send_client_info = true
[listener.0]
    ip = "0.0.0.0"
    port = 5354
`
}

// RenderPostCfgSh replaces placeholders in the self-healing boot script.
func RenderPostCfgSh(resolverID, bootstrapIP string) string {
	s := strings.ReplaceAll(PostCfgShTemplate, "PLACEHOLDER_RESOLVER_ID", resolverID)
	return strings.ReplaceAll(s, "PLACEHOLDER_BOOTSTRAP", bootstrapIP)
}

// RenderControldEnv generates the recovery config.
func RenderControldEnv(resolverID, bootstrapIP, version string) string {
	s := strings.ReplaceAll(ControldEnv, "PLACEHOLDER_RESOLVER_ID", resolverID)
	s = strings.ReplaceAll(s, "PLACEHOLDER_BOOTSTRAP", bootstrapIP)
	return strings.ReplaceAll(s, "PLACEHOLDER_VERSION", version)
}

// RenderControldUpdateSh generates the auto-update cron script.
func RenderControldUpdateSh() string {
	return ControldUpdateSh
}
