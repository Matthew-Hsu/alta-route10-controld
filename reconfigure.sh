#!/bin/sh
# reconfigure.sh — change DNS settings without re-running full setup
#
# Usage: reconfigure.sh [OPTIONS]
#   --help          Show help
#   --protocol      Change DNS protocol (interactive or --to <type>)
#   --resolver      Change resolver ID (interactive or --to <id>)
#   --policy        Manage split DNS policies
#   --benchmark     Run benchmark and apply fastest
#   --force-dns     Toggle forced DNS (hijack port 53 + 853 for all clients)
#   --show          Display current config

set -e

LIB_DIR="$(dirname "$0")"
# shellcheck source=lib.sh
. "$LIB_DIR/lib.sh" 2>/dev/null || { [ -f /cfg/lib.sh ] && . /cfg/lib.sh; } || { echo "lib.sh not found" >&2; exit 1; }

# ── Help ──

usage() {
    print_banner
    cat <<EOF

  ${BOLD}Usage:${RESET}  reconfigure.sh [ACTION] [OPTIONS]

  ${BOLD}Actions:${RESET}
    --show          Display current configuration
    --protocol      Change DNS protocol (prompts, or use --to <type>)
    --resolver      Change resolver ID (prompts, or use --to <id>)
    --benchmark     Benchmark all protocols, apply fastest
    --policy        Manage split DNS policies (add/remove/list)
    --force-dns     Toggle forced DNS (hijack all outbound DNS)
    --repair        Re-apply DNS redirects to every LAN bridge (incl. new VLANs)
    --help          Show this help

  ${BOLD}Options:${RESET}
    --to <value>    Non-interactive: set value directly
                    (e.g. --protocol --to doq, --resolver --to abc123)
    --force         Skip confirmation prompts

  ${BOLD}Examples:${RESET}
    reconfigure.sh                          # show menu
    reconfigure.sh --show                   # display current config
    reconfigure.sh --protocol               # interactive protocol change
    reconfigure.sh --protocol --to doq      # switch to DoQ immediately
    reconfigure.sh --resolver --to xyz789   # change resolver ID
    reconfigure.sh --benchmark              # find fastest, apply it
    reconfigure.sh --policy                 # manage split DNS rules
    reconfigure.sh --force-dns              # toggle forced DNS hijacking
    reconfigure.sh --repair                 # cover VLANs added since install
EOF
    exit 0
}

# ── Parse args ──

ACTION=""
TARGET=""
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)       usage ;;
        --show)          ACTION="show" ;;
        --protocol)      ACTION="protocol" ;;
        --resolver)      ACTION="resolver" ;;
        --benchmark)     ACTION="benchmark" ;;
        --policy)        ACTION="policy" ;;
        --force-dns)     ACTION="force_dns" ;;
        --repair)        ACTION="repair" ;;
        --to)            [ -z "${2:-}" ] && die "--to requires a value"; TARGET="$2"; shift ;;
        --force|-f)      FORCE=1 ;;
        *)               die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ── Load current config ──

if ! load_env; then
    die "No ControlD config found. Run setup.sh first."
fi

PLABEL=$(proto_label "$DNS_TYPE")

# ── Apply and restart ──

