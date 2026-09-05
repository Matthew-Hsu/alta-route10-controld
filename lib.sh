#!/bin/sh
# lib.sh — shared function library for Alta Route 10 + ControlD
# Source this file: . /path/to/lib.sh

# Version of these scripts, semver: MAJOR for a change that breaks an existing
# install (a config key or file layout an upgrade cannot read), MINOR for new
# capability that upgrades cleanly, PATCH for fixes with no new behavior.
#
# Only a release commit on master moves this, paired with a tag. Branches never
# bump it, however much they change: unmerged work is not released, and a
# branch that raises it either collides with the next branch to do the same or
# ships a version that was never cut. See CONTRIBUTING.md, "Releases".
VERSION="1.8.0"

# The ctrld release a fresh install pins. Deliberately separate from VERSION:
# these move for unrelated reasons, and while they shared one variable a tools
# bump silently pointed setup.sh at a ctrld release that does not exist.
# The version actually installed on a router is CTRLD_VERSION in
# /cfg/controld.env, which the weekly updater moves forward from this pin.
CTRLD_PIN="1.5.7"

# Set while the watchdog has torn the DNS redirects down to keep the LAN
# resolving; cleared as soon as the rules go back.
DEGRADED_FLAG="${DEGRADED_FLAG:-/tmp/controld-degraded}"

# Respect a port already set by the caller's environment (an install that had to
# move off 5354 exports it before sourcing this file); load_env applies the same
# default for anything that reads /cfg/controld.env.
DNS_PORT="${DNS_PORT:-5354}"
# The file fw3 runs on every firewall reload, and the marker for the block this
# project owns inside it. FW_USER is overridable so tests never touch /etc.
# awk implementation to use. The router runs BusyBox awk, which handles a
# regex passed through -v differently from GNU awk; overridable so the tests
# can run the same assertions under both.
AWK="${AWK:-awk}"
FW_USER="${FW_USER:-/etc/firewall.user}"
FW_MARKER="controld-dns-redirect"
# Identifies /cfg/rc.local as ours. /etc/rc.local sources that path only if it
# exists, so it is the sanctioned place for a user's own boot hooks — we must
# never clobber or delete someone else's.
RC_MARKER="controld-boot-hook"
# 443-only fallback targets (DoH3/DoH). DoQ/DoT use port 853 which ISPs/mobile
# networks can block, so they are never automatic fallback *targets* — they can
# still be the user's primary protocol. See watchdog self-upgrade for recovery.
FALLBACK_CHAIN="doh3 doh"

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
    printf "  controld-tools %s (pins ctrld %s)\n" "$VERSION" "$CTRLD_PIN"
}

# ── Config Helpers ──

# Load env file, set defaults for missing values
load_env() {
    local env_file="${1:-/cfg/controld.env}"
    [ -f "$env_file" ] || return 1
    # shellcheck source=/dev/null
    . "$env_file"
    # The original project — CookieTyrant's, which this is a fork of — misspelled
    # this key as CURLD_VERSION in its very first commit (f6c81a6). This fork
    # corrected it in d0bc3b0. Adopt the old spelling when only it is present, so
    # an install carried over from the upstream repo keeps working instead of
    # needing a manual migration. Nothing writes it any more, and write_env_file
    # drops it, so the next config rewrite retires it for good.
    CTRLD_VERSION="${CTRLD_VERSION:-${CURLD_VERSION:-}}"
    DNS_TYPE="${DNS_TYPE:-doh3}"
    PREFERRED_PROTOCOL="${PREFERRED_PROTOCOL:-$DNS_TYPE}"
    BOOTSTRAP_IP="${BOOTSTRAP_IP:-76.76.2.22}"
    DNS_PORT="${DNS_PORT:-5354}"
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

# ── LAN Interface Discovery ──

# Root of the sysfs network tree — overridable so tests can point at a fixture.
SYSFS_NET="${SYSFS_NET:-/sys/class/net}"
# The library the router is running, as opposed to the one this process sourced.
# audit.sh compares the two: running a newer checkout against an older install
# is drift worth naming.
INSTALLED_LIB="${INSTALLED_LIB:-/cfg/lib.sh}"

# List the LAN bridges that DNS must be intercepted on, one per line.
#
# Alta names the default LAN bridge br-lan and every additional VLAN
# br-lan_<vlan-id> (br-lan_10, br-lan_20, ...). A hardcoded list therefore
# misses every VLAN the user adds: those clients keep resolving through
# whatever DNS they were handed, bypass ctrld, and never show up as devices in
# the ControlD dashboard. Enumerate sysfs instead, so VLANs created after
# install are covered the next time rules are asserted (boot or watchdog).
#
# Overrides, set in /cfg/controld.env:
#   LAN_IFACES="br-lan br-lan_10"    intercept exactly these
#   LAN_IFACES_EXCLUDE="br-lan_40"   intercept everything except these
lan_ifaces() {
    if [ -n "${LAN_IFACES:-}" ]; then
        for _lan_if in $LAN_IFACES; do printf '%s\n' "$_lan_if"; done
        return 0
    fi
    _lan_found=0
    for _lan_path in "$SYSFS_NET"/br-lan "$SYSFS_NET"/br-lan_*; do
        [ -e "$_lan_path" ] || continue
        _lan_if="${_lan_path##*/}"
        case " ${LAN_IFACES_EXCLUDE:-} " in
            *" ${_lan_if} "*) continue ;;
        esac
        _lan_found=1
        printf '%s\n' "$_lan_if"
    done
    # Fall back to the historical default if sysfs is unreadable
    [ "$_lan_found" = "1" ] || printf 'br-lan\n'
}

# Human-readable name for a LAN bridge, used to label ctrld network blocks
# Usage: lan_net_name br-lan_10  ->  VLAN 10
lan_net_name() {
    case "$1" in
        br-lan)   printf 'LAN' ;;
        br-lan_*) printf 'VLAN %s' "${1#br-lan_}" ;;
        *)        printf '%s' "$1" ;;
    esac
}

# Network address for an IPv4 address + prefix length
# Usage: ipv4_network 192.168.10.1 24  ->  192.168.10.0/24
ipv4_network() {
    $AWK -v ip="$1" -v pfx="$2" 'BEGIN {
        if (split(ip, o, ".") != 4) exit 1
        if (pfx !~ /^[0-9]+$/ || pfx + 0 > 32) exit 1
        for (i = 1; i <= 4; i++) {
            if (o[i] !~ /^[0-9]+$/ || o[i] + 0 > 255) exit 1
            bits = pfx - (i - 1) * 8
            # Repeated doubling rather than 2 ^ (8 - bits): some BusyBox awk
            # builds ship without math support and the exponent operator fails
            if (bits >= 8)      step = 1
            else if (bits <= 0) step = 256
            else { step = 1; for (k = bits; k < 8; k++) step = step * 2 }
            o[i] = int(o[i] / step) * step
        }
        printf "%d.%d.%d.%d/%d\n", o[1], o[2], o[3], o[4], pfx
    }'
}

# Subnet of a LAN bridge — lan_cidr br-lan_10 -> 192.168.10.0/24
# Non-zero (and no output) when the bridge has no IPv4 address.
lan_cidr() {
    _lan_addr="$(ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4; exit}')"
    case "$_lan_addr" in
        */*) ipv4_network "${_lan_addr%/*}" "${_lan_addr#*/}" ;;
        *)   return 1 ;;
    esac
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
    discover_mdns = true
    discover_arp = true
    discover_hosts = true
    discover_refresh_interval = 60
    dhcp_lease_file_path = "/cfg/dhcp.leases"
    dhcp_lease_file_format = "dnsmasq"

