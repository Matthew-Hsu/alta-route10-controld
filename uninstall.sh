#!/bin/sh
# Uninstall ControlD from Alta Labs Route 10
# Removes all ControlD files, cron jobs, and iptables rules,
# then restores the default DNS services.
#
# Usage: uninstall.sh [--force] [--help]

# ── Source lib.sh ──

LIB_DIR="$(dirname "$0")"
# shellcheck source=lib.sh
. "$LIB_DIR/lib.sh" 2>/dev/null || {
    if [ -f /cfg/lib.sh ]; then
        # shellcheck source=/dev/null
        . /cfg/lib.sh
    else
        echo "Error: lib.sh not found." >&2
        exit 1
    fi
}

# ── Defaults ──

FORCE=0

# Files installed by setup.sh
INSTALL_FILES="/cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh \
               /cfg/controld.env /cfg/controld-update.sh /cfg/watchdog.sh"

# ── Help ──

usage() {
    printf "  ${BOLD}Usage:${RESET}  uninstall.sh [OPTIONS]

  ${BOLD}Options:${RESET}
    --force   Skip confirmation prompt
    --help    Show this help message

  ${BOLD}Description:${RESET}
    Completely removes ControlD from this router:
    stops ctrld, deletes config files, removes cron jobs,
    flushes iptables rules, and restores default DNS.

  ${BOLD}Examples:${RESET}
    uninstall.sh
    uninstall.sh --force
"
    exit 0
}

# ── Parse arguments ──

while [ $# -gt 0 ]; do
    case "$1" in
        --force|-f)
            FORCE=1
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            die "Unknown option: $1  (try --help)"
            ;;
    esac
done

# ── Preflight ──

# Check if there is anything to uninstall
_found=0
for _f in $INSTALL_FILES; do
    if [ -f "$_f" ]; then
        _found=1
        break
    fi
done

# Also check for cron jobs
if crontab -l 2>/dev/null | grep -q "controld-update\|watchdog"; then
    _found=1
fi

if [ "$_found" -eq 0 ]; then
    print_banner
    print_ok "No ControlD installation found. Nothing to do."
    exit 0
fi

# ── Banner ──

print_banner
print_header "Uninstall ControlD"

# ── Show what will be removed ──

printf "  ${BOLD}The following items will be removed:${RESET}\n\n"

# List files
_file_count=0
for _f in $INSTALL_FILES; do
    if [ -f "$_f" ]; then
        printf "    ${RED}delete${RESET}  %s\n" "$_f"
        _file_count=$((_file_count + 1))
    fi
done

# List backup directory
if [ -d /cfg/controld-backup ]; then
    printf "    ${RED}delete${RESET}  %s  (backup directory)\n" "/cfg/controld-backup"
    _file_count=$((_file_count + 1))
fi

# List cron jobs
_cron_count=0
if crontab -l 2>/dev/null | grep -q "controld-update"; then
    printf "    ${RED}remove${RESET}  cron: controld-update (weekly auto-update)\n"
    _cron_count=$((_cron_count + 1))
fi
if crontab -l 2>/dev/null | grep -q "watchdog"; then
    printf "    ${RED}remove${RESET}  cron: watchdog (5-min health check)\n"
    _cron_count=$((_cron_count + 1))
fi

# List iptables rules
_ipt_count=0
_ipt_count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "5354" || true)
if [ "$_ipt_count" -gt 0 ]; then
    printf "    ${RED}flush${RESET}   iptables: %d DNS redirect rule(s)\n" "$_ipt_count"
fi

# List running process
if pidof ctrld >/dev/null 2>&1; then
    printf "    ${RED}stop${RESET}    ctrld process (PID %s)\n" "$(pidof ctrld)"
fi

# Summary
printf "\n  ${BOLD}Summary:${RESET}  %d file(s), %d cron job(s), %d iptables rule(s)\n" \
    "$_file_count" "$_cron_count" "$_ipt_count"

printf "\n  After removal, default DNS services will be restored:\n"
printf "    - https-dns-proxy ( restarted )\n"
printf "    - dnsmasq         ( restarted )\n"

# ── Confirm ──

if [ "$FORCE" -ne 1 ]; then
    printf "\n"
    printf "  ${YELLOW}This cannot be undone.${RESET}\n"
    printf "  "
    printf "Remove all ControlD configuration? [y/N]: "
    read -r _confirm
    case "$_confirm" in
        y|Y) ;;
        *)   printf "\n"; print_ok "Aborted. No changes made."; exit 0 ;;
    esac
