#!/bin/sh
# ControlD DNS installer for Alta Labs Route 10
# Run this script ON the router:
#   wget -O /tmp/setup.sh https://codeberg.org/CookieTyrant/alta-route10-controld/raw/branch/master/setup.sh
#   sh /tmp/setup.sh
#
# Supports: DoH (HTTP/2), DoH3 (HTTP/3), DoQ (QUIC)
# All prompts have defaults in [brackets] -- press Enter to accept.

set -e

# ── Source shared library ──

LIB_DIR="$(dirname "$0")"
if [ -f "${LIB_DIR}/lib.sh" ]; then
    # shellcheck source=lib.sh
    . "${LIB_DIR}/lib.sh"
elif [ -f /cfg/lib.sh ]; then
    # Running on a router where lib.sh was installed to /cfg/
    # shellcheck source=/dev/null
    . /cfg/lib.sh
else
    echo "  [!!] lib.sh not found in ${LIB_DIR} or /cfg/" >&2
    exit 1
fi

# ── Usage ──

show_help() {
    print_banner
    cat << 'HELPEOF'

  Usage: setup.sh [OPTIONS]

  Interactive installer for ControlD encrypted DNS on Alta Labs Route 10.
  When run without flags, walks you through each step with prompts.

  Options:
    --protocol <type>   DNS protocol: doh3, doq, doh, dot
                        (skips interactive protocol prompt)
    --resolver <id>     ControlD resolver ID from your dashboard
                        (skips interactive resolver prompt)
    --help              Show this help message and exit
    --version           Show version and exit

  Non-interactive mode:
    Use --protocol and --resolver together to run without any prompts.
    Both flags are required for fully non-interactive operation.

  Examples:
    sh setup.sh                                  # full interactive
    sh setup.sh --resolver abc123 --protocol doh3  # non-interactive
    sh setup.sh --help                           # show this help

  Installed files (on router):
    /cfg/controld.env         Recovery config (self-healing)
    /cfg/ctrld                DNS proxy binary
    /cfg/ctrld.toml           DNS proxy configuration
    /cfg/post-cfg.sh          Self-healing boot script
    /cfg/controld-update.sh   Weekly auto-update
    /cfg/watchdog.sh          5-min health check + protocol fallback

  More info: https://controld.com -> Dashboard -> Endpoint Resolvers
HELPEOF
}

# ── Parse flags ──

FLAG_PROTOCOL=""
FLAG_RESOLVER=""
FLAG_HELP=""
FLAG_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --protocol)
            [ -z "${2:-}" ] && die "--protocol requires an argument (doh3, doq, doh, dot)"
            FLAG_PROTOCOL="$2"
            shift 2
            ;;
        --resolver)
            [ -z "${2:-}" ] && die "--resolver requires an argument (your resolver ID)"
            FLAG_RESOLVER="$2"
            shift 2
            ;;
        --help|-h)
            FLAG_HELP=1
            shift
            ;;
        --version|-v)
            FLAG_VERSION=1
            shift
            ;;
        *)
            die "Unknown option: $1  (try --help)"
            ;;
    esac
done

# Handle --version early
if [ -n "$FLAG_VERSION" ]; then
    show_version
    exit 0
fi

# Handle --help early
if [ -n "$FLAG_HELP" ]; then
    show_help
    exit 0
fi

print_banner

# ── Preflight checks ──

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
    print_warn "Expected aarch64, got ${ARCH}. This may not work."
    printf "  Continue? [y/N]: "
    read -r CONTINUE
    [ "$CONTINUE" = "y" ] || [ "$CONTINUE" = "Y" ] || exit 1
fi

if ! is_alta_router; then
    if [ ! -d /cfg ]; then
        die "/cfg/ not found. Is this an Alta Labs router?"
    fi
fi

# ── Step 1: Get resolver ID ──

print_step "Step 1: ControlD Configuration"

RESOLVER_ID="${FLAG_RESOLVER}"
if [ -z "$RESOLVER_ID" ]; then
    print_info "Get your resolver ID from: https://controld.com -> Dashboard -> Endpoint Resolvers"
    printf "  Resolver ID: "
    read -r RESOLVER_ID
fi

if [ -z "$RESOLVER_ID" ]; then
    die "Resolver ID is required."
fi

if ! valid_resolver "$RESOLVER_ID"; then
    die "Resolver ID seems invalid (must be 5+ lowercase alphanumeric characters)."
fi