apply_and_restart() {
    local msg="$1"
    write_ctrld_config /cfg/ctrld.toml "$RESOLVER_ID" "$BOOTSTRAP_IP" "$DNS_TYPE"

    # Carry split-DNS config across the rewrite: whole tables, in TOML order —
    # the extra upstreams and networks first, then the policy that references
    # them. (Copying just the header lines, as this used to, left ctrld with
    # empty [upstream.N] tables and a policy pointing at nothing.)
    if [ -f /cfg/ctrld.toml.bak ]; then
        local extra_up extra_net policy
        extra_up="$(toml_blocks /cfg/ctrld.toml.bak '[upstream.' '[upstream.0]')"
        extra_net="$(toml_blocks /cfg/ctrld.toml.bak '[network.' '[network.0]')"
        policy="$(toml_blocks /cfg/ctrld.toml.bak '[listener.0.policy]')"
        if [ -n "$extra_up" ] || [ -n "$extra_net" ] || [ -n "$policy" ]; then
            {
                if [ -n "$extra_up" ];  then printf '\n%s\n' "$extra_up";  fi
                if [ -n "$extra_net" ]; then printf '\n%s\n' "$extra_net"; fi
                if [ -n "$policy" ];    then printf '\n%s\n' "$policy";    fi
            } >> /cfg/ctrld.toml
            print_info "Split DNS policy config preserved"
            # Preserved upstreams still carry the old protocol. Leaving them
            # there means a policy keeps using a transport the user just moved
            # off — failing for exactly the devices the policy targets.
            retarget_upstreams /cfg/ctrld.toml "$DNS_TYPE"
            print_info "Policy upstreams moved to $(proto_label "$DNS_TYPE")"
        fi
    fi

    # Update env file
    cat > /cfg/controld.env << EOF
RESOLVER_ID=${RESOLVER_ID}
BOOTSTRAP_IP=${BOOTSTRAP_IP}
CTRLD_VERSION=${CTRLD_VERSION}
DNS_TYPE=${DNS_TYPE}
PREFERRED_PROTOCOL=${PREFERRED_PROTOCOL:-$DNS_TYPE}
FORCED_DNS=${FORCED_DNS:-0}
EOF

    print_ok "$msg"
    print_info "Restarting ctrld..."

    stop_ctrld
    start_ctrld /cfg/ctrld.toml || die "ctrld failed to start"

    if check_dns "127.0.0.1#${DNS_PORT}"; then
        print_ok "DNS working on $(proto_label "$DNS_TYPE")"
    else
        print_fail "DNS not responding — watchdog will attempt recovery"
    fi
    rm -f /cfg/ctrld.toml.bak
}

# ── Action: Show ──

do_show() {
    print_header "Current Configuration"
    printf "  %-20s %s\n" "Resolver ID:" "${RESOLVER_ID}"
    printf "  %-20s %s\n" "Protocol:"    "$(proto_label "$DNS_TYPE")"
    _pref="${PREFERRED_PROTOCOL:-$DNS_TYPE}"
    [ "$_pref" = "$DNS_TYPE" ] || printf "  %-20s %s ${DIM}(watchdog will return to it)${RESET}\n" "Preferred:" "$(proto_label "$_pref")"
    printf "  %-20s %s\n" "Bootstrap IP:" "${BOOTSTRAP_IP}"
    printf "  %-20s %s\n" "ctrld version:" "${CTRLD_VERSION}"
    printf "  %-20s %s\n" "ctrld running:" "$(pidof ctrld 2>/dev/null && echo 'yes (PID above)' || echo 'no')"

    if [ -f /cfg/ctrld.toml ]; then
        # Show upstreams
        UPSTREAM_COUNT=$(grep -c '^\[upstream\.' /cfg/ctrld.toml 2>/dev/null || echo 0)
        printf "\n  ${BOLD}Upstreams (%d):${RESET}\n" "$UPSTREAM_COUNT"
        grep -A3 '^\[upstream\.' /cfg/ctrld.toml 2>/dev/null | while read -r line; do
            case "$line" in
                name*) printf "    %s\n" "$(echo "$line" | sed 's/.*= "//;s/"//')" ;;
                type*) printf "      protocol: %s\n" "$(echo "$line" | sed 's/.*= "//;s/"//')" ;;
            esac
        done

        # Show policy
        if grep -q '\[listener.0.policy\]' /cfg/ctrld.toml 2>/dev/null; then
            printf "\n  ${BOLD}Split DNS Policy:${RESET} ${GREEN}active${RESET}\n"
            MAC_RULES=$(grep -c '=\[' /cfg/ctrld.toml 2>/dev/null || echo 0)
            NET_RULES=$(grep -c '{"network\.' /cfg/ctrld.toml 2>/dev/null || echo 0)
            printf "    MAC rules: %d  |  Network rules: %d\n" "$MAC_RULES" "$NET_RULES"
        else
            printf "\n  ${BOLD}Split DNS Policy:${RESET} ${DIM}none${RESET}\n"
        fi
    fi
    printf "\n"
}

# ── Action: Protocol ──