fi

printf "\n"

# ── Stop ctrld ──

print_step "Stopping ctrld..."
if pidof ctrld >/dev/null 2>&1; then
    stop_ctrld
    if pidof ctrld >/dev/null 2>&1; then
        # Force kill if still running
        kill -9 "$(pidof ctrld)" 2>/dev/null || true
        sleep 1
    fi
    print_ok "ctrld stopped"
else
    print_ok "ctrld was not running"
fi

# ── Remove iptables rules ──

print_step "Removing iptables rules..."
iptables -t nat -F PREROUTING 2>/dev/null || true
print_ok "iptables PREROUTING chain flushed"

# ── Remove files ──

print_step "Removing files..."
for _f in $INSTALL_FILES; do
    if [ -f "$_f" ]; then
        rm -f "$_f"
        print_ok "Removed ${_f}"
    fi
done

# Remove backup directory
if [ -d /cfg/controld-backup ]; then
    rm -rf /cfg/controld-backup
    print_ok "Removed /cfg/controld-backup"
fi

# ── Remove cron jobs ──

print_step "Removing cron jobs..."
if crontab -l 2>/dev/null | grep -q "controld-update\|watchdog"; then
    crontab -l 2>/dev/null | grep -v "controld-update" | grep -v "watchdog" | crontab - 2>/dev/null || true
    print_ok "Cron jobs removed"
else
    print_ok "No ControlD cron jobs found"
fi

# ── Restore default DNS ──

print_step "Restoring default DNS services..."

# Reset https-dns-proxy to a public resolver (not ControlD)
if uci get https-dns-proxy.@https-dns-proxy[0] >/dev/null 2>&1; then
    uci set https-dns-proxy.@https-dns-proxy[0].resolver_url="https://dns.quad9.net/dns-query" 2>/dev/null || true
    uci set https-dns-proxy.@https-dns-proxy[0].bootstrap_dns="9.9.9.9" 2>/dev/null || true
fi
if uci get https-dns-proxy.@https-dns-proxy[1] >/dev/null 2>&1; then
    uci set https-dns-proxy.@https-dns-proxy[1].resolver_url="https://dns.quad9.net/dns-query" 2>/dev/null || true
    uci set https-dns-proxy.@https-dns-proxy[1].bootstrap_dns="9.9.9.9" 2>/dev/null || true
fi
if uci get https-dns-proxy.@https-dns-proxy[2] >/dev/null 2>&1; then
    uci set https-dns-proxy.@https-dns-proxy[2].resolver_url="https://dns.quad9.net/dns-query" 2>/dev/null || true
    uci set https-dns-proxy.@https-dns-proxy[2].bootstrap_dns="9.9.9.9" 2>/dev/null || true
fi
uci commit https-dns-proxy 2>/dev/null || true

/etc/init.d/https-dns-proxy restart 2>/dev/null || true
print_ok "https-dns-proxy restarted (Quad9)"

# Reset dnsmasq to use https-dns-proxy defaults
uci delete dhcp.@dnsmasq[0].server 2>/dev/null || true
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053' 2>/dev/null || true
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054' 2>/dev/null || true
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5055' 2>/dev/null || true
uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || true
uci commit dhcp 2>/dev/null || true

/etc/init.d/dnsmasq restart 2>/dev/null || true
print_ok "dnsmasq restarted"

# ── Verify ──

print_step "Verifying..."
_remaining=0
for _f in $INSTALL_FILES; do
    if [ -f "$_f" ]; then
        print_fail "File still exists: ${_f}"
        _remaining=$((_remaining + 1))
    fi
done

if pidof ctrld >/dev/null 2>&1; then
    print_fail "ctrld is still running"
    _remaining=$((_remaining + 1))
fi

if [ "$_remaining" -eq 0 ]; then
    print_ok "All ControlD components removed"
fi

if nslookup google.com >/dev/null 2>&1; then
    print_ok "System DNS is working"
else
    print_warn "System DNS may need a moment to stabilize"
fi

# ── Done ──

printf "\n"
print_ok "Uninstall complete."
printf "  ${DIM}A reboot is recommended to ensure a clean state.${RESET}\n"
printf "\n"