if [ -z "$FLAG_RESOLVER" ]; then
    printf "  Bootstrap IP [76.76.2.22]: "
    read -r BOOTSTRAP_IP
fi
BOOTSTRAP_IP="${BOOTSTRAP_IP:-76.76.2.22}"

# ── Step 1b: Protocol selection ──

DNS_TYPE="${FLAG_PROTOCOL}"
if [ -z "$DNS_TYPE" ]; then
    printf "\n  ${BOLD}${BLUE}════════════════════════════════════════════════════════════${RESET}\n"
    printf "  ${BOLD}Choose Your DNS Protocol${RESET}\n"
    printf "  ${BOLD}${BLUE}════════════════════════════════════════════════════════════${RESET}\n\n"

    printf "  ${BOLD}1) DoH3 — DNS-over-HTTPS/3  (HTTP/3 + QUIC)${RESET}  ${GREEN}[recommended]${RESET}\n"
    printf "     ${DIM}Port 443 | Looks like normal HTTPS traffic\n"
    printf "     Fastest for most ISPs. Hard to block or identify as DNS.${RESET}\n\n"

    printf "  ${BOLD}2) DoQ — DNS-over-QUIC${RESET}\n"
    printf "     ${DIM}Port 853 | Purpose-built DNS over QUIC\n"
    printf "     Lowest protocol overhead. ISPs can see it's DNS traffic.${RESET}\n\n"

    printf "  ${BOLD}3) DoH — DNS-over-HTTPS/2  (HTTP/2 + TCP)${RESET}\n"
    printf "     ${DIM}Port 443 | Most widely compatible\n"
    printf "     No QUIC — higher latency but works everywhere.${RESET}\n\n"

    printf "  ${BOLD}4) Benchmark — test all three and pick the fastest${RESET}\n"
    printf "     ${DIM}Runs 10 queries per protocol, takes about 30 seconds.${RESET}\n\n"

    printf "  ${DIM}All protocols encrypt your DNS. The difference is speed and stealth.${RESET}\n"
    printf "  ${DIM}The watchdog will auto-fallback (DoQ -> DoH3 -> DoH) if one fails.${RESET}\n\n"

    printf "  Choice [1]: "
    read -r PROTO_CHOICE
    PROTO_CHOICE="${PROTO_CHOICE:-1}"

    case "$PROTO_CHOICE" in
        1) DNS_TYPE="doh3" ;;
        2) DNS_TYPE="doq"  ;;
        3) DNS_TYPE="doh"  ;;
        4)
            # ── Inline benchmark ──
            print_step "Benchmarking DNS protocols..."
            printf "  ${DIM}Testing 10 queries per protocol against your ControlD endpoint...${RESET}\n\n"

            BENCH_PORT=5360
            BENCH_QUERIES=10
            BENCH_DOMAINS="google.com cloudflare.com amazon.com wikipedia.org github.com"
            BENCH_FASTEST=""
            BENCH_FASTEST_MS=999999

            # Download ctrld first if not already present (needed for benchmark)
            if [ ! -x /cfg/ctrld ]; then
                print_info "Downloading ctrld for benchmark..."
                wget -O /tmp/ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/v${VERSION}/ctrld_${VERSION}_linux_arm64.tar.gz" >/dev/null 2>&1 || die "Download failed"
                tar xzf /tmp/ctrld.tar.gz -C /tmp
                mv "/tmp/dist/ctrld_${VERSION}_linux_arm64/ctrld" /cfg/ctrld
                chmod +x /cfg/ctrld
                rm -rf /tmp/dist /tmp/ctrld.tar.gz
            fi

            for BPROTO in doq doh3 doh; do
                BLABEL=$(proto_label "$BPROTO")
                BENDPOINT=$(get_endpoint "$BPROTO" "$RESOLVER_ID")

                # Write temp config
                cat > /tmp/ctrld-bench.toml << EOF
[service]
    log_level = "error"
    cache_enable = false
