#!/bin/sh
# ControlD DNS installer for Alta Labs Route 10
# Run this script ON the router:
#   wget -O /tmp/setup.sh https://codeberg.org/CookieTyrant/alta-route10-controld/raw/branch/master/setup.sh
#   sh /tmp/setup.sh
#
# lib.sh is auto-downloaded if not present — no need to wget it separately.
#
# Supports: DoH (HTTP/2), DoH3 (HTTP/3), DoQ (QUIC)
# All prompts have defaults in [brackets] -- press Enter to accept.

set -e

# ── Repository base URL for auto-downloading supplementary files ──

REPO_BASE="https://codeberg.org/CookieTyrant/alta-route10-controld/raw/branch/master"

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
    # Auto-download lib.sh from the repository (single-file wget scenario)
    printf "  Downloading lib.sh from repository... "
    if wget -O "${LIB_DIR}/lib.sh" "${REPO_BASE}/lib.sh" >/dev/null 2>&1; then
        printf "OK\n"
        # shellcheck source=lib.sh
        . "${LIB_DIR}/lib.sh"
    else
        rm -f "${LIB_DIR}/lib.sh"
        printf "FAILED\n"
        echo "  [!!] Could not auto-download lib.sh." >&2
        echo "  [!!] Download it manually and re-run setup:" >&2
        echo "  [!!]   wget -O /tmp/lib.sh ${REPO_BASE}/lib.sh" >&2
        exit 1
    fi
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

    printf "  ${DIM}All protocols encrypt your DNS. The key tradeoff is the port:${RESET}\n"
    printf "  ${DIM}• Port 443 (DoH3/DoH) blends with HTTPS — robust, almost never blocked.${RESET}\n"
    printf "  ${DIM}• Port 853 (DoQ/DoT) is a dedicated DNS port — ${BOLD}some ISPs/mobile networks block it${RESET}${DIM}.${RESET}\n\n"

    printf "  ${BOLD}1) DoH3 — DNS-over-HTTPS/3  (HTTP/3 + QUIC)${RESET}  ${GREEN}[recommended]${RESET}\n"
    printf "     ${DIM}Port 443 | Looks like normal HTTPS. Fastest for most ISPs.${RESET}\n\n"

    printf "  ${BOLD}2) DoQ — DNS-over-QUIC${RESET}  ${YELLOW}(may be blocked on some networks)${RESET}\n"
    printf "     ${DIM}Port 853 | Lowest overhead, but ISPs can identify AND block it.${RESET}\n\n"

    printf "  ${BOLD}3) DoH — DNS-over-HTTPS/2  (HTTP/2 + TCP)${RESET}\n"
    printf "     ${DIM}Port 443 | Most compatible. No QUIC — slightly higher latency.${RESET}\n\n"

    printf "  ${BOLD}4) Benchmark — test all three and pick the fastest for your network${RESET}  ${GREEN}[if unsure]${RESET}\n"
    printf "     ${DIM}Runs 10 queries per protocol, ~30 seconds.${RESET}\n\n"

    printf "  ${DIM}Watchdog: if your protocol fails, it falls back to DoH3/DoH (port 443)${RESET}\n"
    printf "  ${DIM}and automatically returns to your preferred protocol once it recovers.${RESET}\n\n"

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
                wget -O /tmp/ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/v${CTRLD_PIN}/ctrld_${CTRLD_PIN}_linux_arm64.tar.gz" >/dev/null 2>&1 || die "Download failed"
                tar xzf /tmp/ctrld.tar.gz -C /tmp
                mv "/tmp/dist/ctrld_${CTRLD_PIN}_linux_arm64/ctrld" /cfg/ctrld
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

print_step "Step 2: Installing ctrld v${CTRLD_PIN}..."

