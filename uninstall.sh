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

# The redirect port is per-install, not a constant: setup.sh moves off 5354
# when something else holds it and records the choice as DNS_PORT here. Every
# other script loads this before touching iptables; this one did not, so on a
# moved install it deleted rules for 5354 (there are none), left the real
# redirects in place pointing at a port with nothing behind it, and then
# reported success — the router's own lookups do not traverse PREROUTING, so
# even the closing DNS check passed while every LAN client was dark.
load_env >/dev/null 2>&1 || true

# ── Defaults ──

FORCE=0

# Files installed by setup.sh
# rc.local and lib.sh belong here too: the boot hook re-runs the install and the
# library regenerates the firewall rules, so leaving either behind means an
# uninstalled router puts the DNS redirects back on the next reboot — pointing
# at a ctrld binary that is no longer there.
# Everything setup.sh installs. uninstall.sh removes itself last, and lib.sh
# goes with the rest: leaving the utility scripts behind without it would just
# leave commands that error out.
INSTALL_FILES="/cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh \
               /cfg/controld.env /cfg/controld-update.sh /cfg/watchdog.sh \
               /cfg/ctrld.prev \
               /cfg/status.sh /cfg/benchmark.sh /cfg/reconfigure.sh \
               /cfg/audit.sh /cfg/ctrld.toml.bak /cfg/ctrld.toml.fallback \
               /cfg/lib.sh /cfg/uninstall.sh"
# /cfg/rc.local is handled separately: it is only ours if it carries our
# marker, and a pre-install copy may need restoring in its place.

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

# Also check for cron jobs. Matched by script path, never by keyword: the
# router ships "* * * * * /usr/bin/wireguard_watchdog", which the bare word
# matched — so this reported a ControlD install on a router that had none.
if cron_has /cfg/watchdog.sh || cron_has /cfg/controld-update.sh; then
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
if cron_has /cfg/controld-update.sh; then
    printf "    ${RED}remove${RESET}  cron: controld-update (weekly auto-update)\n"
    _cron_count=$((_cron_count + 1))
fi
if cron_has /cfg/watchdog.sh; then
    printf "    ${RED}remove${RESET}  cron: watchdog (5-min health check)\n"
    _cron_count=$((_cron_count + 1))
fi

# List iptables rules
_ipt_count=0
_ipt_count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "redir ports ${DNS_PORT}$" || true)
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
printf "\n  Only this project's DNS redirect rules are removed. Your port\n"
printf "  forwards, UPnP mappings and other firewall rules are untouched,\n"
printf "  and no reboot is needed.\n"

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
        for _kp in $(pidof ctrld 2>/dev/null); do kill -9 "$_kp" 2>/dev/null || true; done
        sleep 1
    fi
    print_ok "ctrld stopped"
else
    print_ok "ctrld was not running"
fi

# ── Remove iptables rules ──

print_step "Removing iptables rules..."

# Delete only the rules this project added. Flushing the whole PREROUTING chain
# (what this used to do) also removes the firewall's own zone jumps, so every
# port forward and UPnP mapping stops working until the firewall is reloaded —
# an unrelated outage caused by uninstalling something else.
remove_dns_redirects "$DNS_PORT"

# Sweep any strays an older install left on bridges that no longer exist
iptables-save -t nat 2>/dev/null \
    | grep '^-A PREROUTING' \
    | grep -- "--to-ports ${DNS_PORT}" \
    | while read -r _rule; do
        # shellcheck disable=SC2086  # the saved rule spec must word-split
        iptables -t nat -D PREROUTING ${_rule#-A PREROUTING } 2>/dev/null || true
    done

_left="$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "redir ports ${DNS_PORT}$" || true)"
if [ "$_left" -eq 0 ]; then
    print_ok "ControlD redirect rules removed (other firewall rules untouched)"
else
    print_warn "${_left} redirect rule(s) still present — check: iptables -t nat -L PREROUTING -n"
fi

# The firewall.user block would re-add them on the next firewall reload
if [ -f "$FW_USER" ]; then
    remove_block "$FW_USER" "$FW_MARKER"
    sed -i -e '/controld-forced-dns-853/d' \
           -e '/ControlD per-device DNS redirect/d' \
           -e '/^iptables -t nat -A PREROUTING -i br-lan.*--dport 53 -j REDIRECT --to-port/d' \
           -e '/^iptables -t nat -A PREROUTING -i br-lan.*--dport 853 -j REDIRECT --to-port/d' "$FW_USER"
    print_ok "firewall.user entries removed (rules will not return on reload)"
fi

# ── Restore forced DNS ──

# Without this, force_dns stays set in uci and https-dns-proxy keeps hijacking
# ports 53 and 853 after the app is gone — someone uninstalling to get their
# DNS back would still be intercepted. force_dns is the only switch we own;
# see disable_forced_dns for why force_dns_port is left alone.
print_step "Disabling forced DNS..."
if command -v disable_forced_dns >/dev/null 2>&1; then
    disable_forced_dns
    print_ok "Forced DNS disabled (uci force_dns cleared)"
else
    print_warn "lib.sh unavailable — check 'uci show https-dns-proxy.config' by hand"
fi

# ── Boot hook ──

print_step "Removing boot hook..."
if [ -f /cfg/rc.local ] && ! is_our_rc_local /cfg/rc.local; then
    print_warn "/cfg/rc.local is not ours — left untouched"
elif [ -f /cfg/rc.local ]; then
    rm -f /cfg/rc.local
    print_ok "Removed /cfg/rc.local"
fi
if [ -f /cfg/rc.local.pre-controld ]; then
    mv /cfg/rc.local.pre-controld /cfg/rc.local
    print_ok "Restored the /cfg/rc.local that existed before install"
fi

# Runtime state, so the router is clean without waiting for a reboot
rm -f /tmp/controld-degraded /tmp/controld-dns-fail.count /tmp/controld-upgrade.count
# The watchdog's lock is a directory, not a file
rm -rf /tmp/controld-watchdog.lock

# The ctrld binary creates /etc/controld for its own state. rmdir only removes
# it when empty, so anything the daemon actually left there is preserved.
rmdir /etc/controld 2>/dev/null || true

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
# cron_remove matches the script path. "grep -v watchdog" also matched the
# router's own /usr/bin/wireguard_watchdog job and deleted it as collateral,
# with nothing to put it back — the same failure fixed elsewhere in 04815f0,
# which this caller was missed by.
if cron_has /cfg/watchdog.sh || cron_has /cfg/controld-update.sh; then
    cron_remove /cfg/watchdog.sh
    cron_remove /cfg/controld-update.sh
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

# /cfg/controld-backup is left by the backup.sh that shipped with earlier
# versions. That script is gone (it copied /cfg into /cfg, so it could not
# survive the /cfg wipe it existed for), but the directory it made persists.
if [ -d /cfg/controld-backup ]; then
    rm -rf /cfg/controld-backup
    print_ok "Removed /cfg/controld-backup (left by the old backup.sh)"
fi

# force_dns_port is left as we found it. It is a stock https-dns-proxy default
# (the shipped /etc/config lists 53 and 853, and the init script falls back to
# the same pair when the option is absent), the Route 10 rewrites it on boot,
# and the init script ignores it entirely while force_dns is 0. Say so, because
# anyone auditing the uninstall will find the ports still listed.
_fdp="$(uci -q get https-dns-proxy.config.force_dns_port 2>/dev/null || true)"
if [ -n "$_fdp" ]; then
    print_info "force_dns_port lists ${_fdp} — stock package default, inert with force_dns=0"
fi

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