[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "bench"
[upstream.0]
    bootstrap_ip = "${BOOTSTRAP_IP}"
    endpoint = "${BENDPOINT}"
    name = "bench"
    timeout = 5000
    type = "${BPROTO}"
    send_client_info = false
[listener.0]
    ip = "127.0.0.1"
    port = ${BENCH_PORT}
EOF

                kill "$(pidof ctrld 2>/dev/null)" 2>/dev/null || true
                sleep 1
                /cfg/ctrld run -c /tmp/ctrld-bench.toml -d >/dev/null 2>&1 &

                # Wait for ready
                _bn=0
                while [ "$_bn" -lt 10 ]; do
                    nslookup google.com "127.0.0.1#${BENCH_PORT}" >/dev/null 2>&1 && break
                    sleep 1; _bn=$((_bn + 1))
                done

                if [ "$_bn" -eq 10 ]; then
                    printf "  %-18s ${RED}FAILED${RESET}  (could not connect)\n" "$BLABEL"
                    kill "$(pidof ctrld 2>/dev/null)" 2>/dev/null || true
                    continue
                fi

                # Run queries
                _bt=0; _bs=0; _bf=0
                for _bi in $(seq 1 "$BENCH_QUERIES"); do
                    _bd=$(echo "$BENCH_DOMAINS" | awk "{print \$(((_bi - 1) % 5 + 1))}")
                    _bs1=$(date +%s%N 2>/dev/null || date +%s)
                    if nslookup "$_bd" "127.0.0.1#${BENCH_PORT}" >/dev/null 2>&1; then
                        _bs2=$(date +%s%N 2>/dev/null || date +%s)
                        if [ -n "$_bs1" ] && [ "${#_bs1}" -gt 9 ]; then
                            _bel=$(( (_bs2 - _bs1) / 1000000 ))
                        else
                            _bel=$(( (_bs2 - _bs1) * 1000 ))
                            [ "$_bel" -eq 0 ] && _bel=1
                        fi
                        _bt=$((_bt + _bel)); _bs=$((_bs + 1))
                    else
                        _bf=$((_bf + 1))
                    fi
                done

                kill "$(pidof ctrld 2>/dev/null)" 2>/dev/null || true
                sleep 1

                if [ "$_bs" -eq 0 ]; then
                    printf "  %-18s ${RED}FAILED${RESET}  (0/${BENCH_QUERIES} succeeded)\n" "$BLABEL"
                    continue
                fi

                _bavg=$((_bt / _bs))

                if [ "$_bavg" -lt "$BENCH_FASTEST_MS" ]; then
                    BENCH_FASTEST_MS=$_bavg
                    BENCH_FASTEST=$BPROTO
                    printf "  %-18s ${GREEN}%dms${RESET} avg   %d/%d ok   ${DIM}<-- fastest${RESET}\n" "$BLABEL" "$_bavg" "$_bs" "$BENCH_QUERIES"
                else
                    printf "  %-18s ${BOLD}%dms${RESET} avg   %d/%d ok\n" "$BLABEL" "$_bavg" "$_bs" "$BENCH_QUERIES"
                fi
            done

            rm -f /tmp/ctrld-bench.toml

            if [ -n "$BENCH_FASTEST" ]; then
                DNS_TYPE="$BENCH_FASTEST"
                printf "\n  ${GREEN}${BOLD}>>> Fastest: %s (%dms avg)${RESET} — selected automatically.\n" "$(proto_label "$DNS_TYPE")" "$BENCH_FASTEST_MS"
            else
                DNS_TYPE="doh3"
                print_warn "All protocols failed benchmark. Defaulting to DoH3."
            fi
            printf "\n"
            ;;
        *)  print_warn "Invalid choice, defaulting to DoH3"
            DNS_TYPE="doh3" ;;
    esac
fi

if ! valid_proto "$DNS_TYPE"; then
    die "Invalid protocol '${DNS_TYPE}'. Must be one of: doh3, doq, doh, dot"
fi

PLABEL="$(proto_label "$DNS_TYPE")"

printf "\n"

# ── Step 2: Check for existing config ──

if [ -f /cfg/post-cfg.sh ] || [ -f /cfg/ctrld ]; then
    print_warn "Existing ControlD configuration found."
    if [ -z "$FLAG_RESOLVER" ]; then
        printf "  Overwrite? [Y/n]: "
        read -r OVERWRITE
        OVERWRITE="${OVERWRITE:-Y}"
        if [ "$OVERWRITE" = "n" ] || [ "$OVERWRITE" = "N" ]; then
            print_info "Aborting."
            exit 0
        fi
    fi
    stop_ctrld
fi

# ── Step 3: Download ctrld ──

print_step "Step 2: Installing ctrld v${VERSION}..."