# Networks are matched against a client's source IP by split-DNS policies. Only
# the catch-all is generated; policies add narrower blocks using this router's
# real VLAN subnets, which "sh /cfg/status.sh" lists per bridge.
[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "Everyone"

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

# Print whole [table] blocks whose header starts with a literal prefix,
# optionally skipping one exact header. A block runs from its header to the
# next line starting with "[".
#
# Matching is literal string comparison, not a regex passed through -v: BusyBox
# awk (which the router runs) mangles the backslashes in a pattern like
# '^\[upstream\.[1-9]' -- that pattern then matches every line, while
# '^\[listener\.0\.policy\]' matches none. GNU awk handles both, so the unit
# tests passed while on the router a config rewrite silently dropped the
# split-DNS policy and duplicated every other table.
#
# Usage: toml_blocks <file> <header-prefix> [exact-header-to-skip]
#   toml_blocks cfg.toml '[upstream.' '[upstream.0]'
toml_blocks() {
    [ -f "$1" ] || return 0
    $AWK -v p="$2" -v x="${3:-}" '
        substr($0, 1, 1) == "[" { keep = (index($0, p) == 1) && ($0 != x) }
        keep { print }
    ' "$1"
}

# Lowest unused index in a [<table>.N] family, so split-DNS policies allocate
# without overwriting an existing block. Counting blocks (the old approach) only
# works while indices are contiguous — they are not once a policy is removed or
# an install is upgraded.
# Usage: next_toml_index <config> <table>   e.g. next_toml_index cfg.toml network
next_toml_index() {
    _nti_file="${1:-/cfg/ctrld.toml}"
    _nti_tbl="$2"
    [ -f "$_nti_file" ] || { printf '0'; return 0; }
    $AWK -v t="$_nti_tbl" '
        match($0, "^\\[" t "\\.[0-9]+\\]") {
            n = substr($0, length(t) + 3, RLENGTH - length(t) - 3) + 0
            if (n >= max) max = n + 1
        }
        END { printf "%d", max }
    ' "$_nti_file"
}

# One line per upstream: "<index>\t<name>\t<type>".
#
# Both readouts that show upstreams used `grep -A<n>` with a fixed offset into
# the block, and both had the wrong offset: -A1 stops at bootstrap_ip so every
# name printed empty, -A3 stops at name so no protocol ever printed. The offset
# is also not stable — it depends on how many keys a block happens to carry.
# Parse the block instead, and match the header exactly: a `grep "[upstream.1]"`
# also matches [upstream.10].
# Usage: list_upstreams <config>
list_upstreams() {
    [ -f "$1" ] || return 0
    $AWK '
        function emit() {
            # Never an empty middle field: tab is IFS whitespace, so a shell
            # `IFS=<tab> read -r idx name type` collapses the run and shifts the
            # protocol into the name column. status.sh printed "upstream.1: doq ()".
            printf "%s\t%s\t%s\n", idx, (name == "" ? "(unnamed)" : name),
                                      (type == "" ? "(unset)" : type)
        }
        { sub(/\r$/, "") }                       # tolerate CRLF
        substr($0, 1, 1) == "[" {
            if (inb && idx != "") emit()
            inb = (index($0, "[upstream.") == 1)
            idx = ""; name = ""; type = ""
            # Strip the known prefix and everything from "]" on, rather than
            # assuming "]" is the last character: a trailing space or comment
            # after the header used to be read into the index.
            if (inb) { idx = $0; sub(/^\[upstream\./, "", idx); sub(/\].*$/, "", idx) }
            next
        }
        inb && $1 ~ /^name$/ { name = $0; sub(/^[^=]*=[ \t]*/, "", name); gsub(/"/, "", name) }
        inb && $1 ~ /^type$/ { type = $0; sub(/^[^=]*=[ \t]*/, "", type); gsub(/"/, "", type) }
        # `name="x"` with no spaces is one field, so $1 is the whole assignment
        inb && $1 ~ /^name=/  { name = $0; sub(/^[^=]*=[ \t]*/, "", name); gsub(/"/, "", name) }
        inb && $1 ~ /^type=/  { type = $0; sub(/^[^=]*=[ \t]*/, "", type); gsub(/"/, "", type) }
        END { if (inb && idx != "") emit() }
    ' "$1"
}

# How many split-DNS rules of one kind a config carries.
#
# Counted on the quoted key, not on the separator. Both callers matched `="` or
# `=\[`, while every rule this project writes is `{"key" = ["upstream.N"]}`
# with spaces around the "=", so both counts were always zero — a config full
# of MAC rules reported none.
# Usage: policy_rule_count <config> <mac|network>
policy_rule_count() {
    [ -f "$1" ] || { printf '0'; return 0; }
    case "$2" in
        # grep -c prints 0 and exits 1 on no match; `|| true` keeps that under
        # set -e without the second zero an `|| echo 0` would append.
        mac)     _prc_n="$(grep -cE '\{"([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"[[:space:]]*=' "$1" || true)" ;;
        network) _prc_n="$(grep -c '{"network\.' "$1" || true)" ;;
        *)       _prc_n=0 ;;
    esac
    [ -n "$_prc_n" ] || _prc_n=0
    printf '%s' "$_prc_n"
}

# Carry the split-DNS tables of <source> into a freshly written <target>.
#
# Whole tables, in TOML order: the extra upstreams and networks first, then the
# policy that references them. (Copying just the header lines, as reconfigure
# once did, left ctrld with empty [upstream.N] tables and a policy pointing at
# nothing.) Returns 0 when something was carried, 1 when there was nothing to
# carry — so a caller can stay quiet on a config that never had policies.
#
# The caller retargets afterwards: preserved upstreams still carry the old
# protocol, and leaving them means a policy keeps using a transport the user
# just moved off, failing for exactly the devices the policy targets.
# Usage: carry_policy_blocks <target-config> <source-config>
carry_policy_blocks() {
    _cpb_target="$1"; _cpb_source="$2"
    [ -f "$_cpb_source" ] || return 1
    _cpb_up="$(toml_blocks "$_cpb_source" '[upstream.' '[upstream.0]')"
    _cpb_net="$(toml_blocks "$_cpb_source" '[network.' '[network.0]')"
    _cpb_pol="$(toml_blocks "$_cpb_source" '[listener.0.policy]')"
    [ -n "$_cpb_up" ] || [ -n "$_cpb_net" ] || [ -n "$_cpb_pol" ] || return 1
    {
        [ -z "$_cpb_up" ]  || printf '\n%s\n' "$_cpb_up"
        [ -z "$_cpb_net" ] || printf '\n%s\n' "$_cpb_net"
        [ -z "$_cpb_pol" ] || printf '\n%s\n' "$_cpb_pol"
    } >> "$_cpb_target"
    return 0
}

# Add one split-DNS rule, creating whatever structure is missing.
#
# The callers anchored an insert on the list header — sed "/^    macs = \[/a..."
# — which silently does nothing when the policy carries only the other kind of
# list. That is the shape the setup wizard writes whenever route type 1 (CIDR
# only) or 2 (MAC only) is chosen, so adding the first rule of the other kind
# was a no-op: the [upstream.N] block had already been appended, ctrld was
# restarted, and "Device rule added" was printed over a config that had gained
# an orphan upstream and no rule.
#
# Returns non-zero if the rule is not in the file afterwards, so a caller can
# never report a write that did not happen.
# Usage: policy_add_rule <config> <mac|network> <key> <upstream-index>
policy_add_rule() {
    _par_file="$1"; _par_kind="$2"; _par_key="$3"; _par_up="$4"
    [ -f "$_par_file" ] || return 1
    case "$_par_kind" in
        mac)     _par_list="macs" ;;
        network) _par_list="networks" ;;
        *)       return 1 ;;
    esac
    _par_entry="    {\"${_par_key}\" = [\"upstream.${_par_up}\"]},"
    _par_before="$(grep -cF "\"${_par_key}\"" "$_par_file" 2>/dev/null || true)"

    # One matcher for the header, shared with the awk branch below. They used
    # to disagree — an unanchored grep here, an exact string compare there — so
    # a trailing space or a CRLF line ending put this function down a path that
    # found no policy and silently wrote nothing.
    if ! grep -qE '^\[listener\.0\.policy\][[:space:]]*\r?$' "$_par_file" 2>/dev/null; then
        # No policy table yet — create it around this rule
        {
            printf '\n[listener.0.policy]\n'
            printf '    name = "Split DNS Policy"\n'
            printf '    %s = [\n' "$_par_list"
            printf '%s\n' "$_par_entry"
            printf '    ]\n'
        } >> "$_par_file"
    elif grep -q "^[[:space:]]*${_par_list}[[:space:]]*=[[:space:]]*\[" "$_par_file"; then
        # Inserted after the FIRST matching list header only. The sed form this
        # replaces had no address restriction, so a file carrying the header
        # twice got the rule twice — and the count check still passed.
        _par_tmp="${_par_file}.policy.$$"
        if ! $AWK -v list="$_par_list" -v entry="$_par_entry" '
            { sub(/\r$/, "") }
            !ins && $0 ~ ("^[ \t]*" list "[ \t]*=[ \t]*\\[") { print; print entry; ins = 1; next }
            { print }
        ' "$_par_file" > "$_par_tmp"; then
            rm -f "$_par_tmp"
            return 1
        fi
        mv "$_par_tmp" "$_par_file"
    else
        # A policy exists but has no list of this kind. It has to go inside the
        # policy table: appending to the end of the file would land it in
        # whatever table happens to follow.
        _par_tmp="${_par_file}.policy.$$"
        if ! $AWK -v list="$_par_list" -v entry="$_par_entry" '
            { sub(/\r$/, "") }
            substr($0, 1, 1) == "[" {
                if (inpol) { printf "    %s = [\n%s\n    ]\n", list, entry; inpol = 0 }
                if ($0 ~ /^\[listener\.0\.policy\][ \t]*$/) inpol = 1
            }
            { print }
            END { if (inpol) printf "    %s = [\n%s\n    ]\n", list, entry }
        ' "$_par_file" > "$_par_tmp"; then
            rm -f "$_par_tmp"
            return 1
        fi
        mv "$_par_tmp" "$_par_file"
    fi

    # Trailing commas are legal in TOML arrays, so the entry is written with
    # one and left alone. The `sed ':a;N;$!ba;s/,\n    \]/'` this replaces had
    # no /g and only ever cleaned the first of the two lists anyway.
    _par_after="$(grep -cF "\"${_par_key}\"" "$_par_file" 2>/dev/null || true)"
    [ "${_par_after:-0}" -gt "${_par_before:-0}" ]
}

# True when version <a> is strictly newer than version <b>.
#
# Compared field by field as numbers, so 1.10.0 beats 1.9.0 — a string compare
# gets that backwards. sort -V would do it but is not in BusyBox's sort.
# Usage: version_gt 1.6.0 1.5.7
version_gt() {
    $AWK -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) {
            xi = (i <= na) ? x[i] + 0 : 0
            yi = (i <= nb) ? y[i] + 0 : 0
            if (xi > yi) exit 0
            if (xi < yi) exit 1
        }
        exit 1
    }'
}

# ── Release Download Verification ──

# Pull one asset's SHA-256 out of a checksums.txt body ("<sha>  <filename>")
# Usage: checksum_for_asset <checksums-text> <asset-filename>
checksum_for_asset() {
    printf '%s\n' "$1" | $AWK -v a="$2" '$2 == a { print $1; exit }'
}

# Check a downloaded release asset against the checksums.txt published beside it.
#   0 = verified, 1 = MISMATCH (do not use the file), 2 = could not verify
# Callers must treat 1 and 2 differently: a mismatch is a hard stop, an
# unverifiable download (no sha256sum, checksums.txt unreachable) is a warning.
# Usage: verify_ctrld_download <file> <asset-filename> <version>
verify_ctrld_download() {
    _vcd_file="$1"; _vcd_asset="$2"; _vcd_ver="$3"
    command -v sha256sum >/dev/null 2>&1 || return 2
    [ -f "$_vcd_file" ] || return 2
    _vcd_sums="$(wget -qO- "https://github.com/Control-D-Inc/ctrld/releases/download/v${_vcd_ver}/checksums.txt" 2>/dev/null)"
    [ -n "$_vcd_sums" ] || return 2
    _vcd_want="$(checksum_for_asset "$_vcd_sums" "$_vcd_asset")"
    [ -n "$_vcd_want" ] || return 2
    _vcd_got="$(sha256sum "$_vcd_file" | awk '{print $1}')"
    [ "$_vcd_want" = "$_vcd_got" ]
}

# ── Protocol Benchmark ──
#
# One implementation, because there were three: benchmark.sh, reconfigure.sh's
# --benchmark, and setup.sh's menu option 4, each with a different bug.

BENCH_DOMAINS="google.com cloudflare.com amazon.com wikipedia.org github.com"
BENCH_DOMAIN_COUNT=5
# A throwaway listener on loopback, so production DNS on DNS_PORT is untouched.
BENCH_PORT="${BENCH_PORT:-5360}"
BENCH_CONF="${BENCH_CONF:-/tmp/ctrld-bench.toml}"

# The Nth benchmark domain, 1-based and wrapping.
#
# setup.sh's copy read: awk "{print \$(((_bi - 1) % 5 + 1))}". _bi is a shell
# variable and awk never saw it, so awk evaluated an uninitialised zero and the
# expression came out as $0 — the whole record. Every query then looked up a
# single hostname made of all five domains joined by spaces, all ten failed,
# and every protocol reported FAILED (0/10) before setup fell back to DoH3.
# The index is computed in the shell so awk is only ever handed a number.
bench_domain() {
    # Clamp: awk's $0 is the whole record and a negative field index is a fatal
    # awk error, so index 0 would reproduce exactly the bug this replaced and a
    # negative one would abort. No caller passes either today.
    _bd_n="$1"
    [ "${_bd_n:-0}" -ge 1 ] 2>/dev/null || _bd_n=1
    _bd_i=$(( (_bd_n - 1) % BENCH_DOMAIN_COUNT + 1 ))
    printf '%s\n' "$BENCH_DOMAINS" | $AWK -v i="$_bd_i" '{ print $i }'
}

# Milliseconds since the epoch. Non-zero (and no output) if the clock cannot be
# read at all.
#
# `date +%s%N 2>/dev/null || date +%s` looked like a fallback and was not.
# BusyBox date does not fail on an unsupported %N unless built with
# FEATURE_DATE_NANO — it succeeds and prints "1788539662%N", so the `||` never
# fired. A length check then fed that string to $(( )), and an arithmetic error
# is fatal to the whole shell in ash and dash: neither `|| true` nor `if !`
# contains it, so the benchmark would have taken setup.sh down mid-install.
# Validate the digits instead of measuring the length of whatever came back.
now_ms() {
    _nm="$(date +%s%N 2>/dev/null)"
    case "$_nm" in
        ''|*[!0-9]*) _nm="" ;;
    esac
    # 10 digits is seconds (the platform dropped %N); ~19 is nanoseconds.
    if [ -n "$_nm" ] && [ "${#_nm}" -gt 12 ]; then
        printf '%s' $((_nm / 1000000))
        return 0
    fi
    _nm="$(date +%s 2>/dev/null)"
    case "$_nm" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' $((_nm * 1000))
}