wget -O /tmp/ctrld.tar.gz "https://github.com/Control-D-Inc/ctrld/releases/download/v${CTRLD_PIN}/ctrld_${CTRLD_PIN}_linux_arm64.tar.gz" || {
    die "Download failed. Check internet connectivity."
}
tar xzf /tmp/ctrld.tar.gz -C /tmp
mv "/tmp/dist/ctrld_${CTRLD_PIN}_linux_arm64/ctrld" /cfg/ctrld
chmod +x /cfg/ctrld
rm -rf /tmp/dist /tmp/ctrld.tar.gz
print_ok "ctrld binary installed to /cfg/ctrld"

# ── Step 4: Write recovery config ──

print_step "Step 3: Writing configuration files..."

cat > /cfg/controld.env << EOF
RESOLVER_ID=${RESOLVER_ID}
BOOTSTRAP_IP=${BOOTSTRAP_IP}
CURLD_VERSION=${CTRLD_PIN}
DNS_TYPE=${DNS_TYPE}
PREFERRED_PROTOCOL=${DNS_TYPE}
FORCED_DNS=0
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
    discover_mdns = true
    discover_arp = true
    discover_hosts = true
    discover_refresh_interval = 60
    dhcp_lease_file_path = "/cfg/dhcp.leases"
    dhcp_lease_file_format = "dnsmasq"