wget -O /tmp/ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/v${VERSION}/ctrld_${VERSION}_linux_arm64.tar.gz" || {
    die "Download failed. Check internet connectivity."
}
tar xzf /tmp/ctrld.tar.gz -C /tmp
mv "/tmp/dist/ctrld_${VERSION}_linux_arm64/ctrld" /cfg/ctrld
chmod +x /cfg/ctrld
rm -rf /tmp/dist /tmp/ctrld.tar.gz
print_ok "ctrld binary installed to /cfg/ctrld"

# ── Step 4: Write recovery config ──

print_step "Step 3: Writing configuration files..."

cat > /cfg/controld.env << EOF
RESOLVER_ID=${RESOLVER_ID}
BOOTSTRAP_IP=${BOOTSTRAP_IP}
CURLD_VERSION=${VERSION}
DNS_TYPE=${DNS_TYPE}
EOF
print_ok "/cfg/controld.env written"

# ── Step 5: Write ctrld.toml ──

write_ctrld_config /cfg/ctrld.toml "$RESOLVER_ID" "$BOOTSTRAP_IP" "$DNS_TYPE"
print_ok "/cfg/ctrld.toml written (${PLABEL})"

# ── Step 6: Write self-healing post-cfg.sh ──
# NOTE: Single-quoted heredoc prevents variable expansion --
# ${RESOLVER_ID} etc are resolved at runtime when the script sources controld.env

cat > /cfg/post-cfg.sh << 'BOOTSCRIPT'
#!/bin/sh
# Self-healing ControlD setup for Alta Labs Route 10
# Reads /cfg/controld.env and rebuilds everything if missing

[ -f /cfg/controld.env ] || { logger -t post-cfg 'controld.env missing, skipping'; exit 0; }
. /cfg/controld.env

# Source lib.sh if available (provides helper functions)
if [ -f /cfg/lib.sh ]; then
    # shellcheck source=/dev/null
    . /cfg/lib.sh
else
    # Inline minimal helpers when lib.sh is absent
    DNS_PORT=5354
    get_endpoint() {
        case "$1" in
            doq|dot) printf "%s.dns.controld.com" "$2" ;;
            *)       printf "https://dns.controld.com/%s" "$2" ;;
        esac
    }
    write_ctrld_config() {
        _outfile="$1"; _resolver="$2"; _bootstrap="$3"; _type="$4"
        _endpoint="$(get_endpoint "$_type" "$_resolver")"
        cat > "$_outfile" << TOMLINNER
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
    bootstrap_ip = "${_bootstrap}"
    endpoint = "${_endpoint}"
    name = "ControlD"
    timeout = 5000
    type = "${_type}"
    send_client_info = true

[listener.0]
    ip = "0.0.0.0"
    port = ${DNS_PORT}
TOMLINNER
    }
    check_dns() {
        if [ -n "${1:-}" ]; then
            nslookup google.com "$1" >/dev/null 2>&1
        else
            nslookup google.com >/dev/null 2>&1
        fi
    }
    stop_ctrld() {
        kill "$(pidof ctrld 2>/dev/null)" 2>/dev/null || true
        sleep 1
    }
    start_ctrld() {
        _config="${1:-/cfg/ctrld.toml}"
        _timeout="${2:-15}"
        nohup /cfg/ctrld run -c "$_config" -d >/dev/null 2>&1 &
        _n=0
        while [ "$_n" -lt "$_timeout" ]; do
            check_dns "127.0.0.1#${DNS_PORT}" && return 0
            sleep 1; _n=$((_n + 1))
        done
        return 1
    }
    restart_ctrld() { stop_ctrld; start_ctrld "$@"; }
    ensure_iptables() {
        _port="${1:-$DNS_PORT}"
        _cnt="$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "$_port")"
        if [ "$_cnt" -eq 0 ]; then
            iptables -t nat -A PREROUTING -i br-lan   -p udp --dport 53 -j REDIRECT --to-port "$_port"
            iptables -t nat -A PREROUTING -i br-lan   -p tcp --dport 53 -j REDIRECT --to-port "$_port"
            iptables -t nat -A PREROUTING -i br-lan_2 -p udp --dport 53 -j REDIRECT --to-port "$_port"
            iptables -t nat -A PREROUTING -i br-lan_2 -p tcp --dport 53 -j REDIRECT --to-port "$_port"
            return 0
        fi
        return 1
    }
fi

# Default to doh3 for legacy installs without DNS_TYPE
DNS_TYPE="${DNS_TYPE:-doh3}"

UPSTREAM_ENDPOINT="$(get_endpoint "$DNS_TYPE" "$RESOLVER_ID")"