# Write the throwaway config for one protocol.
# Usage: bench_write_config <file> <proto> <resolver> <bootstrap> <port>
bench_write_config() {
    cat > "$1" << BWCEOF
[service]
    log_level = "error"
    cache_enable = false
[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "bench"
[upstream.0]
    bootstrap_ip = "${4}"
    endpoint = "$(get_endpoint "$2" "$3")"
    name = "bench"
    timeout = 5000
    type = "${2}"
    send_client_info = false
[listener.0]
    ip = "127.0.0.1"
    port = ${5}
BWCEOF
}

# Stop the throwaway daemon, identified by the config it was started with, and
# print how many were stopped.
#
# Never by pidof. That is the production resolver for every LAN client, and
# killing it while the port-53 redirects still point at DNS_PORT is not a
# fallback but a black hole — reconfigure.sh's benchmark did exactly that
# before each of three protocols, taking the whole LAN's DNS down for the run.
#
# Nor by correlating PID to port: benchmark.sh swept leftovers with
# `netstat -tlnp | grep "${pid}.*${port}"`, but netstat prints the local
# address before the PID column, so that pattern could never match. `ctrld -d`
# daemonizes, so the $! it also killed may be a parent whose child survives. A
# leaked daemon keeps BENCH_PORT, the next protocol's ctrld fails to bind and
# exits, the readiness probe then succeeds against the stale listener, and all
# three rows of the table report the first protocol's latency.
# Usage: bench_stop [config]
bench_stop() {
    _bs_conf="${1:-$BENCH_CONF}"
    _bs_n=0
    for _bs_pid in $(ps w 2>/dev/null | grep "[c]trld run -c ${_bs_conf}" | $AWK '{ print $1 }'); do
        kill "$_bs_pid" 2>/dev/null || true
        _bs_n=$((_bs_n + 1))
    done
    printf '%s' "$_bs_n"
}

# Time <queries> lookups against one protocol on the test port.
# Sets BENCH_AVG (milliseconds, or "FAIL"), BENCH_OK and BENCH_FAIL.
# Usage: bench_protocol <proto> <resolver> <bootstrap> <queries> [port] [config]
bench_protocol() {
    _bp_proto="$1"; _bp_resolver="$2"; _bp_boot="$3"; _bp_queries="$4"
    _bp_port="${5:-$BENCH_PORT}"; _bp_conf="${6:-$BENCH_CONF}"

    bench_stop "$_bp_conf" >/dev/null
    bench_write_config "$_bp_conf" "$_bp_proto" "$_bp_resolver" "$_bp_boot" "$_bp_port"
    /cfg/ctrld run -c "$_bp_conf" -d >/dev/null 2>&1 &

    _bp_n=0
    while [ "$_bp_n" -lt 10 ]; do
        nslookup google.com "127.0.0.1#${_bp_port}" >/dev/null 2>&1 && break
        sleep 1; _bp_n=$((_bp_n + 1))
    done
    if [ "$_bp_n" -ge 10 ]; then
        bench_stop "$_bp_conf" >/dev/null
        BENCH_AVG="FAIL"; BENCH_OK=0; BENCH_FAIL="$_bp_queries"
        return 1
    fi
    # Something answered on the test port — confirm it is the daemon we started.
    # If the port was already taken (production can land on it: setup.sh's
    # fallback scan covers DNS_PORT+1..+100, which spans BENCH_PORT) our ctrld
    # fails to bind and exits, the probe above succeeds against the other
    # listener, and every protocol reports that listener's latency instead.
    if ! ps w 2>/dev/null | grep -q "[c]trld run -c ${_bp_conf}"; then
        BENCH_AVG="FAIL"; BENCH_OK=0; BENCH_FAIL="$_bp_queries"
        return 1
    fi

    # A while loop, not a literal `for _i in 1 2 3 ... 30`: that silently
    # capped --queries at 30 while still printing the requested total, so
    # "--queries 50" reported 30/50 with 0 failures.
    _bp_total=0; _bp_ok=0; _bp_bad=0; _bp_i=1
    while [ "$_bp_i" -le "$_bp_queries" ]; do
        _bp_dom="$(bench_domain "$_bp_i")"
        _bp_s1="$(now_ms)" || _bp_s1=""
        if nslookup "$_bp_dom" "127.0.0.1#${_bp_port}" >/dev/null 2>&1; then
            _bp_s2="$(now_ms)" || _bp_s2=""
            if [ -n "$_bp_s1" ] && [ -n "$_bp_s2" ]; then
                _bp_el=$((_bp_s2 - _bp_s1))
                [ "$_bp_el" -gt 0 ] || _bp_el=1
            else
                _bp_el=1
            fi
            _bp_total=$((_bp_total + _bp_el)); _bp_ok=$((_bp_ok + 1))
        else
            _bp_bad=$((_bp_bad + 1))
        fi
        _bp_i=$((_bp_i + 1))
    done

    bench_stop "$_bp_conf" >/dev/null
    if [ "$_bp_ok" -eq 0 ]; then
        BENCH_AVG="FAIL"; BENCH_OK=0; BENCH_FAIL="$_bp_queries"
        return 1
    fi
    BENCH_AVG=$((_bp_total / _bp_ok)); BENCH_OK="$_bp_ok"; BENCH_FAIL="$_bp_bad"
    return 0
}

# ── Upstream Protocol Switching ──

# Resolver ID out of a ControlD endpoint, in either protocol's form.
# Non-zero for anything that is not a ControlD endpoint, so a custom upstream
# is never rewritten into one.
# Usage: resolver_from_endpoint https://dns.controld.com/abc123  ->  abc123
#        resolver_from_endpoint abc123.dns.controld.com          ->  abc123
resolver_from_endpoint() {
    case "$1" in
        https://dns.controld.com/*) printf '%s' "${1##*/}" ;;
        *.dns.controld.com)         printf '%s' "${1%%.*}" ;;
        *) return 1 ;;
    esac
}