do_protocol() {
    print_header "Change DNS Protocol"
    printf "  Current: ${BOLD}%s${RESET}\n\n" "$PLABEL"

    local new_type="${TARGET}"
    if [ -z "$new_type" ]; then
        printf "  ${BOLD}1)${RESET} DoH3 (HTTP/3) — stealthy, fast\n"
        printf "  ${BOLD}2)${RESET} DoQ (QUIC)    — lowest overhead\n"
        printf "  ${BOLD}3)${RESET} DoH (HTTP/2)  — most compatible\n"
        printf "  ${BOLD}4)${RESET} Benchmark     — test and pick fastest\n\n"
        printf "  Choice: "
        read -r choice
        case "$choice" in
            1) new_type="doh3" ;;
            2) new_type="doq"  ;;
            3) new_type="doh"  ;;
            4) do_benchmark; return ;;
            *) die "Cancelled" ;;
        esac
    fi

    valid_proto "$new_type" || die "Invalid protocol: $new_type"

    if [ "$new_type" = "$DNS_TYPE" ]; then
        print_info "Already on $(proto_label "$DNS_TYPE"). No change needed."
        return
    fi

    [ "$FORCE" -eq 1 ] || {
        printf "\n  Switch from ${BOLD}%s${RESET} to ${BOLD}%s${RESET}? [Y/n]: " "$PLABEL" "$(proto_label "$new_type")"
        read -r confirm
        case "$confirm" in n|N|no|NO) print_info "Cancelled."; return ;; esac
    }

    cp /cfg/ctrld.toml /cfg/ctrld.toml.bak
    DNS_TYPE="$new_type"
    PREFERRED_PROTOCOL="$new_type"
    apply_and_restart "Switched to $(proto_label "$DNS_TYPE")"
}

# ── Action: Resolver ──

do_resolver() {
    print_header "Change Resolver ID"
    printf "  Current: ${BOLD}%s${RESET}\n\n" "$RESOLVER_ID"

    local new_id="${TARGET}"
    if [ -z "$new_id" ]; then
        printf "  New resolver ID (from controld.com dashboard): "
        read -r new_id
    fi

    [ -z "$new_id" ] && die "Cancelled"
    valid_resolver "$new_id" || die "Invalid resolver ID (must be 5+ lowercase alphanumeric)"

    if [ "$new_id" = "$RESOLVER_ID" ]; then
        print_info "Same resolver ID. No change needed."
        return
    fi

    [ "$FORCE" -eq 1 ] || {
        printf "\n  Change resolver from ${BOLD}%s${RESET} to ${BOLD}%s${RESET}? [Y/n]: " "$RESOLVER_ID" "$new_id"
        read -r confirm
        case "$confirm" in n|N|no|NO) print_info "Cancelled."; return ;; esac
    }

    cp /cfg/ctrld.toml /cfg/ctrld.toml.bak
    RESOLVER_ID="$new_id"
    apply_and_restart "Resolver changed to ${RESOLVER_ID}"

    # The fallback has to move too. It answers whenever ctrld is down, so
    # leaving it on the old ID means a rotated-away profile — a leaked one,
    # say — still resolves for the whole LAN at the next ctrld restart.
    if set_fallback_resolver "$RESOLVER_ID" "$BOOTSTRAP_IP"; then
        /etc/init.d/https-dns-proxy restart >/dev/null 2>&1 || true
        print_ok "https-dns-proxy fallback moved to the new resolver"
    else
        print_warn "Could not update the https-dns-proxy fallback — check 'uci show https-dns-proxy'"
    fi
}

# ── Action: Benchmark ──