logger -t post-cfg "starting with resolver=${RESOLVER_ID} type=${DNS_TYPE}"

# Self-heal: download ctrld binary if missing
if [ ! -x /cfg/ctrld ]; then
    logger -t post-cfg 'ctrld binary missing, downloading...'
    wget -O /tmp/ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/v${CURLD_VERSION}/ctrld_${CURLD_VERSION}_linux_arm64.tar.gz" || { logger -t post-cfg 'ctrld download failed'; exit 1; }
    tar xzf /tmp/ctrld.tar.gz -C /tmp
    mv "/tmp/dist/ctrld_${CURLD_VERSION}_linux_arm64/ctrld" /cfg/ctrld
    chmod +x /cfg/ctrld
    rm -rf /tmp/dist /tmp/ctrld.tar.gz
    logger -t post-cfg 'ctrld binary restored'
fi

# Self-heal: generate ctrld.toml if missing
if [ ! -f /cfg/ctrld.toml ]; then
    logger -t post-cfg 'ctrld.toml missing, generating from controld.env'
    write_ctrld_config /cfg/ctrld.toml "$RESOLVER_ID" "$BOOTSTRAP_IP" "$DNS_TYPE"
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
stop_ctrld

# Start ctrld as daemon with config file
start_ctrld /cfg/ctrld.toml

# Only redirect DNS if ctrld is confirmed working
if check_dns "127.0.0.1#${DNS_PORT}"; then
    ensure_iptables "$DNS_PORT"
    logger -t post-cfg "ctrld started (${DNS_TYPE}) with device discovery, DNS redirected to port ${DNS_PORT}"
else
    logger -t post-cfg 'ctrld failed health check, using https-dns-proxy fallback'
fi
BOOTSCRIPT

chmod +x /cfg/post-cfg.sh
print_ok "/cfg/post-cfg.sh written (self-healing)"

# ── Step 6b: Advanced DNS Policy (optional) ──

printf "\n"
print_header "Advanced DNS Policy (optional)"
print_info "Route specific devices or networks to different ControlD profiles."
print_info "Requires multiple resolver IDs from your ControlD dashboard."
printf "\n"

DO_SPLIT=""
if [ -z "$FLAG_RESOLVER" ]; then
    printf "  Configure split DNS policies? [y/N]: "
    read -r DO_SPLIT
fi

POLICY_UPSTREAMS=""
POLICY_NETWORKS=""
POLICY_MACS=""
POLICY_CONF=""
UPSTREAM_IDX=1
NETWORK_IDX=3

if [ "$DO_SPLIT" = "y" ] || [ "$DO_SPLIT" = "Y" ]; then
    while true; do
        printf "\n"
        print_info "Adding DNS policy upstream..."
        printf "    Resolver ID (or empty to finish): "
        read -r POLICY_RESOLVER
        [ -z "$POLICY_RESOLVER" ] && break

        if ! valid_resolver "$POLICY_RESOLVER"; then
            print_warn "Invalid resolver ID, skipping."
            continue
        fi

        printf "    Policy name (e.g. Kids, IoT, Guest): "
        read -r POLICY_NAME
        POLICY_NAME="${POLICY_NAME:-Policy-${UPSTREAM_IDX}}"

        POLICY_EP="$(get_endpoint "$DNS_TYPE" "$POLICY_RESOLVER")"

        POLICY_UPSTREAMS="${POLICY_UPSTREAMS}
[upstream.${UPSTREAM_IDX}]
    bootstrap_ip = \"${BOOTSTRAP_IP}\"
    endpoint = \"${POLICY_EP}\"
    name = \"ControlD-${POLICY_NAME}\"
    timeout = 5000
    type = \"${DNS_TYPE}\"
    send_client_info = true
"

        printf "\n"
        printf "    Route to this policy by:\n"
        printf "      1) Network/subnet (e.g. 192.168.1.200/32)\n"
        printf "      2) Device MAC address (e.g. AA:BB:CC:DD:EE:FF)\n"
        printf "      3) Both\n"
        printf "    Route type [1]: "
        read -r ROUTE_TYPE
        ROUTE_TYPE="${ROUTE_TYPE:-1}"

        case "$ROUTE_TYPE" in
            1|3)
                printf "\n"
                printf "    Enter CIDRs (space-separated). Examples:\n"
                printf "      192.168.1.200/32       (single device)\n"
                printf "      192.168.2.0/24         (entire subnet)\n"
                printf "    CIDRs: "
                read -r CIDR_LIST
                if [ -n "$CIDR_LIST" ]; then
                    CIDR_ARRAY=""
                    for cidr in $CIDR_LIST; do
                        if valid_cidr "$cidr"; then
                            CIDR_ARRAY="${CIDR_ARRAY}\"${cidr}\", "
                        else
                            print_warn "Invalid CIDR skipped: ${cidr}"
                        fi
                    done
                    CIDR_ARRAY="$(printf "%s" "$CIDR_ARRAY" | sed 's/, $//')"
                    if [ -n "$CIDR_ARRAY" ]; then
                        POLICY_NETWORKS="${POLICY_NETWORKS}
