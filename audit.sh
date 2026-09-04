#!/bin/sh
# audit.sh — check a ControlD install for drift, staleness and leftovers.
# Read-only: this script never changes anything.
#
# status.sh answers "is it working". This answers "is it clean" — duplicate
# rules from repeated installs, references to things that no longer exist,
# artifacts left by earlier versions, and whether packets are actually
# reaching ctrld rather than merely having rules that say they should.
# shellcheck source=lib.sh

# ── Bootstrap lib.sh ─────────────────────────────────────────────────────────
LIB_DIR="$(dirname "$0")"
# shellcheck source=lib.sh
. "$LIB_DIR/lib.sh"

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    _name="$(basename "$0")"
    cat <<USAGE
Usage: ${_name} [OPTIONS]

Audit a ControlD install on an Alta Labs Route 10 for drift and leftovers.
Read-only — reports findings, changes nothing.

Options:
  --raw       Also dump crontab, firewall.user, uci and the nat table
  --help      Show this help message and exit

Exit status:
  0   no drift found
  1   drift found (details in the output)

Sections:
  installed   Script and ctrld versions, and whether the install matches
              the copy of audit.sh being run
  duplicates  Repeated iptables rules, cron jobs, firewall blocks, uci lists
  stale       Rules for vanished bridges, cron jobs for deleted scripts,
              a boot hook whose target is gone
  coverage    Rules expected vs present, and packets actually intercepted
  leftovers   Artifacts from earlier versions or other installs
  discovery   Whether ctrld can still name devices
USAGE
}

RAW=0
for arg in "$@"; do
    case "$arg" in
        --raw)    RAW=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf "Unknown option: %s\n" "$arg" >&2; usage >&2; exit 1 ;;
    esac
done

# ── Findings ─────────────────────────────────────────────────────────────────

DRIFT=0
REVIEW=0
drift()  { DRIFT=$((DRIFT + 1));   print_fail "$1"; }
review() { REVIEW=$((REVIEW + 1)); print_warn "$1"; }

print_banner
load_env >/dev/null 2>&1 || true
DNS_PORT="${DNS_PORT:-5354}"
# controld.env is the source of truth for this, not uci — that is the point of
# 3bc68c3, and ensure_forced_dns restores uci from it. Reading uci alone meant
# that after a firmware update wiped /etc/config, but before the watchdog's
# next cycle put it back, the port-853 rules this project had correctly kept
# were reported as unexpected drift.
FORCE_DNS="${FORCED_DNS:-}"
if [ -z "$FORCE_DNS" ]; then
    FORCE_DNS="$(uci -q get https-dns-proxy.config.force_dns 2>/dev/null || echo 0)"
fi

# ── Installed versions ───────────────────────────────────────────────────────

print_header "Installed"

# $VERSION is whichever lib.sh this process sourced, which is not necessarily
# the one on the router: audit.sh can be run from a checkout in /tmp. Report
# both, and say so when they differ — an audit describing a version the router
# is not running is worse than no audit.
_installed_ver="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$INSTALLED_LIB" 2>/dev/null | head -1)"
if [ -z "$_installed_ver" ]; then
    review "${INSTALLED_LIB} not found — nothing installed, or an incomplete install"
    printf "         this audit is running against lib.sh %s\n" "$VERSION"
elif [ "$_installed_ver" = "$VERSION" ]; then
    print_ok "Scripts ${_installed_ver}"
elif version_gt "$_installed_ver" "$VERSION"; then
    review "Installed scripts are ${_installed_ver}, this audit is ${VERSION} — the checkout is behind the router"
else
    review "Installed scripts are ${_installed_ver}, this audit is ${VERSION} — the router is behind the checkout"
fi

if [ -n "${CTRLD_VERSION:-}" ]; then
    print_ok "ctrld ${CTRLD_VERSION} on $(proto_label "${DNS_TYPE:-doh3}")"
else
    review "No ctrld version recorded — /cfg/controld.env missing or unreadable"
fi
printf "         redirect port %s, forced DNS %s\n" "$DNS_PORT" "$FORCE_DNS"

# ── Duplicates ───────────────────────────────────────────────────────────────

print_header "Duplicates"

dup="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--to-ports ${DNS_PORT}" | sort | uniq -d)"
if [ -z "$dup" ]; then
    print_ok "No duplicate redirect rules"
else
    drift "Duplicate redirect rules — a repeated install added them twice:"
    printf '%s\n' "$dup" | sed 's/^/           /'
fi

dup="$(crontab -l 2>/dev/null | grep -v '^[[:space:]]*$' | sort | uniq -d)"
if [ -z "$dup" ]; then
    print_ok "No duplicate cron entries"
else
    drift "Duplicate cron entries:"
    printf '%s\n' "$dup" | sed 's/^/           /'
fi