do_benchmark() {
    print_header "Benchmarking Protocols"
    printf "  ${DIM}Testing 10 queries per protocol...${RESET}\n\n"

    local bench_port=5360
    local bench_queries=10
    local fastest="" fastest_ms=999999

    for proto in doq doh3 doh; do
        local label endpoint
        label=$(proto_label "$proto")
        endpoint=$(get_endpoint "$proto" "$RESOLVER_ID")

        cat > /tmp/ctrld-bench.toml << EOF
[service]
    log_level = "error"
    cache_enable = false
[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "bench"
[upstream.0]
    bootstrap_ip = "${BOOTSTRAP_IP}"
    endpoint = "${endpoint}"
    name = "bench"
    timeout = 5000
    type = "${proto}"
    send_client_info = false
[listener.0]
    ip = "127.0.0.1"
    port = ${bench_port}
EOF

        kill "$(pidof ctrld 2>/dev/null)" 2>/dev/null || true
        sleep 1
        /cfg/ctrld run -c /tmp/ctrld-bench.toml -d >/dev/null 2>&1 &

        local n=0
        while [ "$n" -lt 10 ]; do
            nslookup google.com "127.0.0.1#${bench_port}" >/dev/null 2>&1 && break
            sleep 1; n=$((n + 1))
        done

        if [ "$n" -eq 10 ]; then
            printf "  %-18s ${RED}FAILED${RESET}\n" "$label"
            kill "$(pidof ctrld 2>/dev/null)" 2>/dev/null || true
            continue
        fi

        local total=0 success=0 ms=0
        for i in $(seq 1 "$bench_queries"); do
            local s1 s2 elapsed
            s1=$(date +%s%N 2>/dev/null || date +%s)
            if nslookup google.com "127.0.0.1#${bench_port}" >/dev/null 2>&1; then
                s2=$(date +%s%N 2>/dev/null || date +%s)
                if [ "${#s1}" -gt 9 ]; then
                    elapsed=$(( (s2 - s1) / 1000000 ))
                else
                    elapsed=$(( (s2 - s1) * 1000 )); [ "$elapsed" -eq 0 ] && elapsed=1
                fi
                total=$((total + elapsed)); success=$((success + 1))
            fi
        done

        kill "$(pidof ctrld 2>/dev/null)" 2>/dev/null || true
        sleep 1

        [ "$success" -eq 0 ] && { printf "  %-18s ${RED}FAILED${RESET}\n" "$label"; continue; }
        ms=$((total / success))

        if [ "$ms" -lt "$fastest_ms" ]; then
            fastest_ms=$ms; fastest=$proto
            printf "  %-18s ${GREEN}%dms${RESET} avg   %d/%d ok   ${DIM}<-- fastest${RESET}\n" "$label" "$ms" "$success" "$bench_queries"
        else
            printf "  %-18s %dms avg   %d/%d ok\n" "$label" "$ms" "$success" "$bench_queries"
        fi
    done

    rm -f /tmp/ctrld-bench.toml

    if [ -z "$fastest" ]; then
        print_fail "All protocols failed. No changes made."
        # Restart the original ctrld
        start_ctrld /cfg/ctrld.toml || true
        return
    fi

    # Restart original ctrld
    start_ctrld /cfg/ctrld.toml || true

    if [ "$fastest" = "$DNS_TYPE" ]; then
        printf "\n  ${GREEN}Current protocol $(proto_label "$DNS_TYPE") is already fastest (${fastest_ms}ms).${RESET}\n"
        return
    fi

    printf "\n  ${GREEN}${BOLD}Fastest: %s (%dms)${RESET}\n" "$(proto_label "$fastest")" "$fastest_ms"
    printf "  Current: %s\n\n" "$(proto_label "$DNS_TYPE")"

    if [ "$FORCE" -eq 1 ]; then
        confirm="y"
    else
        printf "  Apply %s? [Y/n]: " "$(proto_label "$fastest")"
        read -r confirm
    fi

    case "$confirm" in n|N|no|NO) print_info "Cancelled. No changes made."; return ;; esac

    cp /cfg/ctrld.toml /cfg/ctrld.toml.bak
    DNS_TYPE="$fastest"
    PREFERRED_PROTOCOL="$fastest"
    apply_and_restart "Switched to $(proto_label "$DNS_TYPE") (${fastest_ms}ms avg)"
}

# ── Action: Policy ──