# Rewrite one buffered [upstream.N] block for a protocol. Reads the block on
# stdin, writes it to stdout. Helper for retarget_upstreams.
retarget_upstream_block() {
    _rub_proto="$1"
    _rub_block="$(cat)"
    _rub_ep="$(printf '%s\n' "$_rub_block" \
        | sed -n 's/^[[:space:]]*endpoint[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' | head -1)"
    if ! _rub_id="$(resolver_from_endpoint "$_rub_ep")"; then
        # Not a ControlD endpoint — leave this upstream exactly as it is
        printf '%s\n' "$_rub_block"
        return 0
    fi
    _rub_new="$(get_endpoint "$_rub_proto" "$_rub_id")"
    printf '%s\n' "$_rub_block" \
        | sed -e "s|^\([[:space:]]*endpoint[[:space:]]*=[[:space:]]*\).*|\1\"${_rub_new}\"|" \
              -e "s|^\([[:space:]]*type[[:space:]]*=[[:space:]]*\).*|\1\"${_rub_proto}\"|"
}

# Switch every ControlD upstream in a config to a transport protocol, keeping
# each upstream's own resolver ID.
#
# Protocol changes used to be done with an unanchored sed, which rewrote every
# endpoint line in the file to the main resolver's — so one protocol fallback
# silently repointed a split-DNS profile (kids, guest) at the default profile,
# with nothing failing and nothing logged. Switching transport is per upstream;
# the resolver each one points at is its identity and must survive.
# Usage: retarget_upstreams <config> <proto>
retarget_upstreams() {
    _rtu_file="$1"; _rtu_proto="$2"
    [ -f "$_rtu_file" ] || return 1
    _rtu_tmp="${_rtu_file}.retarget.$$"
    : > "$_rtu_tmp"
    _rtu_buf=""
    _rtu_in=0
    while IFS= read -r _rtu_line || [ -n "$_rtu_line" ]; do
        case "$_rtu_line" in
            \[*\])
                # A table header ends whatever block we were collecting
                if [ "$_rtu_in" = "1" ]; then
                    printf '%s\n' "$_rtu_buf" | retarget_upstream_block "$_rtu_proto" >> "$_rtu_tmp"
                    _rtu_buf=""
                    _rtu_in=0
                fi
                case "$_rtu_line" in
                    \[upstream.*\]) _rtu_in=1; _rtu_buf="$_rtu_line"; continue ;;
                esac
                ;;
        esac
        if [ "$_rtu_in" = "1" ]; then
            _rtu_buf="${_rtu_buf}
