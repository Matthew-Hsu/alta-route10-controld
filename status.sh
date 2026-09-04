#!/bin/sh
# status.sh — report ControlD status on Alta Labs Route 10
# Uses lib.sh for output helpers and shared state.
# shellcheck source=lib.sh

# ── Bootstrap lib.sh ─────────────────────────────────────────────────────────
LIB_DIR="$(dirname "$0")"
# shellcheck source=lib.sh
. "$LIB_DIR/lib.sh"

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    _name="$(basename "$0")"
    cat <<EOF
Usage: ${_name} [OPTIONS]

Report ControlD DNS status on an Alta Labs Route 10 router.

Options:
  --help      Show this help message and exit

Sections displayed:
  config      Config files (/cfg/controld.env, ctrld binary, etc.)
  services    ctrld and https-dns-proxy process status
  dns         DNS resolution through ctrld and system resolver
  iptables    NAT redirect rules for per-device visibility
  upstreams   Each upstream's name and protocol, and split-DNS rule counts
  endpoint    Resolver ID, active and preferred protocol, ctrld version
  cron        Auto-update and watchdog cron entries
  activity    Recent log lines from this project's own scripts
EOF
}

# ── Parse arguments ──────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf "Unknown option: %s\n" "$arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ── Banner ───────────────────────────────────────────────────────────────────

print_banner

# Load the install's settings up front — DNS_PORT and the LAN_IFACES overrides
# are needed by the iptables section below, not just by the endpoint section.
load_env >/dev/null 2>&1 || true

# ── Config Files ─────────────────────────────────────────────────────────────

print_header "Configuration Files"

for f in /cfg/controld.env /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh /cfg/controld-update.sh /cfg/watchdog.sh; do
    if [ -f "$f" ]; then
        print_ok "$f exists"
    else
        print_fail "$f missing"
    fi
done

# ── Services ─────────────────────────────────────────────────────────────────

print_header "Services"

ctrld_pid=$(pidof ctrld 2>/dev/null)
if [ -n "$ctrld_pid" ]; then
    print_ok "ctrld is running (PID ${ctrld_pid})"
else
    print_fail "ctrld is NOT running"
fi

https_status=$(/etc/init.d/https-dns-proxy status 2>&1)
if [ "$https_status" = "running" ]; then
    print_ok "https-dns-proxy is running (fallback)"
else
    print_fail "https-dns-proxy is not running"
fi

# ── DNS Resolution ───────────────────────────────────────────────────────────

print_header "DNS Resolution"

if check_dns "127.0.0.1#${DNS_PORT}"; then
    print_ok "ctrld DNS responding on port ${DNS_PORT}"
else
    print_fail "ctrld not responding on port ${DNS_PORT}"
fi

if check_dns; then
    print_ok "System DNS working"
else
    print_fail "System DNS not working"
fi

# ── iptables ─────────────────────────────────────────────────────────────────

print_header "iptables Redirect Rules"

rules=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "$DNS_PORT")
if [ "$rules" -gt 0 ]; then
    print_ok "${rules} redirect rule(s) active (per-device visibility enabled)"
else
    print_fail "No redirect rules (per-device visibility disabled)"
fi

# Per-bridge coverage. A LAN bridge without a rule is the usual reason devices
# resolve fine but never appear in the ControlD dashboard: their queries never
# reach ctrld, so ControlD only ever sees the router itself.
uncovered=""
for iface in $(lan_ifaces); do
    if iptables -t nat -C PREROUTING -i "$iface" -p udp --dport 53 \
            -j REDIRECT --to-port "$DNS_PORT" 2>/dev/null; then
        subnet="$(lan_cidr "$iface" 2>/dev/null || echo "no IPv4")"
        print_ok "${iface} -> port ${DNS_PORT} (${subnet})"
    else
        uncovered="${uncovered} ${iface}"
        print_fail "${iface} has NO redirect — its clients bypass ControlD"
    fi
done
if [ -f "$DEGRADED_FLAG" ]; then
    print_warn "$(cat "$DEGRADED_FLAG" 2>/dev/null)"
    print_info "DNS still resolves via dnsmasq -> https-dns-proxy; fix ctrld to restore visibility"