do_policy() {
    print_header "Split DNS Policy Manager"

    while true; do
        printf "\n  ${BOLD}Policy Menu:${RESET}\n"
        printf "    ${BOLD}1)${RESET} Show current policies\n"
        printf "    ${BOLD}2)${RESET} Add device rule (MAC -> resolver)\n"
        printf "    ${BOLD}3)${RESET} Add network rule (CIDR -> resolver)\n"
        printf "    ${BOLD}4)${RESET} Remove all policies\n"
        printf "    ${BOLD}q)${RESET} Done\n\n"
        printf "  Choice: "
        read -r pchoice

        case "$pchoice" in
            1)
                if [ -f /cfg/ctrld.toml ] && grep -q '\[listener.0.policy\]' /cfg/ctrld.toml; then
                    printf "\n  ${BOLD}Active Policy Rules:${RESET}\n"
                    sed -n '/\[listener.0.policy\]/,$p' /cfg/ctrld.toml | grep -E '(networks|macs|rules)' | while read -r line; do
                        printf "    %s\n" "$line"
                    done
                else
                    print_info "No split DNS policies configured."
                fi
                ;;
            2)
                printf "\n  ${BOLD}Add Device Rule${RESET}\n"
                printf "  Device MAC address (e.g. AA:BB:CC:DD:EE:FF): "
                read -r mac
                valid_mac "$mac" || { print_fail "Invalid MAC format"; continue; }

                printf "  Resolver ID for this device: "
                read -r policy_resolver
                valid_resolver "$policy_resolver" || { print_fail "Invalid resolver ID"; continue; }

                printf "  Policy name (e.g. Kids, IoT): "
                read -r policy_name
                policy_name="${policy_name:-Device}"

                # Add upstream and MAC rule to existing config
                local next_idx
                next_idx=$(next_toml_index /cfg/ctrld.toml upstream)
                local pol_endpoint
                pol_endpoint=$(get_endpoint "$DNS_TYPE" "$policy_resolver")

                printf "\n  Adding: MAC %s -> %s (%s)\n" "$mac" "$policy_name" "$policy_resolver"
                printf "  Confirm? [Y/n]: "
                read -r confirm
                case "$confirm" in n|N|no|NO) continue ;; esac

                # Append upstream
                cat >> /cfg/ctrld.toml << EOF

[upstream.${next_idx}]
    bootstrap_ip = "${BOOTSTRAP_IP}"
    endpoint = "${pol_endpoint}"
    name = "ControlD-${policy_name}"
    timeout = 5000
    type = "${DNS_TYPE}"
    send_client_info = true
EOF

                # Add or append to policy section
                if grep -q '\[listener.0.policy\]' /cfg/ctrld.toml; then
                    # Find the macs line and append
                    sed -i "/^    macs = \[/a\\    {\"${mac}\" = [\"upstream.${next_idx}\"]}," /cfg/ctrld.toml
                else
                    cat >> /cfg/ctrld.toml << EOF

[listener.0.policy]
    name = "Split DNS Policy"
    macs = [
        {"${mac}" = ["upstream.${next_idx}"]},
    ]
EOF
                fi

                # Remove trailing comma on last macs entry
                sed -i ':a;N;$!ba;s/,\n    \]/\n    \]/' /cfg/ctrld.toml

                stop_ctrld; start_ctrld /cfg/ctrld.toml || die "ctrld failed to start"
                print_ok "Device rule added. MAC ${mac} -> ${policy_name}"
                ;;
            3)
                printf "\n  ${BOLD}Add Network Rule${RESET}\n"
                for _lif in $(lan_ifaces); do
                    _lcidr="$(lan_cidr "$_lif" 2>/dev/null)" || continue
                    printf "    %-12s %-18s %s\n" "$_lif" "$_lcidr" "$(lan_net_name "$_lif")"
                done
                printf "  CIDR (e.g. 192.168.1.200/32 or 192.168.2.0/24): "
                read -r cidr
                valid_cidr "$cidr" || { print_fail "Invalid CIDR format"; continue; }

                printf "  Resolver ID for this network: "
                read -r policy_resolver
                valid_resolver "$policy_resolver" || { print_fail "Invalid resolver ID"; continue; }

                printf "  Policy name (e.g. Guest, IoT-VLAN): "
                read -r policy_name
                policy_name="${policy_name:-Network}"

                local next_up
                next_up=$(next_toml_index /cfg/ctrld.toml upstream)
                local next_net
                next_net=$(next_toml_index /cfg/ctrld.toml network)
                local pol_endpoint
                pol_endpoint=$(get_endpoint "$DNS_TYPE" "$policy_resolver")

                printf "\n  Adding: %s -> %s (%s)\n" "$cidr" "$policy_name" "$policy_resolver"
                printf "  Confirm? [Y/n]: "
                read -r confirm
                case "$confirm" in n|N|no|NO) continue ;; esac

                # Append network and upstream
                cat >> /cfg/ctrld.toml << EOF