# grep -c prints 0 and exits 1 on no match, so a `|| echo 0` here would append
# a second zero and break the arithmetic below.
blocks="$(grep -c "${FW_MARKER} BEGIN" "$FW_USER" 2>/dev/null)"; [ -n "$blocks" ] || blocks=0
case "$blocks" in
    1) print_ok "Exactly one managed block in ${FW_USER}" ;;
    0) if [ -s "$FW_USER" ] && grep -q REDIRECT "$FW_USER" 2>/dev/null; then
           drift "${FW_USER} has REDIRECT lines but no managed block"
       else
           print_ok "No managed block in ${FW_USER}, and nothing stray"
       fi ;;
    *) drift "${blocks} managed blocks in ${FW_USER} (expected 1)" ;;
esac

stray="$(sed "/${FW_MARKER} BEGIN/,/${FW_MARKER} END/d" "$FW_USER" 2>/dev/null | grep -c 'REDIRECT')"
[ -n "$stray" ] || stray=0
if [ "$stray" -eq 0 ]; then
    print_ok "No REDIRECT lines outside the managed block"
else
    drift "${stray} REDIRECT line(s) outside the managed block"
fi

for _opt in dhcp.@dnsmasq[0].server https-dns-proxy.config.force_dns_port; do
    dup="$(uci -q get "$_opt" 2>/dev/null | tr ' ' '\n' | sort | uniq -d)"
    if [ -z "$dup" ]; then
        print_ok "No duplicate entries in ${_opt}"
    else
        drift "Duplicate entries in ${_opt}: $(printf '%s' "$dup" | tr '\n' ' ')"
    fi
done

# ── Stale references ─────────────────────────────────────────────────────────

print_header "Stale References"

rule_ifaces="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--to-ports ${DNS_PORT}" \
               | sed -n 's/.*-i \([^ ]*\) .*/\1/p' | sort -u)"
ghost=""
for _if in $rule_ifaces; do
    [ -d "${SYSFS_NET}/${_if}" ] || ghost="${ghost} ${_if}"
done
if [ -z "$ghost" ]; then
    print_ok "Every redirect rule targets a bridge that still exists"
else
    drift "Rules for bridge(s) that no longer exist:${ghost}"
    print_info "Fix:  sh /cfg/reconfigure.sh --repair"
fi

# A live rule with no firewall.user line vanishes at the next firewall reload.
for _if in $rule_ifaces; do
    grep -q " -i ${_if} " "$FW_USER" 2>/dev/null \
        || review "${_if} has a live rule but no ${FW_USER} line — lost on firewall reload"
done

missing=""
for _f in $(crontab -l 2>/dev/null | sed -n 's|.*\(/cfg/[A-Za-z0-9._-]*\.sh\).*|\1|p' | sort -u); do
    [ -f "$_f" ] || missing="${missing} ${_f}"
done
if [ -z "$missing" ]; then
    print_ok "Every cron job points at a script that exists"
else
    drift "Cron job(s) point at missing script(s):${missing}"
fi

if grep -q '/cfg/rc.local' /etc/rc.local 2>/dev/null; then
    if [ -f /cfg/rc.local ]; then
        print_ok "/etc/rc.local sources /cfg/rc.local, which exists"
        if is_our_rc_local /cfg/rc.local; then
            print_ok "/cfg/rc.local is ours (carries the ${RC_MARKER} marker)"
        else
            review "/cfg/rc.local exists but is not ours — left alone by uninstall"
        fi
    else
        drift "/etc/rc.local sources /cfg/rc.local but the file is gone"
    fi
elif [ -f /cfg/rc.local ]; then
    review "/cfg/rc.local exists but /etc/rc.local does not source it — it never runs"
fi

# ── Coverage ─────────────────────────────────────────────────────────────────

print_header "Redirect Coverage"

if [ "$FORCE_DNS" = "1" ]; then ports="53 853"; else ports="53"; fi
bridges="$(lan_ifaces)"
nb=0
for _if in $bridges; do nb=$((nb + 1)); done
expected=0
for _if in $bridges; do
    for _p in $ports; do expected=$((expected + 2)); done
done
actual="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -c -- "--to-ports ${DNS_PORT}")"
printf "         %s bridge(s), ports %s, tcp+udp\n" "$nb" "$(echo "$ports" | tr ' ' '+')"
if [ "$actual" -eq "$expected" ]; then
    print_ok "${actual} rule(s) present, ${expected} expected"
else
    drift "${actual} rule(s) present, ${expected} expected"
fi
for _if in $bridges; do
    for _p in $ports; do
        for _pr in tcp udp; do
            iptables -t nat -C PREROUTING -i "$_if" -p "$_pr" --dport "$_p" \
                -j REDIRECT --to-port "$DNS_PORT" 2>/dev/null \
                || drift "Missing rule: ${_if} ${_pr}/${_p}"
        done
    done
done

# Rules can be present and still never match — wrong bridge, or a rule earlier
# in the chain taking the traffic first. Counters are the only proof.
print_header "Packets Actually Intercepted"
counts="$(iptables -t nat -L PREROUTING -nv 2>/dev/null \
          | $AWK -v port="$DNS_PORT" '$0 ~ ("redir ports " port) { p[$6] += $1 } END { for (i in p) print i, p[i] }' \
          | sort)"
