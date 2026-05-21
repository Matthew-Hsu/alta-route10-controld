#!/bin/sh
# lib.sh — shared function library for Alta Route 10 + ControlD
# Source this file: . /path/to/lib.sh

VERSION="1.5.0"
DNS_PORT=5354
FALLBACK_CHAIN="doq doh3 doh"

# ── Colors ──

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

# ── Output ──

print_ok()   { printf "  ${GREEN}[OK]${RESET}  %s\n" "$1"; }
print_fail() { printf "  ${RED}[!!]${RESET} %s\n" "$1"; }
print_warn() { printf "  ${YELLOW}[~~]${RESET} %s\n" "$1"; }
print_info() { printf "  ${BLUE}[--]${RESET} %s\n" "$1"; }

print_step() {
    printf "\n  ${BOLD}%s${RESET}\n" "$1"
}

print_header() {
    printf "\n  ${BOLD}${BLUE}%s${RESET}\n" "$1"
}

die() {
    print_fail "$1"
    exit 1
}

print_banner() {
    printf "
  ${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗
  ║   Alta Labs Route 10 + ControlD DNS                     ║
  ║   Encrypted DNS with per-device visibility               ║
  ╚══════════════════════════════════════════════════════════╝${RESET}
"
}

# ── Help / Version ──

show_version() {
    printf "  controld-tools %s\n" "$VERSION"
}

# ── Config Helpers ──

# Load env file, set defaults for missing values
load_env() {
    local env_file="${1:-/cfg/controld.env}"
    [ -f "$env_file" ] || return 1
    # shellcheck source=/dev/null
    . "$env_file"
    DNS_TYPE="${DNS_TYPE:-doh3}"
    BOOTSTRAP_IP="${BOOTSTRAP_IP:-76.76.2.22}"
    return 0
}

# Build upstream endpoint URL from protocol type and resolver ID
# Usage: get_endpoint <type> <resolver_id>
get_endpoint() {
    local type="$1"
    local resolver="$2"
    case "$type" in
        doq) printf "%s.dns.controld.com" "$resolver" ;;
        dot) printf "%s.dns.controld.com" "$resolver" ;;
        *)   printf "https://dns.controld.com/%s" "$resolver" ;;
    esac
}

# Get human-readable protocol label
# Usage: proto_label <type>
proto_label() {
    case "$1" in
        doh3) printf "DoH3 (HTTP/3)" ;;
        doq)  printf "DoQ (QUIC)" ;;
        doh)  printf "DoH (HTTP/2)" ;;
        dot)  printf "DoT (TLS)" ;;
        *)    printf "%s" "$1" ;;
    esac
}

# Get next protocol in fallback chain
# Usage: next_proto <current_type>
next_proto() {
    local current="$1"
    local found=0
    for proto in $FALLBACK_CHAIN; do
        if [ "$found" = "1" ]; then
            printf "%s" "$proto"
            return
        fi
        [ "$proto" = "$current" ] && found=1
    done
    # Wrap around
    printf "%s" "$(echo "$FALLBACK_CHAIN" | awk '{print $1}')"
}

# Generate ctrld.toml config
# Usage: write_ctrld_config <output_file> <resolver> <bootstrap> <type> [extra_upstreams] [policy]
write_ctrld_config() {
    local outfile="$1"
    local resolver="$2"
    local bootstrap="$3"
    local type="$4"
    local endpoint
    endpoint=$(get_endpoint "$type" "$resolver")

    cat > "$outfile" << EOF
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
    bootstrap_ip = "${bootstrap}"
    endpoint = "${endpoint}"
    name = "ControlD"
    timeout = 5000
    type = "${type}"
    send_client_info = true

[listener.0]
    ip = "0.0.0.0"
    port = ${DNS_PORT}
EOF
}

# ── Process Management ──

# Kill any running ctrld process
stop_ctrld() {
    kill "$(pidof ctrld 2>/dev/null)" 2>/dev/null || true
    sleep 1
}

# Start ctrld and wait for it to be ready
# Usage: start_ctrld <config_file> [timeout_secs]
start_ctrld() {
    local config="${1:-/cfg/ctrld.toml}"
    local timeout="${2:-15}"
    nohup /cfg/ctrld run -c "$config" -d >/dev/null 2>&1 &
    local n=0
    while [ "$n" -lt "$timeout" ]; do
        if check_dns "127.0.0.1#${DNS_PORT}"; then
            return 0
        fi
        sleep 1
        n=$((n + 1))
    done
    return 1
}

# Restart ctrld: stop + start
restart_ctrld() {
    stop_ctrld
    start_ctrld "$@"
}

# ── Health Checks ──

# Test DNS resolution
# Usage: check_dns [server]  (default: system DNS)
check_dns() {
    local server="${1:-}"
    if [ -n "$server" ]; then
        nslookup google.com "$server" >/dev/null 2>&1
    else
        nslookup google.com >/dev/null 2>&1
    fi
}

# Ensure iptables redirect rules are in place
ensure_iptables() {
    local port="${1:-$DNS_PORT}"
    local count
    count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "$port")
    if [ "$count" -eq 0 ]; then
        iptables -t nat -A PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-port "$port"
        iptables -t nat -A PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-port "$port"
        iptables -t nat -A PREROUTING -i br-lan_2 -p udp --dport 53 -j REDIRECT --to-port "$port"
        iptables -t nat -A PREROUTING -i br-lan_2 -p tcp --dport 53 -j REDIRECT --to-port "$port"
        return 0
    fi
    return 1
}

# ── Input Validation ──

# Validate resolver ID (alphanumeric, 5+ chars)
valid_resolver() {
    local id="$1"
    [ ${#id} -ge 5 ] && echo "$id" | grep -qE '^[a-z0-9]+$'
}

# Validate MAC address format
valid_mac() {
    local mac="$1"
    echo "$mac" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

# Validate CIDR format
valid_cidr() {
    local cidr="$1"
    echo "$cidr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'
}

# Validate protocol type
valid_proto() {
    case "$1" in
        doh3|doq|doh|dot) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Router Detection ──

is_alta_router() {
    [ -d /cfg ] && [ "$(uname -m)" = "aarch64" ]
}