[network.${next_net}]
    cidrs = ["${cidr}"]
    name = "${policy_name}"

[upstream.${next_up}]
    bootstrap_ip = "${BOOTSTRAP_IP}"
    endpoint = "${pol_endpoint}"
    name = "ControlD-${policy_name}"
    timeout = 5000
    type = "${DNS_TYPE}"
    send_client_info = true
EOF

                if grep -q '\[listener.0.policy\]' /cfg/ctrld.toml; then
                    sed -i "/^    networks = \[/a\\    {\"network.${next_net}\" = [\"upstream.${next_up}\"]}," /cfg/ctrld.toml
                else
                    cat >> /cfg/ctrld.toml << EOF

[listener.0.policy]
    name = "Split DNS Policy"
    networks = [
        {"network.${next_net}" = ["upstream.${next_up}"]},
    ]
EOF
                fi

                sed -i ':a;N;$!ba;s/,\n    \]/\n    \]/' /cfg/ctrld.toml

                stop_ctrld; start_ctrld /cfg/ctrld.toml || die "ctrld failed to start"
                print_ok "Network rule added. ${cidr} -> ${policy_name}"
                ;;
            4)
                if ! grep -q '\[listener.0.policy\]' /cfg/ctrld.toml 2>/dev/null; then
                    print_info "No policies to remove."
                    continue
                fi
                printf "  ${RED}Remove ALL policy rules and extra upstreams?${RESET} [y/N]: "
                read -r confirm
                case "$confirm" in y|Y|yes|YES) ;; *) continue ;; esac

                # Regenerate base config (drops all policies and extra upstreams)
                cp /cfg/ctrld.toml /cfg/ctrld.toml.bak
                write_ctrld_config /cfg/ctrld.toml "$RESOLVER_ID" "$BOOTSTRAP_IP" "$DNS_TYPE"
                stop_ctrld; start_ctrld /cfg/ctrld.toml || die "ctrld failed to start"
                rm -f /cfg/ctrld.toml.bak
                print_ok "All policies removed. Single upstream restored."
                ;;
            q|Q) return ;;
            *)  print_warn "Invalid choice" ;;
        esac
    done
}

# ── Action: Force DNS ──

do_force_dns() {
    print_header "Forced DNS Hijacking"
    printf "  Ensures all LAN clients use ControlD DNS by intercepting\n"
    printf "  outbound DNS on port 53 (plain) and port 853 (DoT).\n\n"

    # Source of truth is the FORCED_DNS flag; fall back to live uci state for legacy installs
    local current="${FORCED_DNS:-0}"
    if [ "$current" = "0" ]; then
        current="$(uci -q get https-dns-proxy.config.force_dns 2>/dev/null || echo "0")"
    fi

    if [ "$current" = "1" ]; then
        printf "  Current: ${GREEN}ENABLED${RESET} — all outbound DNS is intercepted\n\n"
        if [ "$FORCE" -eq 1 ]; then
            confirm="y"
        else
            printf "  ${RED}Disable forced DNS?${RESET} [y/N]: "
            read -r confirm
        fi
        case "$confirm" in
            y|Y|yes|YES)
                set_forced_dns_flag 0
                disable_forced_dns
                print_ok "Forced DNS disabled. Devices may use their own DNS."
                ;;
            *)
                print_info "No changes made."
                ;;
        esac
    else
        printf "  Current: ${RED}DISABLED${RESET} — devices can bypass ControlD DNS\n\n"
        printf "  Smart TVs (Panasonic, Samsung), IoT devices, and browsers\n"
        printf "  with DoH/DoT can ignore the DHCP DNS setting.\n\n"
        if [ "$FORCE" -eq 1 ]; then
            confirm="y"
        else
            printf "  Enable forced DNS hijacking? [Y/n]: "
            read -r confirm
        fi
        # [Y/n] — default Yes
        case "$confirm" in
            n|N|no|NO)
                print_info "No changes made."
                ;;
            *)
                set_forced_dns_flag 1
                FORCED_DNS=1
                ensure_forced_dns
                print_ok "Forced DNS enabled. All outbound DNS is now hijacked."
                print_info "Note: DNS-over-HTTPS (port 443) cannot be redirected without"
                print_info "breaking HTTPS. Most TVs and IoT devices use DoT, not DoH."
                ;;
        esac
    fi
}