[network.${NETWORK_IDX}]
    cidrs = [${CIDR_ARRAY}]
    name = \"${POLICY_NAME}\"
"
                        POLICY_CONF="${POLICY_CONF}
    {\"network.${NETWORK_IDX}\" = [\"upstream.${UPSTREAM_IDX}\"]},"
                        NETWORK_IDX=$((NETWORK_IDX + 1))
                    fi
                fi
                ;;
        esac

        case "$ROUTE_TYPE" in
            2|3)
                printf "    MAC addresses (space-separated): "
                read -r MAC_LIST
                if [ -n "$MAC_LIST" ]; then
                    for mac in $MAC_LIST; do
                        if valid_mac "$mac"; then
                            POLICY_MACS="${POLICY_MACS}
    {\"${mac}\" = [\"upstream.${UPSTREAM_IDX}\"]},"
                        else
                            print_warn "Invalid MAC skipped: ${mac}"
                        fi
                    done
                fi
                ;;
        esac

        UPSTREAM_IDX=$((UPSTREAM_IDX + 1))
    done

    # Append policy config to ctrld.toml
    if [ -n "$POLICY_UPSTREAMS" ] || [ -n "$POLICY_NETWORKS" ]; then
        printf "" >> /cfg/ctrld.toml
        printf "\n# Policy upstreams\n" >> /cfg/ctrld.toml
        printf "%s\n" "$POLICY_UPSTREAMS" >> /cfg/ctrld.toml
        printf "# Policy networks\n" >> /cfg/ctrld.toml
        printf "%s\n" "$POLICY_NETWORKS" >> /cfg/ctrld.toml

        if [ -n "$POLICY_CONF" ] || [ -n "$POLICY_MACS" ]; then
            POLICY_CONF="$(printf "%s" "$POLICY_CONF" | sed '$ s/,$//')"
            POLICY_MACS="$(printf "%s" "$POLICY_MACS" | sed '$ s/,$//')"

            printf "\n" >> /cfg/ctrld.toml
            printf "[listener.0.policy]\n" >> /cfg/ctrld.toml
            printf "    name = \"Split DNS Policy\"\n" >> /cfg/ctrld.toml
            if [ -n "$POLICY_CONF" ]; then
                printf "    networks = [\n" >> /cfg/ctrld.toml
                printf "%s\n" "$POLICY_CONF" >> /cfg/ctrld.toml
                printf "    ]\n" >> /cfg/ctrld.toml
            fi
            if [ -n "$POLICY_MACS" ]; then
                printf "    macs = [\n" >> /cfg/ctrld.toml
                printf "%s\n" "$POLICY_MACS" >> /cfg/ctrld.toml
                printf "    ]\n" >> /cfg/ctrld.toml
            fi
        fi

        printf "POLICY_UPSTREAMS=%s\n" "$UPSTREAM_IDX" >> /cfg/controld.env
        print_ok "Split DNS policy configured"
    fi
fi

# ── Step 6c: Install watchdog ──

cat > /cfg/watchdog.sh << 'WATCHDOG'
#!/bin/sh
# ControlD watchdog with automatic protocol fallback
# Runs via cron every 5 minutes
# 1. Checks ctrld is alive and DNS resolves
# 2. If failing, tries next protocol in fallback chain
# 3. Logs all actions via syslog

[ -f /cfg/controld.env ] || exit 0
. /cfg/controld.env

# Source lib.sh if available, otherwise inline helpers
if [ -f /cfg/lib.sh ]; then
    # shellcheck source=/dev/null
    . /cfg/lib.sh
else
    DNS_PORT=5354
    FALLBACK_CHAIN="doq doh3 doh"

    get_endpoint() {
        case "$1" in
            doq|dot) printf "%s.dns.controld.com" "$2" ;;
            *)       printf "https://dns.controld.com/%s" "$2" ;;
        esac
    }
    next_proto() {
        _current="$1"; _found=0
        for _proto in $FALLBACK_CHAIN; do
            if [ "$_found" = "1" ]; then printf "%s" "$_proto"; return; fi
            [ "$_proto" = "$_current" ] && _found=1
        done
        printf "%s" "$(echo "$FALLBACK_CHAIN" | awk '{print $1}')"
    }
    check_dns() {
        if [ -n "${1:-}" ]; then
            nslookup google.com "$1" >/dev/null 2>&1
        else
            nslookup google.com >/dev/null 2>&1
        fi
    }
    stop_ctrld() {
        kill "$(pidof ctrld 2>/dev/null)" 2>/dev/null || true
        sleep 1
    }
    start_ctrld() {
        _config="${1:-/cfg/ctrld.toml}"
        _timeout="${2:-10}"
        nohup /cfg/ctrld run -c "$_config" -d >/dev/null 2>&1 &
        _n=0
        while [ "$_n" -lt "$_timeout" ]; do
            check_dns "127.0.0.1#${DNS_PORT}" && return 0
            sleep 1; _n=$((_n + 1))
        done
        return 1
    }
    restart_ctrld() { stop_ctrld; start_ctrld "$@"; }
    ensure_iptables() {
        _port="${1:-$DNS_PORT}"
        _cnt="$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "$_port")"
        if [ "$_cnt" -eq 0 ]; then
            iptables -t nat -A PREROUTING -i br-lan   -p udp --dport 53 -j REDIRECT --to-port "$_port"
            iptables -t nat -A PREROUTING -i br-lan   -p tcp --dport 53 -j REDIRECT --to-port "$_port"
            iptables -t nat -A PREROUTING -i br-lan_2 -p udp --dport 53 -j REDIRECT --to-port "$_port"
            iptables -t nat -A PREROUTING -i br-lan_2 -p tcp --dport 53 -j REDIRECT --to-port "$_port"
            return 0
        fi
        return 1
    }