if [ -z "$counts" ]; then
    drift "No redirect rules to count — nothing is being intercepted"
else
    printf '%s\n' "$counts" | while read -r _if _n; do
        if [ "$_n" -gt 0 ] 2>/dev/null; then
            print_ok "${_if}: ${_n} packet(s) redirected"
        else
            print_warn "${_if}: 0 packets — no DNS seen yet (idle VLAN, or clients bypassing)"
        fi
    done
    printf "         Counters are cumulative since boot. A VLAN with active\n"
    printf "         devices and 0 packets is the one worth investigating.\n"
fi

# ── Leftovers ────────────────────────────────────────────────────────────────

print_header "Leftovers"

# /etc/controld is created by the ctrld binary itself on start; uninstall rmdirs
# it. ctrld.toml.bak is reconfigure.sh's rollback copy, normally removed on
# success — one surviving a failed reconfigure still holds the previous
# resolver ID.
found=0
for _p in /etc/controld /etc/ctrld.toml /etc/init.d/ctrld /root/.ctrld \
          /var/log/ctrld.log /cfg/ctrld.toml.bak /cfg/ctrld.prev \
          /cfg/controld-backup /cfg/rc.local.pre-controld "$DEGRADED_FLAG"; do
    if [ -e "$_p" ]; then
        case "$_p" in
            /etc/controld)            review "${_p} — created by ctrld while running; uninstall removes it" ;;
            /cfg/ctrld.toml.bak)      review "${_p} — leftover from an interrupted reconfigure; holds the previous resolver ID" ;;
            /cfg/ctrld.prev)          review "${_p} — the previous ctrld the updater kept for rollback; expected after an update" ;;
            /cfg/controld-backup)     review "${_p} — from the removed backup.sh; uninstall deletes it" ;;
            /cfg/rc.local.pre-controld) review "${_p} — your pre-install boot hook, restored by uninstall" ;;
            "$DEGRADED_FLAG")         review "${_p} — $(cat "$_p" 2>/dev/null)" ;;
            *)                        review "${_p} — not installed by this project" ;;
        esac
        found=1
    fi
done
[ "$found" -eq 0 ] && print_ok "No known leftover paths present"

# Anything in /cfg that looks like ours but is not on the install manifest.
# Everything this project can create in /cfg. Paths the leftovers block above
# already names belong here too, or each one is reported twice — once as a
# known leftover and again as unexpected.
KNOWN=" controld.env ctrld ctrld.toml post-cfg.sh controld-update.sh watchdog.sh lib.sh status.sh benchmark.sh reconfigure.sh audit.sh uninstall.sh rc.local ctrld.prev ctrld.toml.bak rc.local.pre-controld "
unknown=""
for _e in /cfg/*ctrld* /cfg/*controld* /cfg/*.sh /cfg/rc.local*; do
    [ -e "$_e" ] || continue
    _b="${_e##*/}"
    case "$KNOWN" in *" $_b "*) : ;; *) unknown="${unknown} ${_b}" ;; esac
done
if [ -z "$unknown" ]; then
    print_ok "Nothing unexpected in /cfg"
else
    review "In /cfg but not on the install manifest:${unknown}"
fi

# ── Device discovery ─────────────────────────────────────────────────────────

print_header "Device Discovery"

if [ -f /cfg/dhcp.leases ]; then
    leases="$(grep -c . /cfg/dhcp.leases 2>/dev/null)"; [ -n "$leases" ] || leases=0
    if find /cfg/dhcp.leases -mmin +120 2>/dev/null | grep -q .; then
        review "dhcp.leases has not changed in over 2h — ControlD may show IPs, not names"
    else
        print_ok "dhcp.leases is current (${leases} lease(s)) — ctrld can name devices"
    fi
else
    review "/cfg/dhcp.leases missing — ControlD will show IPs, not device names"
fi

# ── Raw dumps ────────────────────────────────────────────────────────────────

if [ "$RAW" -eq 1 ]; then
    print_header "Raw State"
    printf '\n-- crontab --\n';           crontab -l 2>/dev/null
    printf '\n-- %s --\n' "$FW_USER";     cat "$FW_USER" 2>/dev/null
    printf '\n-- uci https-dns-proxy.config --\n'; uci -q show https-dns-proxy.config 2>/dev/null
    printf '\n-- nat PREROUTING --\n';    iptables -t nat -S PREROUTING 2>/dev/null
fi

# ── Summary ──────────────────────────────────────────────────────────────────

print_header "Summary"
if [ "$DRIFT" -eq 0 ] && [ "$REVIEW" -eq 0 ]; then
    print_ok "Clean — no drift, nothing to review"
elif [ "$DRIFT" -eq 0 ]; then
    print_ok "No drift. ${REVIEW} item(s) to review above."
else
    print_fail "${DRIFT} drift item(s), ${REVIEW} to review."
fi
printf "\n"

[ "$DRIFT" -eq 0 ] || exit 1
exit 0