${_rtu_line}"
        else
            printf '%s\n' "$_rtu_line" >> "$_rtu_tmp"
        fi
    done < "$_rtu_file"
    if [ "$_rtu_in" = "1" ]; then
        printf '%s\n' "$_rtu_buf" | retarget_upstream_block "$_rtu_proto" >> "$_rtu_tmp"
    fi
    mv "$_rtu_tmp" "$_rtu_file"
}

# ── Process Management ──

# Kill any running ctrld process
stop_ctrld() {
    for _kp in $(pidof ctrld 2>/dev/null); do kill "$_kp" 2>/dev/null || true; done
    sleep 1
}

# Is anything listening on a TCP or UDP port?
#
# start_ctrld probes this before paying for a DNS query, and setup.sh's
# port-conflict step carried a private copy of the same two commands.
# Usage: port_in_use <port>
port_in_use() {
    local port="${1:-$DNS_PORT}"
    netstat -tulnp 2>/dev/null | grep -q ":${port} " && return 0
    if command -v ss >/dev/null 2>&1; then
        ss -tulnp 2>/dev/null | grep -q ":${port} " && return 0
    fi
    return 1
}

# Start ctrld and wait until it answers on the DNS port.
#
# `timeout` is seconds of wall clock. It used to be an iteration count, and
# every iteration ran an nslookup against the DNS port: when ctrld exits during
# startup that port is closed and each probe costs the resolver's own timeout
# — about 5s on a Route 10 — so a "15 second" start actually took ~90. The
# watchdog's worst case is one start plus three fallback attempts, which put a
# full recovery cycle over six minutes, longer than its own five-minute cron
# interval, and the overlapping instances then raced each other over the
# fail-count file and the config. Gating the query on the port being open keeps
# a failed start close to the time the caller asked for.
# Usage: start_ctrld <config_file> [timeout_secs]
start_ctrld() {
    local config="${1:-/cfg/ctrld.toml}"
    local timeout="${2:-15}"
    nohup /cfg/ctrld run -c "$config" -d >/dev/null 2>&1 &
    local started
    started="$(date +%s 2>/dev/null)"
    case "$started" in ''|*[!0-9]*) started="" ;; esac
    local now
    local elapsed
    local n=0
    # The iteration cap is a backstop, not the bound. This router has no RTC
    # and its clock jumps when NTP first syncs, so a wall clock that steps
    # backwards must not be able to stall the loop.
    while [ "$n" -lt $((timeout * 4)) ]; do
        if port_in_use "$DNS_PORT" && check_dns "127.0.0.1#${DNS_PORT}"; then
            return 0
        fi
        elapsed=""
        if [ -n "$started" ]; then
            now="$(date +%s 2>/dev/null)"
            case "$now" in ''|*[!0-9]*) : ;; *) elapsed=$((now - started)) ;; esac
        fi
        if [ -n "$elapsed" ] && [ "$elapsed" -ge "$timeout" ]; then
            return 1
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

# Was /cfg/rc.local written by this project?
#
# Hooks generated before the marker existed have to be recognised too, or an
# upgraded install leaves its own boot hook behind on uninstall — and that hook
# then re-adds cron jobs at the next boot pointing at scripts that were just
# deleted. The legacy signature is the logger line every version has emitted.
# Usage: is_our_rc_local [file]
is_our_rc_local() {
    _iorl_file="${1:-/cfg/rc.local}"
    [ -f "$_iorl_file" ] || return 1
    grep -qF "$RC_MARKER" "$_iorl_file" 2>/dev/null && return 0
    grep -qF "ControlD boot hook" "$_iorl_file" 2>/dev/null
}

# ── Cron Jobs ──

# Is a cron entry for this exact script installed?
#
# Matching the bare word "watchdog" also matches the router's own
# wireguard_watchdog job. rc.local then believed ours was already installed and
# skipped reinstalling it after every reboot — so the health check silently
# stopped running — while status.sh reported a job that was not there. Match the
# script path, never a word that another service might share.
# Usage: cron_has /cfg/watchdog.sh [crontab-file]
cron_has() {
    if [ -n "${2:-}" ]; then
        grep -qF "$1" "$2" 2>/dev/null
    else
        crontab -l 2>/dev/null | grep -qF "$1"
    fi
}

# Remove only our own cron entry. "grep -v watchdog" deleted the router's
# wireguard_watchdog job as collateral.
# Usage: cron_remove /cfg/watchdog.sh
cron_remove() {
    crontab -l 2>/dev/null | grep -vF "$1" | crontab - 2>/dev/null || true
}

# ── Syslog ──

# Where BusyBox syslogd writes when it was not given -C. /var/log is a symlink
# to /tmp/log on OpenWrt, so both usually name the same file; try each.
LOG_FILES="${LOG_FILES:-/var/log/messages /tmp/log/messages}"

