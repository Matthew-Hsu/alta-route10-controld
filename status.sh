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
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Report ControlD DNS status on an Alta Labs Route 10 router.

Options:
  --help      Show this help message and exit

Sections displayed:
  config      Config files (/cfg/controld.env, ctrld binary, etc.)
  services    ctrld and https-dns-proxy process status
  dns         DNS resolution through ctrld and system resolver
  iptables    NAT redirect rules for per-device visibility
  upstreams   Upstream count and policy status from ctrld.toml
  cron        Auto-update and watchdog cron entries
  watchdog    Last few watchdog log entries
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

# ── Upstreams & Policies ────────────────────────────────────────────────────

print_header "Upstreams & Policies"

if [ -f /cfg/ctrld.toml ]; then
    upstream_count=$(grep -c '^\[upstream\.' /cfg/ctrld.toml 2>/dev/null || echo 0)
    print_ok "${upstream_count} upstream(s) configured"

    grep '^\[upstream\.' /cfg/ctrld.toml 2>/dev/null | while read -r line; do
        idx=$(echo "$line" | grep -o '[0-9]*')
        name=$(grep -A1 "\\[upstream.${idx}\\]" /cfg/ctrld.toml | grep 'name' | sed 's/.*= "//;s/"//')
        proto=$(grep -A5 "\\[upstream.${idx}\\]" /cfg/ctrld.toml | grep 'type' | sed 's/.*= "//;s/"//')
        printf "         upstream.%s: %s (%s)\n" "$idx" "$name" "$(proto_label "$proto")"
    done

    if grep -q '\[listener.0.policy\]' /cfg/ctrld.toml 2>/dev/null; then
        print_ok "Split DNS policy active"
        mac_count=$(grep -c '="' /cfg/ctrld.toml 2>/dev/null || echo 0)
        if [ "$mac_count" -gt 0 ]; then
            print_ok "MAC rules: ${mac_count} device(s)"
        fi
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
    if [ -n "${CURLD_VERSION:-}" ]; then
        print_ok "Version: ${CURLD_VERSION}"
    fi
else
    print_fail "/cfg/controld.env not found or unreadable"
fi

# ── Cron Jobs ────────────────────────────────────────────────────────────────

print_header "Cron Jobs"

if crontab -l 2>/dev/null | grep -q 'controld-update'; then
    print_ok "Weekly auto-update cron installed"
else
    print_fail "No auto-update cron job"
fi

if crontab -l 2>/dev/null | grep -q 'watchdog'; then
    print_ok "Watchdog cron installed (5-min health check)"
else
    print_fail "No watchdog cron job"
fi

# ── Watchdog Logs ────────────────────────────────────────────────────────────

if [ -f /cfg/watchdog.sh ]; then
    log_entries=$(logread 2>/dev/null | grep watchdog | tail -3)
    if [ -n "$log_entries" ]; then
        print_header "Recent Watchdog Activity"
        echo "$log_entries" | while read -r line; do
            printf "         %s\n" "$(echo "$line" | sed 's/.*watchdog:/watchdog:/')"
        done
    fi
fi

printf "\n"