# ── Action: Repair ──

# Re-assert the port-53 (and, when forced DNS is on, port-853) redirects on
# every LAN bridge. Installs made before VLAN discovery existed only ever
# redirected br-lan and br-lan_2, so every other VLAN resolved around ctrld and
# never showed up as a device in ControlD. Safe to run repeatedly.
do_repair() {
    print_header "Repair DNS Redirects"

    _bridges="$(lan_ifaces | tr '\n' ' ')"
    printf "  LAN bridges found:%s\n" " ${_bridges}"
    printf "  Redirecting port 53 to ctrld on port %s.\n\n" "$DNS_PORT"

    if ! pidof ctrld >/dev/null 2>&1; then
        print_warn "ctrld is not running — start it before redirecting DNS"
        return 1
    fi
    if ! check_dns "127.0.0.1#${DNS_PORT}"; then
        print_warn "ctrld is not answering on port ${DNS_PORT} — not touching iptables"
        return 1
    fi

    if ensure_iptables "$DNS_PORT"; then
        print_ok "Redirect rules added for bridges that were missing them"
    else
        print_info "All LAN bridges already had a redirect rule"
    fi

    _pruned="$(prune_stale_redirects "$DNS_PORT")"
    if [ "${_pruned:-0}" -gt 0 ]; then
        print_ok "Removed ${_pruned} stale rule(s) for bridges that no longer exist"
    else
        print_info "No stale rules from removed bridges"
    fi

    if ensure_firewall_user_rules "$DNS_PORT"; then
        print_ok "/etc/firewall.user updated (rules survive a firewall reload)"
    else
        print_info "/etc/firewall.user already up to date"
    fi

    if [ "${FORCED_DNS:-0}" = "1" ]; then
        ensure_forced_dns
        print_ok "Forced DNS (port 853) re-applied to all bridges"
    fi

    printf "\n"
    for _rif in $(lan_ifaces); do
        if iptables -t nat -C PREROUTING -i "$_rif" -p udp --dport 53 \
                -j REDIRECT --to-port "$DNS_PORT" 2>/dev/null; then
            print_ok "${_rif} -> port ${DNS_PORT}"
        else
            print_fail "${_rif} still has no redirect"
        fi
    done

    printf "\n"
    print_info "Clients keep their old DNS answers until their cache expires;"
    print_info "reconnect a device (or wait a few minutes) to see it in ControlD."
}

# ── Interactive menu ──

if [ -z "$ACTION" ]; then
    do_show
    printf "  ${BOLD}What do you want to change?${RESET}\n\n"
    printf "    ${BOLD}1)${RESET} Change DNS protocol\n"
    printf "    ${BOLD}2)${RESET} Change resolver ID\n"
    printf "    ${BOLD}3)${RESET} Run benchmark, apply fastest\n"
    printf "    ${BOLD}4)${RESET} Manage split DNS policies\n"
    printf "    ${BOLD}5)${RESET} Toggle forced DNS hijacking\n"
    printf "    ${BOLD}6)${RESET} Repair DNS redirects (cover all VLANs)\n"
    printf "    ${BOLD}q)${RESET} Exit\n\n"
    printf "  Choice: "
    read -r menu_choice

    case "$menu_choice" in
        1) do_protocol ;;
        2) do_resolver ;;
        3) do_benchmark ;;
        4) do_policy ;;
        5) do_force_dns ;;
        6) do_repair ;;
        q|Q) print_info "Done."; exit 0 ;;
        *)  die "Cancelled" ;;
    esac
else
    case "$ACTION" in
        show)      do_show ;;
        protocol)  do_protocol ;;
        resolver)  do_resolver ;;
        benchmark) do_benchmark ;;
        policy)    do_policy ;;
        force_dns) do_force_dns ;;
        repair)    do_repair ;;
        *)         die "Unknown action: $ACTION" ;;
    esac
fi