# Recent syslog lines matching a pattern, oldest first.
#
# logread only works when syslogd was started with -C, which creates the
# shared-memory ring buffer it reads. The Route 10 runs
# `syslogd -n -b 2 -t -u` — no -C — so logread fails outright with "can't find
# syslogd buffer", and every logger call this project makes looked lost. They
# are not: syslogd defaults to a file, and -b 2 rotates it. status.sh silently
# printed no watchdog section at all on that firmware, and troubleshooting.md
# opened with a logread command that could never work there.
# Usage: log_lines <extended-regex> [count]
log_lines() {
    _ll_pat="$1"; _ll_n="${2:-20}"
    _ll_out="$(logread 2>/dev/null || true)"
    if [ -z "$_ll_out" ]; then
        for _ll_f in $LOG_FILES; do
            if [ -f "$_ll_f" ]; then
                # syslogd -b N keeps rotated history alongside the live file as
                # <file>.0 (most recently rotated) and <file>.1 (older).
                # Reading only the live file made the caller's output go blank
                # the moment it rotated, however recent the event — and
                # docs/troubleshooting.md already told the reader status.sh
                # handled these. Oldest first, so tail still yields the most
                # recent matching lines.
                _ll_set=""
                for _ll_r in 2 1 0; do
                    [ -f "${_ll_f}.${_ll_r}" ] && _ll_set="${_ll_set} ${_ll_f}.${_ll_r}"
                done
                # Word splitting on _ll_set is intended: it is a file list.
                # shellcheck disable=SC2086
                _ll_out="$(cat $_ll_set "$_ll_f" 2>/dev/null || true)"
                break
            fi
        done
    fi
    [ -n "$_ll_out" ] || return 1
    printf '%s\n' "$_ll_out" | grep -E "$_ll_pat" 2>/dev/null | tail -n "$_ll_n"
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

# ── iptables Redirect Rules ──

# Add a REDIRECT rule unless an identical one already exists.
# Usage: ensure_redirect_rule <append|insert> <iface> <tcp|udp> <dport> <to-port>
# Returns 0 when a rule was added, 1 when it was already present or failed.
ensure_redirect_rule() {
    _err_mode="$1"; _err_if="$2"; _err_proto="$3"; _err_dport="$4"; _err_to="$5"
    if iptables -t nat -C PREROUTING -i "$_err_if" -p "$_err_proto" \
            --dport "$_err_dport" -j REDIRECT --to-port "$_err_to" 2>/dev/null; then
        return 1
    fi
    if [ "$_err_mode" = "insert" ]; then
        # Head of PREROUTING, so the hijack wins over firewall zone port-forwards
        iptables -t nat -I PREROUTING 1 -i "$_err_if" -p "$_err_proto" \
            --dport "$_err_dport" -j REDIRECT --to-port "$_err_to" 2>/dev/null
    else
        iptables -t nat -A PREROUTING -i "$_err_if" -p "$_err_proto" \
            --dport "$_err_dport" -j REDIRECT --to-port "$_err_to" 2>/dev/null
    fi
}

# Delete a REDIRECT rule if present (never fails)
# Usage: del_redirect_rule <iface> <tcp|udp> <dport> <to-port>
del_redirect_rule() {
    iptables -t nat -D PREROUTING -i "$1" -p "$2" --dport "$3" \
        -j REDIRECT --to-port "$4" 2>/dev/null || true
}

# Emit the iptables commands that assert the DNS redirect, for /etc/firewall.user
# Usage: dns_redirect_commands <to-port> <dport>...
dns_redirect_commands() {
    _drc_to="$1"; shift
    for _drc_if in $(lan_ifaces); do
        for _drc_dport in "$@"; do
            printf 'iptables -t nat -A PREROUTING -i %s -p udp --dport %s -j REDIRECT --to-port %s\n' \
                "$_drc_if" "$_drc_dport" "$_drc_to"
            printf 'iptables -t nat -A PREROUTING -i %s -p tcp --dport %s -j REDIRECT --to-port %s\n' \
                "$_drc_if" "$_drc_dport" "$_drc_to"
        done
    done
}

# Ensure the port-53 redirect exists on every LAN bridge.
#
# Rules are checked per interface and per protocol rather than "is there any
# rule mentioning the port", so a VLAN added after install gets covered on the
# next call (boot, or the 5-minute watchdog) instead of silently bypassing ctrld.
# Returns 0 if anything was added.
ensure_iptables() {
    local port="${1:-$DNS_PORT}"
    local added=0
    local iface
    for iface in $(lan_ifaces); do
        if ensure_redirect_rule append "$iface" udp 53 "$port"; then added=$((added + 1)); fi
        if ensure_redirect_rule append "$iface" tcp 53 "$port"; then added=$((added + 1)); fi
    done
    if [ "$added" -gt 0 ]; then
        # Rules are back — whatever tore them down is no longer true
        rm -f "$DEGRADED_FLAG" 2>/dev/null || true
        return 0
    fi
    return 1
}

# Tear the DNS redirects down, on every bridge and both ports.
#
# Last resort for the watchdog: with ctrld dead the redirects point port 53 at a
# closed port, so every client on every bridge loses DNS entirely — worse than
# not intercepting at all. Removing them hands resolution back to dnsmasq ->
# https-dns-proxy: still encrypted, just without per-device visibility.
# post-cfg.sh and the watchdog re-add the rules once ctrld answers again.
# Usage: remove_dns_redirects [port]
remove_dns_redirects() {
    _rdr_port="${1:-$DNS_PORT}"
    for _rdr_if in $(lan_ifaces); do
        for _rdr_dport in 53 853; do
            del_redirect_rule "$_rdr_if" udp "$_rdr_dport" "$_rdr_port"
            del_redirect_rule "$_rdr_if" tcp "$_rdr_dport" "$_rdr_port"
        done
    done
    # Drop the firewall.user block too, or the next firewall reload re-adds them
    remove_block "$FW_USER" "$FW_MARKER"
    printf 'ctrld unrecoverable — DNS redirects removed so the LAN keeps resolving\n' \
        > "$DEGRADED_FLAG" 2>/dev/null || true
}

# Delete redirect rules pointing at our port on interfaces that are not LAN
# bridges any more — a VLAN removed from the router, or br-lan_2 left behind by
# the era when the bridge list was hardcoded. Rules are otherwise only ever
# added, so stale ones linger until a reboot. Prints the number removed.
# Usage: prune_stale_redirects [port]
prune_stale_redirects() {
    _psr_port="${1:-$DNS_PORT}"
    _psr_keep=" $(lan_ifaces | tr '\n' ' ')"
    _psr_rules="$(iptables-save -t nat 2>/dev/null | grep '^-A PREROUTING' \
        | grep -- "--to-ports ${_psr_port}")"
    _psr_n=0
    if [ -n "$_psr_rules" ]; then
        _psr_ifs="$IFS"
        IFS='
'
        for _psr_rule in $_psr_rules; do
            _psr_if="$(printf '%s\n' "$_psr_rule" | sed -n 's/.* -i \([^ ]*\).*/\1/p')"
            [ -n "$_psr_if" ] || continue
            case "$_psr_keep" in *" ${_psr_if} "*) continue ;; esac
            # shellcheck disable=SC2086  # the saved rule spec must word-split
            if iptables -t nat -D PREROUTING ${_psr_rule#-A PREROUTING } 2>/dev/null; then
                _psr_n=$((_psr_n + 1))
            fi
        done
        IFS="$_psr_ifs"
    fi
    printf '%s' "$_psr_n"
}

# ── Marker-Delimited File Blocks ──
# Used to keep /etc/firewall.user in sync with the current LAN bridge list
# without appending a duplicate block on every run.

# Print the body of a marked block (empty if absent)
# Usage: read_block <file> <marker>
read_block() {
    [ -f "$1" ] || return 0
    $AWK -v m="$2" '
        $0 == "# " m " BEGIN" { inb = 1; next }
        $0 == "# " m " END"   { inb = 0; next }
        inb { print }
    ' "$1"
}

# Replace (or create) a marked block with the text on stdin
# Usage: replace_block <file> <marker> < body
replace_block() {
    _rb_file="$1"; _rb_marker="$2"
    _rb_body="$(cat)"
    _rb_tmp="${_rb_file}.controld.$$"
    [ -f "$_rb_file" ] || : > "$_rb_file"
    if ! $AWK -v m="$_rb_marker" '
        $0 == "# " m " BEGIN" { skip = 1; next }
        $0 == "# " m " END"   { skip = 0; next }
        !skip { print }
    ' "$_rb_file" > "$_rb_tmp"; then
        rm -f "$_rb_tmp"
        return 1
    fi
    {
        printf '# %s BEGIN\n' "$_rb_marker"
        printf '%s\n' "$_rb_body"
        printf '# %s END\n' "$_rb_marker"
    } >> "$_rb_tmp"
    mv "$_rb_tmp" "$_rb_file"
}

# Delete a marked block
# Usage: remove_block <file> <marker>
remove_block() {
    [ -f "$1" ] || return 0
    printf '' | replace_block "$1" "$2"
    # replace_block leaves an empty block behind; strip the markers too
    sed -i "/^# $2 BEGIN$/,/^# $2 END$/d" "$1"
}

# Keep /etc/firewall.user asserting the DNS redirects for the current LAN
# bridges, so they are restored instantly on a firewall reload. Rewrites only on
# drift (a new VLAN, a changed port), so the 5-minute watchdog does not write to
# flash every cycle. Port 853 is included only when forced DNS is on.
# Usage: ensure_firewall_user_rules [port]
ensure_firewall_user_rules() {
    _efu_port="${1:-$DNS_PORT}"
    _efu_file="$FW_USER"
    if [ "${FORCED_DNS:-0}" = "1" ]; then
        _efu_want="$(dns_redirect_commands "$_efu_port" 53 853)"
    else
        _efu_want="$(dns_redirect_commands "$_efu_port" 53)"
    fi
    if [ "$(read_block "$_efu_file" "$FW_MARKER")" = "$_efu_want" ]; then
        return 1
    fi
    # Drop pre-marker rules from older installs so they are not duplicated
    if [ -f "$_efu_file" ]; then
        sed -i -e '/controld-forced-dns-853/d' \
               -e '/ControlD per-device DNS redirect/d' \
               -e '/^iptables -t nat -A PREROUTING -i br-lan.*--dport 53 -j REDIRECT --to-port/d' \
               -e '/^iptables -t nat -A PREROUTING -i br-lan.*--dport 853 -j REDIRECT --to-port/d' "$_efu_file"
    fi
    printf '%s\n' "$_efu_want" | replace_block "$_efu_file" "$FW_MARKER"
    logger -t controld "firewall.user DNS redirect rules updated ($(lan_ifaces | tr '\n' ' '))"
    return 0
}

# The FORCED_DNS value a (re)install should write.
#
# Preserves an existing choice, falling back to the live uci state for installs
# that predate the flag. setup.sh wrote 0 unconditionally, so re-running it over
# a working install left the flag saying "off" while uci and the port-853 rules
# still said "on": ensure_forced_dns then skipped its restore and firewall.user
# was rebuilt without the DoT hijack, so the setting decayed at the next reboot
# while status.sh still reported it enabled.
# Usage: preserved_forced_dns [env-file]
preserved_forced_dns() {
    _pfd_env="${1:-/cfg/controld.env}"
    _pfd_val=""
    if [ -f "$_pfd_env" ]; then
        _pfd_val="$(sed -n 's/^FORCED_DNS=\([01]\).*/\1/p' "$_pfd_env" | head -1)"
    fi
    if [ "$_pfd_val" = "1" ]; then
        printf '1'
        return 0
    fi
    if [ "$(uci -q get https-dns-proxy.config.force_dns 2>/dev/null || echo 0)" = "1" ]; then
        printf '1'
        return 0
    fi
    printf '0'
}

# ── Env file ──

# Write the recovery config from the current settings.
#
# FORCED_DNS is resolved BEFORE the file is opened. `cat > file << EOF`
# truncates the target before the here-document is expanded, so a $(...) inside
# the here-doc that reads that same file always sees it empty. setup.sh did
# exactly that: the preserved value was silently always empty, and only the uci
# fallback inside preserved_forced_dns kept forced DNS alive across a re-install
# — until a firmware update wiped /etc/config, when the setting vanished with it.
# Usage: write_env_file [path]
# CURLD_VERSION is listed so it is never carried forward: an env file inherited
# from the original project has it, load_env adopts its value, and the first
# rewrite then drops the misspelled line rather than preserving it forever.
WEF_MANAGED="RESOLVER_ID BOOTSTRAP_IP CTRLD_VERSION CURLD_VERSION DNS_TYPE PREFERRED_PROTOCOL FORCED_DNS"

write_env_file() {
    _wef_path="${1:-/cfg/controld.env}"
    _wef_forced="$(preserved_forced_dns "$_wef_path")"

    # Everything the file carries that this function does not manage, read
    # before the redirect below truncates it.
    #
    # This used to emit six keys and nothing else, so every rewrite — any
    # reconfigure.sh --protocol/--resolver/--benchmark, and every setup.sh
    # re-install — silently deleted the rest. DNS_PORT went, while ctrld.toml
    # kept the moved port: at the next boot post-cfg.sh probed 5354, failed its
    # health check, added no redirects, and the watchdog then read a failing
    # DNS check every five minutes and churned the protocol chain against a
    # problem that was never the protocol. LAN_IFACES_EXCLUDE went too — the
    # documented way to leave a guest VLAN on its own DNS — so the watchdog
    # started intercepting that VLAN within five minutes of an unrelated
    # protocol change.
    _wef_keep=""
    if [ -f "$_wef_path" ]; then
        # Only well-formed assignments are carried. The file is sourced, so a
        # malformed line like `FOO=bar baz` runs `baz` on every load; carrying
        # such a line forward would make that permanent, where previously the
        # next rewrite dropped it. A value is kept when it is fully
        # double-quoted or contains nothing that the shell would act on.
        _wef_keep="$($AWK -v managed=" $WEF_MANAGED " '
            /^[A-Za-z_][A-Za-z0-9_]*=/ {
                eq = index($0, "=")
                k = substr($0, 1, eq - 1)
                if (index(managed, " " k " ") != 0) next
                v = substr($0, eq + 1)
                if (v ~ /^"[^"]*"$/ || v ~ /^[A-Za-z0-9_.:\/@%+-]*$/) print
            }
        ' "$_wef_path")"
    fi

    cat > "$_wef_path" << WEFEOF
RESOLVER_ID=${RESOLVER_ID}
BOOTSTRAP_IP=${BOOTSTRAP_IP}
CTRLD_VERSION=${CTRLD_VERSION}
DNS_TYPE=${DNS_TYPE}
PREFERRED_PROTOCOL=${PREFERRED_PROTOCOL:-$DNS_TYPE}
FORCED_DNS=${_wef_forced}
WEFEOF
    [ -z "$_wef_keep" ] || printf '%s\n' "$_wef_keep" >> "$_wef_path"
}

# ── Fallback resolver ──

# Point the https-dns-proxy fallback at a ControlD resolver.
#
# This is the backstop that answers whenever ctrld is down, so it has to move
# with the resolver ID. Rotating an ID and leaving this behind means a retired
# or leaked profile still resolves for the whole LAN every time ctrld restarts.
# Every configured instance is updated — the router ships three, but the count
# is read from uci rather than assumed.
# Usage: set_fallback_resolver <resolver-id> <bootstrap-ip>
set_fallback_resolver() {
    _sfr_id="$1"
    _sfr_boot="$2"
    _sfr_i=0
    # Bounded: a broken `uci get` that always succeeds must not spin forever.
    while [ "$_sfr_i" -lt 16 ] && uci -q get "https-dns-proxy.@https-dns-proxy[${_sfr_i}]" >/dev/null 2>&1; do
        uci set "https-dns-proxy.@https-dns-proxy[${_sfr_i}].resolver_url=https://dns.controld.com/${_sfr_id}"
        uci set "https-dns-proxy.@https-dns-proxy[${_sfr_i}].bootstrap_dns=${_sfr_boot}"
        _sfr_i=$((_sfr_i + 1))
    done
    [ "$_sfr_i" -gt 0 ] || return 1
    uci commit https-dns-proxy
    return 0
}

# ── Forced DNS ──

# Write FORCED_DNS=<0|1> to /cfg/controld.env — update in place or append if absent.
# Usage: set_forced_dns_flag <0|1>
set_forced_dns_flag() {
    _val="$1"
    if grep -q '^FORCED_DNS=' /cfg/controld.env 2>/dev/null; then
        sed -i "s|^FORCED_DNS=.*|FORCED_DNS=${_val}|" /cfg/controld.env
    else
        printf 'FORCED_DNS=%s\n' "$_val" >> /cfg/controld.env
    fi
}

# Ensure forced-DNS state matches the FORCED_DNS env flag.
# Restores uci config + port-853 iptables rules + firewall.user lines ONLY on drift,
# so it is cheap to call from the 5-min watchdog (no https-dns-proxy restart in the
# steady state). Requires FORCED_DNS and DNS_PORT (set via load_env).
ensure_forced_dns() {
    [ "${FORCED_DNS:-0}" = "1" ] || return 0

    _port="${DNS_PORT:-5354}"
    _changed=0

    # 1. uci config — restored here so it survives firmware wipes of /etc/config
    _cur="$(uci -q get https-dns-proxy.config.force_dns 2>/dev/null || echo "0")"
    [ "$_cur" = "1" ] || { uci set https-dns-proxy.config.force_dns=1; _changed=1; }
    # Ensure 53 and 853 are both in force_dns_port. Additive on purpose: the
    # list is a stock https-dns-proxy default and may carry extra ports someone
    # added deliberately, so add what is missing instead of rebuilding it.
    # Matched word-wise so a port like 8530 is not mistaken for 853.
    _ports=" $(uci -q get https-dns-proxy.config.force_dns_port 2>/dev/null || echo "") "
    for _fdp in 53 853; do
        case "$_ports" in
            *" ${_fdp} "*) : ;;
            *)  uci add_list https-dns-proxy.config.force_dns_port="$_fdp"
                _ports="${_ports}${_fdp} "
                _changed=1 ;;
        esac
    done
    if [ "$_changed" = "1" ]; then
        uci commit https-dns-proxy
        /etc/init.d/https-dns-proxy restart >/dev/null 2>&1 || true
        logger -t forced-dns "restored uci force_dns=1 (ports 53,853)"
    fi

    # 2. port-853 iptables rules — restored here so they survive reboot.
    #    Checked per bridge, so a VLAN added after install is covered too.
    _added=0
    for _if in $(lan_ifaces); do
        if ensure_redirect_rule insert "$_if" tcp 853 "$_port"; then _added=$((_added + 1)); fi
        if ensure_redirect_rule insert "$_if" udp 853 "$_port"; then _added=$((_added + 1)); fi
    done
    if [ "$_added" -gt 0 ]; then
        logger -t forced-dns "restored ${_added} port-853 redirect rule(s)"
    fi

    # 3. firewall.user — persist the 53 + 853 rules so a firewall reload
    #    restores them instantly (rewritten only when the bridge list drifts)
    ensure_firewall_user_rules "$_port" || true

    return 0
}