fi

DNS_TYPE="${DNS_TYPE:-doh3}"
MAX_RESTART_ATTEMPTS=3

# Check if ctrld is running
if ! pidof ctrld >/dev/null 2>&1; then
    logger -t watchdog "ctrld not running, restarting"
    restart_ctrld /cfg/ctrld.toml && logger -t watchdog "ctrld restarted (${DNS_TYPE})"
    exit 0
fi

# Check DNS resolution
if check_dns "127.0.0.1#${DNS_PORT}"; then
    exit 0
fi

# DNS failing -- try protocol fallback
logger -t watchdog "DNS failed on ${DNS_TYPE}, starting fallback"

# Restore iptables if missing
ensure_iptables "$DNS_PORT"
logger -t watchdog "restored iptables rules"

_proto="$DNS_TYPE"; _attempt=0
while [ "$_attempt" -lt "$MAX_RESTART_ATTEMPTS" ]; do
    _proto="$(next_proto "$_proto")"; _attempt=$((_attempt + 1))
    logger -t watchdog "trying ${_proto} (attempt ${_attempt}/${MAX_RESTART_ATTEMPTS})"
    _endpoint="$(get_endpoint "$_proto" "$RESOLVER_ID")"
    sed -i "s|endpoint = \".*\"|endpoint = \"${_endpoint}\"|" /cfg/ctrld.toml
    sed -i "s|type = \"[a-z0-9]*\"|type = \"${_proto}\"|" /cfg/ctrld.toml
    if restart_ctrld /cfg/ctrld.toml; then
        sed -i "s|DNS_TYPE=.*|DNS_TYPE=${_proto}|" /cfg/controld.env
        logger -t watchdog "fallback to ${_proto} succeeded"
        exit 0
    fi
done
logger -t watchdog "all protocols failed"
WATCHDOG

chmod +x /cfg/watchdog.sh

# Install watchdog cron (every 5 minutes)
crontab -l 2>/dev/null | grep -v watchdog | crontab -
(crontab -l 2>/dev/null; printf '*/5 * * * * /cfg/watchdog.sh\n') | crontab - 2>/dev/null || {
    print_warn "Could not install watchdog cron"
}
print_ok "Watchdog installed (5-min health check + protocol fallback)"

# ── Step 7: Write auto-update script ──