elif [ -n "$uncovered" ]; then
    print_info "Fix:  /cfg/reconfigure.sh --repair   (re-applies rules for all bridges)"
fi

force_dns=$(uci -q get https-dns-proxy.config.force_dns 2>/dev/null || echo "0")
if [ "$force_dns" = "1" ]; then
    print_ok "Forced DNS: enabled (port 53 + 853 hijacked)"
else
    print_warn "Forced DNS: disabled (devices may bypass ControlD)"
fi

dot_rules=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c 'dpt:853')
if [ "$dot_rules" -gt 0 ]; then
    print_ok "DoT hijack: ${dot_rules} rule(s) for port 853"
else
    print_warn "DoT hijack: no port 853 rules (DoT devices can bypass)"
fi

# ── Upstreams & Policies ────────────────────────────────────────────────────

print_header "Upstreams & Policies"

if [ -f /cfg/ctrld.toml ]; then
    upstream_count=$(grep -c '^\[upstream\.' /cfg/ctrld.toml 2>/dev/null || echo 0)
    print_ok "${upstream_count} upstream(s) configured"

    list_upstreams /cfg/ctrld.toml | while IFS="$(printf '\t')" read -r idx name proto; do
        printf "         upstream.%s: %s (%s)\n" "$idx" "$name" "$(proto_label "$proto")"
    done

    if grep -q '\[listener.0.policy\]' /cfg/ctrld.toml 2>/dev/null; then
        print_ok "Split DNS policy active"
        mac_count=$(policy_rule_count /cfg/ctrld.toml mac)
        net_count=$(policy_rule_count /cfg/ctrld.toml network)
        print_ok "MAC rules: ${mac_count} device(s), network rules: ${net_count}"
    else
        print_info "No split DNS policy configured"
    fi
else
    print_fail "/cfg/ctrld.toml not found"
fi

# ── ControlD Endpoint (from env) ────────────────────────────────────────────

print_header "ControlD Endpoint"

if load_env; then
    print_ok "Resolver ID: ${RESOLVER_ID}"
    print_ok "Protocol: $(proto_label "${DNS_TYPE}")"
    if [ "${PREFERRED_PROTOCOL:-${DNS_TYPE}}" != "${DNS_TYPE}" ]; then
        print_warn "Preferred: $(proto_label "${PREFERRED_PROTOCOL}") — on fallback; watchdog will return to it"
    fi
    if [ -n "${CTRLD_VERSION:-}" ]; then
        print_ok "Version: ${CTRLD_VERSION}"
    fi
else
    print_fail "/cfg/controld.env not found or unreadable"
fi

# ── Cron Jobs ────────────────────────────────────────────────────────────────

print_header "Cron Jobs"

if cron_has /cfg/controld-update.sh; then
    print_ok "Weekly auto-update cron installed"
else
    print_fail "No auto-update cron job"
fi

if cron_has /cfg/watchdog.sh; then
    print_ok "Watchdog cron installed (5-min health check)"
else
    print_fail "No watchdog cron job"
fi

# ── Recent Activity ──────────────────────────────────────────────────────────

if [ -f /cfg/watchdog.sh ]; then
    # The header prints unconditionally now. It used to appear only when
    # logread returned something, so on a router where logread cannot work
    # — the Route 10 runs syslogd without -C — the whole section vanished with
    # no indication that anything had been looked for.
    print_header "Recent ControlD Activity"
    # Matched on our own syslog tags, with the leading space that a syslog line
    # puts before the tag. A bare "watchdog" also matched the router's
    # wireguard_watchdog and crond's "cmd /cfg/watchdog.sh" execution notices,
    # so this section showed another service's logs under our heading — the
    # same bare-word trap as the cron guard in 04815f0.
    log_entries="$(log_lines '[[:space:]](watchdog|post-cfg|rc\.local|controld-update):' 5 || true)"
    if [ -n "$log_entries" ]; then
        # Drop the hostname and syslog facility; keep the timestamp and tag.
        echo "$log_entries" | while read -r line; do
            printf "         %s\n" "$(echo "$line" | sed 's/ [^ ]* [a-z][a-z]*\.[a-z][a-z]* / /')"
        done
    else
        print_info "No watchdog entries found (checked logread and ${LOG_FILES})"
    fi
fi

printf "\n"