# Disable forced DNS: remove port-853 iptables rules, firewall.user lines, uci flag.
disable_forced_dns() {
    _port="${DNS_PORT:-5354}"

    for _if in $(lan_ifaces); do
        del_redirect_rule "$_if" tcp 853 "$_port"
        del_redirect_rule "$_if" udp 853 "$_port"
    done

    if [ -f "$FW_USER" ]; then
        # Legacy (pre-marker) lines, then rewrite our block without port 853
        sed -i -e '/controld-forced-dns-853/d' -e '/--dport 853 -j REDIRECT/d' "$FW_USER"
        FORCED_DNS=0
        # Only re-assert a block that is still there. This call means "keep the
        # persisted rules in step with the new setting", which is right when
        # forced DNS is toggled off on a live install — the port-53 redirects
        # stay. uninstall.sh calls this *after* tearing the block out, and
        # ensure_firewall_user_rules creates one when none exists, so it wrote
        # twelve port-53 REDIRECTs back into /etc/firewall.user pointing at a
        # port nothing would ever listen on again. Found on a router: the next
        # firewall reload or reboot would have taken DNS down on every bridge,
        # permanently, with none of this project left on the box to explain it.
        if grep -q "^# ${FW_MARKER} BEGIN\$" "$FW_USER" 2>/dev/null; then
            ensure_firewall_user_rules "$_port" || true
        fi
    fi

    uci set https-dns-proxy.config.force_dns=0
    uci commit https-dns-proxy
    /etc/init.d/https-dns-proxy restart >/dev/null 2>&1 || true

    # force_dns=0 is the entire disable, and force_dns_port is deliberately left
    # alone. The init script unsets the whole forcing block unless force_dns is 1
    # ([ "$force_dns" = '1' ] || unset force_dns), so the port list is inert once
    # this is 0. The list is also not ours to remove: 53 and 853 are the ports
    # the package ships in /etc/config/https-dns-proxy, and the same pair is the
    # init script's built-in fallback when the option is absent. Earlier versions
    # deleted it, which removed a vendor default and lost the argument anyway --
    # the Route 10 rewrites the option back on the next boot.
    logger -t forced-dns "forced DNS disabled"
}