cat > /cfg/controld-update.sh << 'UPDATESCRIPT'
#!/bin/sh
# Weekly auto-update for ctrld
[ -f /cfg/controld.env ] || exit 0
. /cfg/controld.env

LATEST="$(wget -qO- 'https://api.github.com/repos/Control-D-Inc/ctrld/releases/latest' | grep '"tag_name"' | grep -o 'v[0-9.]*')"
[ -z "$LATEST" ] && exit 0
CURRENT="v${CURLD_VERSION}"

if [ "$LATEST" != "$CURRENT" ]; then
    VER="${LATEST#v}"
    logger -t controld-update "Updating ctrld from ${CURRENT} to ${LATEST}"
    wget -O /tmp/ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/${LATEST}/ctrld_${VER}_linux_arm64.tar.gz" || exit 1
    tar xzf /tmp/ctrld.tar.gz -C /tmp || exit 1
    kill "$(pidof ctrld 2>/dev/null)" 2>/dev/null
    mv "/tmp/dist/ctrld_${VER}_linux_arm64/ctrld" /cfg/ctrld
    chmod +x /cfg/ctrld
    rm -rf /tmp/dist /tmp/ctrld.tar.gz
    sed -i "s|CURLD_VERSION=.*|CURLD_VERSION=${VER}|" /cfg/controld.env
    /cfg/ctrld run -c /cfg/ctrld.toml -d >/dev/null 2>&1 &
    logger -t controld-update "ctrld updated to ${LATEST}"
fi
UPDATESCRIPT

chmod +x /cfg/controld-update.sh
print_ok "/cfg/controld-update.sh written"

# ── Step 8: Install cron job for weekly updates ──

crontab -l 2>/dev/null | grep -v controld-update | crontab -
(crontab -l 2>/dev/null; printf '0 3 * * 1 /cfg/controld-update.sh\n') | crontab - 2>/dev/null || {
    print_warn "Could not install cron job (non-fatal, auto-update won't run)"
}
print_ok "Weekly auto-update cron installed"

# ── Step 9: Copy lib.sh to router for runtime use ──

if [ -f "${LIB_DIR}/lib.sh" ] && [ ! -f /cfg/lib.sh ]; then
    cp "${LIB_DIR}/lib.sh" /cfg/lib.sh
    print_ok "lib.sh copied to /cfg/ for runtime use"
fi

# ── Step 10: Apply configuration ──

print_step "Step 4: Applying configuration..."

/cfg/post-cfg.sh || {
    print_warn "post-cfg.sh reported errors. DNS may still be stabilizing."
}

# ── Step 11: Verify ──

print_step "Step 5: Verification"
printf "\n"

if pidof ctrld >/dev/null; then
    print_ok "ctrld is running (PID $(pidof ctrld))"
else
    print_fail "ctrld is NOT running"
fi

if check_dns "127.0.0.1#${DNS_PORT}"; then
    print_ok "ctrld DNS responding on port ${DNS_PORT}"
else
    print_warn "ctrld not responding on port ${DNS_PORT} (may need a moment)"
fi

RULES="$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "${DNS_PORT}")"
if [ "$RULES" -gt 0 ]; then
    print_ok "iptables redirect rules active (${RULES} rules)"
else
    print_warn "No iptables redirect rules"
fi

if check_dns; then
    print_ok "System DNS working"
else
    print_fail "System DNS not working"
fi

# ── Done ──

printf "\n"
printf "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}\n"
printf "  ${BOLD}${GREEN}║                    Setup Complete!                       ║${RESET}\n"
printf "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "  Your DNS is now routed through ControlD via ${PLABEL}.\n\n"
printf "  Check your dashboard: ${BOLD}https://controld.com${RESET}\n"
printf "  Individual devices should appear within a few minutes.\n\n"
printf "  ${BOLD}Installed on router:${RESET}\n"
printf "    /cfg/controld.env         Recovery config (self-healing)\n"
printf "    /cfg/ctrld                DNS proxy binary\n"
printf "    /cfg/ctrld.toml           DNS proxy configuration\n"
printf "    /cfg/post-cfg.sh          Self-healing boot script\n"
printf "    /cfg/controld-update.sh   Weekly auto-update\n"
printf "    /cfg/watchdog.sh          5-min health check + protocol fallback\n"
printf "    /cfg/lib.sh               Shared function library\n\n"
printf "  To check:      sh status.sh\n"
printf "  To benchmark:  sh benchmark.sh\n"
printf "  To uninstall:  sh uninstall.sh\n\n"