[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "Everyone"

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
    # Every LAN bridge, not a hardcoded pair: Alta names VLAN bridges
    # br-lan_<vlan-id>, and a bridge with no redirect bypasses ctrld entirely.
    lan_ifaces() {
        if [ -n "${LAN_IFACES:-}" ]; then
            for _li in $LAN_IFACES; do printf '%s\n' "$_li"; done
            return 0
        fi
        _lfound=0
        for _lp in /sys/class/net/br-lan /sys/class/net/br-lan_*; do
            [ -e "$_lp" ] || continue
            _li="${_lp##*/}"
            case " ${LAN_IFACES_EXCLUDE:-} " in *" ${_li} "*) continue ;; esac
            _lfound=1
            printf '%s\n' "$_li"
        done
        [ "$_lfound" = "1" ] || printf 'br-lan\n'
    }
    ensure_redirect_rule() {
        _rif="$1"; _rproto="$2"; _rdport="$3"; _rto="$4"
        iptables -t nat -C PREROUTING -i "$_rif" -p "$_rproto" --dport "$_rdport" \
            -j REDIRECT --to-port "$_rto" 2>/dev/null && return 1
        iptables -t nat -A PREROUTING -i "$_rif" -p "$_rproto" --dport "$_rdport" \
            -j REDIRECT --to-port "$_rto" 2>/dev/null
    }
    ensure_iptables() {
        _port="${1:-$DNS_PORT}"
        _added=0
        for _if in $(lan_ifaces); do
            if ensure_redirect_rule "$_if" udp 53 "$_port"; then _added=$((_added + 1)); fi
            if ensure_redirect_rule "$_if" tcp 53 "$_port"; then _added=$((_added + 1)); fi
        done
        [ "$_added" -gt 0 ] && return 0
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
uci set dhcp.@dnsmasq[0].leasetime='24h'
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
    ensure_iptables "$DNS_PORT" || true
    # Persist the redirects so a firewall reload restores them instantly
    command -v ensure_firewall_user_rules >/dev/null 2>&1 && { ensure_firewall_user_rules "$DNS_PORT" || true; }
    # Restore forced-DNS state (port 853 + uci) if enabled — survives reboot/firmware
    command -v ensure_forced_dns >/dev/null 2>&1 && ensure_forced_dns
    logger -t post-cfg "ctrld started (${DNS_TYPE}), DNS redirected to ${DNS_PORT} on: $(lan_ifaces | tr '\n' ' ')"
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
# Allocate from the config that was just written rather than assuming an index:
# a fixed one silently overwrites a network block when the layout changes.
NETWORK_IDX="$(next_toml_index /cfg/ctrld.toml network)"

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
    FALLBACK_CHAIN="doh3 doh"

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
    # Every LAN bridge, not a hardcoded pair: Alta names VLAN bridges
    # br-lan_<vlan-id>, and a bridge with no redirect bypasses ctrld entirely.
    lan_ifaces() {
        if [ -n "${LAN_IFACES:-}" ]; then
            for _li in $LAN_IFACES; do printf '%s\n' "$_li"; done
            return 0
        fi
        _lfound=0
        for _lp in /sys/class/net/br-lan /sys/class/net/br-lan_*; do
            [ -e "$_lp" ] || continue
            _li="${_lp##*/}"
            case " ${LAN_IFACES_EXCLUDE:-} " in *" ${_li} "*) continue ;; esac
            _lfound=1
            printf '%s\n' "$_li"
        done
        [ "$_lfound" = "1" ] || printf 'br-lan\n'
    }
    ensure_redirect_rule() {
        _rif="$1"; _rproto="$2"; _rdport="$3"; _rto="$4"
        iptables -t nat -C PREROUTING -i "$_rif" -p "$_rproto" --dport "$_rdport" \
            -j REDIRECT --to-port "$_rto" 2>/dev/null && return 1
        iptables -t nat -A PREROUTING -i "$_rif" -p "$_rproto" --dport "$_rdport" \
            -j REDIRECT --to-port "$_rto" 2>/dev/null
    }
    ensure_iptables() {
        _port="${1:-$DNS_PORT}"
        _added=0
        for _if in $(lan_ifaces); do
            if ensure_redirect_rule "$_if" udp 53 "$_port"; then _added=$((_added + 1)); fi
            if ensure_redirect_rule "$_if" tcp 53 "$_port"; then _added=$((_added + 1)); fi
        done
        [ "$_added" -gt 0 ] && return 0
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
# Debounce: only fall back / restart ctrld after FAIL_THRESHOLD consecutive
# failed cycles, so a single transient nslookup blip does NOT restart ctrld or
# churn the DNS protocol (both cause re-registration bursts that duplicate
# devices in the ControlD device-clients list).
FAIL_COUNT_FILE="/tmp/controld-dns-fail.count"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"

if check_dns "127.0.0.1#${DNS_PORT}"; then
    # DNS healthy — self-heal forced-DNS state (drift only) + check discovery inputs.
    # ensure_iptables is idempotent (iptables -C per rule) and picks up bridges
    # added since install, so a new VLAN starts resolving through ctrld within
    # 5 minutes instead of at the next reboot.
    if ensure_iptables "$DNS_PORT"; then
        logger -t watchdog "added DNS redirect rules for new LAN bridge(s)"
        command -v ensure_firewall_user_rules >/dev/null 2>&1 && { ensure_firewall_user_rules "$DNS_PORT" || true; }
    fi
    command -v ensure_forced_dns >/dev/null 2>&1 && ensure_forced_dns
    if [ -f /cfg/dhcp.leases ] && find /cfg/dhcp.leases -mmin +120 2>/dev/null | grep -q .; then
        logger -t watchdog "dhcp.leases stale (>2h) — device discovery may degrade"
    fi
    rm -f "$FAIL_COUNT_FILE"
    command -v do_upgrade_check >/dev/null 2>&1 && do_upgrade_check
    exit 0
fi
fails=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
fails=$((fails + 1))
echo "$fails" > "$FAIL_COUNT_FILE"
if [ "$fails" -lt "$FAIL_THRESHOLD" ]; then
    logger -t watchdog "DNS check failed (${fails}/${FAIL_THRESHOLD}) — waiting before restart to avoid churn"
    exit 0
fi
rm -f "$FAIL_COUNT_FILE"

# Sustained DNS failure -- try protocol fallback
logger -t watchdog "DNS failed on ${DNS_TYPE} after ${FAIL_THRESHOLD} consecutive checks, starting fallback"

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

# ── Step 6c: Write /cfg/rc.local (boot persistence hook) ──
# Sourced by the router's /etc/rc.local at every boot: runs post-cfg.sh,
# reinstalls cron jobs (crontab lives in /etc and may be wiped by firmware
# updates), and reasserts port-53 iptables redirects so they survive firewall
# restarts. (Port-853 forced-DNS persistence is handled by ensure_forced_dns,
# which post-cfg.sh and the watchdog call at boot / every 5 min.)

cat > /cfg/rc.local << 'RCLOCAL'
#!/bin/sh
# /cfg/rc.local — sourced by /etc/rc.local at every boot
# Restores ControlD DNS, iptables rules, cron jobs, and firewall persistence

logger -t rc.local "ControlD boot hook starting"

# 1. Run the main setup (starts ctrld, sets iptables, configures fallback DNS)
[ -x /cfg/post-cfg.sh ] && /cfg/post-cfg.sh &

# 2. Reinstall cron jobs (crontab lives in /etc which may not survive firmware updates)
(
    while ! pidof crond >/dev/null 2>&1; do sleep 1; done
    CRONTAB="$(crontab -l 2>/dev/null)"
    echo "$CRONTAB" | grep -q "watchdog" || {
        (crontab -l 2>/dev/null; echo "*/5 * * * * /cfg/watchdog.sh") | crontab -
        logger -t rc.local "watchdog cron installed"
    }
    echo "$CRONTAB" | grep -q "controld-update" || {
        (crontab -l 2>/dev/null; echo "0 3 * * 1 /cfg/controld-update.sh") | crontab -
        logger -t rc.local "auto-update cron installed"
    }
) &

# 3. Ensure iptables redirect rules survive firewall restarts.
#    The rule set depends on which LAN bridges exist, so it is generated by
#    lib.sh rather than hardcoded here (post-cfg.sh does the same at boot).
(
    sleep 10
    if [ -f /cfg/lib.sh ]; then
        # shellcheck source=/dev/null
        . /cfg/lib.sh
        load_env >/dev/null 2>&1 || true
        ensure_firewall_user_rules "$DNS_PORT" && \
            logger -t rc.local "firewall.user rules refreshed"
    fi
    # Without lib.sh there is no rule generator here; post-cfg.sh still applies
    # the redirects directly at boot via its inline fallback helpers.
) &

logger -t rc.local "ControlD boot hook scheduled"
RCLOCAL

chmod +x /cfg/rc.local
print_ok "/cfg/rc.local written (boot persistence: post-cfg + cron + firewall)"

# ── Step 7: Write auto-update script ──

cat > /cfg/controld-update.sh << 'UPDATESCRIPT'
#!/bin/sh
# Weekly auto-update for ctrld
[ -f /cfg/controld.env ] || exit 0
. /cfg/controld.env

LATEST="$(wget -qO- 'https://api.github.com/repos/Control-D-Inc/ctrld/releases/latest' | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\(v[0-9.]*\)".*/\1/')"
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

# Always refresh it: re-running setup.sh is the documented upgrade path, and
# skipping the copy when /cfg/lib.sh exists would leave an old library (and its
# bugs) in charge of every boot and watchdog run.
if [ -f "${LIB_DIR}/lib.sh" ] && [ "${LIB_DIR}/lib.sh" != "/cfg/lib.sh" ]; then
    cp "${LIB_DIR}/lib.sh" /cfg/lib.sh
    print_ok "lib.sh installed to /cfg/ for runtime use"
elif [ ! -f /cfg/lib.sh ]; then
    wget -O /cfg/lib.sh "${REPO_BASE}/lib.sh" >/dev/null 2>&1 && \
        print_ok "lib.sh downloaded to /cfg/"
fi

# ── Step 9b: Install utility scripts ──

UTILITY_SCRIPTS="status.sh benchmark.sh reconfigure.sh uninstall.sh"
_installed=""
for _uscript in $UTILITY_SCRIPTS; do
    if [ -f "${LIB_DIR}/${_uscript}" ]; then
        cp "${LIB_DIR}/${_uscript}" "/cfg/${_uscript}"
    else
        wget -O "/cfg/${_uscript}" "${REPO_BASE}/${_uscript}" >/dev/null 2>&1 || continue
    fi
    chmod +x "/cfg/${_uscript}"
    _installed="${_installed} ${_uscript}"
done
if [ -n "$_installed" ]; then
    print_ok "Utility scripts installed:${_installed}"
else
    print_warn "Could not install utility scripts (non-fatal)"
fi

# ── Step 9c: Port conflict detection ──

_port_in_use() {
    netstat -tulnp 2>/dev/null | grep -q ":${1} " && return 0
    if command -v ss >/dev/null 2>&1; then
        ss -tulnp 2>/dev/null | grep -q ":${1} " && return 0
    fi
    return 1
}

if _port_in_use "$DNS_PORT"; then
    # Check if it's our own ctrld from a previous install
    if pidof ctrld >/dev/null 2>&1; then
        print_warn "Port ${DNS_PORT} is occupied by an existing ctrld process"
        print_info "Stopping old ctrld process..."
        stop_ctrld
        sleep 1
    else
        print_warn "Port ${DNS_PORT} is already in use by another process"
        # Try to find a free port
        _alt_port=$((DNS_PORT + 1))
        while [ "$_alt_port" -lt $((DNS_PORT + 100)) ]; do
            _port_in_use "$_alt_port" || break
            _alt_port=$((_alt_port + 1))
        done
        if [ -z "$FLAG_RESOLVER" ]; then
            printf "  Use port ${_alt_port} instead? [Y/n]: "
            read -r _use_alt
            _use_alt="${_use_alt:-Y}"
        else
            _use_alt="Y"
        fi
        if [ "$_use_alt" = "Y" ] || [ "$_use_alt" = "y" ]; then
            DNS_PORT="$_alt_port"
            print_info "Using port ${DNS_PORT}"
            # Rewrite ctrld.toml with new port
            sed -i "s/port = [0-9]*/port = ${DNS_PORT}/" /cfg/ctrld.toml
            sed -i "s/DNS_PORT=.*/DNS_PORT=${DNS_PORT}/" /cfg/controld.env 2>/dev/null || true
            # Update the env file with the custom port
            grep -q "^DNS_PORT=" /cfg/controld.env || echo "DNS_PORT=${DNS_PORT}" >> /cfg/controld.env
        else
            die "Cannot proceed — port ${DNS_PORT} is occupied."
        fi
    fi
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

_covered=""; _uncovered=""
for _if in $(lan_ifaces); do
    if iptables -t nat -C PREROUTING -i "$_if" -p udp --dport 53 \
            -j REDIRECT --to-port "${DNS_PORT}" 2>/dev/null; then
        _covered="${_covered} ${_if}"
    else
        _uncovered="${_uncovered} ${_if}"
    fi
done
if [ -n "$_covered" ]; then
    print_ok "DNS redirected on:${_covered}"
else
    print_warn "No iptables redirect rules"
fi
if [ -n "$_uncovered" ]; then
    print_warn "No redirect on:${_uncovered} (these clients would bypass ControlD)"
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
printf "    /cfg/lib.sh               Shared function library\n"
printf "    /cfg/status.sh            Status reporting tool\n"
printf "    /cfg/benchmark.sh         Protocol benchmark tool\n"
printf "    /cfg/reconfigure.sh       Quick reconfiguration tool\n"
printf "    /cfg/uninstall.sh         Uninstaller\n\n"
printf "  ${BOLD}Quick commands:${RESET}\n"
printf "    sh /cfg/status.sh         Check DNS health\n"
printf "    sh /cfg/benchmark.sh      Test protocol speeds\n"
printf "    sh /cfg/reconfigure.sh    Change protocol/resolver/policy\n"
printf "    sh /cfg/uninstall.sh      Remove ControlD\n\n"
printf "  ${DIM}Note: Use the scripts above instead of running /cfg/ctrld directly.${RESET}\n"
printf "  ${DIM}The ctrld 'start'/'status' commands expect a different config format.${RESET}\n\n"