# ── Protocol self-upgrade ──

# If running on a fallback protocol, periodically test the user's
# PREFERRED_PROTOCOL on a throwaway loopback port (5360) and switch production
# back only if it resolves. Production DNS is never disrupted during the test
# (separate port + loopback listener); production is switched only on success.
# Rate-limited by UPGRADE_INTERVAL healthy cycles. Honors DRY_RUN.
# Requires load_env first (DNS_TYPE, PREFERRED_PROTOCOL, RESOLVER_ID, BOOTSTRAP_IP).
do_upgrade_check() {
    _ucf="/tmp/controld-upgrade.count"
    _uint="${UPGRADE_INTERVAL:-6}"   # ~30 min at 5-min cron
    _uport=5360

    # Already on the preferred protocol — nothing to do; clear any stale counter
    [ "${PREFERRED_PROTOCOL:-$DNS_TYPE}" != "$DNS_TYPE" ] || { rm -f "$_ucf"; return 0; }

    _u=$(cat "$_ucf" 2>/dev/null || echo 0)
    _u=$((_u + 1))
    if [ "$_u" -lt "$_uint" ]; then
        [ "${DRY_RUN:-0}" = "1" ] || echo "$_u" > "$_ucf"
        return 0
    fi
    [ "${DRY_RUN:-0}" = "1" ] || echo 0 > "$_ucf"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        logger -t watchdog "DRY-RUN: would test + upgrade back to $(proto_label "$PREFERRED_PROTOCOL")"
        return 0
    fi

    # Probe the preferred protocol on a throwaway ctrld on the loopback test port
    _ep="$(get_endpoint "$PREFERRED_PROTOCOL" "$RESOLVER_ID")"
    cat > /tmp/ctrld-upgrade.toml << EOF
[service]
    log_level = "error"
    cache_enable = false
[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "upgrade-test"
[upstream.0]
    bootstrap_ip = "${BOOTSTRAP_IP}"
    endpoint = "${_ep}"
    name = "upgrade-test"
    timeout = 5000
    type = "${PREFERRED_PROTOCOL}"
    send_client_info = false
[listener.0]
    ip = "127.0.0.1"
    port = ${_uport}
EOF
    /cfg/ctrld run -c /tmp/ctrld-upgrade.toml -d >/dev/null 2>&1 &
    _tpid=$!
    _un=0
    while [ "$_un" -lt 8 ]; do
        nslookup google.com "127.0.0.1#${_uport}" >/dev/null 2>&1 && break
        sleep 1; _un=$((_un + 1))
    done
    # Kill ONLY the test ctrld (matched by its config path) — never production
    _killed=0
    for _p in $(ps w 2>/dev/null | grep '[c]trld run -c /tmp/ctrld-upgrade.toml' | awk '{print $1}'); do
        kill "$_p" 2>/dev/null; _killed=1
    done
    [ "$_killed" = "1" ] || kill "$_tpid" 2>/dev/null
    rm -f /tmp/ctrld-upgrade.toml

    if [ "$_un" -ge 8 ]; then
        logger -t watchdog "preferred $(proto_label "$PREFERRED_PROTOCOL") still failing on test — staying on $(proto_label "$DNS_TYPE")"
        return 1
    fi

    logger -t watchdog "preferred $(proto_label "$PREFERRED_PROTOCOL") healthy — upgrading back"
    # Switch the transport in place. Regenerating the config here (what this
    # used to do) silently deleted every split-DNS policy — automatically, about
    # 30 minutes after any protocol fallback, with nothing logged.
    retarget_upstreams /cfg/ctrld.toml "$PREFERRED_PROTOCOL"
    if restart_ctrld /cfg/ctrld.toml; then
        sed -i "s/^DNS_TYPE=.*/DNS_TYPE=${PREFERRED_PROTOCOL}/" /cfg/controld.env
        logger -t watchdog "upgraded to $(proto_label "$PREFERRED_PROTOCOL")"
        return 0
    fi
    logger -t watchdog "upgrade to $(proto_label "$PREFERRED_PROTOCOL") failed after switch — watchdog will retry"
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
