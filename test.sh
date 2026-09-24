#!/bin/sh
# test.sh: comprehensive test suite for Alta Route 10 + ControlD
# Run locally: sh test.sh
# Run on router: sh /tmp/controld/test.sh   (a copy of the repo, not /cfg)

set -e

# ── Test Framework ──

PASS=0
FAIL=0
SKIP=0
TOTAL=0
CURRENT_GROUP=""

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

describe() {
    CURRENT_GROUP="$1"
    printf "\n  ${BOLD}${YELLOW}[TEST] %s${RESET}\n" "$1"
}

assert_eq() {
    TOTAL=$((TOTAL + 1))
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf "    ${GREEN}PASS${RESET}  %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "    ${RED}FAIL${RESET}  %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

# The haystack reaches grep through printf, never echo, and the needle through
# -e, never as a bare operand.
#
# dash's echo expands backslash escapes and BusyBox ash's does not, so a
# haystack carrying a literal "\033" arrives at grep as an escape character in
# CI and as six characters on the router. An assertion over any text with a
# backslash in it therefore tested something different in each place, which is
# the one failure mode this suite exists to rule out. printf '%s\n' passes the
# string through unchanged in every shell.
#
# And a needle is a pattern, not an option. Without -e, one beginning with a
# dash is parsed by grep as a flag: `assert_contains` then fails for a reason
# that has nothing to do with the haystack, and `assert_not_contains` passes
# whatever the haystack holds, because grep exits non-zero either way. An
# assertion over an iptables rule spec or a command line is the obvious case,
# and it is the second time a helper in this file has been able to report a
# pass it never earned.
assert_contains() {
    TOTAL=$((TOTAL + 1))
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s\n' "$haystack" | grep -q -e "$needle"; then
        PASS=$((PASS + 1))
        printf "    ${GREEN}PASS${RESET}  %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "    ${RED}FAIL${RESET}  %s\n  string does not contain: '%s'\n" "$desc" "$needle"
    fi
}

assert_not_contains() {
    TOTAL=$((TOTAL + 1))
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s\n' "$haystack" | grep -q -e "$needle"; then
        FAIL=$((FAIL + 1))
        printf "    ${RED}FAIL${RESET}  %s\n  string should not contain: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
        printf "    ${GREEN}PASS${RESET}  %s\n" "$desc"
    fi
}

assert_match() {
    TOTAL=$((TOTAL + 1))
    local desc="$1" actual="$2" pattern="$3"
    if printf '%s\n' "$actual" | grep -qE -e "$pattern"; then
        PASS=$((PASS + 1))
        printf "    ${GREEN}PASS${RESET}  %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "    ${RED}FAIL${RESET}  %s\n  '%s' does not match pattern: '%s'\n" "$desc" "$actual" "$pattern"
    fi
}

assert_file_contains() {
    TOTAL=$((TOTAL + 1))
    local desc="$1" file="$2" pattern="$3"
    if [ -f "$file" ] && grep -q -e "$pattern" "$file"; then
        PASS=$((PASS + 1))
        printf "    ${GREEN}PASS${RESET}  %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "    ${RED}FAIL${RESET}  %s\n  file '%s' missing or doesn't contain: '%s'\n" "$desc" "$file" "$pattern"
    fi
}

assert_true() {
    TOTAL=$((TOTAL + 1))
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf "    ${GREEN}PASS${RESET}  %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "    ${RED}FAIL${RESET}  %s\n  command failed: %s\n" "$desc" "$*"
    fi
}

assert_false() {
    TOTAL=$((TOTAL + 1))
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        printf "    ${RED}FAIL${RESET}  %s\n  command should have failed but succeeded: %s\n" "$desc" "$*"
    else
        PASS=$((PASS + 1))
        printf "    ${GREEN}PASS${RESET}  %s\n" "$desc"
    fi
}

# Source greps that only ever see code.
#
# An assertion that greps a whole file for the thing it is checking is
# satisfied by a comment that merely mentions it, including the comment left
# behind when the real line is commented out. That has already fooled one
# assertion in this suite (a bare `grep -q running_protocol` matched a comment
# naming the function rather than the call), so the filter lives in one place
# instead of being re-derived per assertion. Comment-only lines are blanked
# rather than deleted, so code_lineno's numbering still matches the real file.
#
# Everything after the filename is handed to grep untouched, so a call keeps
# whichever dialect it was already written in. That is not cosmetic: forcing
# -E on patterns written for BRE silently changes what they mean.
# `_port_in_use()` and `trld run -c ${_bs_conf}` both stop matching, and
# `FORCED_DNS=$(preserved_forced_dns` makes grep exit on "Unmatched (", and an
# assertion that quietly stops testing anything looks exactly like one that
# passes.
# Usage: code_grep <file> [grep-opts] <pattern>   (same for code_lineno)
code_only()   { sed 's/^[[:space:]]*#.*$//' "$@"; }
code_grep()   { _cg_f="$1"; shift; code_only "$_cg_f" | grep -q "$@"; }
code_lineno() { _cl_f="$1"; shift; code_only "$_cl_f" | grep -n "$@" | head -1 | cut -d: -f1; }

skip() {
    TOTAL=$((TOTAL + 1))
    SKIP=$((SKIP + 1))
    printf "    ${YELLOW}SKIP${RESET}  %s\n" "$1"
}

# ── Setup ──

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# This suite reads the project's sources, not only the installed runtime: a
# score of describe blocks extract from setup.sh, and one compares README.md's
# protocol menu against the installer's own. An install puts lib.sh and five
# utility scripts into /cfg and nothing else, so running from there read files
# that were not there — and `set -e` turns a failed command substitution in an
# assignment into an exit. The suite died at assertion 420 of ~700 with exit 2
# and no summary at all, after 38 failures that were one missing file wearing
# different hats. A long stream of PASS lines ending at a prompt reads like
# success.
#
# Fail here instead, before a single assertion runs, and say what to do. This
# is why CONTRIBUTING.md's on-router step is a copy of the repo.
_ts_missing=""
for _ts_need in lib.sh setup.sh status.sh benchmark.sh reconfigure.sh \
                audit.sh uninstall.sh README.md docs/technical-details.md; do
    [ -f "$SCRIPT_DIR/$_ts_need" ] || _ts_missing="${_ts_missing} ${_ts_need}"
done
if [ -n "$_ts_missing" ]; then
    echo "test.sh needs the project's sources beside it. Missing:${_ts_missing}" >&2
    echo "An install does not put them all in /cfg. Run from a copy of the repo:" >&2
    echo "  scp -r *.sh README.md docs route10:/tmp/controld/" >&2
    echo "  ssh route10 'sh /tmp/controld/test.sh'" >&2
    exit 1
fi

TMPDIR=$(mktemp -d 2>/dev/null || echo "/tmp/controld-test-$$")
mkdir -p "$TMPDIR"

# The real PATH, captured before any test puts a stub in front of it. The
# integration block runs the router's own scripts as child processes, and they
# must resolve the system's binaries, not this suite's fakes. See the guard
# just above "Router integration tests".
TS_REAL_PATH="$PATH"

# Source the library
. "$SCRIPT_DIR/lib.sh"

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

printf "\n  ${BOLD}═══════════════════════════════════════════════════${RESET}\n"
printf "  ${BOLD}  ControlD Tools Test Suite${RESET}\n"
printf "  ${BOLD}═══════════════════════════════════════════════════${RESET}\n"

# ══════════════════════════════════════════════════════════════════
# UNIT TESTS: lib.sh functions
# ══════════════════════════════════════════════════════════════════

describe "the assertion helpers — a needle that begins with a dash"

# grep takes the needle as a pattern via -e. Without it, a needle beginning
# with a dash is parsed as a flag and grep exits non-zero whatever the haystack
# holds: assert_contains failed for the wrong reason, and assert_not_contains
# reported a pass for a needle that was plainly there. An iptables rule spec is
# the obvious haystack, and this suite now asserts over several.
#
# Each probe runs in a command substitution, so its subshell's counters are
# discarded and only its verdict is examined here.
AH_HAY='-A PREROUTING -i br-lan_99 -p udp --dport 53 -j REDIRECT'
assert_contains "assert_not_contains fails on a dash-led needle that is present" \
    "$(assert_not_contains probe "$AH_HAY" '-i br-lan_99')" "FAIL"
assert_contains "assert_contains passes on a dash-led needle that is present" \
    "$(assert_contains probe "$AH_HAY" '-i br-lan_99')" "PASS"
assert_contains "assert_contains fails on a dash-led needle that is absent" \
    "$(assert_contains probe "$AH_HAY" '-i br-lan_7 ')" "FAIL"

describe "get_endpoint() — endpoint URL generation"
assert_eq "DoQ endpoint"    "abc123.dns.controld.com" "$(get_endpoint doq abc123)"
assert_eq "DoT endpoint"    "abc123.dns.controld.com" "$(get_endpoint dot abc123)"
assert_eq "DoH3 endpoint"   "https://dns.controld.com/abc123" "$(get_endpoint doh3 abc123)"
assert_eq "DoH endpoint"    "https://dns.controld.com/abc123" "$(get_endpoint doh abc123)"
assert_eq "Long resolver"   "xyz999abc.dns.controld.com" "$(get_endpoint doq xyz999abc)"

describe "proto_label() — human-readable names"
assert_eq "DoH3 label"  "DoH3 (HTTP/3)"  "$(proto_label doh3)"
assert_eq "DoQ label"   "DoQ (QUIC)"     "$(proto_label doq)"
assert_eq "DoH label"   "DoH (HTTP/2)"   "$(proto_label doh)"
assert_eq "DoT label"   "DoT (TLS)"      "$(proto_label dot)"

describe "next_proto() — fallback chain"
assert_eq "doq next"    "doh3" "$(next_proto doq)"
assert_eq "doh3 next"   "doh"  "$(next_proto doh3)"
assert_eq "doh wraps"   "doh3" "$(next_proto doh)"

describe "valid_policy_name() — input validation"
assert_true  "a plain name"             valid_policy_name "Kids"
assert_true  "spaces and an apostrophe" valid_policy_name "Kid's iPad"
assert_false "a double quote"           valid_policy_name 'Kid "A"'
assert_false "a backslash"              valid_policy_name 'Kids\Guest'

describe "valid_resolver() — input validation"
assert_true  "valid short resolver"  valid_resolver "abc123"
assert_true  "valid long resolver"   valid_resolver "abc12345de"
assert_false "too short"             valid_resolver "ab"
assert_false "empty string"          valid_resolver ""
assert_false "has uppercase"         valid_resolver "ABC123"
assert_false "has special chars"     valid_resolver "abc-123"

describe "valid_mac() — MAC address validation"
assert_true  "valid MAC"      valid_mac "AA:BB:CC:DD:EE:FF"
assert_true  "lowercase MAC"  valid_mac "aa:bb:cc:dd:ee:ff"
assert_false "too short"      valid_mac "AA:BB:CC"
assert_false "wrong separator" valid_mac "AA-BB-CC-DD-EE-FF"
assert_false "empty string"   valid_mac ""

describe "valid_cidr() — CIDR notation validation"
assert_true  "valid /24"       valid_cidr "192.168.1.0/24"
assert_true  "valid /32"       valid_cidr "192.168.1.100/32"
assert_false "no mask"         valid_cidr "192.168.1.0"
assert_false "empty string"    valid_cidr ""

describe "valid_proto() — protocol type validation"
assert_true  "doh3 is valid"   valid_proto doh3
assert_true  "doq is valid"    valid_proto doq
assert_true  "doh is valid"    valid_proto doh
assert_true  "dot is valid"    valid_proto dot
assert_false "invalid proto"   valid_proto "https"
assert_false "empty string"    valid_proto ""

# ══════════════════════════════════════════════════════════════════
# CONFIG GENERATION TESTS
# ══════════════════════════════════════════════════════════════════

describe "write_ctrld_config() — TOML generation"

TEST_CONF="$TMPDIR/test-doh3.toml"
write_ctrld_config "$TEST_CONF" "abc123" "76.76.2.22" "doh3"
assert_file_contains "DoH3 type in config"      "$TEST_CONF" 'type = "doh3"'
assert_file_contains "DoH3 endpoint in config"   "$TEST_CONF" 'endpoint = "https://dns.controld.com/abc123"'
assert_file_contains "bootstrap IP in config"     "$TEST_CONF" 'bootstrap_ip = "76.76.2.22"'
assert_file_contains "DNS port in config"         "$TEST_CONF" 'port = 5354'
assert_file_contains "cache enabled"              "$TEST_CONF" 'cache_enable = true'
assert_file_contains "DHCP discovery"             "$TEST_CONF" 'discover_dhcp = true'
assert_file_contains "lease file path"            "$TEST_CONF" 'dhcp_lease_file_path = "/cfg/dhcp.leases"'
assert_file_contains "send_client_info"           "$TEST_CONF" 'send_client_info = true'
assert_file_contains "catch-all network"          "$TEST_CONF" 'cidrs = \["0.0.0.0/0"\]'
# The old config hardcoded 192.168.1.0/24 + 192.168.2.0/24, which described no
# real router. LAN subnets are discovered at runtime instead.
assert_false "no hardcoded LAN subnets" grep -q '192.168.[12].0/24' "$TEST_CONF"

TEST_CONF2="$TMPDIR/test-doq.toml"
write_ctrld_config "$TEST_CONF2" "xyz789" "76.76.2.22" "doq"
assert_file_contains "DoQ type in config"        "$TEST_CONF2" 'type = "doq"'
assert_file_contains "DoQ endpoint in config"    "$TEST_CONF2" 'endpoint = "xyz789.dns.controld.com"'

# Verify TOML is parseable (basic syntax check)
assert_true "TOML has [service] section"   grep -q '\[service\]' "$TEST_CONF"
assert_true "TOML has [upstream.0]"         grep -q '\[upstream\.0\]' "$TEST_CONF"
assert_true "TOML has [listener.0]"         grep -q '\[listener\.0\]' "$TEST_CONF"
assert_true "TOML has [network.0]"          grep -q '\[network\.0\]' "$TEST_CONF"

# ══════════════════════════════════════════════════════════════════
# LAN INTERFACE DISCOVERY
# ══════════════════════════════════════════════════════════════════

describe "lan_ifaces() — LAN bridge discovery"

FAKE_NET="$TMPDIR/sys-net"
mkdir -p "$FAKE_NET/br-lan" "$FAKE_NET/br-lan_2" "$FAKE_NET/br-lan_10" \
         "$FAKE_NET/br-lan_20" "$FAKE_NET/eth4" "$FAKE_NET/ppp0"

ifaces="$(SYSFS_NET="$FAKE_NET" lan_ifaces | tr '\n' ' ')"
assert_contains "finds the default bridge"      "$ifaces" "br-lan "
assert_contains "finds VLAN 10 bridge"          "$ifaces" "br-lan_10"
assert_contains "finds VLAN 20 bridge"          "$ifaces" "br-lan_20"
assert_not_contains "skips the WAN interface"   "$ifaces" "eth4"
assert_not_contains "skips PPP interfaces"      "$ifaces" "ppp0"

excluded="$(SYSFS_NET="$FAKE_NET" LAN_IFACES_EXCLUDE="br-lan_20" lan_ifaces | tr '\n' ' ')"
assert_not_contains "LAN_IFACES_EXCLUDE drops a bridge" "$excluded" "br-lan_20"
assert_contains "LAN_IFACES_EXCLUDE keeps the rest"  "$excluded" "br-lan_10"

override="$(LAN_IFACES="br-lan br-lan_30" lan_ifaces | tr '\n' ' ')"
assert_eq "LAN_IFACES overrides discovery" "br-lan br-lan_30 " "$override"

fallback="$(SYSFS_NET="$TMPDIR/no-such-dir" lan_ifaces)"
assert_eq "falls back to br-lan when sysfs is unreadable" "br-lan" "$fallback"

describe "lan_net_name() — bridge labels"
assert_eq "default bridge"  "LAN"     "$(lan_net_name br-lan)"
assert_eq "VLAN bridge"     "VLAN 10" "$(lan_net_name br-lan_10)"
assert_eq "unknown bridge"  "eth4"    "$(lan_net_name eth4)"

describe "ipv4_network() — subnet from address + prefix"
assert_eq "/24"  "192.168.10.0/24" "$(ipv4_network 192.168.10.117 24)"
assert_eq "/16"  "192.168.0.0/16"  "$(ipv4_network 192.168.10.117 16)"
assert_eq "/8"   "10.0.0.0/8"      "$(ipv4_network 10.1.2.3 8)"
assert_eq "/20"  "172.16.0.0/20"   "$(ipv4_network 172.16.5.9 20)"
assert_eq "/32"  "192.168.1.7/32"  "$(ipv4_network 192.168.1.7 32)"
assert_false "rejects a bad octet"  ipv4_network 192.168.1.999 24
assert_false "rejects a bad prefix" ipv4_network 192.168.1.1 33

describe "dns_redirect_commands() — firewall.user rules"
cmds="$(SYSFS_NET="$FAKE_NET" dns_redirect_commands 5354 53)"
assert_eq "one rule per bridge per protocol" "8" "$(printf '%s\n' "$cmds" | wc -l | tr -d ' ')"
assert_contains "covers VLAN 10 on udp" "$cmds" \
    "PREROUTING 1 -i br-lan_10 -p udp --dport 53 -j REDIRECT --to-port 5354"
assert_contains "covers VLAN 20 on tcp" "$cmds" \
    "PREROUTING 1 -i br-lan_20 -p tcp --dport 53 -j REDIRECT --to-port 5354"
both="$(SYSFS_NET="$FAKE_NET" dns_redirect_commands 5354 53 853)"
assert_eq "port 853 doubles the rule count" "16" "$(printf '%s\n' "$both" | wc -l | tr -d ' ')"

# Every line inserts at the head. firewall.user runs after fw3 has rebuilt its
# chains, so an appended rule lands below the zone chains — and one of those
# carries https-dns-proxy's own port-53 redirect, which then takes the traffic.
# Appending here would undo on the next firewall reload whatever precedence the
# live insertion established.
assert_eq "every restored rule inserts at the head" "16" \
    "$(printf '%s\n' "$both" | grep -c -e '-I PREROUTING 1')"
assert_not_contains "none is appended below the zone chains" "$both" '\-A PREROUTING'

describe "ensure_iptables() — port 53 must outrank the firewall zone chains"

# An appended REDIRECT sits below the zone chains fw3 builds, and
# https-dns-proxy's package redirect lives in one of them, taking port 53 to
# dnsmasq before our rule is reached. Found on a router where one zone covered
# three of six bridges: correct rules, healthy status.sh, clean audit.sh, and
# 45,563 queries answered by the wrong resolver. Inserting the same rule at the
# head took 42 packets within seconds.
#
# The 853 hijack already inserted, with a comment saying why. Port 53 — the
# path every client actually uses — did not.
EI_BIN="$TMPDIR/eibin"; mkdir -p "$EI_BIN"
EI_LOG="$TMPDIR/ei.log"; export EI_LOG
cat > "$EI_BIN/iptables" << 'EIEOF'
#!/bin/sh
# -C is the "does this rule exist" probe: say no, so the add path runs.
for _a in "$@"; do [ "$_a" = "-C" ] && exit 1; done
# -S lists the chain. Empty here: a sandbox with no rules yet, so the
# precedence check finds neither ours nor a zone jump and changes nothing.
for _a in "$@"; do [ "$_a" = "-S" ] && exit 0; done
printf '%s\n' "$*" >> "$EI_LOG"
exit 0
EIEOF
chmod +x "$EI_BIN/iptables"
: > "$EI_LOG"
( PATH="$EI_BIN:$PATH"; LAN_IFACES="br-lan br-lan_10"; ensure_iptables 5354 ) >/dev/null 2>&1
EI_ADDS="$(cat "$EI_LOG" 2>/dev/null)"

assert_eq "one rule added per bridge per protocol" "4" \
    "$(printf '%s\n' "$EI_ADDS" | grep -c 'PREROUTING')"
assert_eq "and every one of them inserts at the head" "4" \
    "$(printf '%s\n' "$EI_ADDS" | grep -c -e '-I PREROUTING 1')"
assert_not_contains "nothing is appended" "$EI_ADDS" '\-A PREROUTING'
assert_contains "the VLAN bridge is covered on udp" "$EI_ADDS" \
    '-I PREROUTING 1 -i br-lan_10 -p udp --dport 53 -j REDIRECT --to-port 5354'
unset EI_LOG

describe "ensure_iptables() — an already-appended rule must be moved, not left"

# The fix above only helps a fresh install. An install made before it has the
# rules appended, and ensure_redirect_rule returns early on a rule that exists,
# so --repair and the watchdog's five-minute cycle would both walk past an
# outranked rule and report success. This is the migration path: the chain is
# read, ours is found sitting below a zone jump, and it is deleted so the insert
# puts it back at the head.
#
# The chain fixture is the shape taken off a real router: the fw3 zone jump for
# the bridge, then our appended redirect far below it.
MG_BIN="$TMPDIR/mgbin"; mkdir -p "$MG_BIN"
MG_LOG="$TMPDIR/mg.log"; export MG_LOG
MG_CHAIN="$TMPDIR/mg.chain"; export MG_CHAIN
cat > "$MG_BIN/iptables" << 'MGEOF'
#!/bin/sh
for _a in "$@"; do [ "$_a" = "-C" ] && exit 1; done
for _a in "$@"; do [ "$_a" = "-S" ] && { cat "$MG_CHAIN" 2>/dev/null; exit 0; } ; done
printf '%s\n' "$*" >> "$MG_LOG"
exit 0
MGEOF
chmod +x "$MG_BIN/iptables"

# br-lan_10's redirect sits below its own zone jump; br-lan_20's sits above its
# own, with only another bridge's jump ahead of it.
cat > "$MG_CHAIN" << 'MGCEOF'
-A PREROUTING -i br-lan_10 -m comment --comment "!fw3" -j zone_lan_prerouting
-A PREROUTING -i br-lan_20 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan_20 -m comment --comment "!fw3" -j zone_v20zone_prerouting
-A PREROUTING -i br-lan_10 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
MGCEOF

assert_eq "a rule below its own zone jump is outranked" "below" \
    "$(PATH="$MG_BIN:$PATH" redirect_outranked br-lan_10 5354)"

# A jump for another bridge cannot take this bridge's traffic. Walking the
# chain without filtering by interface would call this outranked and tear down
# a rule that was working — br-lan_20 carried 13,941 packets on the router this
# came from, through a zone that happens not to redirect DNS.
assert_eq "a jump for another bridge does not outrank it" "ok" \
    "$(PATH="$MG_BIN:$PATH" redirect_outranked br-lan_20 5354)"

: > "$MG_LOG"
( PATH="$MG_BIN:$PATH"; LAN_IFACES="br-lan_10"; ensure_iptables 5354 ) >/dev/null 2>&1
MG_RAN="$(cat "$MG_LOG" 2>/dev/null)"
assert_contains "the outranked rule is deleted first" "$MG_RAN" \
    '-D PREROUTING -i br-lan_10 -p udp --dport 53'
assert_contains "and re-inserted at the head" "$MG_RAN" \
    '-I PREROUTING 1 -i br-lan_10 -p udp --dport 53 -j REDIRECT --to-port 5354'

# Once ours is ahead of the jump there is nothing to migrate, or --repair and
# the watchdog would tear down and rebuild working rules every five minutes.
cat > "$MG_CHAIN" << 'MGCOKEOF'
-A PREROUTING -i br-lan_10 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan_10 -m comment --comment "!fw3" -j zone_lan_prerouting
MGCOKEOF
: > "$MG_LOG"
( PATH="$MG_BIN:$PATH"; LAN_IFACES="br-lan_10"; ensure_iptables 5354 ) >/dev/null 2>&1
assert_not_contains "a rule already at the head is never deleted" \
    "$(cat "$MG_LOG" 2>/dev/null)" '\-D PREROUTING'
unset MG_LOG MG_CHAIN

describe "replace_block() / read_block() / remove_block()"
BLOCK_FILE="$TMPDIR/firewall.user"
printf 'existing line\n' > "$BLOCK_FILE"
printf 'one\ntwo\n' | replace_block "$BLOCK_FILE" "test-marker"
assert_eq "block body round-trips" "one
two" "$(read_block "$BLOCK_FILE" test-marker)"
assert_file_contains "unrelated content is kept" "$BLOCK_FILE" "existing line"
printf 'three\n' | replace_block "$BLOCK_FILE" "test-marker"
assert_eq "rewriting replaces, never appends" "three" "$(read_block "$BLOCK_FILE" test-marker)"
assert_eq "only one block after rewrite" "1" \
    "$(grep -c 'test-marker BEGIN' "$BLOCK_FILE" | tr -d ' ')"
remove_block "$BLOCK_FILE" "test-marker"
assert_false "removed block leaves no markers" grep -q 'test-marker' "$BLOCK_FILE"
assert_file_contains "removal keeps other content" "$BLOCK_FILE" "existing line"

describe "ensure_firewall_user_rules() — persisted rules"

# Stub logger and point the library at a temp file, so the test never touches /etc
mkdir -p "$TMPDIR/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMPDIR/bin/logger"
chmod +x "$TMPDIR/bin/logger"
PATH="$TMPDIR/bin:$PATH"

FW_USER="$TMPDIR/firewall.user"
SYSFS_NET="$FAKE_NET"
# A user rule plus the hardcoded block older versions appended
cat > "$FW_USER" << 'FWEOF'
iptables -t nat -A PREROUTING -i br-lan -p udp --dport 123 -j REDIRECT --to-port 9999

# ControlD per-device DNS redirect (restored by /cfg/rc.local)
iptables -t nat -A PREROUTING -i br-lan   -p udp --dport 53 -j REDIRECT --to-port 5354
iptables -t nat -A PREROUTING -i br-lan_2 -p udp --dport 53 -j REDIRECT --to-port 5354
FWEOF

assert_true "rewrites on drift" ensure_firewall_user_rules 5354
assert_file_contains "covers VLAN 10 now"     "$FW_USER" "br-lan_10 -p udp --dport 53"
assert_file_contains "keeps the user's own rule" "$FW_USER" "dport 123"
assert_false "drops the old hardcoded block" grep -q "restored by /cfg/rc.local" "$FW_USER"
# The legacy lines are replaced, not appended to
assert_eq "no duplicated rules" "0" \
    "$(sort "$FW_USER" | uniq -d | grep -c . | tr -d ' ')"
assert_eq "one rule pair per bridge" "2" \
    "$(grep -c 'br-lan_2 ' "$FW_USER" | tr -d ' ')"
assert_false "port 853 absent while forced DNS is off" grep -q 'dport 853' "$FW_USER"
assert_false "second call makes no changes" ensure_firewall_user_rules 5354

FORCED_DNS=1
assert_true "forced DNS adds port 853" ensure_firewall_user_rules 5354
assert_file_contains "853 rule present" "$FW_USER" "br-lan_10 -p tcp --dport 853"
FORCED_DNS=0
unset FW_USER SYSFS_NET

describe "is_our_rc_local() — never clobber someone else's boot hook"

# /etc/rc.local sources /cfg/rc.local only if it exists, so that path is the
# sanctioned place for a user's own boot hooks.
RCFIX="$TMPDIR/rc.local"
printf '#!/bin/sh\n# my own boot hook\nmount -o remount,rw /\n' > "$RCFIX"
assert_false "a user's own hook is not ours"   is_our_rc_local "$RCFIX"
printf '#!/bin/sh\n# /cfg/rc.local — %s\n' "$RC_MARKER" > "$RCFIX"
assert_true  "our generated hook is ours"      is_our_rc_local "$RCFIX"
assert_false "a missing file is not ours"      is_our_rc_local "$TMPDIR/no-such-rc.local"

# A hook written before the marker existed is still ours. Missing this left the
# boot hook behind on a real uninstall, and that hook re-adds cron jobs at the
# next boot pointing at scripts uninstall had just deleted.
RCOLD="$TMPDIR/rc.local.legacy"
cat > "$RCOLD" << 'RCOLDEOF'
#!/bin/sh
# /cfg/rc.local — sourced by /etc/rc.local at every boot
# Restores ControlD DNS, iptables rules, cron jobs, and firewall persistence

logger -t rc.local "ControlD boot hook starting"
[ -x /cfg/post-cfg.sh ] && /cfg/post-cfg.sh &
RCOLDEOF
assert_true "a pre-marker hook is recognised as ours" is_our_rc_local "$RCOLD"

# The generated file must carry the marker, or uninstall would refuse to remove
# its own hook and setup would back it up as a stranger's on every run.
RCGEN="$TMPDIR/rc-generated.sh"
sed -n "/^cat > \/cfg\/rc.local << 'RCLOCAL'/,/^RCLOCAL$/p" "$SCRIPT_DIR/setup.sh" \
    | sed '1d;$d' > "$RCGEN"
assert_true  "the generated hook carries the marker" is_our_rc_local "$RCGEN"

# is_our_rc_local also matches the logger line, so the assertion above still
# passes with the marker comment deleted. That comment is an interface rather
# than commentary (AGENTS.md, "Prose"), so assert the marker itself, or a prose
# pass over setup.sh could drop it with the suite staying green.
assert_true  "the generated hook carries the marker literally" \
    grep -qF "$RC_MARKER" "$RCGEN"

# RCFIX above hand-writes the marker line that setup.sh generates. Assert the
# two still match: a fixture shaped like the real file only tests the real file
# while it stays shaped like it.
assert_eq "the fixture's marker line matches the generated hook" \
    "$(grep -F "$RC_MARKER" "$RCGEN"  | head -1)" \
    "$(grep -F "$RC_MARKER" "$RCFIX"  | head -1)"

# Every script setup.sh generates is executed directly: watchdog.sh and
# controld-update.sh from cron, post-cfg.sh from the boot hook. A shell running
# a file with no shebang falls back to /bin/sh, so losing one is survivable
# rather than fatal, which is exactly why nothing noticed when it was removed
# from watchdog.sh and all 501 assertions still passed. Shebangs are an
# interface (AGENTS.md, "Prose"), so check the first line of each.
# Enumerated from setup.sh rather than listed here, so a script added later is
# covered without anyone remembering to extend this loop. A hardcoded list is
# the kind of guard that silently stops keeping up with the code it guards.
GEN_SCRIPTS="$(grep -oE "^cat > /cfg/[A-Za-z0-9._-]+ << '[A-Z]+'" "$SCRIPT_DIR/setup.sh" \
    | sed "s|^cat > /cfg/||; s| << '|:|; s|'\$||")"

# Two failures share this assertion, and both want a person to look. If the
# pattern above stops matching, the loop below runs over nothing and passes
# while testing nothing. If the count went up, a new script now ships to
# routers: check it is wired into cron or the boot hook, that uninstall.sh
# removes it, and that its own interfaces are guarded (AGENTS.md, "Prose"),
# then raise this number.
assert_eq "setup.sh generates the 4 scripts this suite knows about" "4" \
    "$(printf '%s\n' "$GEN_SCRIPTS" | grep -c .)"

# shellcheck disable=SC2086  # one name:TAG pair per word is the point
for _gen in $GEN_SCRIPTS; do
    _gen_name="${_gen%%:*}"
    _gen_tag="${_gen##*:}"
    assert_eq "generated ${_gen_name} opens with a shebang" "#!/bin/sh" \
        "$(sed -n "/^cat > \/cfg\/${_gen_name} << '${_gen_tag}'/,/^${_gen_tag}\$/p" \
            "$SCRIPT_DIR/setup.sh" | sed -n '2p')"
done

# It is sourced by /etc/rc.local, which runs its own logic afterwards: an exit
# or set -e here would silently skip the rest of the router's boot script.
assert_false "generated hook has no exit"   grep -qE '^[[:space:]]*exit' "$RCGEN"
assert_false "generated hook has no set -e" grep -qE '^[[:space:]]*set -e' "$RCGEN"
assert_true  "generated hook warns that it is sourced" grep -q 'sources' "$RCGEN"

describe "load_env() — the default every readout depends on"

# load_env takes the file as a parameter, so this runs the real path rather
# than an imitation of it. Flipping its default to 0, or deleting the line,
# left the suite green: every other test here drives the flag through the
# environment, which reaches the inline ${AUTO_UPDATE:-1} fallbacks in
# status.sh and audit.sh and never this assignment. On a router that flip
# means every readout reports the update off while the cron runs it.
LE_ENV="$TMPDIR/loadenv.env"
printf 'RESOLVER_ID=abc123\nCTRLD_VERSION=1.5.7\n' > "$LE_ENV"
assert_eq "an install predating the flag loads as on" "1" \
    "$( ( AUTO_UPDATE=; load_env "$LE_ENV" >/dev/null 2>&1; printf '%s' "$AUTO_UPDATE" ) )"
printf 'RESOLVER_ID=abc123\nAUTO_UPDATE=0\n' > "$LE_ENV"
assert_eq "and a recorded opt-out loads as off" "0" \
    "$( ( AUTO_UPDATE=; load_env "$LE_ENV" >/dev/null 2>&1; printf '%s' "$AUTO_UPDATE" ) )"
# The file wins over whatever the caller happened to have set, or a stray
# value in the environment would decide what the router reports.
assert_eq "the file beats an ambient value" "0" \
    "$( ( AUTO_UPDATE=1; load_env "$LE_ENV" >/dev/null 2>&1; printf '%s' "$AUTO_UPDATE" ) )"

describe "installed_auto_update() — only a deliberate 0 turns the update off"

IAU_ENV="$TMPDIR/iau.env"
assert_true  "no env file at all means on"  installed_auto_update "$TMPDIR/no-such.env"
printf 'RESOLVER_ID=abc123\n' > "$IAU_ENV"
assert_true  "an install predating the flag means on" installed_auto_update "$IAU_ENV"
printf 'AUTO_UPDATE=1\n' >> "$IAU_ENV"
assert_true  "an explicit 1 means on"       installed_auto_update "$IAU_ENV"
printf 'RESOLVER_ID=abc123\nAUTO_UPDATE=0\n' > "$IAU_ENV"
assert_false "an explicit 0 means off"      installed_auto_update "$IAU_ENV"
# Unparseable is on, not off. The alternative leaves a router that never
# patches itself because of a typo nobody can see.
printf 'AUTO_UPDATE=maybe\n' > "$IAU_ENV"
assert_true  "a value nobody can parse means on" installed_auto_update "$IAU_ENV"
# A caller running under set -e must read the same answer as one that is not.
# setup.sh and reconfigure.sh both set it, and the reader inherits it, so a
# line that returns non-zero before the flag aborted the sourced read and the
# opt-out was silently ignored in the caller that installs the cron. A
# malformed assignment is enough: `FOO=bar baz` runs baz.
IAU_EE="$TMPDIR/iau-errexit.env"
printf 'RESOLVER_ID=abc123
NOISY=bar baz
AUTO_UPDATE=0
' > "$IAU_EE"
assert_eq "errexit in the caller does not change the answer"     "$( ( set +e; installed_auto_update "$IAU_EE" && echo on || echo off ) )"     "$( ( set -e; installed_auto_update "$IAU_EE" && echo on || echo off ) )"
assert_false "and an opt-out behind a failing line is still an opt-out"     installed_auto_update "$IAU_EE"

# AUTO_UPDATE_SOMETHING=0 must not read as AUTO_UPDATE=0.
printf 'AUTO_UPDATE_NOTES=0\n' > "$IAU_ENV"
assert_true  "a longer key that starts the same is not this one" installed_auto_update "$IAU_ENV"

describe "AUTO_UPDATE — both readers must agree on every shape of the value"

# Three readers and one key. load_env sources the file, so the shell decides
# what the value is, and that is what status.sh, audit.sh and reconfigure.sh
# report. installed_auto_update sources the same file in a subshell, and that is
# what setup.sh and the rc.local boot hook act on. write_env_file is the third,
# below. A value they read differently is the
# worst failure this feature has: every readout says the update is off while the
# cron goes back at each boot and runs it.
#
# Asserted as agreement across a table rather than as regex text, so the shapes
# are what is pinned, not the expression that happens to handle them today.
AUV_ENV="$TMPDIR/agree.env"
auv_shell_says() {   # what load_env's sourcing yields, as on/off
    (
        AUTO_UPDATE=
        # shellcheck source=/dev/null
        . "$1"
        [ "${AUTO_UPDATE:-1}" = "0" ] && echo off || echo on
    )
}
auv_sed_says() {     # what setup.sh and the boot hook act on
    installed_auto_update "$1" && echo on || echo off
}
auv_agree() {
    printf 'RESOLVER_ID=abc123\nAUTO_UPDATE=%s\nDNS_PORT=5354\n' "$1" > "$AUV_ENV"
    [ "$(auv_shell_says "$AUV_ENV")" = "$(auv_sed_says "$AUV_ENV")" ]
}

# Written by set_auto_update_flag.
assert_true "a bare 0 agrees"   auv_agree '0'
assert_true "a bare 1 agrees"   auv_agree '1'
# Quoted is a shape write_env_file carries forward untouched and load_env
# strips, so it reaches both readers and has to mean the same to each.
assert_true "a quoted 0 agrees" auv_agree '"0"'
assert_true "a quoted 1 agrees" auv_agree '"1"'
# Anything hand-edited. None of these is meaningful; what matters is that the
# readers reach the same conclusion rather than splitting.
assert_true "a leading-zero value agrees" auv_agree '01'
assert_true "a doubled zero agrees"       auv_agree '00'
assert_true "trailing whitespace agrees"  auv_agree '0 '
assert_true "an empty value agrees"       auv_agree ''
assert_true "a word agrees"               auv_agree 'maybe'
assert_true "a 0 with a comment after it agrees" auv_agree '0 # off'
assert_true "a hash with no space before it agrees"  auv_agree '0#off'
assert_true "a single-quoted 0 agrees"               auv_agree "'0'"
assert_true "a 0 with a tab after it agrees"         auv_agree '0	'
assert_true "a negative zero agrees"                 auv_agree '-0'
assert_true "an all-caps word agrees"                auv_agree 'OFF'
assert_true "the string false agrees"                auv_agree 'false'
assert_true "a 2 agrees"                             auv_agree '2'

# write_env_file does not read this key. It carries the line when its filter
# accepts the value and drops it otherwise, exactly as it treats DNS_PORT and
# every other unmanaged key, so the shell stays the only thing deciding what
# the line means.
#
# That is the whole contract, and it is two claims rather than a list of
# shapes: the forms anyone actually writes survive a rewrite, and a rewrite
# never turns an install that was updating into one that is not.
#
# It was 46 lines of shell-quoting emulation so that four exotic hand-edits
# also survived. Those 46 lines twice concluded "off" from a file every reader
# called "on", which silently stops a router patching the binary answering its
# DNS. Losing an exotic hand-edit is recoverable and the readouts show it;
# inventing an opt-out is neither.
auv_survives_rewrite() {
    printf 'RESOLVER_ID=abc123\n%s\nDNS_PORT=5354\n' "$1" > "$AUV_ENV"
    _b="$(auv_shell_says "$AUV_ENV")"
    ( RESOLVER_ID=abc123; BOOTSTRAP_IP=1.2.3.4; CTRLD_VERSION=1.5.7
      DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3
      write_env_file "$AUV_ENV" ) 2>/dev/null
    [ "$_b" = "$(auv_shell_says "$AUV_ENV")" ]
}
assert_true "the form the toggle writes survives a rewrite" \
    auv_survives_rewrite 'AUTO_UPDATE=0'
assert_true "and the quoted form a hand-edit produces" \
    auv_survives_rewrite 'AUTO_UPDATE="0"'
assert_true "an install that never opted out stays that way" \
    auv_survives_rewrite 'AUTO_UPDATE=1'
assert_true "and one carrying no key at all" \
    auv_survives_rewrite 'DNS_TYPE=doh3'
assert_true "a repeated key takes the last assignment" \
    auv_survives_rewrite 'AUTO_UPDATE=1
AUTO_UPDATE=0'

# And the direction is not arbitrary: everything unparseable has to land on on,
# because a router that silently stops patching itself is the worse failure.
printf 'AUTO_UPDATE=maybe\n' > "$AUV_ENV"
assert_eq "an unparseable value means on, not off" "on" "$(auv_sed_says "$AUV_ENV")"

describe "controld-update.sh — the flag stops an update the cron did not"

# An outcome test on the generated script, run the way the watchdog's is: the
# updater is heredoc text inside setup.sh, so nothing here would otherwise
# execute it. The backstop exists for a cron neither installer put there, so
# the test starts the script exactly as crond would and asserts it reaches the
# network not at all.
CU_CFG="$TMPDIR/cu-cfg"; CU_BIN="$TMPDIR/cu-bin"; CU_LOG="$TMPDIR/cu.log"
mkdir -p "$CU_CFG" "$CU_BIN"
export CU_LOG

# "|| true" on every run below: the suite runs under set -e (line 6), and this
# script exits non-zero by design on a rejected argument and on a failed
# download. Without it the file dies mid-way and prints no summary, which reads
# as a pass to anything scanning for the word FAIL. Found exactly that way.
CUGEN="$TMPDIR/controld-update-generated.sh"
sed -n "/^cat > \/cfg\/controld-update.sh << 'UPDATESCRIPT'/,/^UPDATESCRIPT$/p" "$SCRIPT_DIR/setup.sh" \
    | sed '1d;$d' \
    | sed -e "s|/cfg/|${CU_CFG}/|g" > "$CUGEN"

assert_true "the generated updater is valid sh" sh -n "$CUGEN"

printf '#!/bin/sh\necho "logger $*" >> "$CU_LOG"\n' > "$CU_BIN/logger"
# wget is the first thing an update reaches for. If it runs, the flag failed.
printf '#!/bin/sh\necho "wget $*" >> "$CU_LOG"\nexit 1\n' > "$CU_BIN/wget"
chmod +x "$CU_BIN/logger" "$CU_BIN/wget"

cat > "$CU_CFG/controld.env" << 'CUENVOFF'
RESOLVER_ID=abc123
CTRLD_VERSION=1.5.7
AUTO_UPDATE=0
CUENVOFF
: > "$CU_LOG"
( PATH="$CU_BIN:$PATH"; sh "$CUGEN" ) >/dev/null 2>&1 || true
CU_OFF="$(cat "$CU_LOG" 2>/dev/null)"
assert_contains     "it says why it did nothing" "$CU_OFF" "auto-update is off"
assert_not_contains "and never reaches the network" "$CU_OFF" "wget"

# The updater carries its own copy of the reader, so it drifts independently.
# A quoted opt-out must stop it too.
cat > "$CU_CFG/controld.env" << 'CUENVQ'
RESOLVER_ID=abc123
CTRLD_VERSION=1.5.7
AUTO_UPDATE="0"
CUENVQ
: > "$CU_LOG"
( PATH="$CU_BIN:$PATH"; sh "$CUGEN" ) >/dev/null 2>&1 || true
CU_Q="$(cat "$CU_LOG" 2>/dev/null)"
assert_contains     "a quoted opt-out stops the updater"  "$CU_Q" "auto-update is off"
assert_not_contains "and it still reaches no network"     "$CU_Q" "wget"

# --now has to answer the person who ran it. Reporting only to syslog it
# printed nothing at all, whether it updated, was already current, or could not
# reach the network, and exited 0 either way: the user cannot tell those apart,
# and this firmware's logread has no buffer to consult.
CU_SPEAK="$( ( PATH="$CU_BIN:$PATH"; sh "$CUGEN" --now ) 2>&1 || true )"
assert_contains "--now says what happened on stdout" "$CU_SPEAK" "could not determine latest release"
# From cron it stays quiet, which is what it has always done.
CU_QUIET="$( ( PATH="$CU_BIN:$PATH"; sh "$CUGEN" ) 2>&1 || true )"
assert_eq "and says nothing when run without arguments" "" "$CU_QUIET"

# --now is how a person updates after opting out, and without it the opt-out
# meant "never update": both the README and reconfigure.sh told the user to run
# this script, and it declined. The backstop still has to hold for the cron,
# which passes no arguments, so the two cases are asserted against each other.
cat > "$CU_CFG/controld.env" << 'CUENVNOW'
RESOLVER_ID=abc123
CTRLD_VERSION=1.5.7
AUTO_UPDATE=0
CUENVNOW
: > "$CU_LOG"
( PATH="$CU_BIN:$PATH"; sh "$CUGEN" --now ) >/dev/null 2>&1 || true
CU_NOW="$(cat "$CU_LOG" 2>/dev/null)"
assert_contains     "--now updates despite the opt-out"  "$CU_NOW" "wget"
assert_not_contains "and does not report itself as off"  "$CU_NOW" "auto-update is off"

# An argument nobody meant must not be taken as --now. Silently updating on a
# typo is the opposite of what the flag is for.
: > "$CU_LOG"
( PATH="$CU_BIN:$PATH"; sh "$CUGEN" --nowish ) >/dev/null 2>&1 || true
assert_not_contains "an unknown argument does not reach the network" \
    "$(cat "$CU_LOG" 2>/dev/null)" "wget"

# The same script with the flag absent must still try, or the test above would
# pass on a script that does nothing at all.
cat > "$CU_CFG/controld.env" << 'CUENVON'
RESOLVER_ID=abc123
CTRLD_VERSION=1.5.7
CUENVON
: > "$CU_LOG"
( PATH="$CU_BIN:$PATH"; sh "$CUGEN" ) >/dev/null 2>&1 || true
CU_ON="$(cat "$CU_LOG" 2>/dev/null)"
assert_contains     "with the flag absent it goes looking for a release" "$CU_ON" "wget"
assert_not_contains "and says nothing about being off" "$CU_ON" "auto-update is off"

# Already current is what --now finds most of the time, and it used to exit 0
# with nothing on stdout, which is indistinguishable from a script that never
# ran. On hardware this took reading the source to settle, because every other
# path under --now either prints or exits non-zero. The stub answers on one
# line, which is how the GitHub API really replies and what the greedy match in
# the tag_name extraction has to survive.
cat > "$CU_BIN/wget" << 'CUWGETCUR'
#!/bin/sh
echo "wget $*" >> "$CU_LOG"
printf '%s\n' '{"url":"https://example/1","tag_name":"v1.5.7","name":"Release v1.5.7"}'
CUWGETCUR
chmod +x "$CU_BIN/wget"

cat > "$CU_CFG/controld.env" << 'CUENVCUR'
RESOLVER_ID=abc123
CTRLD_VERSION=1.5.7
AUTO_UPDATE=0
CUENVCUR
: > "$CU_LOG"
CU_CUR="$( ( PATH="$CU_BIN:$PATH"; sh "$CUGEN" --now ) 2>&1 || true )"
assert_contains     "--now says it is already current"  "$CU_CUR" "already on v1.5.7"
assert_not_contains "and downloads nothing to say it"   "$(cat "$CU_LOG" 2>/dev/null)" "tar.gz"

# The other half, or the line above could be bought by making the weekly job
# log once a week that it had nothing to do.
cat > "$CU_CFG/controld.env" << 'CUENVCURCRON'
RESOLVER_ID=abc123
CTRLD_VERSION=1.5.7
CUENVCURCRON
: > "$CU_LOG"
CU_CUR_CRON="$( ( PATH="$CU_BIN:$PATH"; sh "$CUGEN" ) 2>&1 || true )"
assert_eq           "the weekly run stays silent when current" "" "$CU_CUR_CRON"
assert_not_contains "and logs nothing about it either" \
    "$(cat "$CU_LOG" 2>/dev/null)" "already on"

describe "rc.local — a reboot must not hand back a cron that was turned off"

# The reinstall at boot is why deleting the cron was never an off switch: /etc
# does not survive a firmware update, so the hook puts both jobs back. Run the
# generated hook for real against stubs and read the crontab it leaves behind.
RCC_CFG="$TMPDIR/rcc-cfg"; RCC_BIN="$TMPDIR/rcc-bin"; RCC_TAB="$TMPDIR/rcc.crontab"
mkdir -p "$RCC_CFG" "$RCC_BIN"
export RCC_TAB

# A crontab stub that is a crontab: -l lists, - installs from stdin. Asserting
# on the file it leaves is what makes this an outcome test rather than a check
# that some particular command was spelled a particular way.
cat > "$RCC_BIN/crontab" << 'RCCTABEOF'
#!/bin/sh
case "$1" in
    -l) cat "$RCC_TAB" 2>/dev/null ;;
    # Written aside and moved into place, because the real thing is atomic and
    # a truncating stub is not. `(crontab -l; echo job) | crontab -` runs both
    # halves concurrently, so a stub that opened the file for writing emptied
    # it while the left half was still reading, and the job already installed
    # vanished depending on which side won.
    -)  cat > "${RCC_TAB}.new" && mv "${RCC_TAB}.new" "$RCC_TAB" ;;
esac
RCCTABEOF
printf '#!/bin/sh\nexit 0\n' > "$RCC_BIN/pidof"
printf '#!/bin/sh\nexit 0\n' > "$RCC_BIN/logger"
# The hook sleeps 10 before its firewall block. Nothing here is timing, and a
# test that waits for it would be ten seconds slower for no assertion.
printf '#!/bin/sh\nexit 0\n' > "$RCC_BIN/sleep"
chmod +x "$RCC_BIN/crontab" "$RCC_BIN/pidof" "$RCC_BIN/logger" "$RCC_BIN/sleep"

# The hook backgrounds every block so the router's boot script continues, which
# means the parent exits before they finish. `wait` is appended here, not in
# setup.sh: blocking is exactly what the real hook must never do.
# "|| true" on every run of it below, for the reason the updater's fixture
# gives: this suite runs under set -e, and a generated script that exits
# non-zero would take the whole file with it and print no summary.
RCCGEN="$TMPDIR/rc-cron-generated.sh"
sed -e "s|/cfg/|${RCC_CFG}/|g" "$RCGEN" > "$RCCGEN"
printf 'wait\n' >> "$RCCGEN"

# Flag off, crontab empty: the boot must leave it empty.
printf 'RESOLVER_ID=abc123\nAUTO_UPDATE=0\n' > "$RCC_CFG/controld.env"
: > "$RCC_TAB"
( PATH="$RCC_BIN:$PATH"; sh "$RCCGEN" ) >/dev/null 2>&1 || true
assert_not_contains "a reboot does not put the update cron back" \
    "$(cat "$RCC_TAB" 2>/dev/null)" "controld-update.sh"
# The watchdog is not part of the opt-out. Turning off auto-update must not
# switch off the health check that reconciles the protocol and restores the
# redirects.
assert_contains "and the watchdog is reinstalled regardless" \
    "$(cat "$RCC_TAB" 2>/dev/null)" "watchdog.sh"

# A cron that outlived the opt-out is taken out at boot, not merely left in
# place. Nothing else removes it between re-installs, so it used to sit there
# forever and audit.sh reported it at every run with no way to clear it.
printf 'RESOLVER_ID=abc123\nAUTO_UPDATE=0\n' > "$RCC_CFG/controld.env"
printf '*/5 * * * * %s/watchdog.sh\n0 3 * * 1 %s/controld-update.sh\n' \
    "$RCC_CFG" "$RCC_CFG" > "$RCC_TAB"
( PATH="$RCC_BIN:$PATH"; sh "$RCCGEN" ) >/dev/null 2>&1 || true
assert_not_contains "a boot removes an update cron that outlived the opt-out" \
    "$(cat "$RCC_TAB" 2>/dev/null)" "controld-update.sh"
assert_contains "and still leaves the watchdog cron alone" \
    "$(cat "$RCC_TAB" 2>/dev/null)" "watchdog.sh"

# A shape the canonical one does not cover. The hook's reader is an inline copy
# of installed_auto_update, so it is the one that can silently drift back to
# matching the line: reverting it to grep -q '^AUTO_UPDATE=0$' left every other
# assertion here green, because the fixture only ever wrote the bare 0 that
# set_auto_update_flag happens to produce.
printf 'RESOLVER_ID=abc123\nAUTO_UPDATE="0"\n' > "$RCC_CFG/controld.env"
: > "$RCC_TAB"
( PATH="$RCC_BIN:$PATH"; sh "$RCCGEN" ) >/dev/null 2>&1 || true
assert_not_contains "a quoted opt-out is honoured at boot too" \
    "$(cat "$RCC_TAB" 2>/dev/null)" "controld-update.sh"

# The hook reads the flag by comparing the value the subshell prints, not by
# testing the subshell's exit status. Those are not the same: a file that exits
# before the test is reached gives status 0, which the shorter form read as an
# opt-out and then never reinstalled the cron, with no AUTO_UPDATE line in the
# file at all. Nothing in this project writes `exit` into controld.env, but the
# hook must not be one `exit 0` away from silently disabling itself.
printf 'RESOLVER_ID=abc123\nexit 0\n' > "$RCC_CFG/controld.env"
: > "$RCC_TAB"
( PATH="$RCC_BIN:$PATH"; sh "$RCCGEN" ) >/dev/null 2>&1 || true
assert_contains "an env file that exits early is not read as an opt-out" \
    "$(cat "$RCC_TAB" 2>/dev/null)" "controld-update.sh"

# An AUTO_UPDATE in the hook's own environment must not beat the file it is
# supposed to be reading, which is what the reset in front of the dot is for.
printf 'RESOLVER_ID=abc123\n' > "$RCC_CFG/controld.env"
: > "$RCC_TAB"
( PATH="$RCC_BIN:$PATH"; AUTO_UPDATE=0; export AUTO_UPDATE; sh "$RCCGEN" ) >/dev/null 2>&1 || true
assert_contains "an inherited AUTO_UPDATE does not override the file" \
    "$(cat "$RCC_TAB" 2>/dev/null)" "controld-update.sh"

# Flag absent, crontab empty: both jobs come back, which is the behaviour this
# hook has always had and the reason the assertion above is worth anything.
printf 'RESOLVER_ID=abc123\n' > "$RCC_CFG/controld.env"
: > "$RCC_TAB"
( PATH="$RCC_BIN:$PATH"; sh "$RCCGEN" ) >/dev/null 2>&1 || true
assert_contains "with the flag absent the update cron is restored" \
    "$(cat "$RCC_TAB" 2>/dev/null)" "controld-update.sh"

describe "set_auto_update_flag() — the writer and the reader must agree"

# Round-tripped through installed_auto_update rather than asserted as text.
# The two carry the same key by different routes, a grep and a sed here, a
# subshell source in setup.sh's boot hook, and a disagreement between them is
# exactly the failure that would leave someone's opt-out silently ignored.
SAU_ENV="$TMPDIR/sau.env"
printf 'RESOLVER_ID=abc123\nDNS_PORT=5354\n' > "$SAU_ENV"

set_auto_update_flag 0 "$SAU_ENV"
assert_false "off is written and reads back as off" installed_auto_update "$SAU_ENV"
assert_eq    "the key is appended once" "1" "$(grep -c '^AUTO_UPDATE=' "$SAU_ENV")"

set_auto_update_flag 1 "$SAU_ENV"
assert_true  "on is written and reads back as on"   installed_auto_update "$SAU_ENV"
assert_eq    "and replaced in place, not appended again" "1" \
    "$(grep -c '^AUTO_UPDATE=' "$SAU_ENV")"

# On is recorded rather than the line being removed, so "left at the default"
# and "switched off and back on" stay distinguishable.
assert_contains "turning it back on records the choice" \
    "$(cat "$SAU_ENV")" "AUTO_UPDATE=1"

# A file whose last line has no trailing newline must not have the key joined
# onto it. That reads as an update still enabled while reconfigure.sh has just
# printed that it is off, and it corrupts whatever setting was last in the file:
# FORCED_DNS=1AUTO_UPDATE=0 stops ensure_forced_dns restoring the port-853
# hijack while every readout still calls forced DNS on.
SAU_NN="$TMPDIR/sau-nonewline.env"
printf 'RESOLVER_ID=abc123\nFORCED_DNS=1' > "$SAU_NN"
set_auto_update_flag 0 "$SAU_NN"
assert_false "a file with no trailing newline still reads as opted out" \
    installed_auto_update "$SAU_NN"
assert_contains "and the line before it is intact" "$(cat "$SAU_NN")" "FORCED_DNS=1
AUTO_UPDATE=0"

# Nothing else in the file may be disturbed. This is sed -i on a config other
# scripts source; losing DNS_PORT here is the outage described in
# write_env_file's comment.
assert_contains "other keys survive the rewrite" "$(cat "$SAU_ENV")" "DNS_PORT=5354"
assert_contains "and so does the resolver" "$(cat "$SAU_ENV")" "RESOLVER_ID=abc123"

# Round-tripped through write_env_file, which every reconfigure.sh action and
# every re-install calls. This replaced a grep asserting AUTO_UPDATE was absent
# from WEF_MANAGED, which was a statement about the implementation and missed
# the bug entirely: the keep filter accepted a narrower set of values than the
# readers honour, so three shapes this suite blesses as off were read as off
# everywhere and then silently deleted by the first rewrite.
wef_survives() {
    printf 'RESOLVER_ID=abc123\nAUTO_UPDATE=%s\nDNS_PORT=5354\n' "$1" > "$AUV_ENV"
    ( RESOLVER_ID=abc123; BOOTSTRAP_IP=1.2.3.4; CTRLD_VERSION=1.5.7
      DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3
      write_env_file "$AUV_ENV" )
    installed_auto_update "$AUV_ENV" && return 1
    return 0
}
# write_env_file must reach its decision without sourcing. It runs on a file
# that has not been filtered yet, so a dangerous value in the very key it is
# reading is the case that matters: reusing installed_auto_update here sourced
# the file and fired the payload the sibling filter tests plant.
WEF_EXEC="$TMPDIR/wef-exec.env"
printf 'RESOLVER_ID=abc123\nAUTO_UPDATE="$(touch %s/auto-pwned)"\n' "$TMPDIR" > "$WEF_EXEC"
( RESOLVER_ID=abc123; BOOTSTRAP_IP=1.2.3.4; CTRLD_VERSION=1.5.7
  DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3
  write_env_file "$WEF_EXEC" ) 2>/dev/null
assert_false "reading the flag does not execute it" test -e "$TMPDIR/auto-pwned"
assert_false "and a dangerous value is not carried forward" \
    grep -q 'touch' "$WEF_EXEC"

assert_true "a bare 0 survives a config rewrite"        wef_survives '0'
assert_true "a quoted 0 survives"                       wef_survives '"0"'

# Carried verbatim, not re-encoded. The line is written by
# set_auto_update_flag and read by the shell; nothing in between re-derives
# what it means, which is why no shape can be read two ways.
assert_eq "the rewrite leaves exactly one AUTO_UPDATE line" "1" \
    "$(grep -c 'AUTO_UPDATE=' "$AUV_ENV")"

# An explicitly recorded 1 must survive too. set_auto_update_flag writes it
# deliberately so that "left at the default" and "switched off and back on
# again" stay distinguishable, and the first version of the carry above only
# re-emitted the 0, quietly undoing that at the next rewrite.
printf 'RESOLVER_ID=abc123\nAUTO_UPDATE=1\nDNS_PORT=5354\n' > "$AUV_ENV"
( RESOLVER_ID=abc123; BOOTSTRAP_IP=1.2.3.4; CTRLD_VERSION=1.5.7
  DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3
  write_env_file "$AUV_ENV" ) 2>/dev/null
assert_contains "an explicitly recorded 1 survives a rewrite" \
    "$(cat "$AUV_ENV")" "AUTO_UPDATE=1"

# Turning it off again, over a line that already exists. Until this ran, the
# sed branch had only ever been asked to write a 1: hardcoding the replacement
# to 1 meant anyone who had ever toggled the flag could no longer turn the
# update off, while reconfigure.sh printed that they had.
set_auto_update_flag 0 "$AUV_ENV"
assert_false "off can be written over an existing line" installed_auto_update "$AUV_ENV"
assert_eq "still exactly one line" "1" "$(grep -c '^AUTO_UPDATE=' "$AUV_ENV")"

# A longer key that starts the same must not satisfy the "already present"
# test, or the write becomes a silent no-op on a file carrying one.
SAU_NEAR="$TMPDIR/sau-near.env"
printf 'RESOLVER_ID=abc123\nAUTO_UPDATE_NOTES=off since March\n' > "$SAU_NEAR"
set_auto_update_flag 0 "$SAU_NEAR"
assert_false "a file carrying AUTO_UPDATE_NOTES still takes the flag" \
    installed_auto_update "$SAU_NEAR"
assert_contains "and the neighbouring key is untouched" \
    "$(cat "$SAU_NEAR")" "AUTO_UPDATE_NOTES=off since March"

# On is the default, so a rewrite must not start writing a key to the file of a
# router that never opted out.
printf 'RESOLVER_ID=abc123\nDNS_PORT=5354\n' > "$AUV_ENV"
( RESOLVER_ID=abc123; BOOTSTRAP_IP=1.2.3.4; CTRLD_VERSION=1.5.7
  DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3
  write_env_file "$AUV_ENV" )
assert_eq "an install that never opted out gains no AUTO_UPDATE line" "0" \
    "$(grep -c '^AUTO_UPDATE=' "$AUV_ENV")"
assert_contains "and unmanaged keys are still carried" "$(cat "$AUV_ENV")" "DNS_PORT=5354"

describe "reconfigure.sh --auto-update — run for real against stubs"

# do_auto_update was covered only by greps over its source, so deleting the
# option from the parser, deleting its dispatch case, deleting its menu entry,
# or making the off branch write a 1 all left the suite green. Run the script
# the way a router does instead: rewrite its /cfg paths into a sandbox, put a
# real controld.env and lib.sh there, and read the crontab and the env file it
# leaves behind.
RA_CFG="$TMPDIR/ra-cfg"; RA_BIN="$TMPDIR/ra-bin"; RA_TAB="$TMPDIR/ra.crontab"
mkdir -p "$RA_CFG" "$RA_BIN"
export RA_TAB

sed -e "s|/cfg/|${RA_CFG}/|g" "$SCRIPT_DIR/reconfigure.sh" > "$RA_CFG/reconfigure.sh"
sed -e "s|/cfg/|${RA_CFG}/|g" "$SCRIPT_DIR/lib.sh"         > "$RA_CFG/lib.sh"
chmod +x "$RA_CFG/reconfigure.sh"

cat > "$RA_BIN/crontab" << 'RATABEOF'
#!/bin/sh
case "$1" in
    -l) cat "$RA_TAB" 2>/dev/null ;;
    -)  cat > "${RA_TAB}.new" && mv "${RA_TAB}.new" "$RA_TAB" ;;
esac
RATABEOF
printf '#!/bin/sh
exit 1
' > "$RA_BIN/pidof"
printf '#!/bin/sh
exit 1
' > "$RA_BIN/uci"
chmod +x "$RA_BIN/crontab" "$RA_BIN/pidof" "$RA_BIN/uci"

# "|| true": the suite runs under set -e (line 6), so a run that exits non-zero
# would abort the whole file inside the command substitution below and the
# summary would never print. The assertions read the crontab and the env file,
# so a failed run shows up as a wrong outcome rather than a vanished suite.
ra_run() { ( PATH="$RA_BIN:$PATH"; sh "$RA_CFG/reconfigure.sh" --auto-update --force ) 2>&1 || true; }

cat > "$RA_CFG/controld.env" << 'RAENVEOF'
RESOLVER_ID=abc123
BOOTSTRAP_IP=76.76.2.22
CTRLD_VERSION=1.5.7
DNS_TYPE=doh3
PREFERRED_PROTOCOL=doh3
FORCED_DNS=0
DNS_PORT=5354
RAENVEOF
printf '0 3 * * 1 %s/controld-update.sh
*/5 * * * * %s/watchdog.sh
' "$RA_CFG" "$RA_CFG" > "$RA_TAB"

RA_OFF="$(ra_run)"
assert_not_contains "turning it off removes the update cron" \
    "$(cat "$RA_TAB" 2>/dev/null)" "controld-update.sh"
assert_contains "and leaves the watchdog cron alone" \
    "$(cat "$RA_TAB" 2>/dev/null)" "watchdog.sh"
assert_false "and the file records the opt-out" installed_auto_update "$RA_CFG/controld.env"
assert_contains "and it says so" "$RA_OFF" "Weekly auto-update off"

# --show must agree with status.sh about the weekly update. Read from the flag
# alone it printed "on (Mondays 03:00)" on a router whose cron was missing,
# including right after setup.sh reported it could not install one, so two
# readouts contradicted each other in the same minute.
ra_show() { ( PATH="$RA_BIN:$PATH"; sh "$RA_CFG/reconfigure.sh" --show ) 2>&1 || true; }
sed -i 's/^AUTO_UPDATE=.*/AUTO_UPDATE=1/' "$RA_CFG/controld.env"
printf '*/5 * * * * %s/watchdog.sh\n0 3 * * 1 %s/controld-update.sh\n' \
    "$RA_CFG" "$RA_CFG" > "$RA_TAB"
assert_contains "--show reports the update on when its cron is there" \
    "$(ra_show)" "on (Mondays 03:00)"
printf '*/5 * * * * %s/watchdog.sh\n' "$RA_CFG" > "$RA_TAB"
RA_SHOW_GONE="$(ra_show)"
assert_contains "and says so when the cron is missing" \
    "$RA_SHOW_GONE" "cron job is missing"
assert_not_contains "rather than claiming it runs on Mondays" \
    "$RA_SHOW_GONE" "on (Mondays 03:00)"
sed -i 's/^AUTO_UPDATE=.*/AUTO_UPDATE=0/' "$RA_CFG/controld.env"
assert_contains "and an opt-out reads as off whatever the crontab says" \
    "$(ra_show)" "off"

# An older /cfg/lib.sh that predates the writer. reconfigure.sh is documented
# as runnable on its own with a /cfg/lib.sh fallback, so this is reachable:
# unguarded it printed the whole prompt and then died with
# "set_auto_update_flag: not found" at the moment of writing.
RA_OLD_CFG="$TMPDIR/ra-old"; mkdir -p "$RA_OLD_CFG"
sed -e "s|/cfg/|${RA_OLD_CFG}/|g" "$SCRIPT_DIR/reconfigure.sh" > "$RA_OLD_CFG/reconfigure.sh"
sed -e "s|/cfg/|${RA_OLD_CFG}/|g" "$SCRIPT_DIR/lib.sh" \
    | sed '/^set_auto_update_flag() {$/,/^}$/d' > "$RA_OLD_CFG/lib.sh"
assert_false "the stale library really lacks the writer" \
    grep -q '^set_auto_update_flag()' "$RA_OLD_CFG/lib.sh"
cp "$RA_CFG/controld.env" "$RA_OLD_CFG/controld.env"
RA_OLDOUT="$( ( PATH="$RA_BIN:$PATH"; sh "$RA_OLD_CFG/reconfigure.sh" --auto-update --force ) 2>&1 || true )"
# Matched on the half of the message the sandbox's own /cfg rewrite leaves
# alone. Keying on the path itself passed nothing through: the fixture rewrites
# /cfg into the sandbox, so the printed path is not the one a router shows.
assert_contains "an older lib.sh is reported, not hit mid-write" \
    "$RA_OLDOUT" "Re-run setup.sh to update it"
assert_not_contains "and the shell error never reaches the user" \
    "$RA_OLDOUT" "not found"

# Back on. The same command both ways, so a branch that wrote the wrong value
# or never ran at all shows up here rather than in a grep over the source.
RA_ON="$(ra_run)"
assert_contains "turning it back on restores the update cron" \
    "$(cat "$RA_TAB" 2>/dev/null)" "controld-update.sh"
assert_true "and the file records on" installed_auto_update "$RA_CFG/controld.env"
assert_contains "and it says so" "$RA_ON" "Weekly auto-update on"

# Off again, over a line that already exists, which is the sed branch of
# set_auto_update_flag rather than the append branch.
ra_run >/dev/null 2>&1
assert_false "a second opt-out writes over the existing line" \
    installed_auto_update "$RA_CFG/controld.env"
assert_eq "and leaves exactly one line" "1" \
    "$(grep -c '^AUTO_UPDATE=' "$RA_CFG/controld.env")"

# The menu route has to reach the same action, or entry 7 could be deleted
# with every assertion above still passing.
printf '0 3 * * 1 %s/controld-update.sh
*/5 * * * * %s/watchdog.sh
' "$RA_CFG" "$RA_CFG" > "$RA_TAB"
sed -i 's/^AUTO_UPDATE=.*/AUTO_UPDATE=1/' "$RA_CFG/controld.env"
( PATH="$RA_BIN:$PATH"; printf '7\ny\n' | sh "$RA_CFG/reconfigure.sh" ) >/dev/null 2>&1 || true
assert_false "menu entry 7 reaches the same action" \
    installed_auto_update "$RA_CFG/controld.env"

# --to on|off names the state wanted instead of flipping whatever is set, so a
# script or agent can run it twice and get the same result. No --force and no
# input: --to alone must be enough to act without a prompt.
ra_to() { ( PATH="$RA_BIN:$PATH"; sh "$RA_CFG/reconfigure.sh" "$@" ) 2>&1 </dev/null || true; }
printf '*/5 * * * * %s/watchdog.sh\n' "$RA_CFG" > "$RA_TAB"
RA_TO="$(ra_to --auto-update --to off)"
assert_contains "--to off when it is already off changes nothing" "$RA_TO" \
    "Weekly auto-update is already off"
assert_false "and leaves it off" installed_auto_update "$RA_CFG/controld.env"
RA_TO="$(ra_to --auto-update --to on)"
assert_true "--to on turns it on without a prompt" installed_auto_update "$RA_CFG/controld.env"
assert_contains "and installs the cron" "$(cat "$RA_TAB" 2>/dev/null)" "controld-update.sh"
RA_TO="$(ra_to --auto-update --to on)"
assert_contains "running it again changes nothing" "$RA_TO" "Weekly auto-update is already on"
assert_eq "and adds no second cron line" "1" \
    "$(grep -c 'controld-update.sh' "$RA_TAB")"
RA_TO="$(ra_to --auto-update --to off)"
assert_false "--to off turns it off without a prompt" installed_auto_update "$RA_CFG/controld.env"
assert_contains "and it says so" "$RA_TO" "Weekly auto-update off"
RA_TO="$(ra_to --auto-update --to maybe)"
assert_contains "anything but on or off is refused" "$RA_TO" "--to takes on or off here"
assert_false "without changing anything" installed_auto_update "$RA_CFG/controld.env"

# Forced DNS. Only the paths that end before iptables and uci are touched run
# here: the change itself is the same branch --force already takes.
sed -i 's/^FORCED_DNS=.*/FORCED_DNS=1/' "$RA_CFG/controld.env"
RA_TO="$(ra_to --force-dns --to on)"
assert_contains "--force-dns --to on when it is on changes nothing" "$RA_TO" \
    "Forced DNS is already on"
assert_not_contains "and asks nothing" "$RA_TO" "Disable forced DNS?"
RA_TO="$(ra_to --force-dns --to sideways)"
assert_contains "and a bad value is refused there too" "$RA_TO" "--to takes on or off here"
sed -i 's/^FORCED_DNS=.*/FORCED_DNS=0/' "$RA_CFG/controld.env"
RA_TO="$(ra_to --force-dns --to off)"
assert_contains "--force-dns --to off when it is off changes nothing" "$RA_TO" \
    "Forced DNS is already off"
unset RA_TO
unset -f ra_to

describe "reconfigure.sh --auto-update — the toggle moves the cron too"

# The flag governs the next boot and the next re-install, neither of which has
# happened when the command returns. Leaving the crontab alone would let the
# job run on Monday anyway, so the answer is not in force until the cron moves.
assert_true "turning it off takes the cron out now" \
    code_grep "$SCRIPT_DIR/reconfigure.sh" -E 'cron_remove /cfg/controld-update\.sh'
assert_true "and turning it on puts the cron back now" \
    code_grep "$SCRIPT_DIR/reconfigure.sh" -E "crontab - 2>/dev/null"

# --force has to reach it, or an unattended opt-out blocks on a prompt forever.
RCF_HELP="$(sh "$SCRIPT_DIR/reconfigure.sh" --help 2>&1 || true)"
assert_contains "the flag is documented in --help" "$RCF_HELP" "--auto-update"
# The Actions list is what a reader scans for what the tool can do, and it
# lacked the flag while the examples below it carried one.
assert_contains "and listed among its actions" \
    "$(printf '%s\n' "$RCF_HELP" | sed -n '/Actions:/,/Options:/p')" "--auto-update"

# An unknown option must still be an error: --auto-update is only wired up if
# the parser knows it, and a typo silently falling through to the menu is how
# a scripted opt-out would look like it worked.
RCF_BAD="$(sh "$SCRIPT_DIR/reconfigure.sh" --auto-updates 2>&1 || true)"
assert_contains "a near miss is rejected rather than ignored" "$RCF_BAD" "Unknown option"

describe "reconfigure.sh — a config that does not answer is rolled back"

# The redirects stay in place while reconfigure.sh restarts ctrld, so a new
# config that cannot resolve leaves the whole LAN without DNS. DoQ on a network
# that blocks port 853 is enough. Run the real script in a sandbox where the
# stub resolver answers on DoH3 and DoH but not DoQ, and not for a resolver ID
# or policy name marked bad, then check the two files it leaves behind.
RR_CFG="$TMPDIR/rr-cfg"; RR_BIN="$TMPDIR/rr-bin"
mkdir -p "$RR_CFG" "$RR_BIN"
export RR_CFG
# The check reconfigure.sh makes before a change runs a throwaway ctrld on the
# benchmark port with its own config. Keep that config in the sandbox, and put
# the suite's own value back once these tests are done.
RR_SAVED_BENCH_CONF="$BENCH_CONF"
BENCH_CONF="$RR_CFG/bench.toml"; export BENCH_CONF
sed -e "s|/cfg/|${RR_CFG}/|g" "$SCRIPT_DIR/reconfigure.sh" > "$RR_CFG/reconfigure.sh"
sed -e "s|/cfg/|${RR_CFG}/|g" "$SCRIPT_DIR/lib.sh"         > "$RR_CFG/lib.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$RR_CFG/ctrld.calls"\n' > "$RR_CFG/ctrld"
for _rr in pidof uci; do printf '#!/bin/sh\nexit 1\n' > "$RR_BIN/$_rr"; done
for _rr in sleep logger; do printf '#!/bin/sh\nexit 0\n' > "$RR_BIN/$_rr"; done
# Production always listens. The benchmark port is taken while the check's
# config exists, which is from the moment probe_resolver writes it to the
# moment it removes it.
cat > "$RR_BIN/netstat" << 'RRNETEOF'
#!/bin/sh
echo "udp 0 0 0.0.0.0:5354 0.0.0.0:* 1/ctrld"
[ -f "$BENCH_CONF" ] && echo "udp 0 0 127.0.0.1:5360 0.0.0.0:* 1/ctrld"
exit 0
RRNETEOF
# Production answers unless ctrld.toml carries DoQ, a bad resolver or a broken
# policy, which is what the rollback tests need. The check answers unless its
# config matches the ERE a test writes into bench.fail, so the rollback tests,
# which write none, pass the check and reach the rollback.
cat > "$RR_BIN/nslookup" << 'RRNSEOF'
#!/bin/sh
case "${2:-}" in
    *#5360)
        [ -f "$BENCH_CONF" ] || exit 1
        [ -f "$RR_CFG/bench.fail" ] && grep -qE "$(cat "$RR_CFG/bench.fail")" "$BENCH_CONF" && exit 1
        exit 0 ;;
esac
grep -qE 'type = "doq"|zzbad|ControlD-Broken' "$RR_CFG/ctrld.toml" && exit 1
exit 0
RRNSEOF
chmod +x "$RR_CFG/ctrld" "$RR_BIN"/*
unset _rr

rr_reset() {
    cat > "$RR_CFG/controld.env" << 'RRENVEOF'
RESOLVER_ID=abc123
BOOTSTRAP_IP=76.76.2.22
CTRLD_VERSION=1.5.7
DNS_TYPE=doh3
PREFERRED_PROTOCOL=doh3
DNS_PORT=5354
RRENVEOF
    ( DNS_PORT=5354; . "$RR_CFG/lib.sh"
      write_ctrld_config "$RR_CFG/ctrld.toml" abc123 76.76.2.22 doh3 )
    cp "$RR_CFG/ctrld.toml" "$RR_CFG/toml.before"
    cp "$RR_CFG/controld.env" "$RR_CFG/env.before"
    rm -f "$RR_CFG/ctrld.calls" "$RR_CFG/bench.fail"
}
# Exit status is printed as the last line, since the suite runs under set -e.
rr_run() {
    ( PATH="$RR_BIN:$PATH"; sh "$RR_CFG/reconfigure.sh" "$@"; echo "rc=$?" ) 2>&1 || true
}

rr_reset
RR_OUT="$(rr_run --protocol --to doq --force)"
assert_contains "a protocol that does not answer is reported" "$RR_OUT" "restoring the previous one"
assert_contains "and the previous config is restarted" "$RR_OUT" "Previous config restored"
assert_contains "and the run exits non-zero" "$RR_OUT" "rc=1"
assert_true "ctrld.toml is back to what it was" cmp -s "$RR_CFG/toml.before" "$RR_CFG/ctrld.toml"
assert_true "and so is controld.env" cmp -s "$RR_CFG/env.before" "$RR_CFG/controld.env"
assert_false "and no rollback copy is left behind" [ -f "$RR_CFG/ctrld.toml.bak" ]

rr_reset
RR_OUT="$(rr_run --resolver --to zzbad99 --force)"
assert_contains "a resolver ID that does not answer is rolled back too" "$RR_OUT" "rc=1"
assert_true "leaving the old resolver in controld.env" cmp -s "$RR_CFG/env.before" "$RR_CFG/controld.env"
assert_true "and in ctrld.toml" cmp -s "$RR_CFG/toml.before" "$RR_CFG/ctrld.toml"

rr_reset
RR_OUT="$( ( PATH="$RR_BIN:$PATH"; printf '2\naa:bb:cc:dd:ee:01\nxyz789\nBroken\ny\nq\n' \
    | sh "$RR_CFG/reconfigure.sh" --policy; echo "rc=$?" ) 2>&1 || true )"
assert_contains "a policy that does not answer is rolled back" "$RR_OUT" "Previous config restored"
assert_true "leaving ctrld.toml without the new upstream" cmp -s "$RR_CFG/toml.before" "$RR_CFG/ctrld.toml"
assert_false "and no rollback copy is left behind" [ -f "$RR_CFG/ctrld.toml.bak" ]

# A double quote in a policy name is refused before anything is written, so
# there is nothing to roll back and ctrld is not restarted at all.
rr_reset
RR_OUT="$( ( PATH="$RR_BIN:$PATH"; printf '2\naa:bb:cc:dd:ee:01\nxyz789\nKid "A"\nq\n' \
    | sh "$RR_CFG/reconfigure.sh" --policy ) 2>&1 || true )"
assert_contains "reconfigure.sh refuses a quote in a policy name" "$RR_OUT" "Policy name cannot contain"
assert_true "and leaves ctrld.toml as it was" cmp -s "$RR_CFG/toml.before" "$RR_CFG/ctrld.toml"
assert_false "without restarting ctrld" [ -f "$RR_CFG/ctrld.calls" ]

# The change that does answer still goes through, or the rollback would be
# hiding a switch that never happens.
rr_reset
RR_OUT="$(rr_run --protocol --to doh --force)"
assert_contains "a protocol that answers is applied" "$RR_OUT" "rc=0"
assert_contains "and recorded" "$(cat "$RR_CFG/controld.env")" "DNS_TYPE=doh"
assert_contains "and written" "$(cat "$RR_CFG/ctrld.toml")" 'type = "doh"'
assert_false "and its rollback copy is removed" [ -f "$RR_CFG/ctrld.toml.bak" ]

# The protocol menu has to offer every protocol its own Benchmark entry can
# choose. It listed three and benchmarked four, so "pick the fastest" could
# switch a router to DoT, a protocol the menu never showed.
rr_reset
RR_OUT="$( ( PATH="$RR_BIN:$PATH"; printf '4\n' | sh "$RR_CFG/reconfigure.sh" --protocol --force ) 2>&1 || true )"
# Only the numbered menu lines, with colour codes stripped. A benchmark run
# prints every protocol's label too, so the whole output would pass for a menu
# that sent choice 4 to the benchmark.
_rr_esc="$(printf '\033')"
RR_MENU="$(printf '%s\n' "$RR_OUT" | sed "s/${_rr_esc}\[[0-9;]*m//g" | grep -E '^[[:space:]]*[0-9]\)' || true)"
for _rr in doh3 doq doh dot; do
    assert_contains "the protocol menu offers $(proto_label "$_rr")" "$RR_MENU" "$(proto_label "$_rr")"
done
unset _rr _rr_esc RR_MENU
assert_contains "and choosing DoT from it switches to DoT" "$(cat "$RR_CFG/controld.env")" "DNS_TYPE=dot"
RR_OUT="$( ( PATH="$RR_BIN:$PATH"; printf '5\n' | sh "$RR_CFG/reconfigure.sh" --protocol --force ) 2>&1 || true )"
assert_contains "while the Benchmark entry still runs the benchmark" "$RR_OUT" "Benchmarking Protocols"

describe "reconfigure.sh — a change is checked before production is touched"

# The rollback above costs the LAN about 19 seconds of DNS, measured on a Route
# 10, because it finds a bad resolver or a blocked protocol by restarting
# production on it. Asking a throwaway ctrld on the benchmark port first finds
# the same thing with production still answering. "Production never restarted"
# is read from the stub ctrld's call log: production runs with ctrld.toml, the
# check with the benchmark config.
rr_prod_starts() { grep -c "run -c $RR_CFG/ctrld.toml" "$RR_CFG/ctrld.calls" 2>/dev/null || true; }

rr_reset
printf 'zzpre' > "$RR_CFG/bench.fail"
RR_OUT="$(rr_run --resolver --to zzpre11 --force)"
assert_contains "a resolver ID ControlD refuses is refused before the change" "$RR_OUT" \
    "ControlD did not answer for zzpre11"
assert_contains "with the exit status saying so" "$RR_OUT" "rc=1"
assert_not_contains "without reaching the rollback" "$RR_OUT" "restoring the previous one"
assert_eq "and without restarting production" "0" "$(rr_prod_starts)"
assert_true "leaving controld.env as it was" cmp -s "$RR_CFG/env.before" "$RR_CFG/controld.env"
assert_true "and ctrld.toml" cmp -s "$RR_CFG/toml.before" "$RR_CFG/ctrld.toml"
assert_false "and no throwaway config behind" [ -f "$BENCH_CONF" ]

rr_reset
printf 'type = "dot"' > "$RR_CFG/bench.fail"
RR_OUT="$(rr_run --protocol --to dot --force)"
assert_contains "a protocol the network blocks is refused before the switch" "$RR_OUT" \
    "ControlD did not answer over DoT (TLS)"
assert_contains "with the exit status saying so" "$RR_OUT" "rc=1"
assert_eq "and without restarting production" "0" "$(rr_prod_starts)"
assert_true "leaving the recorded protocol as it was" cmp -s "$RR_CFG/env.before" "$RR_CFG/controld.env"

rr_reset
printf 'zzpre' > "$RR_CFG/bench.fail"
RR_OUT="$( ( PATH="$RR_BIN:$PATH"; printf '2\naa:bb:cc:dd:ee:01\nzzpre22\nKids\nq\n' \
    | sh "$RR_CFG/reconfigure.sh" --policy; echo "rc=$?" ) 2>&1 || true )"
assert_contains "a policy resolver ControlD refuses is not added" "$RR_OUT" \
    "ControlD did not answer for zzpre22"
assert_true "leaving ctrld.toml as it was" cmp -s "$RR_CFG/toml.before" "$RR_CFG/ctrld.toml"
assert_eq "without restarting production" "0" "$(rr_prod_starts)"
assert_contains "and the menu carries on" "$RR_OUT" "rc=0"

# A change that answers still goes through, the check included.
rr_reset
RR_OUT="$(rr_run --resolver --to good5678 --force)"
assert_contains "a resolver ID that answers is still applied" "$(cat "$RR_CFG/controld.env")" \
    "RESOLVER_ID=good5678"
assert_contains "after the check says so" "$RR_OUT" "Checking that ControlD answers for good5678"
unset -f rr_prod_starts

# Unset first: that drops the export, so later sandboxes that rewrite lib.sh's
# default are not overridden from the environment.
unset BENCH_CONF
BENCH_CONF="$RR_SAVED_BENCH_CONF"
unset RR_SAVED_BENCH_CONF

describe "setup.sh — a re-install honours an opt-out made since the last one"

# Re-running setup.sh is this project's documented upgrade path, and
# CONTRIBUTING.md lists "a config flag reset on re-install" among the bugs that
# only ever appeared on hardware. The installer cannot run in this sandbox, so
# this is a source assertion: the unconditional install is gone and the
# cron_remove that clears a previously installed job is not inside the branch.
# Step 8 runs here, rather than being pattern-matched. The block is extracted
# between its own section headers, its /cfg paths are pointed at a sandbox, and
# it is executed against a stub crontab, the same way the generated watchdog
# and updater already are.
#
# What the greps this replaced could not see: leaving the gate exactly as
# written and adding the cron install to the else branch too, which hands the
# job back to everyone who opted out; and moving cron_remove below the closing
# fi, where every install deletes the cron it just created, for everyone.
# Both matched the old patterns and left the suite green.
S8_CFG="$TMPDIR/s8-cfg"; S8_BIN="$TMPDIR/s8-bin"; S8_TAB="$TMPDIR/s8.crontab"
mkdir -p "$S8_CFG" "$S8_BIN"
export S8_TAB

cat > "$S8_BIN/crontab" << 'S8TABEOF'
#!/bin/sh
case "$1" in
    -l) cat "$S8_TAB" 2>/dev/null ;;
    -)  cat > "${S8_TAB}.new" && mv "${S8_TAB}.new" "$S8_TAB" ;;
esac
S8TABEOF
chmod +x "$S8_BIN/crontab"
# Same reasoning as the reconfigure fixture: the rewrite bounds paths, not
# commands, and this one executes a block of the installer.
for _s8stub in pidof uci iptables ip nslookup logread netstat; do
    printf '#!/bin/sh\nexit 1\n' > "$S8_BIN/$_s8stub"; chmod +x "$S8_BIN/$_s8stub"
done

S8GEN="$TMPDIR/step8-generated.sh"
sed -n '/^# ── Step 8: Install cron job for weekly updates ──$/,/^# ── Step 9: Copy lib.sh to router for runtime use ──$/p'     "$SCRIPT_DIR/setup.sh" | sed '$d' | sed -e "s|/cfg/|${S8_CFG}/|g" > "$TMPDIR/step8-body.sh"

# Both headers are a sed range anchor now (AGENTS.md, "Prose"). Retitling
# either empties the range, and every assertion below would then pass while
# running nothing at all, so the range is checked before it is used.
# The rewrite is the isolation boundary, so assert it is complete rather than
# trusting it. A surviving /cfg path in any of these would read or write the
# real one, and on a router that is the live install, during the on-device run
# CONTRIBUTING.md prescribes.
for _isolated in "$TMPDIR/step8-body.sh" "$RA_CFG/reconfigure.sh" "$RA_CFG/lib.sh"; do
    assert_false "no /cfg path survives the rewrite in $(basename "$_isolated")" \
        grep -q '/cfg/' "$_isolated"
done

# A crontab that cannot be written must not print both that the job could not
# be installed and that it was.
s8_output() {   # runs Step 8 against a crontab stub that fails, echoes its output
    { printf '. %s/lib.sh\n' "$S8_CFG"; cat "$TMPDIR/step8-body.sh"; } > "$S8GEN"
    sed -e "s|/cfg/|${S8_CFG}/|g" "$SCRIPT_DIR/lib.sh" > "$S8_CFG/lib.sh"
    printf 'RESOLVER_ID=abc123\n' > "$S8_CFG/controld.env"
    printf '#!/bin/sh\nexit 1\n' > "$S8_BIN/crontab"; chmod +x "$S8_BIN/crontab"
    ( PATH="$S8_BIN:$PATH"; sh "$S8GEN" ) 2>&1 || true
}
S8_BROKE="$(s8_output)"
assert_contains     "a crontab that fails is reported"   "$S8_BROKE" "Could not install cron job"
assert_not_contains "and not also reported as installed" "$S8_BROKE" "Weekly auto-update cron installed"
cat > "$S8_BIN/crontab" << 'S8TABEOF2'
#!/bin/sh
case "$1" in
    -l) cat "$S8_TAB" 2>/dev/null ;;
    -)  cat > "${S8_TAB}.new" && mv "${S8_TAB}.new" "$S8_TAB" ;;
esac
S8TABEOF2
chmod +x "$S8_BIN/crontab"

assert_true "the Step 8 range carries its cron_remove" \
    grep -q 'cron_remove' "$TMPDIR/step8-body.sh"
assert_true "and its gate"  grep -q 'installed_auto_update' "$TMPDIR/step8-body.sh"
assert_true "and the crontab write it is here to test" \
    grep -q 'controld-update.sh' "$TMPDIR/step8-body.sh"
# The two anchors fail differently, so they need different guards. A missing
# START anchor empties the range, which the three greps above catch. A missing
# END anchor does not empty it: sed runs to EOF, so the body swells to the rest
# of setup.sh, still carries every string those greps look for, and the
# assertions below then execute hundreds of unrelated lines. Retitling the
# Step 9 header left the whole suite green until this was added. Step 9b's
# marker is the first thing past the range, so its absence bounds the end.
assert_false "the range stops at the Step 9 header, rather than running to EOF" \
    grep -q 'UTILITY_SCRIPTS' "$TMPDIR/step8-body.sh"

# $2 picks what is already in the crontab, and it has to be a parameter. Seeded
# with both jobs every time, "installs the update cron" asserted that a line
# the fixture had just written was still there: wrapping the whole of Step 8 in
# `if false` left three of these assertions green.
s8_run() {   # $1 = lib.sh to run against, $2 = both|watchdog; echoes the crontab
    { printf '. %s/lib.sh\n' "$S8_CFG"; cat "$TMPDIR/step8-body.sh"; } > "$S8GEN"
    cp "$1" "$S8_CFG/lib.sh"
    if [ "${2:-watchdog}" = "both" ]; then
        printf '0 3 * * 1 %s/controld-update.sh\n*/5 * * * * %s/watchdog.sh\n' \
            "$S8_CFG" "$S8_CFG" > "$S8_TAB"
    else
        printf '*/5 * * * * %s/watchdog.sh\n' "$S8_CFG" > "$S8_TAB"
    fi
    ( PATH="$S8_BIN:$PATH"; sh "$S8GEN" ) >/dev/null 2>&1 || true
    cat "$S8_TAB" 2>/dev/null
}
S8_LIB="$TMPDIR/s8-lib.sh"
sed -e "s|/cfg/|${S8_CFG}/|g" "$SCRIPT_DIR/lib.sh" > "$S8_LIB"

# No opt-out: the cron is installed, and the watchdog is left alone.
printf 'RESOLVER_ID=abc123\n' > "$S8_CFG/controld.env"
S8_ON="$(s8_run "$S8_LIB" watchdog)"
assert_contains "no opt-out installs the update cron"  "$S8_ON" "controld-update.sh"
assert_contains "and leaves the watchdog cron alone"   "$S8_ON" "watchdog.sh"

# Opt-out: the job already in the crontab is taken away and not put back. This
# is the re-install path, which CONTRIBUTING.md names as a hardware-only bug.
printf 'RESOLVER_ID=abc123\nAUTO_UPDATE=0\n' > "$S8_CFG/controld.env"
S8_OFF="$(s8_run "$S8_LIB" both)"
assert_not_contains "a re-install honours an opt-out and removes the cron" \
    "$S8_OFF" "controld-update.sh"
assert_contains "while still leaving the watchdog cron alone" "$S8_OFF" "watchdog.sh"

# A shape the toggle does not write, so a reader that went back to matching
# the line rather than sourcing it would install the cron here.
printf 'RESOLVER_ID=abc123\nAUTO_UPDATE="0"\n' > "$S8_CFG/controld.env"
assert_not_contains "a quoted opt-out is honoured by the installer too" \
    "$(s8_run "$S8_LIB" both)" "controld-update.sh"

# An older library that predates the function, which setup.sh's two offline
# bootstrap paths can supply. No library means no flag, which means on.
S8_OLD="$TMPDIR/s8-lib-old.sh"
sed '/^installed_auto_update() {$/,/^}$/d' "$S8_LIB" > "$S8_OLD"
assert_false "the stale library really lacks the function" \
    grep -q '^installed_auto_update()' "$S8_OLD"
printf 'RESOLVER_ID=abc123\n' > "$S8_CFG/controld.env"
assert_contains "an older lib.sh without the function still installs the cron" \
    "$(s8_run "$S8_OLD" watchdog)" "controld-update.sh"

# The generated watchdog is heredoc text inside setup.sh, so nothing in this
# repo has ever executed it. Extract it, point its /cfg and /tmp paths at a
# sandbox, and run it for real against stubs.
#
# The failure being guarded: the dead-ctrld branch used to `exit 0` whether or
# not the restart worked, so a ctrld that exits on startup (corrupt binary, a
# config a new release will not parse) ended every run right there. The
# fallback chain and the redirect teardown both sit further down, on the path
# that needs ctrld running but not answering, so neither was ever reached and
# port 53 stayed pointed at a closed port.
WD_CFG="$TMPDIR/wd-cfg"
WD_BIN="$TMPDIR/wd-bin"
WD_LOG="$TMPDIR/wd.log"
mkdir -p "$WD_CFG" "$WD_BIN"
export WD_LOG

WDGEN="$TMPDIR/watchdog-generated.sh"
sed -n "/^cat > \/cfg\/watchdog.sh << 'WATCHDOG'/,/^WATCHDOG$/p" "$SCRIPT_DIR/setup.sh" \
    | sed '1d;$d' \
    | sed -e "s|/cfg/|${WD_CFG}/|g" \
          -e "s|/tmp/controld-dns-fail.count|${TMPDIR}/wd-fail.count|g" > "$WDGEN"

assert_true "the generated watchdog is valid sh" sh -n "$WDGEN"

# Side-effecting helpers are replaced; next_proto and retarget_upstreams stay
# real, so the fallback loop exercises the code the router would run.
cat > "$WD_CFG/lib.sh" << WDLIBEOF
. "$SCRIPT_DIR/lib.sh"
check_dns()                  { return 1; }
stop_ctrld()                 { :; }
start_ctrld()                { return 1; }
restart_ctrld()              { echo "restart-attempt" >> "\$WD_LOG"; return 1; }
ensure_iptables()            { echo "ensure_iptables" >> "\$WD_LOG"; return 1; }
ensure_firewall_user_rules() { return 1; }
ensure_forced_dns()          { :; }
do_upgrade_check()           { :; }
remove_dns_redirects()       { echo "teardown" >> "\$WD_LOG"; }
WDLIBEOF

cat > "$WD_CFG/controld.env" << 'WDENVEOF'
RESOLVER_ID=abc123
BOOTSTRAP_IP=76.76.2.22
CTRLD_VERSION=1.5.7
DNS_TYPE=doh3
PREFERRED_PROTOCOL=doh3
FORCED_DNS=0
WDENVEOF

write_ctrld_config "$WD_CFG/ctrld.toml" abc123 76.76.2.22 doh3

printf '#!/bin/sh\nexit 1\n' > "$WD_BIN/pidof"          # ctrld is not running
printf '#!/bin/sh\necho "$*" >> "$WD_LOG"\n' > "$WD_BIN/logger"
chmod +x "$WD_BIN/pidof" "$WD_BIN/logger"

# FAIL_THRESHOLD=1 skips the debounce; on a router this costs one extra cycle.
: > "$WD_LOG"
( PATH="$WD_BIN:$PATH"; FAIL_THRESHOLD=1; WD_LOCK="$TMPDIR/wd.lock"; export FAIL_THRESHOLD WD_LOCK; sh "$WDGEN" ) >/dev/null 2>&1
WD_OUT="$(cat "$WD_LOG" 2>/dev/null)"

assert_contains "it tries to restart the dead ctrld" "$WD_OUT" "restart-attempt"
assert_contains "a failed restart does not end the run" "$WD_OUT" "falling through"
assert_contains "it works the protocol fallback chain"  "$WD_OUT" "trying doh"
assert_contains "and tears the redirects down when nothing resolves" "$WD_OUT" "teardown"

# A restart that works must not end the cycle either. The health path below is
# what re-adds the redirects, restores forced DNS and clears the degraded flag,
# and after a teardown all of that is gone, so exiting on a successful restart
# left a healthy ctrld with no redirects until some later cycle. Seen on
# hardware: ctrld answering, 0 redirect rules, 26 drift items. The teardown is
# still a last resort that a healthy cycle must never walk into.
cat > "$WD_CFG/lib.sh" << WDLIBEOF2
. "$SCRIPT_DIR/lib.sh"
check_dns()                  { return 0; }
ensure_iptables()            { echo "ensure_iptables" >> "\$WD_LOG"; return 1; }
ensure_firewall_user_rules() { return 1; }
ensure_forced_dns()          { echo "ensure_forced_dns" >> "\$WD_LOG"; }
do_upgrade_check()           { :; }
restart_ctrld()              { echo "restart-attempt" >> "\$WD_LOG"; return 0; }
remove_dns_redirects()       { echo "teardown" >> "\$WD_LOG"; }
WDLIBEOF2
: > "$WD_LOG"
( PATH="$WD_BIN:$PATH"; WD_LOCK="$TMPDIR/wd.lock"; export WD_LOCK; sh "$WDGEN" ) >/dev/null 2>&1
WD_OUT2="$(cat "$WD_LOG" 2>/dev/null)"
assert_contains     "a successful restart is reported"                 "$WD_OUT2" "ctrld restarted"
assert_contains     "and the same cycle goes on to restore redirects"  "$WD_OUT2" "ensure_iptables"
assert_contains     "and to restore forced DNS"                        "$WD_OUT2" "ensure_forced_dns"
assert_not_contains "without ever reaching the teardown"               "$WD_OUT2" "teardown"

describe "watchdog — one instance at a time"

# A recovery cycle used to run longer than the watchdog's own cron interval, so
# instances overlapped on any real ctrld failure: three were alive at once in a
# router's syslog, sharing the fail-count file (where one instance's reset
# erases another's debounce) and rewriting ctrld.toml underneath each other
# through the fallback loop. b1b5fbd made the cycle short, but a stalled
# resolver can still stretch one past five minutes, so the invariant is
# enforced rather than left to timing.
WD_LOCKDIR="$TMPDIR/wd-lock-test"

# A live owner: the second run must decline, and do nothing else.
rm -rf "$WD_LOCKDIR"; mkdir -p "$WD_LOCKDIR"
printf '%s\n' "$$" > "$WD_LOCKDIR/pid"     # this suite is certainly running
: > "$WD_LOG"
( PATH="$WD_BIN:$PATH"; WD_LOCK="$WD_LOCKDIR"; export WD_LOCK; sh "$WDGEN" ) >/dev/null 2>&1
WD_LOCKED="$(cat "$WD_LOG" 2>/dev/null)"
assert_contains     "a second instance says why it is standing down" \
    "$WD_LOCKED" "another watchdog is still running"
assert_not_contains "and does no work at all"  "$WD_LOCKED" "restart-attempt"
assert_true         "the running instance keeps its lock" test -d "$WD_LOCKDIR"

# A stale lock must be cleared, not honoured, or one interrupted run wedges the
# watchdog until the next reboot. A PID that has been reaped is the real case.
( : ) & WD_DEADPID=$!
wait "$WD_DEADPID" 2>/dev/null || true
rm -rf "$WD_LOCKDIR"; mkdir -p "$WD_LOCKDIR"
printf '%s\n' "$WD_DEADPID" > "$WD_LOCKDIR/pid"
: > "$WD_LOG"
( PATH="$WD_BIN:$PATH"; WD_LOCK="$WD_LOCKDIR"; export WD_LOCK; sh "$WDGEN" ) >/dev/null 2>&1
WD_STALE="$(cat "$WD_LOG" 2>/dev/null)"
assert_contains "a stale lock is reported, not obeyed" "$WD_STALE" "clearing a stale lock"
assert_contains "and the cycle runs"                   "$WD_STALE" "restart-attempt"
assert_false    "a completed run releases the lock"    test -d "$WD_LOCKDIR"

# An interrupted run must release it too. Not hypothetical: a manual run was
# Ctrl-C'd mid-fallback during hardware verification, which under the old code
# left nothing behind only because there was no lock to leave.
#
# The stub blocks in one-second steps rather than a single long sleep: a trap is
# handled between commands, so a shell sitting in `sleep 20` would not run it
# until the sleep returned.
cat > "$WD_CFG/lib.sh" << WDLIBEOF4
. "$SCRIPT_DIR/lib.sh"
check_dns()                  { return 1; }
ensure_iptables()            { return 1; }
ensure_firewall_user_rules() { return 1; }
ensure_forced_dns()          { :; }
do_upgrade_check()           { :; }
restart_ctrld()              { _i=0; while [ "\$_i" -lt 20 ]; do sleep 1; _i=\$((_i + 1)); done; return 0; }
remove_dns_redirects()       { :; }
WDLIBEOF4
rm -rf "$WD_LOCKDIR"
PATH="$WD_BIN:$PATH" WD_LOCK="$WD_LOCKDIR" sh "$WDGEN" >/dev/null 2>&1 &
WD_BGPID=$!
sleep 2
assert_true "a running instance holds the lock" test -d "$WD_LOCKDIR"
kill -TERM "$WD_BGPID" 2>/dev/null || true
wait "$WD_BGPID" 2>/dev/null || true
assert_false "an interrupted run releases it" test -d "$WD_LOCKDIR"

describe "watchdog — a failed fallback must not leave the config diverged"

# Every attempt retargets ctrld.toml before it knows whether the restart works,
# so falling out of the loop left the file on whichever protocol was tried last
# while controld.env still named the original. With the chain "doh3 doh" and
# three attempts that is DoH, and nothing reconciled the two: the next cycle
# restarts ctrld from the toml and logs the env's protocol, so the router runs
# DoH while status.sh reports DoH3, across reboots. Reproduced in a sandbox
# before it was fixed.
WD_DIV="$TMPDIR/wd-divergence"
rm -rf "$WD_DIV"; mkdir -p "$WD_DIV"

WDGEN_DIV="$TMPDIR/watchdog-divergence.sh"
sed -n "/^cat > \/cfg\/watchdog.sh << 'WATCHDOG'/,/^WATCHDOG$/p" "$SCRIPT_DIR/setup.sh" \
    | sed '1d;$d' \
    | sed -e "s|/cfg/|${WD_DIV}/|g" \
          -e "s|/tmp/controld-dns-fail.count|${TMPDIR}/wd-div-fail.count|g" > "$WDGEN_DIV"

cat > "$WD_DIV/controld.env" << 'WDDIVENV'
RESOLVER_ID=abc123
BOOTSTRAP_IP=76.76.2.22
DNS_TYPE=doh3
PREFERRED_PROTOCOL=doh3
FORCED_DNS=0
WDDIVENV

# retarget_upstreams stays real, since it is what rewrites the file, while
# ctrld can never start, which is the case that walks the whole loop.
cat > "$WD_DIV/lib.sh" << WDDIVLIB
. "$SCRIPT_DIR/lib.sh"
check_dns()                  { return 1; }
stop_ctrld()                 { :; }
start_ctrld()                { return 1; }
restart_ctrld()              { return 1; }
ensure_iptables()            { return 1; }
ensure_firewall_user_rules() { return 1; }
ensure_forced_dns()          { :; }
do_upgrade_check()           { :; }
remove_dns_redirects()       { :; }
WDDIVLIB

write_ctrld_config "$WD_DIV/ctrld.toml" abc123 76.76.2.22 doh3
assert_file_contains "the sandbox starts on doh3" "$WD_DIV/ctrld.toml" 'type = "doh3"'

( PATH="$WD_BIN:$PATH"; WD_LOCK="$TMPDIR/wd-div.lock"; FAIL_THRESHOLD=1
  export WD_LOCK FAIL_THRESHOLD; sh "$WDGEN_DIV" ) >/dev/null 2>&1

WD_DIV_TYPE="$(grep -o 'type = "[a-z0-9]*"' "$WD_DIV/ctrld.toml" | head -1)"
WD_DIV_ENV="$(grep '^DNS_TYPE=' "$WD_DIV/controld.env")"
assert_eq "the config is back on the protocol the env still names" 'type = "doh3"' "$WD_DIV_TYPE"
assert_eq "and the env is untouched"                              'DNS_TYPE=doh3'  "$WD_DIV_ENV"
assert_false "the snapshot is not left behind" test -f "$WD_DIV/ctrld.toml.fallback"

# A fallback that works must keep its new protocol, not roll it back. ctrld has
# to look alive here, or the dead-ctrld branch restarts it and exits before the
# fallback loop is ever reached.
WD_DIV_BIN="$TMPDIR/wd-div-bin"
mkdir -p "$WD_DIV_BIN"
printf '#!/bin/sh\necho 4143\n' > "$WD_DIV_BIN/pidof"
printf '#!/bin/sh\nexit 0\n'    > "$WD_DIV_BIN/logger"
chmod +x "$WD_DIV_BIN/pidof" "$WD_DIV_BIN/logger"

write_ctrld_config "$WD_DIV/ctrld.toml" abc123 76.76.2.22 doh3
cat > "$WD_DIV/lib.sh" << WDDIVLIB2
. "$SCRIPT_DIR/lib.sh"
check_dns()                  { return 1; }
stop_ctrld()                 { :; }
start_ctrld()                { return 0; }
restart_ctrld()              { return 0; }
ensure_iptables()            { return 1; }
ensure_firewall_user_rules() { return 1; }
ensure_forced_dns()          { :; }
do_upgrade_check()           { :; }
remove_dns_redirects()       { :; }
WDDIVLIB2
( PATH="$WD_DIV_BIN:$PATH"; WD_LOCK="$TMPDIR/wd-div.lock"; FAIL_THRESHOLD=1
  export WD_LOCK FAIL_THRESHOLD; sh "$WDGEN_DIV" ) >/dev/null 2>&1

assert_file_contains "a working fallback keeps its protocol" "$WD_DIV/ctrld.toml" 'type = "doh"'
assert_file_contains "and records it in the env"             "$WD_DIV/controld.env" 'DNS_TYPE=doh'
assert_false "the snapshot is cleaned up on success" test -f "$WD_DIV/ctrld.toml.fallback"

# audit.sh and uninstall.sh must both know the snapshot by name, or an
# interrupted recovery leaves a file that is reported as foreign and never
# removed.
assert_true "audit.sh names the snapshot"     code_grep "$SCRIPT_DIR/audit.sh" 'ctrld.toml.fallback'
assert_true "uninstall.sh removes it"         code_grep "$SCRIPT_DIR/uninstall.sh" 'ctrld.toml.fallback'

describe "readouts must report the protocol running, not the one recorded"

# status.sh was fixed for this; audit.sh and benchmark.sh read DNS_TYPE the
# same way and were wrong the same way. audit.sh is the project's drift
# detector, so a divergence between controld.env and ctrld.toml being
# invisible to it while it printed the recorded protocol as an OK line, is
# the one report that should never have missed this.
RO_DIR="$TMPDIR/readouts"; rm -rf "$RO_DIR"; mkdir -p "$RO_DIR"

RO_BIN="$TMPDIR/ro-bin"; mkdir -p "$RO_BIN"
for _rc in uci iptables crontab ip nslookup logread pidof netstat; do
    printf '#!/bin/sh\nexit 1\n' > "$RO_BIN/$_rc"; chmod +x "$RO_BIN/$_rc"
done

# What audit.sh will actually report as the recorded values.
#
# It calls load_env, which sources /cfg/controld.env whenever that file exists
# and silently wins over anything exported here. In a sandbox there is no such
# file and the exports below stand; on a real router there is, so hardcoding
# "1.3.6" and "doh3" made this pass only where /cfg does not exist, and a
# sandbox-only pass of exactly the kind this project keeps getting caught by.
# Read the recorded values from wherever audit.sh is going to read them.
if [ -f /cfg/controld.env ]; then
    RO_REC="$(sed -n 's/^DNS_TYPE=//p' /cfg/controld.env | head -1)"
    RO_VER="$(sed -n 's/^CTRLD_VERSION=//p' /cfg/controld.env | head -1)"
fi
# Empty covers both the no-/cfg case and a file that omits the key: load_env
# leaves the exported value alone, so these are what audit.sh ends up with.
RO_REC="${RO_REC:-doh3}"
RO_VER="${RO_VER:-1.3.6}"
# Any protocol that is deliberately not the recorded one.
case "$RO_REC" in doq) RO_OTHER=doh3 ;; *) RO_OTHER=doq ;; esac

write_ctrld_config "$RO_DIR/ctrld.toml"  abc123 76.76.2.22 "$RO_OTHER"
write_ctrld_config "$RO_DIR/agree.toml"  abc123 76.76.2.22 "$RO_REC"

# audit.sh runs off-device, so this is an outcome test on its real output.
# CTRLD_VERSION has to be set for the line under test to be reached at all.
RO_OUT="$(PATH="$RO_BIN:$PATH" CTRLD_TOML="$RO_DIR/ctrld.toml" \
    CTRLD_VERSION="$RO_VER" DNS_TYPE="$RO_REC" RESOLVER_ID=abc123 FORCED_DNS=1 \
    sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
# Anchored to the version line itself: the divergence finding below also
# names the running protocol, so a bare label would pass on that alone.
assert_contains "audit.sh names the protocol ctrld.toml runs" "$RO_OUT" \
    "ctrld ${RO_VER} on $(proto_label "$RO_OTHER")"
assert_not_contains "not the one controld.env records" "$RO_OUT" \
    "ctrld ${RO_VER} on $(proto_label "$RO_REC")"
assert_contains "and raises the divergence as its own finding" "$RO_OUT" \
    "but ctrld.toml runs $(proto_label "$RO_OTHER")"

# Agreeing files must stay silent, or every clean install reports a finding.
RO_OK="$(PATH="$RO_BIN:$PATH" CTRLD_TOML="$RO_DIR/agree.toml" \
    CTRLD_VERSION="$RO_VER" DNS_TYPE="$RO_REC" RESOLVER_ID=abc123 FORCED_DNS=1 \
    sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_not_contains "and says nothing when the two agree" "$RO_OK" "but ctrld.toml runs"

# benchmark.sh measures against live resolvers, so nothing in this suite runs
# it: these are source assertions, comment-blind, like its existing ones.
# The comparison is what matters: reading DNS_TYPE there meant a stale record
# matching the winner printed "(already active)" and hid the fix command.
assert_true "benchmark.sh takes its current protocol from running_protocol" \
    code_grep "$SCRIPT_DIR/benchmark.sh" -E \
    '^BENCH_CURRENT="\$\(running_protocol\)" \|\| BENCH_CURRENT="\$DNS_TYPE"'
assert_true "and compares the winner against that, not against DNS_TYPE" \
    code_grep "$SCRIPT_DIR/benchmark.sh" -E \
    '^if \[ "\$fastest_proto" != "\$BENCH_CURRENT" \]; then'
assert_false "so no live comparison against DNS_TYPE is left" \
    code_grep "$SCRIPT_DIR/benchmark.sh" -E '!= "\$DNS_TYPE"'

describe "watchdog — the fallback chain must start from the protocol actually running"

# The fallback loop seeds next_proto from DNS_TYPE. Reconciliation happens on
# the healthy branch only (do_upgrade_check), and this path never reaches it,
# so a router that rebooted mid-fallback walks the chain from the stale name.
# With the chain "doh3 doh", ctrld.toml really on doh and DNS_TYPE saying
# doh3, next_proto(doh3) is doh: attempt 1 retargets to the protocol that just
# failed, and attempt 3 does it again, so one attempt in three tries anything
# new, while every client on every bridge has no DNS. Seeded from the truth,
# next_proto(doh) wraps to doh3 and the first attempt is productive.
WD_DRIFT="$TMPDIR/wd-drift"
rm -rf "$WD_DRIFT"; mkdir -p "$WD_DRIFT"

WDGEN_DRIFT="$TMPDIR/watchdog-drift.sh"
sed -n "/^cat > \/cfg\/watchdog.sh << 'WATCHDOG'/,/^WATCHDOG$/p" "$SCRIPT_DIR/setup.sh" \
    | sed '1d;$d' \
    | sed -e "s|/cfg/|${WD_DRIFT}/|g" \
          -e "s|/tmp/controld-dns-fail.count|${TMPDIR}/wd-drift-fail.count|g" > "$WDGEN_DRIFT"

# Exactly the state found on the router: the config runs DoH, the env still
# names DoH3, and PREFERRED_PROTOCOL agrees with the env.
cat > "$WD_DRIFT/controld.env" << 'WDDRIFTENV'
RESOLVER_ID=abc123
BOOTSTRAP_IP=76.76.2.22
DNS_TYPE=doh3
PREFERRED_PROTOCOL=doh3
FORCED_DNS=0
WDDRIFTENV
write_ctrld_config "$WD_DRIFT/ctrld.toml" abc123 76.76.2.22 doh

# reconcile_dns_type and retarget_upstreams stay real, since they are what this
# asserts on. The first restart succeeds, so the loop stops after one attempt
# and the config records which protocol that attempt chose.
cat > "$WD_DRIFT/lib.sh" << WDDRIFTLIB
. "$SCRIPT_DIR/lib.sh"
check_dns()                  { return 1; }
stop_ctrld()                 { :; }
start_ctrld()                { return 0; }
restart_ctrld()              { return 0; }
ensure_iptables()            { return 1; }
ensure_firewall_user_rules() { return 1; }
ensure_forced_dns()          { :; }
do_upgrade_check()           { :; }
remove_dns_redirects()       { :; }
WDDRIFTLIB

WD_DRIFT_BIN="$TMPDIR/wd-drift-bin"; mkdir -p "$WD_DRIFT_BIN"
WD_DRIFT_LOG="$TMPDIR/wd-drift.log"; : > "$WD_DRIFT_LOG"
printf '#!/bin/sh\necho 4143\n' > "$WD_DRIFT_BIN/pidof"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$WD_DRIFT_LOG" > "$WD_DRIFT_BIN/logger"
chmod +x "$WD_DRIFT_BIN/pidof" "$WD_DRIFT_BIN/logger"

( PATH="$WD_DRIFT_BIN:$PATH"; WD_LOCK="$TMPDIR/wd-drift.lock"; FAIL_THRESHOLD=1
  export WD_LOCK FAIL_THRESHOLD; sh "$WDGEN_DRIFT" ) >/dev/null 2>&1

assert_file_contains "the first attempt tries a protocol that has not just failed" \
    "$WD_DRIFT/ctrld.toml" 'type = "doh3"'
assert_file_contains "and the env records it" "$WD_DRIFT/controld.env" '^DNS_TYPE=doh3$'
assert_contains "the correction is logged" "$(cat "$WD_DRIFT_LOG")" \
    "DNS_TYPE corrected to doh"
# The pre-fallback line named the stale protocol, so the syslog record of a
# recovery disagreed with the config the recovery actually started from.
assert_contains "and the pre-fallback line names what was really running" \
    "$(cat "$WD_DRIFT_LOG")" "DNS failed on doh after"

describe "running_protocol() — what ctrld.toml is actually configured for"

# The main upstream (upstream.0) is the router's ordinary-DNS protocol by
# convention everywhere in this project: every split-DNS profile is
# additional to it, never instead of it.
RP_DIR="$TMPDIR/running-protocol"
mkdir -p "$RP_DIR"

write_ctrld_config "$RP_DIR/ctrld.toml" abc123 76.76.2.22 doh
assert_eq "reads the main upstream's protocol" "doh" "$(running_protocol "$RP_DIR/ctrld.toml")"

write_ctrld_config "$RP_DIR/ctrld.toml" abc123 76.76.2.22 doq
assert_eq "and again after a retarget" "doq" "$(running_protocol "$RP_DIR/ctrld.toml")"

assert_false "a missing file is not silently answered" \
    running_protocol "$RP_DIR/does-not-exist.toml"

printf '[upstream.0]\n  name = "x"\n' > "$RP_DIR/no-type.toml"
assert_false "an upstream.0 with no type is not silently answered" \
    running_protocol "$RP_DIR/no-type.toml"

# Anything outside the four protocols this project manages is "unknown", not
# something to report and record. The value is persisted into DNS_TYPE and fed
# to get_endpoint and every later config rewrite, so adopting a hand-edited or
# half-written type is worse than admitting the protocol cannot be determined
# and a half-written config is squarely in scope, since an interrupted write
# is the whole reason this function exists.
printf '[upstream.0]\n  name = "x"\n  type = "notaproto"\n' > "$RP_DIR/bogus.toml"
assert_false "a protocol this project does not manage is not answered" \
    running_protocol "$RP_DIR/bogus.toml"

# Worse than merely unknown: a value carrying sed metacharacters reached an
# unquoted `sed s/.../DNS_TYPE=<value>/` in reconcile_dns_type, which failed
# with "unknown option to \`s'" on stderr and still reported success.
printf '[upstream.0]\n  name = "x"\n  type = "x/y&z"\n' > "$RP_DIR/hostile.toml"
assert_false "nor is one carrying sed metacharacters" \
    running_protocol "$RP_DIR/hostile.toml"

describe "reconcile_dns_type() — DNS_TYPE must not diverge from what ctrld.toml runs"

# The scenario found on a router: a watchdog fallback attempt retargets
# ctrld.toml to a candidate protocol before it knows whether the restart will
# succeed, and only commits DNS_TYPE once it does. A reboot landing in
# between, the observed case, leaves ctrld.toml on one protocol while
# DNS_TYPE and PREFERRED_PROTOCOL still name another. Nothing before this
# reconciled them: self-upgrade compared PREFERRED_PROTOCOL against the stale
# DNS_TYPE and saw no difference, so it never fired; a manual
# `reconfigure.sh --protocol --to doh3` no-opped for the same reason;
# status.sh reported the protocol that was recorded, not the one running. The
# state was stable, not transient.
RC_DIR="$TMPDIR/reconcile"; mkdir -p "$RC_DIR"
write_ctrld_config "$RC_DIR/ctrld.toml" abc123 76.76.2.22 doh   # the real, running protocol
printf 'RESOLVER_ID=abc123\nBOOTSTRAP_IP=76.76.2.22\nDNS_TYPE=doh3\nPREFERRED_PROTOCOL=doh3\n' \
    > "$RC_DIR/controld.env"                                    # what was recorded before the interruption

DNS_TYPE=doh3
# assert_true, not a bare call: a mutated reconcile_dns_type that fails here
# must show as a clean FAIL, not crash the whole suite under set -e.
assert_true "reports a correction was made" \
    reconcile_dns_type "$RC_DIR/controld.env" "$RC_DIR/ctrld.toml"
assert_eq "and updates DNS_TYPE in the caller's shell" "doh" "$DNS_TYPE"
assert_file_contains "and persists it to the env file" "$RC_DIR/controld.env" '^DNS_TYPE=doh$'
assert_false "PREFERRED_PROTOCOL is never touched — that is what the user asked for" \
    grep -q '^PREFERRED_PROTOCOL=doh$' "$RC_DIR/controld.env"
assert_file_contains "it stays what it was" "$RC_DIR/controld.env" '^PREFERRED_PROTOCOL=doh3$'

# Already-correct state must report nothing to do, and touch nothing. The
# common case runs every 5 minutes and must stay silent and cheap.
sed -i 's/^DNS_TYPE=.*/DNS_TYPE=doh/' "$RC_DIR/controld.env"   # now agrees with ctrld.toml
RC_ENV_BEFORE="$(cat "$RC_DIR/controld.env")"
DNS_TYPE=doh
# Bare, direct calls expecting failure would trip this suite's own `set -e`
# (a non-zero exit from an unguarded statement is fatal in ash); assert_false
# already runs the call inside an `if`, which set -e exempts, same as every
# other non-zero-expecting assertion in this suite.
assert_false "reports nothing needed to fix" \
    reconcile_dns_type "$RC_DIR/controld.env" "$RC_DIR/ctrld.toml"
assert_eq "and the file is byte-for-byte untouched" "$RC_ENV_BEFORE" "$(cat "$RC_DIR/controld.env")"

# A ctrld.toml that cannot be read (missing, or no readable upstream.0) is not
# this function's problem to report: it must fail closed, not correct
# DNS_TYPE to garbage.
DNS_TYPE=doh3
assert_false "an unreadable config reports nothing to correct" \
    reconcile_dns_type "$RC_DIR/controld.env" "$RC_DIR/does-not-exist.toml"
assert_file_contains "and DNS_TYPE is left alone on disk" "$RC_DIR/controld.env" '^DNS_TYPE=doh$'

# Nor is a protocol this project does not manage adopted, on disk or in the
# caller's shell, which is where do_upgrade_check and reconfigure.sh read it
# from for every decision they make after the call.
DNS_TYPE=doh3
assert_false "a protocol this project does not manage is not adopted" \
    reconcile_dns_type "$RC_DIR/controld.env" "$RP_DIR/bogus.toml"
assert_eq "and the caller's DNS_TYPE is left alone" "doh3" "$DNS_TYPE"
assert_file_contains "and so is the file" "$RC_DIR/controld.env" '^DNS_TYPE=doh$'

# An env file old enough to have no DNS_TYPE line at all is still supported,
# load_env and post-cfg.sh both default the value rather than refusing the
# file. `sed s/^DNS_TYPE=.*/` has nothing to rewrite there, so the correction
# was reported but never written, and every watchdog cycle then rediscovered
# and re-logged the same divergence, five minutes apart, indefinitely.
printf 'RESOLVER_ID=abc123\nPREFERRED_PROTOCOL=doh3\n' > "$RC_DIR/legacy.env"
DNS_TYPE=doh3
assert_true "an env file with no DNS_TYPE line still gets the correction" \
    reconcile_dns_type "$RC_DIR/legacy.env" "$RC_DIR/ctrld.toml"
assert_file_contains "the line is appended rather than silently skipped" \
    "$RC_DIR/legacy.env" '^DNS_TYPE=doh$'
assert_false "so the very next pass has nothing left to correct" \
    reconcile_dns_type "$RC_DIR/legacy.env" "$RC_DIR/ctrld.toml"

# Appending must never conjure an env file that was not there: every caller
# runs load_env first, so a missing file means something is wrong upstream.
# DNS_TYPE has to disagree with the config here, or the function would return
# non-zero for the wrong reason and the assertion would pass either way.
DNS_TYPE=doh3
assert_false "a missing env file reports nothing to correct" \
    reconcile_dns_type "$RC_DIR/no-such.env" "$RC_DIR/ctrld.toml"
assert_false "and is not created" test -f "$RC_DIR/no-such.env"

describe "do_upgrade_check() — must consult the real protocol, not just the record"

# reconcile_dns_type is stubbed here to control exactly what it reports,
# isolating do_upgrade_check's own decision from reconcile_dns_type's own file
# handling (already tested directly above), the same technique the watchdog
# tests already use to isolate a caller's control flow from its
# collaborators. Everything happens inside a subshell: PATH, the stub
# definition and DNS_TYPE/PREFERRED_PROTOCOL are all gone the moment it exits,
# so nothing here can leak into a test that runs after it. Only what actually
# landed on disk (the log file, the counter file) is asserted on, outside
# the subshell where assert_* must run for PASS/FAIL to be counted at all.
DUC_BIN="$TMPDIR/duc-bin"; mkdir -p "$DUC_BIN"
DUC_LOG="$TMPDIR/duc.log"; export DUC_LOG
printf '#!/bin/sh\necho "$*" >> "$DUC_LOG"\n' > "$DUC_BIN/logger"
chmod +x "$DUC_BIN/logger"

# The counter lives in a sandbox, not at do_upgrade_check's real path. This
# block used to read, write and delete the live file: on a router that reset
# the watchdog's own self-upgrade timer, so running the suite there could
# hold a fallback protocol in place for another full interval. Recorded
# before and compared after, so a regression shows up as a failure rather
# than as someone's router quietly taking longer to recover.
UPGRADE_COUNT_FILE="$TMPDIR/duc-upgrade.count"; export UPGRADE_COUNT_FILE
DUC_REAL_BEFORE="$(cat /tmp/controld-upgrade.count 2>/dev/null || echo ABSENT)"
rm -f "$UPGRADE_COUNT_FILE"

: > "$DUC_LOG"
( PATH="$DUC_BIN:$PATH"
  DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3   # the stuck state: both agree, wrongly
  reconcile_dns_type() { DNS_TYPE=doh; return 0; }   # simulates finding+fixing a real divergence
  do_upgrade_check
) >/dev/null 2>&1 || true
assert_contains "a correction is logged" "$(cat "$DUC_LOG")" "DNS_TYPE corrected to doh"
assert_true "and preferred-vs-actual now genuinely differs, so the upgrade counter starts" \
    test -f "$UPGRADE_COUNT_FILE"
rm -f "$UPGRADE_COUNT_FILE"

: > "$DUC_LOG"
( PATH="$DUC_BIN:$PATH"
  DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3
  reconcile_dns_type() { return 1; }   # nothing to correct
  do_upgrade_check
) >/dev/null 2>&1 || true
assert_not_contains "nothing is logged when there is nothing to correct" \
    "$(cat "$DUC_LOG")" "DNS_TYPE corrected"
assert_false "and — already on preferred — the counter is not started" \
    test -f "$UPGRADE_COUNT_FILE"

# The point of the override: a router running this suite must come out of it
# with its own self-upgrade timer exactly as it was.
assert_eq "and the router's own counter is left exactly as it was" \
    "$DUC_REAL_BEFORE" "$(cat /tmp/controld-upgrade.count 2>/dev/null || echo ABSENT)"
unset UPGRADE_COUNT_FILE

# Anchored to the call itself and blind to comments: a bare file-wide
# `grep -q 'reconcile_dns_type &&'` also matched the comment left behind by
# commenting the call out, so it passed against code with the fix removed.
assert_true "do_upgrade_check actually calls reconcile_dns_type" \
    code_grep "$SCRIPT_DIR/lib.sh" -E \
    '^[[:space:]]*reconcile_dns_type /cfg/controld\.env /cfg/ctrld\.toml &&'

describe "reconfigure.sh and status.sh — wired to the real protocol, not the stale record"

# reconfigure.sh hardcodes /cfg/ctrld.toml and /cfg/controld.env throughout,
# like every other script here, because running it as a real subprocess would
# write to those paths and restart production ctrld if this ever executed on a
# router, which test.sh is explicitly meant to support. Nothing in this suite
# runs reconfigure.sh or status.sh as a subprocess for that reason, so this
# checks wiring and ordering: the real reconciliation logic is exercised
# directly above, safely, against sandbox paths.
# code_lineno, not a bare grep -n: the comment above the call mentions
# reconcile_dns_type, and so does the comment left behind if the call is ever
# commented out, which is exactly how a reverted fix used to slip past this
# whole ordering check with the suite still green.
RCF_LOADS=$(code_lineno "$SCRIPT_DIR/reconfigure.sh" -E '^if ! load_env')
RCF_RECONCILES=$(code_lineno "$SCRIPT_DIR/reconfigure.sh" -E '^reconcile_dns_type && print_info')
RCF_PLABEL=$(code_lineno "$SCRIPT_DIR/reconfigure.sh" -E '^PLABEL=')
RCF_ORDER=no
if [ -n "$RCF_LOADS" ] && [ -n "$RCF_RECONCILES" ] && [ -n "$RCF_PLABEL" ] \
   && [ "$RCF_LOADS" -lt "$RCF_RECONCILES" ] && [ "$RCF_RECONCILES" -lt "$RCF_PLABEL" ]; then
    RCF_ORDER=yes
fi
assert_eq "reconfigure.sh reconciles right after loading, before anything reads DNS_TYPE" \
    "yes" "$RCF_ORDER"

# Anchored to the exact display line, not just a mention of the name
# somewhere in the file: a comment referencing running_protocol elsewhere
# would otherwise satisfy a bare `grep -q running_protocol` the same way a
# reverted fix (back to raw DNS_TYPE) would.
assert_true "status.sh's Protocol line reads the real running protocol" \
    code_grep "$SCRIPT_DIR/status.sh" -E \
    '^[[:space:]]*print_ok "Protocol: \$\(proto_label "\$\{_st_running\}"\)"'
# Anchored to the assignment as a statement, not to a mention of the name.
# status.sh's own comment two lines up names running_protocol, and so does the
# comment left behind by commenting the assignment out; with a bare grep,
# reverting _st_running to DNS_TYPE left the entire suite green.
assert_true "and that variable comes from running_protocol, not DNS_TYPE" \
    code_grep "$SCRIPT_DIR/status.sh" -E \
    '^[[:space:]]*_st_running="\$\(running_protocol\)"'
assert_false "status.sh still never writes to controld.env" \
    code_grep "$SCRIPT_DIR/status.sh" -E 'sed -i.*controld\.env|> */cfg/controld\.env'



describe "lib.sh bootstrap — a missing library must never fail silently"

# `.` is a POSIX special built-in: a failed one exits a non-interactive shell
# on the spot, so `. lib.sh 2>/dev/null || <fallback>` never reaches its
# fallback under the router's ash, or dash, and bash is the outlier that runs
# it. reconfigure.sh, benchmark.sh and uninstall.sh all bootstrapped that way,
# and with stderr discarded on top they produced no output whatsoever and exit 2
# when run from a directory with no lib.sh beside them. Their /cfg fallback,
# written for exactly that case, was unreachable. uninstall.sh is the one that
# mattered: the README teaches fetching a single script into /tmp, and doing
# that with the uninstaller removed nothing while looking like it had run.
#
# status.sh and audit.sh were left out of that fix and kept the bare dot, so
# they had no /cfg fallback at all: on a router they refused to run while their
# siblings worked. The first version of this assertion did not catch it. It
# asked only that the script "say something", which the shell's own "cannot
# open" satisfies, so it stayed green over two scripts that could not find an
# installed library.
#
# The second version went too far the other way and demanded the else branch's
# own message. That only holds where /cfg/lib.sh is absent. On a router, where
# it exists, the fallback succeeds and the script prints its usage instead, so
# all five assertions failed on exactly the machine the suite most needs to be
# green on. CONTRIBUTING.md asks for a run there, and it went red.
#
# Both outcomes are the script handling the situation: the fallback found the
# installed library and it ran, or nothing was found and it said so. A bare dot
# produces neither, in either environment, which is what makes this testable
# here and on a router.
BS_DIR="$TMPDIR/bootstrap"; rm -rf "$BS_DIR"; mkdir -p "$BS_DIR"
for _bs in reconfigure.sh benchmark.sh uninstall.sh status.sh audit.sh; do
    cp "$SCRIPT_DIR/$_bs" "$BS_DIR/$_bs"
    # --help exits before any of these touches the system, uninstall included.
    _bs_out="$(cd "$BS_DIR" && sh "./$_bs" --help 2>&1 || true)"
    rm -f "$BS_DIR/$_bs"
    _bs_ok=no
    case "$_bs_out" in
        *"lib.sh not found"*) _bs_ok=yes ;;   # else branch, no library anywhere
        *"Usage:"*)           _bs_ok=yes ;;   # /cfg fallback worked, script ran
    esac
    assert_eq "${_bs} handles a missing lib.sh rather than dying on the dot" \
        "yes" "$_bs_ok"
done

# The shape that caused it, not the wording of any one instance.
for _bs in reconfigure.sh benchmark.sh uninstall.sh status.sh audit.sh setup.sh; do
    assert_false "${_bs} does not bootstrap through a discarded failed dot" \
        code_grep "$SCRIPT_DIR/$_bs" -E '^[[:space:]]*\. .*lib\.sh" 2>/dev/null'
done

describe "reconfigure.sh --show — one field, one line"

# `$(pidof ctrld 2>/dev/null && echo 'yes (PID above)')` put the PID on stdout
# inside the substitution and then appended a second line, so printf's %s took
# both and the field wrapped mid-readout:
#     ctrld running:       6249
#     yes (PID above)
# Seen on a router while verifying something else. status.sh already does this
# correctly, capturing the PID then printing one line, so this matches it, and
# several PIDs render as "yes (PID 123 456)" in both.
#
# Source assertions: nothing in this suite runs reconfigure.sh as a subprocess,
# because it reads and writes the real /cfg paths and doing that on a router
# would overwrite a live install.
assert_true "the running-PID field is captured before it is printed" \
    code_grep "$SCRIPT_DIR/reconfigure.sh" -E \
    '^[[:space:]]*_rc_pid="\$\(pidof ctrld 2>/dev/null \|\| true\)"'
# The shape of the bug, not just the old wording: any substitution that runs
# pidof and chains a label onto it prints two lines into one field.
assert_false "no substitution prints the PID and a label together" \
    code_grep "$SCRIPT_DIR/reconfigure.sh" -E '\$\(pidof ctrld[^)]*&&'

describe "uninstall.sh — a full purge, not just file removal"

# Leaving force_dns set means https-dns-proxy keeps hijacking 53 and 853 after
# the app is gone: someone uninstalling to get their DNS back is still caught.
assert_true "uninstall disables forced DNS" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'disable_forced_dns'
# force_dns_port is not ours: see the dedicated section below. Uninstall must
# never delete it, and must say why it is still listed.
assert_false "uninstall does not delete the package port list" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'uci delete https-dns-proxy.config.force_dns_port'
assert_true "uninstall explains the port list it leaves behind" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'stock package default, inert with force_dns=0'
assert_true "uninstall removes the empty /etc/controld ctrld creates" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'rmdir /etc/controld'
assert_true "uninstall clears runtime state" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'controld-degraded'
assert_true "uninstall checks rc.local ownership" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'is_our_rc_local'
assert_true "uninstall restores a pre-install rc.local" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'rc.local.pre-controld'
assert_false "rc.local is not in the blind removal list" \
    code_grep "$SCRIPT_DIR/uninstall.sh" -E '^\s+/cfg/rc.local '
assert_true "setup backs up a foreign rc.local" \
    code_grep "$SCRIPT_DIR/setup.sh" 'rc.local.pre-controld'
# dnsmasq's servers are the firmware's, written from Alta's Use DoH. Writing the
# three https-dns-proxy ports back on uninstall turned Use DoH on again for
# dnsmasq, and starting https-dns-proxy unconditionally did the same for the
# service. restart_fallback carries the Use DoH rule and has its own tests.
assert_false "uninstall does not rewrite dnsmasq's servers" \
    code_grep "$SCRIPT_DIR/uninstall.sh" -E 'uci (add_list|delete|set) dhcp'
assert_false "or restart dnsmasq" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'init.d/dnsmasq'
assert_false "and never starts https-dns-proxy directly" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'init.d/https-dns-proxy'
assert_true "it restarts the fallback only through restart_fallback" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'restart_fallback'

# The redirect port is per-install (setup.sh moves off 5354 when it is taken),
# so uninstall must read controld.env before it removes anything. Without it,
# DNS_PORT was lib.sh's 5354 default and a moved install kept every redirect,
# pointing at a port with nothing behind it. A source assertion because the
# behaviour needs /cfg, uci and iptables; it checks ordering, not presence,
# since a load_env below the first use would be no better than none.
UNINST_LOADS=$(code_lineno "$SCRIPT_DIR/uninstall.sh" '^load_env')
UNINST_USES=$(code_lineno "$SCRIPT_DIR/uninstall.sh" 'remove_dns_redirects "')
UNINST_ORDER=no
if [ -n "$UNINST_LOADS" ] && [ -n "$UNINST_USES" ] && [ "$UNINST_LOADS" -lt "$UNINST_USES" ]; then
    UNINST_ORDER=yes
fi
assert_eq "uninstall loads the install's config before removing rules" "yes" "$UNINST_ORDER"
assert_false "uninstall does not hardcode the default port" \
    code_grep "$SCRIPT_DIR/uninstall.sh" -E 'grep -c "5354"|--to-ports 5354'

# The teardown must survive everything that runs after it.
#
# uninstall.sh removed the managed block, printed "rules will not return on
# reload", and then called disable_forced_dns, which sets FORCED_DNS=0 and
# calls ensure_firewall_user_rules, and that creates a block when none exists.
# So the block came back, holding twelve port-53 REDIRECTs aimed at a port
# nothing would listen on once ctrld was gone. Found on a router. The next
# firewall reload or reboot applies /etc/firewall.user, so it would have taken
# DNS down on every bridge, permanently, with nothing of this project left
# on the box to explain it.
#
# Every other uninstall assertion here is a source grep, which is why the suite
# could not see it: each function is correct on its own and the sequence is not.
# This one runs the real functions in the real order and looks at the file.
UF_DIR="$TMPDIR/uninstall-fw"
UF_BIN="$TMPDIR/uninstall-fw-bin"
mkdir -p "$UF_DIR" "$UF_BIN"
printf '#!/bin/sh\nexit 0\n' > "$UF_BIN/uci"
printf '#!/bin/sh\nexit 0\n' > "$UF_BIN/logger"
chmod +x "$UF_BIN/uci" "$UF_BIN/logger"

UF_FILE="$UF_DIR/firewall.user"
printf '%s\n' \
  '# a rule the user added themselves' \
  'iptables -t nat -A PREROUTING -i br-lan -p tcp --dport 8080 -j REDIRECT --to-port 80' \
  > "$UF_FILE"

UF_OUT="$(
    PATH="$UF_BIN:$PATH"
    . "$SCRIPT_DIR/lib.sh"
    FW_USER="$UF_FILE"
    LAN_IFACES="br-lan br-lan_10"
    DNS_PORT=5354
    FORCED_DNS=1
    del_redirect_rule() { :; }
    ensure_firewall_user_rules "$DNS_PORT" >/dev/null 2>&1
    # …and now the order uninstall.sh runs them in
    remove_block "$FW_USER" "$FW_MARKER"
    disable_forced_dns >/dev/null 2>&1
    cat "$FW_USER"
)"

assert_not_contains "no managed block survives the uninstall sequence" \
    "$UF_OUT" "controld-dns-redirect"
assert_not_contains "and no redirect to our port is left behind" \
    "$UF_OUT" "REDIRECT --to-port 5354"
assert_contains "the user's own unrelated rule is untouched" \
    "$UF_OUT" "dport 8080"

# Toggling forced DNS off on a *live* install must still keep the port-53
# rules persisted. That is what this call is for, and the guard above must not
# have broken it.
UF_LIVE="$(
    PATH="$UF_BIN:$PATH"
    . "$SCRIPT_DIR/lib.sh"
    FW_USER="$UF_FILE"
    LAN_IFACES="br-lan br-lan_10"
    DNS_PORT=5354
    FORCED_DNS=1
    del_redirect_rule() { :; }
    ensure_firewall_user_rules "$DNS_PORT" >/dev/null 2>&1
    disable_forced_dns >/dev/null 2>&1
    cat "$FW_USER"
)"
assert_contains     "a live install keeps its port-53 rules when 853 is turned off" \
    "$UF_LIVE" "dport 53 -j REDIRECT --to-port 5354"
assert_not_contains "and loses the port-853 rules" \
    "$UF_LIVE" "dport 853"
assert_contains     "the managed block is still there to hold them" \
    "$UF_LIVE" "controld-dns-redirect BEGIN"

# uninstall.sh must not announce the teardown before the last thing that can
# undo it. The check has to come after disable_forced_dns.
UF_FWCHECK=$(code_lineno "$SCRIPT_DIR/uninstall.sh" 'carries no redirect to port')
UF_DISABLE=$(code_lineno "$SCRIPT_DIR/uninstall.sh" '^    disable_forced_dns$')
UF_ORDER=no
if [ -n "$UF_FWCHECK" ] && [ -n "$UF_DISABLE" ] && [ "$UF_DISABLE" -lt "$UF_FWCHECK" ]; then
    UF_ORDER=yes
fi
assert_eq "uninstall verifies firewall.user after the last writer touches it" "yes" "$UF_ORDER"
# Anchored to a print statement: the comment explaining this bug quotes the old
# message, and a bare substring match found that instead of the code.
assert_false "and no longer promises a clean reload before checking" \
    grep -qE '^[[:space:]]*print_(ok|step) .*rules will not return on reload' \
    "$SCRIPT_DIR/uninstall.sh"

describe "cron_has() — must not confuse another service's job for ours"

# The router ships "* * * * * /usr/bin/wireguard_watchdog". Matching the bare
# word "watchdog" made rc.local skip reinstalling our job after every reboot.
CRONFIX="$TMPDIR/crontab.txt"
cat > "$CRONFIX" << 'CRONEOF'
0 3 * * * logrotate /etc/logrotate.conf
* * * * * /usr/bin/wireguard_watchdog
0 3 * * 1 /cfg/controld-update.sh
CRONEOF
assert_false "wireguard_watchdog is not our watchdog" cron_has /cfg/watchdog.sh "$CRONFIX"
assert_true  "our update job is found"                cron_has /cfg/controld-update.sh "$CRONFIX"
printf '%s\n' '*/5 * * * * /cfg/watchdog.sh' >> "$CRONFIX"
assert_true  "our watchdog is found once present"     cron_has /cfg/watchdog.sh "$CRONFIX"

# cron_remove must delete only our entry. "grep -v watchdog" took the router's
# wireguard_watchdog job with it, and nothing puts that back. Run the real
# function against a stub crontab and assert on what the crontab ends up as.
CRONBIN="$TMPDIR/cronbin"
mkdir -p "$CRONBIN"
cat > "$CRONBIN/crontab" << 'CRONSTUBEOF'
#!/bin/sh
# Minimal crontab over $CRON_STORE: -l lists, - replaces from stdin
case "${1:-}" in
    -l) cat "$CRON_STORE" 2>/dev/null ;;
    -)  cat > "${CRON_STORE}.t" && mv "${CRON_STORE}.t" "$CRON_STORE" ;;
    *)  exit 1 ;;
esac
CRONSTUBEOF
chmod +x "$CRONBIN/crontab"
CRON_STORE="$TMPDIR/crontab.store"; export CRON_STORE
cat > "$CRON_STORE" << 'CRONSTOREEOF'
0 3 * * * logrotate /etc/logrotate.conf
* * * * * /usr/bin/wireguard_watchdog
*/5 * * * * /cfg/watchdog.sh
0 3 * * 1 /cfg/controld-update.sh
CRONSTOREEOF

CRON_SAVED_PATH="$PATH"
PATH="$CRONBIN:$PATH"
cron_remove /cfg/watchdog.sh
cron_remove /cfg/controld-update.sh
CRON_LEFT="$(crontab -l)"
PATH="$CRON_SAVED_PATH"

assert_contains     "the router's own wireguard_watchdog survives" "$CRON_LEFT" "wireguard_watchdog"
assert_contains     "unrelated jobs survive"                       "$CRON_LEFT" "logrotate"
assert_not_contains "our watchdog job is gone"                     "$CRON_LEFT" "/cfg/watchdog.sh"
assert_not_contains "our update job is gone"                       "$CRON_LEFT" "/cfg/controld-update.sh"
unset CRON_STORE

# and no caller may go back to the loose match. Scoped to lines that touch the
# crontab, so status.sh grepping syslog for watchdog messages is not caught.
for _cs in setup.sh status.sh uninstall.sh reconfigure.sh audit.sh; do
    assert_eq "${_cs} matches cron jobs by script path, not the bare word" "" \
        "$(code_only "$SCRIPT_DIR/$_cs" \
           | grep 'crontab' | grep -E '(watchdog|controld-update)' | grep -v '/cfg/')"
done

describe "installed_dns_port() — a re-install must not reset a moved port"

# setup.sh never calls load_env, on purpose: it asks for the resolver ID and
# protocol rather than inheriting them. DNS_PORT was the one key that had to be
# inherited and was not, so it sat at lib.sh's 5354 for the whole run.
#
# The result on a re-install over a moved install: write_ctrld_config wrote
# port 5354 into ctrld.toml while write_env_file carried DNS_PORT=5355 forward,
# and the two files disagreed. The port-conflict step reconciles them only when
# 5354 is still taken, so once whatever held it had gone, nothing did.
IDP="$TMPDIR/idp.env"

printf 'RESOLVER_ID=abc123\nDNS_PORT=5355\n' > "$IDP"
assert_eq "a recorded port is adopted" "5355" "$(installed_dns_port "$IDP")"

printf 'RESOLVER_ID=abc123\n' > "$IDP"
assert_eq "an install with no recorded port gets the default" "5354" "$(installed_dns_port "$IDP")"
assert_eq "a fresh install with no env file gets the default" "5354" \
    "$(installed_dns_port "$TMPDIR/idp-nope.env")"

# A value that cannot be a port must not reach ctrld.toml or an iptables rule,
# where it fails later and further from the cause than it does here.
for _idp_bad in 'DNS_PORT=' 'DNS_PORT=abc' 'DNS_PORT=0' 'DNS_PORT=99999' 'DNS_PORT=53 54' 'DNS_PORT="abc"' 'DNS_PORT="0"'; do
    printf 'RESOLVER_ID=abc123\n%s\n' "$_idp_bad" > "$IDP"
    assert_eq "a port of '${_idp_bad#DNS_PORT=}' falls back to the default" "5354" \
        "$(installed_dns_port "$IDP")"
done
# The boundaries are valid, so they are adopted rather than rejected.
printf 'DNS_PORT=1\n' > "$IDP"
assert_eq "port 1 is a port" "1" "$(installed_dns_port "$IDP")"
printf 'DNS_PORT=65535\n' > "$IDP"
assert_eq "port 65535 is a port" "65535" "$(installed_dns_port "$IDP")"

# A fully quoted value is a shape the rest of the project honours:
# write_env_file's filter accepts it and carries it forward, and load_env
# sources it. Rejecting it here fell back to 5354 and recreated the very
# disagreement this function exists to prevent.
printf 'DNS_PORT="5355"\n' > "$IDP"
assert_eq "a quoted port is adopted, as load_env would" "5355" "$(installed_dns_port "$IDP")"
# And the project really does honour it, so the two agree rather than both
# being asserted against a literal.
assert_eq "installed_dns_port and load_env agree on a quoted port" \
    "$(installed_dns_port "$IDP")" \
    "$(sh -c '. "$1" >/dev/null 2>&1; printf "%s" "${DNS_PORT:-}"' _ "$IDP")"

# Leading zeros pass a numeric range check and are not a legal TOML integer, so
# they must not reach ctrld.toml: ctrld would refuse the config it was handed.
printf 'DNS_PORT=00005355\n' > "$IDP"
assert_eq "a port with leading zeros falls back to the default" "5354" \
    "$(installed_dns_port "$IDP")"

# A trailing comment is the shape the docs put on the neighbouring key, and the
# pattern this replaced required the value to end the line. So DNS_PORT read as
# 5354 while every sourcing reader on the same router said 5355, and that
# disagreement is what puts a port into ctrld.toml that nothing is listening on.
# Asserted against the shell rather than a literal, because agreeing with
# load_env is the property, not matching a number someone typed twice.
printf 'DNS_PORT=5355   # moved off the default\n' > "$IDP"
assert_eq "a commented port is adopted"  "5355" "$(installed_dns_port "$IDP")"
assert_eq "and it agrees with what the shell sets" \
    "$(installed_dns_port "$IDP")" \
    "$(sh -c '. "$1" >/dev/null 2>&1; printf "%s" "${DNS_PORT:-}"' _ "$IDP")"

# errexit is inherited into the subshell, and setup.sh calls this under set -e.
# A line that fails ahead of DNS_PORT aborted the read and handed back the
# default, which is the bug installed_auto_update had before its set +e.
printf 'false\nDNS_PORT=5355\n' > "$IDP"
assert_eq "a failing line ahead of the key does not lose it" "5355" \
    "$( set -e; installed_dns_port "$IDP" )"

# Nothing the file sets may escape into the caller, or reading the port would
# quietly adopt the protocol and resolver setup.sh is in the middle of asking
# for. That is the whole reason setup.sh cannot just call load_env.
printf 'DNS_PORT=5355\nDNS_TYPE=doq\nRESOLVER_ID=leaked\n' > "$IDP"
IDP_LEAK="$(installed_dns_port "$IDP"; printf ' DNS_TYPE=%s RESOLVER_ID=%s' "${DNS_TYPE:-unset}" "${RESOLVER_ID:-unset}")"
assert_not_contains "reading the port does not adopt the protocol" "$IDP_LEAK" "DNS_TYPE=doq"
assert_not_contains "and does not adopt the resolver"              "$IDP_LEAK" "RESOLVER_ID=leaked"

# An inherited DNS_PORT must not stand in for one the file does not set. A file
# that names the key hides this, because sourcing overwrites the inherited value
# either way; the case that needs the reset is a file with no DNS_PORT at all,
# where without it setup.sh would adopt whatever its own environment happened to
# carry and call it the installed port.
printf 'RESOLVER_ID=abc123\n' > "$IDP"
assert_eq "an inherited value is not mistaken for a recorded one" "5354" \
    "$( DNS_PORT=9999; installed_dns_port "$IDP" )"
printf 'DNS_PORT=5355\n' > "$IDP"
assert_eq "and the file still wins when it does name the key" "5355" \
    "$( DNS_PORT=9999; installed_dns_port "$IDP" )"

# The outcome that matters: after a re-install the two files must name the same
# port. write_env_file preserves the recorded one and write_ctrld_config takes
# whatever DNS_PORT holds, so adopting it first is what keeps them in step.
IDP_CFG="$TMPDIR/idp-cfg.env"
IDP_TOML="$TMPDIR/idp-cfg.toml"
cat > "$IDP_CFG" << 'IDPEOF'
RESOLVER_ID=old123
BOOTSTRAP_IP=76.76.2.22
CTRLD_VERSION=1.5.7
DNS_TYPE=doh3
PREFERRED_PROTOCOL=doh3
FORCED_DNS=0
DNS_PORT=5355
IDPEOF
IDP_SAVED="$DNS_PORT"
(
    RESOLVER_ID=new456; BOOTSTRAP_IP=76.76.2.22; CTRLD_VERSION=1.5.7
    DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3
    DNS_PORT="$(installed_dns_port "$IDP_CFG")"
    write_env_file "$IDP_CFG"
    write_ctrld_config "$IDP_TOML" new456 76.76.2.22 doh3
) >/dev/null 2>&1
DNS_PORT="$IDP_SAVED"
assert_eq "the config and the env file agree on the port after a re-install" \
    "$(sed -n 's/^DNS_PORT=//p' "$IDP_CFG")" \
    "$(sed -n 's/^[[:space:]]*port = //p' "$IDP_TOML")"
assert_file_contains "and it is the moved port, not the default" "$IDP_TOML" 'port = 5355'

# Ordering, the same way uninstall.sh's load_env is checked: a read below the
# first write would be no better than none. The end-to-end path needs a router,
# so this guards the one thing that can be checked here.
SETUP_READS=$(code_lineno "$SCRIPT_DIR/setup.sh" '^DNS_PORT="\$(installed_dns_port')
SETUP_WRITES=$(code_lineno "$SCRIPT_DIR/setup.sh" '^write_ctrld_config /cfg/ctrld.toml')
SETUP_ORDER=no
if [ -n "$SETUP_READS" ] && [ -n "$SETUP_WRITES" ] && [ "$SETUP_READS" -lt "$SETUP_WRITES" ]; then
    SETUP_ORDER=yes
fi
assert_eq "setup reads the installed port before it writes the config" "yes" "$SETUP_ORDER"

describe "preserved_forced_dns() — a re-install must not disable forced DNS"

mkdir -p "$TMPDIR/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMPDIR/bin/uci"   # uci says nothing / not present
chmod +x "$TMPDIR/bin/uci"
PATH="$TMPDIR/bin:$PATH"

printf 'FORCED_DNS=1\n' > "$TMPDIR/fd.env"
assert_eq "an enabled install stays enabled"  "1" "$(preserved_forced_dns "$TMPDIR/fd.env")"
printf 'FORCED_DNS=0\n' > "$TMPDIR/fd.env"
assert_eq "a disabled install stays disabled" "0" "$(preserved_forced_dns "$TMPDIR/fd.env")"
assert_eq "no env file means off"             "0" "$(preserved_forced_dns "$TMPDIR/none.env")"

# Installs predating the flag: uci is the only record that it is on
printf '#!/bin/sh\necho 1\n' > "$TMPDIR/bin/uci"
printf 'RESOLVER_ID=abc\n' > "$TMPDIR/fd-noflag.env"
assert_eq "falls back to live uci state"      "1" "$(preserved_forced_dns "$TMPDIR/fd-noflag.env")"
printf 'FORCED_DNS=0\n' > "$TMPDIR/fd.env"
assert_eq "uci on beats a stale 0 in the file" "1" "$(preserved_forced_dns "$TMPDIR/fd.env")"

# Back to uci saying nothing, which is a router whose /etc/config a firmware
# update has just wiped. That is the window the value is preserved in the file
# for, and the only one where the file is the sole record.
printf '#!/bin/sh\nexit 1\n' > "$TMPDIR/bin/uci"

# The shapes the shell honours and the old pattern did not. Each one read as
# off, and with uci unable to answer the rewrite then recorded off for someone
# who had turned it on. Asserted against the shell, because agreeing with
# load_env is the property rather than matching a literal typed twice.
for _pfd_on in 'FORCED_DNS="1"' 'FORCED_DNS=1  # leave this on' 'FORCED_DNS=1 '; do
    printf '%s\n' "$_pfd_on" > "$TMPDIR/fd.env"
    assert_eq "'${_pfd_on}' is read as on" "1" "$(preserved_forced_dns "$TMPDIR/fd.env")"
done
printf 'FORCED_DNS="1"\n' > "$TMPDIR/fd.env"
assert_eq "and a quoted flag agrees with what the shell sets" \
    "$(preserved_forced_dns "$TMPDIR/fd.env")" \
    "$(sh -c '. "$1" >/dev/null 2>&1; printf "%s" "${FORCED_DNS:-}"' _ "$TMPDIR/fd.env")"

# The end is anchored, so a value that only starts with 1 stops reading as 1.
# The shell sets FORCED_DNS=10, every consumer compares against 1 and treats it
# as off, and the unanchored pattern was the only thing calling it on.
# An unbalanced quote is in the list because making each quote independently
# optional accepted it, and a file carrying one cannot be sourced at all: the
# shell dies on the syntax error, so nothing downstream would see a 1 anyway.
for _pfd_bad in 'FORCED_DNS=10' 'FORCED_DNS=1x' 'FORCED_DNS="1' 'FORCED_DNS=1"' 'FORCED_DNS=on'; do
    printf '%s\n' "$_pfd_bad" > "$TMPDIR/fd.env"
    assert_eq "'${_pfd_bad}' does not read as on" "0" "$(preserved_forced_dns "$TMPDIR/fd.env")"
done

# A quoted 0 must still read as off rather than falling through to a uci that
# cannot answer, which would be the same bug pointing the other way.
printf 'FORCED_DNS="0"\n' > "$TMPDIR/fd.env"
assert_eq "a quoted 0 is read as off" "0" "$(preserved_forced_dns "$TMPDIR/fd.env")"

# The outcome, through the real writer: a rewrite must carry the flag rather
# than derive it from a uci that is not there.
PFD_RT="$TMPDIR/pfd-rt.env"
printf 'RESOLVER_ID=abc123\nFORCED_DNS="1"\n' > "$PFD_RT"
( RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22; CTRLD_VERSION=1.5.7
  DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3
  write_env_file "$PFD_RT" ) >/dev/null 2>&1
assert_file_contains "a rewrite keeps forced DNS on" "$PFD_RT" '^FORCED_DNS=1$'

# setup.sh must actually preserve it. This fix was once described in a commit
# before it was in the diff, and no test noticed. The assertion that replaced
# that gap checked for the literal `FORCED_DNS=$(preserved_forced_dns ...)`
# inside setup.sh's here-doc, and passed for months while that exact line read
# an already-truncated file. Both are now covered by running the real writer
# against a real file, in "write_env_file()" below.

describe "force_dns_port — a package default, not ours to delete"

# 53 and 853 are the ports https-dns-proxy ships in its own /etc/config, and the
# same pair is the init script's fallback when the option is absent. Deleting
# them on uninstall removed a vendor default and did not stick either, since the
# Route 10 wrote the option back on the next boot. Three fixes chased that
# before anyone read the package, each guarded by a test that asserted where
# the delete sat in the file rather than what the router ended up with. These
# run the real functions against a fake uci and assert on the resulting state.
FD_SAVED_PATH="$PATH"
mkdir -p "$TMPDIR/ucibin"
cat > "$TMPDIR/ucibin/uci" << 'UCIEOF'
#!/bin/sh
# Minimal stateful uci: get/set/add_list/delete/commit over $UCI_STORE
store="$UCI_STORE"
[ -f "$store" ] || : > "$store"
[ "$1" = "-q" ] && shift
cmd="$1"; shift
arg="${1:-}"
key="${arg%%=*}"
val=""
case "$arg" in *=*) val="${arg#*=}" ;; esac
# Keys carry regex-special characters (https-dns-proxy.@https-dns-proxy[0]),
# so match them literally with awk's index() rather than as patterns.
_get() { awk -v k="$1" 'index($0, k " ") == 1 { print substr($0, length(k) + 2); exit }' "$store"; }
_del() { awk -v k="$1" 'index($0, k " ") != 1' "$store" > "$store.t"; mv "$store.t" "$store"; }
_put() { _del "$1"; printf '%s %s\n' "$1" "$2" >> "$store"; }
case "$cmd" in
    get)      v="$(_get "$key")"; [ -n "$v" ] || exit 1; printf '%s\n' "$v" ;;
    set)      _put "$key" "$val" ;;
    add_list) v="$(_get "$key")"; _put "$key" "${v:+$v }$val" ;;
    delete)   _del "$key" ;;
    commit)   : ;;
    *)        exit 1 ;;
esac
exit 0
UCIEOF
chmod +x "$TMPDIR/ucibin/uci"
printf '#!/bin/sh\nexit 0\n' > "$TMPDIR/ucibin/iptables"
chmod +x "$TMPDIR/ucibin/iptables"
PATH="$TMPDIR/ucibin:$PATH"
UCI_STORE="$TMPDIR/uci.store"; export UCI_STORE
FW_USER="$TMPDIR/fd-firewall.user"
SYSFS_NET="$FAKE_NET"
DNS_PORT=5354

# A router with forced DNS on and the stock port list
: > "$UCI_STORE"
uci set https-dns-proxy.config.force_dns=1
uci add_list https-dns-proxy.config.force_dns_port=53
uci add_list https-dns-proxy.config.force_dns_port=853
: > "$FW_USER"
disable_forced_dns >/dev/null 2>&1 || true

assert_eq "disable turns the hijack off" "0" \
    "$(uci -q get https-dns-proxy.config.force_dns)"
assert_eq "disable leaves the package port list alone" "53 853" \
    "$(uci -q get https-dns-proxy.config.force_dns_port)"

# A trimmed list plus a port someone added deliberately. 8530 also catches the
# substring bug: a naive *853* match sees it and never adds the DoT port.
: > "$UCI_STORE"
uci set https-dns-proxy.config.force_dns=0
uci add_list https-dns-proxy.config.force_dns_port=53
uci add_list https-dns-proxy.config.force_dns_port=8530
: > "$FW_USER"
FORCED_DNS=1
ensure_forced_dns >/dev/null 2>&1 || true

assert_eq "enable turns the hijack on" "1" \
    "$(uci -q get https-dns-proxy.config.force_dns)"
assert_eq "enable adds only the missing port, keeping the rest" "53 8530 853" \
    "$(uci -q get https-dns-proxy.config.force_dns_port)"

ensure_forced_dns >/dev/null 2>&1 || true
assert_eq "a second enable adds no duplicates" "53 8530 853" \
    "$(uci -q get https-dns-proxy.config.force_dns_port)"

# Use DoH, as the firmware leaves it in dnsmasq's servers. Enabling forced DNS
# restarted https-dns-proxy unconditionally, and on 1.5h that is a start, so it
# overrode DoH off on every boot and every settings save.
: > "$UCI_STORE"
uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#5053'
assert_true "alta_doh_on reads a local https-dns-proxy port as DoH on" alta_doh_on
: > "$UCI_STORE"
uci add_list 'dhcp.@dnsmasq[0].server=75.153.171.68#53'
uci add_list 'dhcp.@dnsmasq[0].server=75.153.171.124#53'
assert_false "and the ISP's servers alone as DoH off" alta_doh_on
assert_false "restart_fallback does nothing while DoH is off" restart_fallback
: > "$UCI_STORE"
assert_false "no servers at all reads as off" alta_doh_on

PATH="$FD_SAVED_PATH"
unset UCI_STORE FW_USER SYSFS_NET DNS_PORT FORCED_DNS
assert_false "setup.sh never hardcodes FORCED_DNS=0" \
    code_grep "$SCRIPT_DIR/setup.sh" '^FORCED_DNS=0$'

describe "version split — tools version vs pinned ctrld"

assert_match "VERSION is semver"    "$VERSION"    '^[0-9]+\.[0-9]+\.[0-9]+$'
assert_match "CTRLD_PIN is semver"  "$CTRLD_PIN"  '^[0-9]+\.[0-9]+\.[0-9]+$'
# These moved together once, and bumping the tools version silently repointed
# setup.sh at a ctrld release that does not exist.
assert_false "the two versions are not the same variable" [ "$VERSION" = "$CTRLD_PIN" ]
assert_true  "download URLs use the pin, not the tools version" \
    code_grep "$SCRIPT_DIR/setup.sh" 'releases/download/v${CTRLD_PIN}'
assert_false "no download URL is built from VERSION" \
    code_grep "$SCRIPT_DIR/setup.sh" 'releases/download/v${VERSION}'

describe "checksum_for_asset() — release verification"

SUMS="$(printf '%s\n' \
    "3f02b8ea9665b1b0f74f4abdcb60148d249804afd604ae5fad84ad9fb3ee2e81  ctrld_1.5.7_linux_amd64.tar.gz" \
    "f3247d562055b3dad62231ec4d7517970a6e89caf4753e7a5854e52162246d38  ctrld_1.5.7_linux_arm64.tar.gz")"
assert_eq "picks the arm64 sum" \
    "f3247d562055b3dad62231ec4d7517970a6e89caf4753e7a5854e52162246d38" \
    "$(checksum_for_asset "$SUMS" ctrld_1.5.7_linux_arm64.tar.gz)"
assert_eq "picks the amd64 sum" \
    "3f02b8ea9665b1b0f74f4abdcb60148d249804afd604ae5fad84ad9fb3ee2e81" \
    "$(checksum_for_asset "$SUMS" ctrld_1.5.7_linux_amd64.tar.gz)"
assert_eq "unknown asset yields nothing" "" \
    "$(checksum_for_asset "$SUMS" ctrld_9.9.9_linux_arm64.tar.gz)"
# A filename that is a prefix of another must not match it
assert_eq "no partial-name match" "" \
    "$(checksum_for_asset "$SUMS" ctrld_1.5.7_linux_arm.tar.gz)"
assert_eq "unverifiable download reports 2, not 0" "2" \
    "$(rc=0; verify_ctrld_download "$TMPDIR/no-such-file" asset 1.5.7 || rc=$?; echo $rc)"

describe "retarget_upstreams() — protocol switch keeps each resolver"

RT="$TMPDIR/retarget.toml"
cat > "$RT" << 'RTEOF'
[upstream.0]
    endpoint = "https://dns.controld.com/main1234"
    name = "ControlD"
    type = "doh3"
[upstream.1]
    endpoint = "https://dns.controld.com/kids5678"
    name = "ControlD-Kids"
    type = "doh3"
[upstream.2]
    endpoint = "https://dns.quad9.net/dns-query"
    name = "Quad9"
    type = "doh"
[listener.0.policy]
    networks = [
    {"network.1" = ["upstream.1"]}
    ]
RTEOF
retarget_upstreams "$RT" doq

# The bug this replaces: an unanchored sed rewrote every endpoint to the main
# resolver, silently moving a split-DNS profile onto the default profile.
assert_file_contains "main upstream switched to DoQ form"  "$RT" 'endpoint = "main1234.dns.controld.com"'
assert_file_contains "policy upstream keeps its own resolver" "$RT" 'endpoint = "kids5678.dns.controld.com"'
assert_eq "the two resolvers stay distinct" "2" \
    "$(grep -c 'dns.controld.com' "$RT" | tr -d ' ')"
assert_false "kids resolver was not replaced by the main one" \
    grep -q 'main1234.dns.controld.com.*kids\|kids5678.*main1234' "$RT"
assert_eq "no upstream still points at the old main endpoint" "0" \
    "$(grep -c 'dns.controld.com/main1234' "$RT" | tr -d ' ')"
assert_file_contains "non-ControlD upstream untouched" "$RT" 'endpoint = "https://dns.quad9.net/dns-query"'
assert_file_contains "and keeps its own protocol"      "$RT" 'type = "doh"'
assert_eq "both ControlD upstreams retyped" "2" "$(grep -c 'type = "doq"' "$RT" | tr -d ' ')"
assert_file_contains "policy table survives the rewrite" "$RT" 'network.1" = \["upstream.1"\]'

# Round-trip back, and the original endpoints must come back exactly
retarget_upstreams "$RT" doh3
assert_file_contains "round-trips to the DoH form"        "$RT" 'endpoint = "https://dns.controld.com/main1234"'
assert_file_contains "policy resolver round-trips too"    "$RT" 'endpoint = "https://dns.controld.com/kids5678"'

describe "lib.sh carries no dead code"

# check_port_in_use and proto_port were each defined, documented in a Usage
# comment, and never called from anywhere: setup.sh carried its own private
# _port_in_use rather than using the shared one. A library function with no
# caller still has to be read and maintained, and reads as available API.
#
# Every function must be referenced somewhere beyond its own definition and
# Usage comment: another script, a doc, or a test.
# The file list is built from globs, using no external tool at all: BusyBox
# grep has no --include, so `grep -r --include` failed on every real router
# while passing in CI, and CONTRIBUTING.md documents running this suite on the
# router, from a copy of the repo at /tmp/controld. find would work but is one more implementation to depend on.
LIB_SCAN=""
for _lp in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.md "$SCRIPT_DIR"/docs/*.md \
           "$SCRIPT_DIR"/config/*.example; do
    [ -f "$_lp" ] && LIB_SCAN="${LIB_SCAN} ${_lp}"
done
LIB_DEAD=""
for _fn in $(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$SCRIPT_DIR/lib.sh" | tr -d '()'); do
    # </dev/null matters: with an empty file list grep falls back to standard
    # input and blocks forever, hanging the whole suite instead of failing.
    # shellcheck disable=SC2086  # the file list must word-split
    _refs=$(grep -hoE "\b${_fn}\b" $LIB_SCAN </dev/null 2>/dev/null | wc -l)
    # The one scan that must keep reading comments: a function's own "# Usage:"
    # line is deliberately counted as a self-reference, so code_only here would
    # make every documented function look like it had one caller too many.
    _self=$(grep -cE "^${_fn}\(\)|^# Usage: ${_fn}\b" "$SCRIPT_DIR/lib.sh")
    [ "$((_refs - _self))" -gt 0 ] || LIB_DEAD="${LIB_DEAD} ${_fn}"
done
assert_eq "every lib.sh function has a caller" "" "$LIB_DEAD"

describe "log_lines() — logread is not available on every router"

# logread reads the shared-memory ring buffer that syslogd -C creates. The
# Route 10 runs `syslogd -n -b 2 -t -u`, with no -C, so logread fails outright
# and every logger call this project makes appeared lost. They are not: syslogd
# defaults to a file. status.sh printed no watchdog section at all there, with
# nothing to say it had looked.
LL_DIR="$TMPDIR/logs"; mkdir -p "$LL_DIR"
printf 'Sep 4 12:00 h watchdog: added DNS redirect rules\nSep 4 12:05 h watchdog: ctrld will not start\nSep 4 12:06 h other: noise\n' > "$LL_DIR/messages"
LL_BIN="$TMPDIR/logbin"; mkdir -p "$LL_BIN"

# A router where logread cannot work
printf '#!/bin/sh\necho "logread: can%s find syslogd buffer" >&2\nexit 1\n' "'t" > "$LL_BIN/logread"
chmod +x "$LL_BIN/logread"
LL_OUT="$(PATH="$LL_BIN:$PATH" LOG_FILES="$LL_DIR/messages" sh -c ". '$SCRIPT_DIR/lib.sh'; log_lines watchdog 5")"
assert_contains "falls back to the syslog file"   "$LL_OUT" "added DNS redirect rules"
assert_contains "and finds the F-01 log line"     "$LL_OUT" "ctrld will not start"
assert_not_contains "the pattern still filters"   "$LL_OUT" "noise"
assert_eq "the count is honoured" "1" \
    "$(PATH="$LL_BIN:$PATH" LOG_FILES="$LL_DIR/messages" sh -c ". '$SCRIPT_DIR/lib.sh'; log_lines watchdog 1" | wc -l | tr -d ' ')"

# A router where it does work: logread wins, the file is not consulted
printf '#!/bin/sh\necho "Sep 4 13:00 h watchdog: from the ring buffer"\n' > "$LL_BIN/logread"
chmod +x "$LL_BIN/logread"
LL_OUT2="$(PATH="$LL_BIN:$PATH" LOG_FILES="$LL_DIR/messages" sh -c ". '$SCRIPT_DIR/lib.sh'; log_lines watchdog 5")"
assert_contains     "logread is preferred when it works" "$LL_OUT2" "from the ring buffer"
assert_not_contains "and the file is not read as well"   "$LL_OUT2" "added DNS redirect rules"

# Neither source available
assert_false "reports failure when there is no log at all" \
    sh -c "PATH='$LL_BIN:\$PATH' LOG_FILES='$TMPDIR/no-such-log' sh -c \". '$SCRIPT_DIR/lib.sh'; logread() { return 1; }; log_lines watchdog\""

# An actual invocation, command substitution or a pipe, not the word. The
# comment above the call and the "checked logread and ..." message both name it
# on purpose, and matching those would fail for the wrong reason.
assert_eq "status.sh does not invoke logread itself" "" \
    "$(code_only "$SCRIPT_DIR/status.sh" \
       | grep -E '\$\(logread|logread[[:space:]]*\||^[[:space:]]*logread' || true)"
assert_true  "status.sh goes through the helper" \
    code_grep "$SCRIPT_DIR/status.sh" 'log_lines '

# A rotated syslog must not blank the section. syslogd -b N moves the live file
# to <file>.0 and starts a new one, so on a router that logs steadily the event
# you are looking for can be in .0 minutes after it happened. Reading only the
# live file showed "no entries found" with the history sitting right next to it
# and docs/troubleshooting.md already claimed status.sh handled these files.
LR_DIR="$TMPDIR/log-rotate"
mkdir -p "$LR_DIR"
printf 'Sep 4 10:00 h watchdog: oldest, in messages.1\n' > "$LR_DIR/messages.1"
printf 'Sep 4 11:00 h watchdog: rotated, in messages.0\n' > "$LR_DIR/messages.0"
printf 'Sep 4 12:00 h watchdog: live, in messages\n'      > "$LR_DIR/messages"

LR_OUT="$(LOG_FILES="$LR_DIR/messages" log_lines watchdog 10)"
assert_contains "the live file is still read"        "$LR_OUT" "live, in messages"
assert_contains "and the most recent rotated file"   "$LR_OUT" "rotated, in messages.0"
assert_contains "and the one before that"            "$LR_OUT" "oldest, in messages.1"
assert_eq       "all three lines, none duplicated"   "3" "$(printf '%s\n' "$LR_OUT" | grep -c . | tr -d ' ')"
assert_eq       "oldest first, so tail keeps the newest" "live, in messages" \
    "$(printf '%s\n' "$LR_OUT" | tail -1 | sed 's/.*watchdog: //')"

# An event only in the rotated file must still be found, the case the router
# hit on hardware.
rm -f "$LR_DIR/messages.0" "$LR_DIR/messages.1"
printf 'Sep 4 11:00 h watchdog: added DNS redirect rules\n' > "$LR_DIR/messages.0"
printf 'Sep 5 00:00 h crond: something else entirely\n'     > "$LR_DIR/messages"
LR_OUT2="$(LOG_FILES="$LR_DIR/messages" log_lines watchdog 10 || true)"
assert_contains "an event that has already rotated is still reported" \
    "$LR_OUT2" "added DNS redirect rules"

# Every tag this project logs under must be covered by status.sh's activity
# filter. forced-dns and controld were not, so the lines a restore cycle emits,
# the port-853 rules and the firewall.user rewrite, were invisible under a
# heading that claims to show our activity. Derived from the sources rather than
# hardcoded, so a tag added later cannot go missing the same way.
SL_PAT="$(sed -n "s/.*log_lines '\([^']*\)'.*/\1/p" "$SCRIPT_DIR/status.sh")"
assert_true "status.sh has an activity filter to check" test -n "$SL_PAT"
for _sl_tag in $(for _sl_f in "$SCRIPT_DIR"/*.sh; do code_only "$_sl_f"; done \
                 | grep -o 'logger -t [A-Za-z0-9._-]*' \
                 | sed 's/logger -t //' | sort -u); do
    if printf ' %s: message body\n' "$_sl_tag" | grep -qE "$SL_PAT"; then
        _sl_hit=yes
    else
        _sl_hit=no
    fi
    assert_eq "the activity filter covers our '${_sl_tag}' tag" "yes" "$_sl_hit"
done

# And still not another service's. These are the lines that made 92e5dec
# necessary; widening the tag list must not have let them back in.
for _sl_bad in 'Sep 4 12:00 h user.notice wireguard_watchdog: peer down' \
               'Sep 4 12:00 h cron.info crond: USER root pid 123 cmd /cfg/watchdog.sh' \
               'Sep 4 12:00 h daemon.info ctrld: [INFO] serving' ; do
    if printf '%s\n' "$_sl_bad" | grep -qE "$SL_PAT"; then _sl_hit=yes; else _sl_hit=no; fi
    assert_eq "another service's line is still excluded: $(printf '%s' "$_sl_bad" | sed 's/.* \([a-z_]*\):.*/\1/')" \
        "no" "$_sl_hit"
done

describe "audit.sh — report our own artifacts as ours"

# ctrld.prev is the updater's rollback copy and the README documents it, but it
# fell through to the "not installed by this project" arm. It, ctrld.toml.bak
# and rc.local.pre-controld were also absent from the manifest, so each was
# reported twice: once as a known leftover, again as unexpected in /cfg.
# The arm itself, not its wording: matching the message text passes even if the
# case label is changed to something else entirely.
assert_true "ctrld.prev has its own case arm" \
    code_grep "$SCRIPT_DIR/audit.sh" -E '^\s*/cfg/ctrld\.prev\)'
for _ak in ctrld.prev ctrld.toml.bak rc.local.pre-controld; do
    assert_true "${_ak} is on the manifest" \
        code_grep "$SCRIPT_DIR/audit.sh" "^KNOWN=.* ${_ak} "
done
# FORCED_DNS in controld.env is the source of truth (3bc68c3); uci is restored
# from it. Reading uci alone reported correct port-853 rules as drift in the
# window after a firmware update wiped /etc/config.
# audit.sh runs off-device, so this is an outcome test: with uci stubbed to
# report forced DNS off, an inherited FORCED_DNS=1 must still win.
#
# Both cases run against a sandboxed /cfg, because both are about what
# controld.env says and audit.sh reads that file through load_env. Driven from
# the environment, the first assertion failed outright on any router whose
# controld.env carries FORCED_DNS=0, which is every install that has not turned
# forced DNS on, and the second was skipped on every install that has. So the
# on-router run that CONTRIBUTING.md prescribes reported a failure this suite
# could not see anywhere else, on master as much as here.
AU_BIN="$TMPDIR/auditbin"; mkdir -p "$AU_BIN"
printf '#!/bin/sh\necho 0\n' > "$AU_BIN/uci"; chmod +x "$AU_BIN/uci"
# uci alone left audit.sh making real iptables and crontab calls against the
# host, which on a router is the live nat table and the live crontab. Read-only
# there, but it makes this the fixture most likely to go red for reasons that
# have nothing to do with the code under test.
for _austub in iptables ip nslookup logread pidof netstat crontab; do
    printf '#!/bin/sh\nexit 1\n' > "$AU_BIN/$_austub"; chmod +x "$AU_BIN/$_austub"
done
AU_FW="$TMPDIR/au-fw.user"
printf '# controld-dns-redirect BEGIN\n# controld-dns-redirect END\n' > "$AU_FW"
AU_CFG="$TMPDIR/au-cfg"; mkdir -p "$AU_CFG"
for _aus in audit.sh lib.sh; do
    sed -e "s|/cfg/|${AU_CFG}/|g" "$SCRIPT_DIR/$_aus" > "$AU_CFG/$_aus"
done
chmod +x "$AU_CFG/audit.sh"
au_run() {   # $1 = the FORCED_DNS line, or empty for none
    { printf 'RESOLVER_ID=abc123\nCTRLD_VERSION=1.5.7\nDNS_TYPE=doh3\n'
      [ -z "$1" ] || printf '%s\n' "$1"
    } > "$AU_CFG/controld.env"
    ( PATH="$AU_BIN:$PATH"; FW_USER="$AU_FW" sh "$AU_CFG/audit.sh" ) 2>/dev/null || true
}
assert_contains "the env flag wins over live uci" "$(au_run 'FORCED_DNS=1')" "forced DNS 1"
assert_contains "and uci is the fallback when the flag is unset" \
    "$(au_run '')" "forced DNS 0"

describe "bench_domain() — the benchmark must query real hostnames"

# setup.sh's copy read: awk "{print \$(((_bi - 1) % 5 + 1))}". _bi is a shell
# variable and awk never saw it, so awk evaluated an uninitialised zero, the
# expression came out as $0, and every query looked up all five domains joined
# by spaces as a single hostname. All ten failed, every protocol reported
# FAILED (0/10), and setup fell through to "All protocols failed benchmark.
# Defaulting to DoH3." The menu option never once produced a result.
assert_eq "the first domain"  "google.com"     "$(bench_domain 1)"
assert_eq "the second"        "cloudflare.com" "$(bench_domain 2)"
assert_eq "the fifth"         "github.com"     "$(bench_domain 5)"
assert_eq "wraps to the first" "google.com"    "$(bench_domain 6)"
assert_eq "and keeps wrapping" "cloudflare.com" "$(bench_domain 7)"
assert_eq "past thirty, where the old loop stopped" "google.com" "$(bench_domain 31)"

# One hostname per query, never the whole list.
BD_ALL=""
BD_I=1
while [ "$BD_I" -le 12 ]; do
    BD_ALL="${BD_ALL} $(bench_domain "$BD_I")"
    BD_I=$((BD_I + 1))
done
# Count words per individual call. The previous form shelled out to `sh -c`
# with an unexported variable, so the child grepped empty input and the
# assertion passed even against the original all-five-domains bug.
BD_WORST=0
BD_I=1
while [ "$BD_I" -le 12 ]; do
    BD_W=$(bench_domain "$BD_I" | wc -w | tr -d ' ')
    [ "$BD_W" -le "$BD_WORST" ] || BD_WORST="$BD_W"
    BD_I=$((BD_I + 1))
done
assert_eq "every query gets exactly one hostname" "1" "$BD_WORST"
assert_eq "twelve queries yield twelve names" "12" "$(printf '%s' "$BD_ALL" | wc -w | tr -d ' ')"

describe "the benchmark must measure every protocol that can be running"

# benchmark.sh names the running protocol at the top, measures a set, and
# recommends the fastest row. If the running protocol is not one of the rows,
# "switch to X" is advice against a number that was never taken, and it reads
# exactly like advice against one that was.
#
# This asserted the set by reading PROTOCOLS and the two `for` lines out of the
# sources, which an independent review defeated in one edit: point the loop at
# a literal list, leave the declaration alone, and every assertion still passed
# while neither script measured DoT. A declaration is not behaviour.
#
# bench_protocol is the only part that needs a ctrld binary and a network, so
# stubbing just that runs the real loop against a sandbox, the way the watchdog
# is already exercised. What is asserted is which protocols were probed.
BM_DIR="$TMPDIR/benchset"
mkdir -p "$BM_DIR"
cp "$SCRIPT_DIR/benchmark.sh" "$BM_DIR/benchmark.sh"
BENCH_LOG="$BM_DIR/probed.log"; export BENCH_LOG
cat > "$BM_DIR/lib.sh" << BMLIBEOF
. "$SCRIPT_DIR/lib.sh"
load_env() { RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22; DNS_TYPE=doh3; CTRLD_VERSION=1.5.7; return 0; }
running_protocol() { printf 'doh3'; }
bench_protocol() { echo "PROBED:\$1" >> "\$BENCH_LOG"; BENCH_AVG=10; BENCH_OK="\$4"; BENCH_FAIL=0; return 0; }
BMLIBEOF

: > "$BENCH_LOG"
( cd "$BM_DIR" && sh ./benchmark.sh --queries 1 ) >/dev/null 2>&1 </dev/null || true
BM_PROBED="$(cat "$BENCH_LOG" 2>/dev/null)"
for _bp in doh3 doq doh dot; do
    assert_contains "benchmark.sh actually probes ${_bp}" "$BM_PROBED" "PROBED:${_bp}$"
done
assert_eq "and probes nothing else" "4" "$(printf '%s\n' "$BM_PROBED" | grep -c 'PROBED:')"
# Every protocol it probes must be one this project can actually run.
printf '%s\n' "$BM_PROBED" | sed 's/^PROBED://' | while read -r _bp; do
    [ -n "$_bp" ] || continue
    valid_proto "$_bp" || printf 'INVALID:%s\n' "$_bp" >> "$BENCH_LOG.bad"
done
assert_false "benchmark.sh probes nothing this project would refuse to run" \
    test -e "$BENCH_LOG.bad"

# reconfigure.sh --benchmark applies its winner, so measuring fewer would let
# it move someone off DoT without ever having timed DoT. Its loop is a function,
# so it extracts and runs against the same stubs. DNS_TYPE is the winner here,
# which returns before anything is applied.
RB_SRC="$(code_only "$SCRIPT_DIR/reconfigure.sh" | sed -n '/^do_benchmark() {/,/^}$/p')"
assert_true "reconfigure.sh's benchmark extracts" test -n "$RB_SRC"
: > "$BENCH_LOG"
(
    . "$SCRIPT_DIR/lib.sh"
    RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22; DNS_TYPE=doh3; FORCE=0
    # The running protocol wins, so do_benchmark reports "already fastest" and
    # returns before the confirm prompt. Otherwise it blocks on read, and the
    # suite hangs rather than failing, which is worse than either outcome.
    bench_protocol() {
        echo "PROBED:$1" >> "$BENCH_LOG"
        case "$1" in doh3) BENCH_AVG=5 ;; *) BENCH_AVG=10 ;; esac
        BENCH_OK=1; BENCH_FAIL=0; return 0
    }
    eval "$RB_SRC"
    do_benchmark
) >/dev/null 2>&1 </dev/null || true
RB_PROBED="$(cat "$BENCH_LOG" 2>/dev/null)"
for _bp in doh3 doq doh dot; do
    assert_contains "reconfigure.sh --benchmark actually probes ${_bp}" "$RB_PROBED" "PROBED:${_bp}$"
done

# setup.sh's inline benchmark measures the same four, because its menu now
# offers the same four. The two sets have to stay equal in both directions: a
# protocol benchmarked but not listed is one the installer could hand someone
# who never saw it, and a protocol listed but not benchmarked is one "pick the
# fastest" can never pick.
SSET="$(code_only "$SCRIPT_DIR/setup.sh" | sed -n 's/^[[:space:]]*for BPROTO in \(.*\); do$/\1/p' | head -1)"
assert_eq "the installer benchmarks the same four as everything else" "doq doh3 doh dot" "$SSET"

# And the README's copy of that menu has to list the same protocols. It said
# option 4 tested "all protocols" while the installer tested three, which reads
# as a promise that a DoT install is one menu choice away. Compared as sets, so
# neither the menu's order nor the README's wording is pinned.
SMENU="$(code_only "$SCRIPT_DIR/setup.sh" \
    | sed -n '/read -r PROTO_CHOICE/,/^[[:space:]]*esac/p' \
    | sed -n 's/^[[:space:]]*[0-9])[[:space:]]*DNS_TYPE="\([a-z0-9]*\)".*/\1/p' \
    | sort -u | tr '\n' ' ')"
RMENU="$(sed -n '/^#### Guided Protocol Selection/,/^Option 5 runs/p' "$SCRIPT_DIR/README.md" \
    | sed -n 's/^[[:space:]]*[0-9])[[:space:]]*\(Do[A-Za-z0-9]*\).*/\1/p' \
    | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')"
assert_eq "the README's menu lists what the installer offers" "$SMENU" "$RMENU"

describe "a benchmark table must name one winner, not one per row"

# Rows print as each protocol finishes, so at the time a row is written the
# most that is known is the best so far. All three benchmarks marked that
# "<-- fastest", which is correct only if every later protocol is slower: on a
# run whose times improve, every row claimed to be the fastest one. A
# four-protocol table could say it three times, and the reader has no way to
# tell which claim was the surviving one.
#
# Times descend here in probe order, which is the case that produced it. The
# real bench_protocol is the only part needing ctrld and a network, so stubbing
# just that runs the real loop and asserts what a user would read.
BW_DIR="$TMPDIR/benchwin"
mkdir -p "$BW_DIR"
cp "$SCRIPT_DIR/benchmark.sh" "$BW_DIR/benchmark.sh"
cat > "$BW_DIR/lib.sh" << BWLIBEOF
. "$SCRIPT_DIR/lib.sh"
load_env() { RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22; DNS_TYPE=doh3; CTRLD_VERSION=1.5.7; return 0; }
running_protocol() { printf 'doh3'; }
# Probe order is doq doh3 doh dot, so every protocol beats the one before it.
bench_protocol() {
    case "\$1" in doq) BENCH_AVG=40 ;; doh3) BENCH_AVG=30 ;; doh) BENCH_AVG=20 ;; *) BENCH_AVG=10 ;; esac
    BENCH_OK="\$4"; BENCH_FAIL=0; return 0
}
BWLIBEOF

BW_OUT="$( cd "$BW_DIR" && sh ./benchmark.sh --queries 1 2>&1 </dev/null || true )"

assert_eq "no row of an improving run claims to be the fastest" "0" \
    "$(printf '%s\n' "$BW_OUT" | grep -c -e '<--' || true)"
assert_contains "the winner is named once, under the table" "$BW_OUT" \
    "Recommended: DoT (TLS)"
assert_contains "with the time that won" "$BW_OUT" "10ms avg"
# Every measured protocol is still in the table, marker or not.
for _bw in 40 30 20 10; do
    assert_contains "the ${_bw}ms row is still printed" "$BW_OUT" "${_bw}ms"
done

# reconfigure.sh --benchmark has the same table. DNS_TYPE is the winner, so it
# reports "already fastest" and returns before the confirm prompt: otherwise it
# blocks on read and the suite hangs rather than failing, which is worse than
# either outcome.
RW_SRC="$(code_only "$SCRIPT_DIR/reconfigure.sh" | sed -n '/^do_benchmark() {/,/^}$/p')"
RW_OUT="$( (
    . "$SCRIPT_DIR/lib.sh"
    RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22; DNS_TYPE="dot"; FORCE=0
    bench_protocol() {
        case "$1" in doq) BENCH_AVG=40 ;; doh3) BENCH_AVG=30 ;; doh) BENCH_AVG=20 ;; *) BENCH_AVG=10 ;; esac
        BENCH_OK=1; BENCH_FAIL=0; return 0
    }
    eval "$RW_SRC"
    do_benchmark
) 2>&1 </dev/null || true )"
assert_eq "reconfigure.sh marks no row either" "0" \
    "$(printf '%s\n' "$RW_OUT" | grep -c -e '<--' || true)"
assert_contains "and still names the winner once" "$RW_OUT" "already fastest"

describe "a benchmark keeps the running protocol unless the fastest clearly wins"

# On a Route 10 the benchmark recommended switching protocol over a 1 ms lead,
# and reconfigure.sh --benchmark --force acts on that, restarting ctrld for a
# difference no one can notice. The fastest now has to be at least 5 ms and
# 20% faster than the protocol running.
assert_false "a 1 ms lead is not worth switching for" bench_worth_switching 30 29
assert_false "5 ms that is under 20% is not either" bench_worth_switching 50 45
assert_false "20% that is under 5 ms is not either" bench_worth_switching 20 16
assert_true  "5 ms that is also 20% is" bench_worth_switching 25 20
assert_true  "a current protocol that failed is always worth leaving" \
    bench_worth_switching FAIL 20
assert_true  "and so is one that was not measured" bench_worth_switching "" 20

# Both scripts, run for real against a stubbed bench_protocol. DoH3 is running
# at 30 ms and DoT measures 29.
BK_DIR="$TMPDIR/benchkeep"
mkdir -p "$BK_DIR"
cp "$SCRIPT_DIR/benchmark.sh" "$BK_DIR/benchmark.sh"
cat > "$BK_DIR/lib.sh" << BKLIBEOF
. "$SCRIPT_DIR/lib.sh"
load_env() { RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22; DNS_TYPE=doh3; CTRLD_VERSION=1.5.7; return 0; }
running_protocol() { printf 'doh3'; }
bench_protocol() {
    case "\$1" in doh3) BENCH_AVG=30 ;; dot) BENCH_AVG=29 ;; *) BENCH_AVG=60 ;; esac
    BENCH_OK="\$4"; BENCH_FAIL=0; return 0
}
BKLIBEOF
BK_OUT="$( cd "$BK_DIR" && sh ./benchmark.sh --queries 1 2>&1 </dev/null || true )"
assert_contains "benchmark.sh keeps the running protocol over a 1 ms lead" "$BK_OUT" \
    "Recommended: keep DoH3"
assert_not_contains "and prints no command to switch" "$BK_OUT" "--protocol --to dot"

BK_OUT="$( (
    . "$SCRIPT_DIR/lib.sh"
    RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22; DNS_TYPE=doh3; FORCE=1
    bench_protocol() {
        case "$1" in doh3) BENCH_AVG=30 ;; dot) BENCH_AVG=29 ;; *) BENCH_AVG=60 ;; esac
        BENCH_OK=1; BENCH_FAIL=0; return 0
    }
    apply_and_restart() { echo "APPLIED:$DNS_TYPE"; }
    eval "$RW_SRC"
    do_benchmark
) 2>&1 </dev/null || true )"
assert_contains "reconfigure.sh --benchmark --force keeps it too" "$BK_OUT" "Keeping DoH3"
assert_not_contains "without applying anything" "$BK_OUT" "APPLIED:"
BK_OUT="$( (
    . "$SCRIPT_DIR/lib.sh"
    RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22; DNS_TYPE=doh3; FORCE=1
    bench_protocol() {
        case "$1" in doh3) BENCH_AVG=30 ;; dot) BENCH_AVG=20 ;; *) BENCH_AVG=60 ;; esac
        BENCH_OK=1; BENCH_FAIL=0; return 0
    }
    apply_and_restart() { echo "APPLIED:$DNS_TYPE"; }
    cp() { :; }
    eval "$RW_SRC"
    do_benchmark
) 2>&1 </dev/null || true )"
assert_contains "while a clear win is still applied" "$BK_OUT" "APPLIED:dot"
unset BK_DIR BK_OUT

# setup.sh's inline benchmark prints the same table, and it is the one a new
# install sees. Its loop is inside a case arm, so it is extracted and run
# against the same stubs rather than by running the installer.
SW_SRC="$(code_only "$SCRIPT_DIR/setup.sh" | sed -n '/^[[:space:]]*for BPROTO in/,/^[[:space:]]*done$/p')"
assert_true "the installer's benchmark loop extracts" test -n "$SW_SRC"
SW_OUT="$( (
    . "$SCRIPT_DIR/lib.sh"
    RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22
    BENCH_QUERIES=1; BENCH_FASTEST_MS=999999; BENCH_FASTEST=""
    bench_protocol() {
        case "$1" in
            doq)  BENCH_AVG=40 ;;
            doh3) BENCH_AVG=30 ;;
            doh)  BENCH_AVG=20 ;;
            *)    BENCH_AVG=10 ;;
        esac
        BENCH_OK=1; BENCH_FAIL=0; return 0
    }
    eval "$SW_SRC"
    printf 'WINNER:%s\n' "$BENCH_FASTEST"
) 2>&1 </dev/null || true )"
assert_eq "the installer marks no row either" "0" \
    "$(printf '%s\n' "$SW_OUT" | grep -c -e '<--' || true)"
assert_contains "and picks DoT when DoT is the fastest it measured" "$SW_OUT" "WINNER:dot$"

describe "bench_stop() — never the production resolver"

# reconfigure.sh's benchmark ran `kill $(pidof ctrld)` before each of three
# protocols. That is the resolver every LAN client is redirected to, so the
# whole network lost DNS for the run, and a failure between the kill and the
# restart left it that way until the watchdog's next cycle. The throwaway
# daemon is identified by the config path it was started with instead.
assert_true "bench_stop matches on the config path" \
    code_grep "$SCRIPT_DIR/lib.sh" 'trld run -c ${_bs_conf}'
# Scoped to the benchmark regions: a stop_ctrld elsewhere is meant to stop the
# production daemon, and only a benchmark must never do so.
# setup.sh's region is delimited by a section comment, so it has to be sliced
# before comments are blanked, not after, because code_only reads the slice from
# standard input here. reconfigure.sh's is delimited by code either way.
SETUP_BENCH="$(sed -n '/── Inline benchmark ──/,/rm -f "\$BENCH_CONF"/p' "$SCRIPT_DIR/setup.sh" | code_only)"
RECONF_BENCH="$(code_only "$SCRIPT_DIR/reconfigure.sh" | sed -n '/^do_benchmark() {/,/^}/p')"
assert_not_contains "setup.sh's benchmark does not reach for pidof"     "$SETUP_BENCH"  "pidof"
assert_not_contains "reconfigure.sh's benchmark does not reach for pidof" "$RECONF_BENCH" "pidof"
assert_contains     "setup.sh's benchmark uses the shared runner"       "$SETUP_BENCH"  "bench_protocol"
assert_contains     "reconfigure.sh's benchmark uses the shared runner" "$RECONF_BENCH" "bench_protocol"
assert_eq "benchmark.sh never kills ctrld by pidof" "" \
    "$(code_only "$SCRIPT_DIR/benchmark.sh" | grep -n 'pidof ctrld' || true)"
# netstat prints the local address before the PID column, so the old
# leftover-sweep pattern could never match.
assert_false "no PID-to-port correlation is left" \
    code_grep "$SCRIPT_DIR/benchmark.sh" 'netstat -tlnp.*\${_p}'

describe "carry_policy_blocks() — a config rewrite must not drop split DNS"

# setup.sh Step 5 overwrote ctrld.toml outright, with no backup and no
# carry-over, so a re-install deleted every policy upstream, network block and
# routing rule, on the operation the README calls "always safe", and silently
# in the non-interactive form, which never reaches the wizard.
CPB_OLD="$TMPDIR/carry-old.toml"
write_ctrld_config "$CPB_OLD" old123 76.76.2.22 doh3
cat >> "$CPB_OLD" << 'CPBEOF'

[upstream.1]
    bootstrap_ip = "76.76.2.22"
    endpoint = "https://dns.controld.com/kids5678"
    name = "ControlD-Kids"
    type = "doh3"

[network.1]
    cidrs = ["192.168.10.0/24"]
    name = "Kids"

[listener.0.policy]
    name = "Split DNS Policy"
    networks = [
    {"network.1" = ["upstream.1"]},
    ]
CPBEOF

# What a re-install does: regenerate from scratch, then carry the rest across.
CPB_NEW="$TMPDIR/carry-new.toml"
write_ctrld_config "$CPB_NEW" new456 76.76.2.22 doq
assert_true "something is carried when a policy exists" \
    carry_policy_blocks "$CPB_NEW" "$CPB_OLD"
retarget_upstreams "$CPB_NEW" doq

assert_eq "the policy upstream survives"      "2" "$(list_upstreams "$CPB_NEW" | wc -l | tr -d ' ')"
assert_eq "its routing rule survives"         "1" "$(policy_rule_count "$CPB_NEW" network)"
assert_file_contains "the network block survives" "$CPB_NEW" 'cidrs = \["192.168.10.0/24"\]'
assert_file_contains "the new main resolver is in place" "$CPB_NEW" 'endpoint = "new456.dns.controld.com"'
# A profile's resolver is its identity: the rewrite moves transports, never IDs.
assert_file_contains "the policy keeps its own resolver" "$CPB_NEW" 'endpoint = "kids5678.dns.controld.com"'
assert_eq "both upstreams moved to the new transport" "2" \
    "$(grep -c 'type = "doq"' "$CPB_NEW" | tr -d ' ')"
assert_eq "exactly one policy table" "1" \
    "$(grep -c '^\[listener.0.policy\]' "$CPB_NEW" | tr -d ' ')"
assert_eq "the old main resolver is gone" "0" \
    "$(grep -c 'old123' "$CPB_NEW" | tr -d ' ')"

# A plain config has nothing to carry, and the caller must be able to tell.
CPB_PLAIN="$TMPDIR/carry-plain.toml"
CPB_TARGET="$TMPDIR/carry-target.toml"
write_ctrld_config "$CPB_PLAIN" abc123 76.76.2.22 doh3
write_ctrld_config "$CPB_TARGET" abc123 76.76.2.22 doh3
assert_false "nothing to carry from a policy-free config" \
    carry_policy_blocks "$CPB_TARGET" "$CPB_PLAIN"
assert_false "a missing source is not an error to report as carried" \
    carry_policy_blocks "$CPB_TARGET" "$TMPDIR/no-such.toml"

# setup.sh must take the backup and use it, and must not then run the wizard
# over a carried policy: two [listener.0.policy] tables is invalid TOML and
# ctrld would not start at all.
# Run the real thing. Three greps for `cp`, `carry_policy_blocks` and the
# CARRIED_POLICY guard used to stand in for this; they checked those strings
# appeared, not that they ran in an order that works. Deleting the
# retarget_upstreams call and moving the .bak removal above the carry gutted
# the feature with the suite still fully green.
#
# The step is pure file manipulation, so it extracts and runs against a sandbox.
SP_DIR="$TMPDIR/setup-step5"
mkdir -p "$SP_DIR"
sed -n '/^CARRIED_POLICY=0$/,/^rm -f \/cfg\/ctrld\.toml\.bak$/p' "$SCRIPT_DIR/setup.sh" \
    | sed "s|/cfg/|${SP_DIR}/|g" > "$SP_DIR/step5.sh"
assert_true "the install step extracts and parses" sh -n "$SP_DIR/step5.sh"

# An install that already has a policy, on the old protocol and old resolver.
write_ctrld_config "$SP_DIR/ctrld.toml" old123 76.76.2.22 doh3
cat >> "$SP_DIR/ctrld.toml" << 'SPEOF'

[upstream.1]
    endpoint = "https://dns.controld.com/kids5678"
    name = "ControlD-Kids"
    type = "doh3"

[network.1]
    cidrs = ["192.168.10.0/24"]
    name = "Kids"

[listener.0.policy]
    name = "Split DNS Policy"
    networks = [
    {"network.1" = ["upstream.1"]},
    ]
SPEOF
( . "$SCRIPT_DIR/lib.sh"
  RESOLVER_ID=new456; BOOTSTRAP_IP=76.76.2.22; DNS_TYPE=doq; PLABEL="DoQ (QUIC)"
  . "$SP_DIR/step5.sh"
  printf '%s' "$CARRIED_POLICY" > "$SP_DIR/carried" ) >/dev/null 2>&1

assert_eq "the re-install reports a carried policy" "1" "$(cat "$SP_DIR/carried" 2>/dev/null)"
assert_file_contains "the policy table survived"      "$SP_DIR/ctrld.toml" '^\[listener.0.policy\]'
assert_eq "its routing rule survived"            "1" "$(policy_rule_count "$SP_DIR/ctrld.toml" network)"
assert_file_contains "the new resolver is in place"   "$SP_DIR/ctrld.toml" 'endpoint = "new456.dns.controld.com"'
assert_file_contains "the policy keeps its own resolver" "$SP_DIR/ctrld.toml" 'endpoint = "kids5678.dns.controld.com"'
# The retarget is the half the greps did not cover at all.
assert_eq "every upstream moved to the new transport" "2" \
    "$(grep -c 'type = "doq"' "$SP_DIR/ctrld.toml" | tr -d ' ')"
assert_eq "none was left on the old one" "0" \
    "$(grep -c 'type = "doh3"' "$SP_DIR/ctrld.toml" | tr -d ' ')"
assert_false "the backup is cleaned up" [ -f "$SP_DIR/ctrld.toml.bak" ]

# An orphan [upstream.N] and no policy: carry_policy_blocks still returns 0, but
# CARRIED_POLICY must stay 0 or the installer skips the split-DNS wizard and the
# user loses their only chance to configure it during the install.
SP2="$TMPDIR/setup-step5b"
mkdir -p "$SP2"
sed -n '/^CARRIED_POLICY=0$/,/^rm -f \/cfg\/ctrld\.toml\.bak$/p' "$SCRIPT_DIR/setup.sh" \
    | sed "s|/cfg/|${SP2}/|g" > "$SP2/step5.sh"
write_ctrld_config "$SP2/ctrld.toml" old123 76.76.2.22 doh3
printf '\n[upstream.1]\n    endpoint = "https://dns.controld.com/orphan99"\n    name = "Orphan"\n    type = "doh3"\n' >> "$SP2/ctrld.toml"
( . "$SCRIPT_DIR/lib.sh"
  RESOLVER_ID=new456; BOOTSTRAP_IP=76.76.2.22; DNS_TYPE=doq; PLABEL="DoQ (QUIC)"
  . "$SP2/step5.sh"
  printf '%s' "$CARRIED_POLICY" > "$SP2/carried" ) >/dev/null 2>&1
assert_eq "an orphan upstream is not reported as a policy" "0" "$(cat "$SP2/carried" 2>/dev/null)"

describe "policy_rules() — the rules must be visible, not just counted"

# The policy manager's "show current policies" grepped the policy table for
# (networks|macs|rules). That matches the two list headers and no rule at all:
# a rule reads {"network.1" = ["upstream.2"]}, and "network.1" is not
# "networks". The one readout whose whole job is to list the rules printed two
# bracket-opening lines on a config full of them, and there was nowhere else
# to see them: status.sh and --show report counts.
#
# Asserted against the three shapes the writers produce. setup.sh's wizard
# writes a macs-only table for route type 2 and a networks-only table for
# type 1, and policy_add_rule creates whichever list is missing, so a policy
# carrying only one kind is the common case, not an edge one.
PR_BOTH="$TMPDIR/pr-both.toml"
cat > "$PR_BOTH" << 'PRBOTHEOF'
[upstream.0]
    name = "ControlD"
    type = "doh3"
[upstream.1]
    name = "ControlD-Kids"
    type = "doh3"
[upstream.2]
    name = "ControlD-Guest"
    type = "doh3"
[listener.0.policy]
    name = "Split DNS Policy"
    networks = [
    {"network.1" = ["upstream.2"]},
    ]
    macs = [
    {"AA:BB:CC:DD:EE:FF" = ["upstream.1"]},
    {"11:22:33:44:55:66" = ["upstream.2"]},
    ]
PRBOTHEOF

PR_OUT="$(policy_rules "$PR_BOTH")"
assert_contains "a MAC rule is listed with the upstream it routes to" "$PR_OUT" \
    "mac	AA:BB:CC:DD:EE:FF	1"
assert_contains "the second MAC rule is listed too" "$PR_OUT" \
    "mac	11:22:33:44:55:66	2"
assert_contains "a network rule is listed" "$PR_OUT" \
    "network	network.1	2"
assert_eq "three rules in, three rules out" "3" "$(printf '%s\n' "$PR_OUT" | grep -c .)"
# The counts and the listing must agree, or one of them is lying.
assert_eq "the MAC count matches what is listed" \
    "$(policy_rule_count "$PR_BOTH" mac)" \
    "$(printf '%s\n' "$PR_OUT" | grep -c '^mac	')"
assert_eq "the network count matches what is listed" \
    "$(policy_rule_count "$PR_BOTH" network)" \
    "$(printf '%s\n' "$PR_OUT" | grep -c '^network	')"

# macs only, the shape setup.sh writes for route type 2
PR_MAC="$TMPDIR/pr-mac.toml"
sed '/networks = \[/,/^    \]$/d' "$PR_BOTH" > "$PR_MAC"
PR_MAC_OUT="$(policy_rules "$PR_MAC")"
assert_contains "a macs-only policy still lists its rules" "$PR_MAC_OUT" \
    "mac	AA:BB:CC:DD:EE:FF	1"
assert_eq "and reports no network rules" "0" \
    "$(printf '%s\n' "$PR_MAC_OUT" | grep -c '^network	')"

# networks only, the shape setup.sh writes for route type 1
PR_NET="$TMPDIR/pr-net.toml"
sed '/macs = \[/,/^    \]$/d' "$PR_BOTH" > "$PR_NET"
PR_NET_OUT="$(policy_rules "$PR_NET")"
assert_contains "a networks-only policy still lists its rules" "$PR_NET_OUT" \
    "network	network.1	2"
assert_eq "and reports no MAC rules" "0" \
    "$(printf '%s\n' "$PR_NET_OUT" | grep -c '^mac	')"

# A policy table with no rules is not the same as no policy table, and the
# caller prints a different line for each.
PR_EMPTY="$TMPDIR/pr-empty.toml"
printf '[listener.0.policy]\n    name = "Split DNS Policy"\n' > "$PR_EMPTY"
assert_eq "a policy carrying no rules lists nothing" "" "$(policy_rules "$PR_EMPTY")"

# Nothing outside [listener.0.policy] is a rule, however much it looks like one.
PR_STRAY="$TMPDIR/pr-stray.toml"
cat > "$PR_STRAY" << 'PRSTRAYEOF'
[listener.1.policy]
    macs = [
    {"DE:AD:BE:EF:00:01" = ["upstream.9"]},
    ]
PRSTRAYEOF
assert_eq "another listener's policy is not ours to report" "" "$(policy_rules "$PR_STRAY")"
assert_eq "a missing file reports nothing and does not fail" "" "$(policy_rules "$TMPDIR/pr-nope.toml")"

# TOML allows a list inline, and allows more than one entry per line. Neither
# is a shape this project writes, but a hand-edited config or a future ctrld
# rewrite can carry one, and the readout reported such a file as having no
# rules at all while policy_rule_count reported them. The code this replaced
# printed those lines verbatim, so that was a regression against it.
PR_INLINE="$TMPDIR/pr-inline.toml"
cat > "$PR_INLINE" << 'PRINLEOF'
[listener.0.policy]
    name = "Split DNS Policy"
    networks = [{"network.1" = ["upstream.1"]}]
    macs = [{"AA:BB:CC:DD:EE:FF" = ["upstream.2"]}, {"11:22:33:44:55:66" = ["upstream.3"]}]
PRINLEOF
PR_INLINE_OUT="$(policy_rules "$PR_INLINE")"
assert_contains "an inline network list is read" "$PR_INLINE_OUT" "network	network.1	1"
assert_contains "an inline mac list is read"     "$PR_INLINE_OUT" "mac	AA:BB:CC:DD:EE:FF	2"
assert_contains "a second rule on the same line is not dropped" "$PR_INLINE_OUT" \
    "mac	11:22:33:44:55:66	3"
assert_eq "three rules inline, three rules out" "3" "$(printf '%s\n' "$PR_INLINE_OUT" | grep -c .)"
# The listing and the count must agree here too, or one of them is lying.
assert_eq "the inline mac count matches what is listed" \
    "$(policy_rule_count "$PR_INLINE" mac)" \
    "$(printf '%s\n' "$PR_INLINE_OUT" | grep -c '^mac	')"

# ctrld supports a domain list too. Nothing here writes one, and the kind must
# not be inherited from the list above it: a domain rule reported as a network
# rule is worse than one not reported at all.
PR_RULES="$TMPDIR/pr-rules.toml"
cat > "$PR_RULES" << 'PRRULEOF'
[listener.0.policy]
    networks = [
    {"network.1" = ["upstream.1"]},
    ]
    rules = [
    {"*.example.com" = ["upstream.9"]},
    ]
PRRULEOF
PR_RULES_OUT="$(policy_rules "$PR_RULES")"
assert_contains "the network rule is still read" "$PR_RULES_OUT" "network	network.1	1"
assert_not_contains "a domain rule is not reported as a network rule" "$PR_RULES_OUT" \
    'example\.com'
assert_eq "only the lists this project understands are reported" "1" \
    "$(printf '%s\n' "$PR_RULES_OUT" | grep -c .)"

# A rule may route to a list of upstreams. ctrld allows it and
# carry_policy_blocks preserves a hand-written policy table, so the shape is
# reachable. Requiring exactly one dropped the rule from the listing while
# policy_rule_count still counted it, which is the same two-readouts-disagree
# bug in quieter form.
PR_MULTI="$TMPDIR/pr-multi.toml"
cat > "$PR_MULTI" << 'PRMULTEOF'
[listener.0.policy]
    networks = [
    {"network.1" = ["upstream.2", "upstream.3"]},
    {"network.2" = ["upstream.1"]},
    ]
PRMULTEOF
PR_MULTI_OUT="$(policy_rules "$PR_MULTI")"
assert_contains "a rule routing to several upstreams is listed" "$PR_MULTI_OUT" \
    "network	network.1	2"
assert_contains "and the single-upstream rule beside it still is" "$PR_MULTI_OUT" \
    "network	network.2	1"
assert_eq "the count and the listing agree on a multi-upstream policy" \
    "$(policy_rule_count "$PR_MULTI" network)" \
    "$(printf '%s\n' "$PR_MULTI_OUT" | grep -c '^network	')"

describe "format_policy_rules() — what the policy menu actually prints"

# The defect 3885c8c fixed was in reconfigure.sh's menu, not in the helper
# underneath it, and while the formatting lived inline there was no way to
# assert on it: the whole display could be reverted to the grep it replaced
# with every assertion still green. The rendering is a function so the lines a
# person reads are the thing under test.
FPR="$TMPDIR/fpr.toml"
cat > "$FPR" << 'FPREOF'
[upstream.0]
    name = "ControlD"
    type = "doh3"
[upstream.1]
    name = "ControlD-Kids"
    type = "doh3"
[listener.0.policy]
    macs = [
    {"AA:BB:CC:DD:EE:FF" = ["upstream.1"]},
    ]
FPREOF
FPR_OUT="$(format_policy_rules "$FPR")"
# The rule's key, the upstream it routes to, and the name of that upstream all
# have to reach the terminal: "upstream.1" alone is not actionable.
assert_contains "the rule's key is printed"        "$FPR_OUT" 'AA:BB:CC:DD:EE:FF'
assert_contains "the upstream it routes to is printed" "$FPR_OUT" 'upstream\.1'
assert_contains "resolved to that upstream's name"  "$FPR_OUT" '(ControlD-Kids)'
assert_contains "and labelled with its kind"        "$FPR_OUT" 'mac'
assert_eq "one rule in, one line out" "1" "$(printf '%s\n' "$FPR_OUT" | grep -c .)"

# A policy table with no rules must be distinguishable from one with rules, so
# the caller can say something different rather than printing a blank heading.
FPR_EMPTY="$TMPDIR/fpr-empty.toml"
printf '[listener.0.policy]\n    name = "Split DNS Policy"\n' > "$FPR_EMPTY"
assert_false "an empty policy table reports nothing to print" \
    format_policy_rules "$FPR_EMPTY"
assert_eq "and prints nothing" "" "$(format_policy_rules "$FPR_EMPTY" 2>/dev/null)"

# The menu must go through it. This one is a source check on purpose: the
# branch is inside an interactive read loop over /cfg, so it cannot be run
# here, and the grep it replaced is the thing that must not come back.
assert_true "reconfigure.sh's policy menu renders through it" \
    code_grep "$SCRIPT_DIR/reconfigure.sh" 'format_policy_rules /cfg/ctrld.toml'
assert_false "and not through the grep that showed only list headers" \
    code_grep "$SCRIPT_DIR/reconfigure.sh" -F "grep -E '(networks|macs|rules)'"

describe "policy_add_rule() — a reported rule must actually be in the file"

# The callers anchored an insert on the list header, so adding the first rule
# of a kind the policy did not already carry was a silent no-op: sed matched
# nothing, exited 0, and "Device rule added" was printed over a config that had
# gained an orphan upstream and no rule. Both orderings are reachable from a
# first run of the setup wizard, which writes macs-only or networks-only
# depending on the route type chosen.

# 1. No policy table at all: one must be created around the rule
PA1="$TMPDIR/pol-none.toml"
write_ctrld_config "$PA1" abc123 76.76.2.22 doh3
assert_true "a first MAC rule creates the policy" \
    policy_add_rule "$PA1" mac "aa:bb:cc:dd:ee:01" 1
assert_file_contains "the policy table is there" "$PA1" '^\[listener.0.policy\]'
assert_eq "and carries the rule" "1" "$(policy_rule_count "$PA1" mac)"

# 2. A networks-only policy, adding a MAC rule: the case that silently failed
PA2="$TMPDIR/pol-net-only.toml"
write_ctrld_config "$PA2" abc123 76.76.2.22 doh3
cat >> "$PA2" << 'PA2EOF'

[listener.0.policy]
    name = "Split DNS Policy"
    networks = [
    {"network.1" = ["upstream.1"]},
    ]
PA2EOF
assert_true "a MAC rule lands in a networks-only policy" \
    policy_add_rule "$PA2" mac "aa:bb:cc:dd:ee:02" 2
assert_eq "the MAC rule is counted"        "1" "$(policy_rule_count "$PA2" mac)"
assert_eq "the network rule is untouched"  "1" "$(policy_rule_count "$PA2" network)"
# The new list must sit inside the policy table, not after the file's last one.
assert_eq "the macs list is inside the policy table" "1" \
    "$(toml_blocks "$PA2" '[listener.0.policy]' | grep -c 'aa:bb:cc:dd:ee:02')"

# 3. A macs-only policy, adding a network rule: the mirror case
PA3="$TMPDIR/pol-mac-only.toml"
write_ctrld_config "$PA3" abc123 76.76.2.22 doh3
cat >> "$PA3" << 'PA3EOF'

[listener.0.policy]
    name = "Split DNS Policy"
    macs = [
    {"aa:bb:cc:dd:ee:03" = ["upstream.1"]},
    ]
PA3EOF
assert_true "a network rule lands in a macs-only policy" \
    policy_add_rule "$PA3" network "network.5" 2
assert_eq "the network rule is counted" "1" "$(policy_rule_count "$PA3" network)"
assert_eq "the MAC rule is untouched"   "1" "$(policy_rule_count "$PA3" mac)"
assert_eq "the networks list is inside the policy table" "1" \
    "$(toml_blocks "$PA3" '[listener.0.policy]' | grep -c 'network.5')"

# 4. Adding to a list that already exists still works, and accumulates
assert_true "a second MAC rule is added" \
    policy_add_rule "$PA3" mac "aa:bb:cc:dd:ee:04" 3
assert_eq "both MAC rules are present" "2" "$(policy_rule_count "$PA3" mac)"

# A policy table must never be created twice, which is invalid TOML.
assert_eq "exactly one policy table" "1" \
    "$(grep -c '^\[listener.0.policy\]' "$PA3" | tr -d ' ')"

assert_false "a missing file fails rather than reporting success" \
    policy_add_rule "$TMPDIR/no-such.toml" mac "aa:bb:cc:dd:ee:05" 1
assert_false "an unknown rule kind is refused" \
    policy_add_rule "$PA3" hostname "example.com" 1

# A file carrying the list header twice must get the rule once. The sed form
# this replaced had no address restriction and inserted into both, while the
# before/after count check still passed.
PA_DBL="$TMPDIR/pol-double.toml"
printf '[listener.0.policy]\n    macs = [\n    ]\n    macs = [\n    ]\n' > "$PA_DBL"
assert_true "a duplicated list header still takes one rule" \
    policy_add_rule "$PA_DBL" mac "aa:bb:cc:dd:ee:99" 1
assert_eq "inserted exactly once" "1" "$(grep -c 'aa:bb:cc:dd:ee:99' "$PA_DBL" | tr -d ' ')"

# The guard and the awk branch used to match the policy header differently, so
# a trailing space or CRLF sent this down a path that wrote nothing.
PA_CR="$TMPDIR/pol-crlf.toml"
printf '[upstream.0]\r\n    type = "doh3"\r\n[listener.0.policy] \r\n    name = "P"\r\n' > "$PA_CR"
assert_true "a CRLF policy header is still found" \
    policy_add_rule "$PA_CR" mac "aa:bb:cc:dd:ee:aa" 2
assert_eq "and the rule is written" "1" "$(policy_rule_count "$PA_CR" mac)"

describe "setup.sh's policy wizard — an index is allocated, never assumed"

# The wizard allocated NETWORK_IDX from the config and left UPSTREAM_IDX at a
# literal 1, so it wrote [upstream.1] whatever the file already held.
#
# carry_policy_blocks runs a few steps earlier and brings an existing
# [upstream.1] across. README.md offers keeping extra upstreams as a supported
# thing to do, and re-running setup.sh is the documented upgrade path, so a
# config arriving here with upstream.1 taken is not a contrived shape. The
# wizard then appended a second [upstream.1]. Two tables of one name is not
# valid TOML: ctrld would refuse the config and not start, at the end of an
# install, with the redirects already pointing at its port.
#
# Both assignments are pure file reads, so the step extracts and runs against
# a sandbox rather than being grepped for.
SPI_DIR="$TMPDIR/setup-idx"
mkdir -p "$SPI_DIR"
sed -n '/^POLICY_UPSTREAMS=""$/,/^NETWORK_IDX=/p' "$SCRIPT_DIR/setup.sh" \
    | sed "s|/cfg/|${SPI_DIR}/|g" > "$SPI_DIR/idx.sh"
assert_true "the allocation step extracts and parses" sh -n "$SPI_DIR/idx.sh"

# A fresh install: upstream.0 and network.0 exist, so the first free pair is 1/1.
write_ctrld_config "$SPI_DIR/ctrld.toml" abc123 76.76.2.22 doh3
assert_eq "a fresh install allocates the first free slots" "1 1" \
    "$( . "$SPI_DIR/idx.sh" >/dev/null 2>&1; printf '%s %s' "$UPSTREAM_IDX" "$NETWORK_IDX" )"

# A re-install that carried an extra upstream across. The upstream slot the
# wizard used to take is occupied.
cat >> "$SPI_DIR/ctrld.toml" << 'SPIEOF'

[upstream.1]
    endpoint = "https://dns.controld.com/kids5678"
    name = "ControlD-Kids"
    type = "doh3"
SPIEOF
assert_eq "an occupied upstream slot is skipped" "2 1" \
    "$( . "$SPI_DIR/idx.sh" >/dev/null 2>&1; printf '%s %s' "$UPSTREAM_IDX" "$NETWORK_IDX" )"

# And with a carried network block too, which the network side already handled.
cat >> "$SPI_DIR/ctrld.toml" << 'SPINEOF'

[network.1]
    cidrs = ["192.168.10.0/24"]
    name = "Kids"
SPINEOF
assert_eq "an occupied network slot is skipped as well" "2 2" \
    "$( . "$SPI_DIR/idx.sh" >/dev/null 2>&1; printf '%s %s' "$UPSTREAM_IDX" "$NETWORK_IDX" )"

# The outcome that matters: writing an upstream at the allocated index leaves
# exactly one table of that name, so ctrld still has a config it can parse.
SPI_UP="$( . "$SPI_DIR/idx.sh" >/dev/null 2>&1; printf '%s' "$UPSTREAM_IDX" )"
printf '\n[upstream.%s]\n    name = "ControlD-Guest"\n    type = "doh3"\n' \
    "$SPI_UP" >> "$SPI_DIR/ctrld.toml"
assert_eq "no upstream table is written twice" "0" \
    "$(grep -oE '^\[upstream\.[0-9]+\]' "$SPI_DIR/ctrld.toml" | sort | uniq -d | grep -c .)"
assert_eq "and the wizard's upstream is really there" "3" \
    "$(list_upstreams "$SPI_DIR/ctrld.toml" | wc -l | tr -d ' ')"

describe "CURLD_VERSION — an install inherited from the original project"

# The original project misspelled the key in its first commit (f6c81a6); this
# fork corrected it. An install carried over from upstream must still work: the
# old spelling is adopted, and retired at the next config rewrite rather than
# preserved forever by the unmanaged-key carry-over.
CV="$TMPDIR/curld.env"
printf 'RESOLVER_ID=abc123\nBOOTSTRAP_IP=76.76.2.22\nCURLD_VERSION=1.5.7\nDNS_TYPE=doh3\n' > "$CV"
assert_eq "the old spelling is adopted" "1.5.7" \
    "$(unset CTRLD_VERSION CURLD_VERSION; load_env "$CV" >/dev/null 2>&1; printf '%s' "$CTRLD_VERSION")"
# The corrected key must win when both are present.
printf 'CTRLD_VERSION=1.6.0\nCURLD_VERSION=1.5.7\n' > "$TMPDIR/both.env"
assert_eq "the corrected key wins over the old one" "1.6.0" \
    "$(unset CTRLD_VERSION CURLD_VERSION; load_env "$TMPDIR/both.env" >/dev/null 2>&1; printf '%s' "$CTRLD_VERSION")"

CV_SAVED_PATH="$PATH"
mkdir -p "$TMPDIR/cvbin"; printf '#!/bin/sh\nexit 1\n' > "$TMPDIR/cvbin/uci"; chmod +x "$TMPDIR/cvbin/uci"
PATH="$TMPDIR/cvbin:$PATH"
( unset CTRLD_VERSION CURLD_VERSION
  load_env "$CV" >/dev/null 2>&1
  PREFERRED_PROTOCOL="$DNS_TYPE"
  write_env_file "$CV" ) 2>/dev/null
PATH="$CV_SAVED_PATH"
assert_file_contains "the rewrite records the corrected key" "$CV" '^CTRLD_VERSION=1.5.7$'
assert_false "and retires the misspelled one" grep -q '^CURLD_VERSION=' "$CV"

# Both generated scripts source controld.env directly, not through load_env.
SETUP_PC="$(sed -n "/cat > \/cfg\/post-cfg.sh << 'BOOTSCRIPT'/,/^BOOTSCRIPT$/p" "$SCRIPT_DIR/setup.sh")"
SETUP_UP="$(sed -n "/cat > \/cfg\/controld-update.sh << 'UPDATESCRIPT'/,/^UPDATESCRIPT$/p" "$SCRIPT_DIR/setup.sh")"
assert_contains "post-cfg.sh adopts the old spelling too"        "$SETUP_PC" 'CURLD_VERSION'
assert_contains "the weekly updater adopts the old spelling too" "$SETUP_UP" 'CURLD_VERSION'

describe "the lib.sh-absent fallbacks must insert redirects at the head"

# post-cfg.sh and watchdog.sh each carry a minimal copy of these helpers for the
# case where /cfg/lib.sh is gone. Both copies appended, so a router recovering
# without lib.sh would put its redirects below the fw3 zone chains and land back
# in the bug the library path was fixed for — on the disaster-recovery path,
# where lib.sh being missing is most plausible and least likely to be noticed.
#
# Nothing executed either copy: the watchdog harness above substitutes its own
# lib.sh, so it exercises the library, and post-cfg.sh is never run off-router.
# Extract each function and run it against a recording iptables, so the
# assertion is about the command the script issues, not how the source reads.
FB_BIN="$TMPDIR/fb-bin"
mkdir -p "$FB_BIN"
cat > "$FB_BIN/iptables" << 'FBEOF'
#!/bin/sh
# -C must fail, or the helper short-circuits and never reaches the add.
for _a in "$@"; do [ "$_a" = "-C" ] && exit 1; done
printf '%s\n' "$*" >> "$FB_LOG"
exit 0
FBEOF
chmod +x "$FB_BIN/iptables"

SETUP_WD="$(sed -n "/^cat > \/cfg\/watchdog.sh << 'WATCHDOG'/,/^WATCHDOG$/p" "$SCRIPT_DIR/setup.sh")"
for _fb in post-cfg watchdog; do
    case "$_fb" in
        post-cfg) _fb_src="$SETUP_PC" ;;
        *)        _fb_src="$SETUP_WD" ;;
    esac
    _fb_fn="$(printf '%s\n' "$_fb_src" | sed -n '/ensure_redirect_rule() {/,/^    }$/p')"
    assert_true "${_fb}.sh carries an extractable fallback helper" [ -n "$_fb_fn" ]

    FB_LOG="$TMPDIR/fb-${_fb}.log"
    : > "$FB_LOG"
    ( PATH="$FB_BIN:$PATH"; export FB_LOG
      eval "$_fb_fn"
      ensure_redirect_rule br-lan udp 53 5354 ) >/dev/null 2>&1

    assert_file_contains "${_fb}.sh inserts the redirect at the head" \
        "$FB_LOG" '\-I PREROUTING 1'
    assert_false "${_fb}.sh never appends below the zone chains" \
        grep -q -e '-A PREROUTING' "$FB_LOG"
done
unset _fb _fb_src _fb_fn

describe "the lib.sh-absent fallbacks must keep a moved DNS port"

# setup.sh moves off 5354 when something already holds it and records the
# choice in controld.env. Both generated scripts source that file and then, if
# /cfg/lib.sh is gone, define their own minimal helpers. Both set DNS_PORT with
# a bare assignment, which overwrote the recorded port with the default.
#
# In post-cfg.sh that meant starting ctrld from a ctrld.toml on the moved port
# and then health-checking the default one. The check failed, the redirects
# were never added, and per-device visibility was silently gone on every boot
# while DNS kept working through https-dns-proxy. In watchdog.sh it meant a
# healthy router failing its own check every five minutes for ever.
#
# lib.sh states the invariant where it sets the same variable, and uses the
# defaulting form. These two copies now match it. Run the real preamble instead
# of grepping for the shape: extract each script up to the end of its bootstrap
# block, point its /cfg at a sandbox, and read back what DNS_PORT holds.
FBP_DIR="$TMPDIR/fallback-port"
for _fbp in post-cfg watchdog; do
    case "$_fbp" in
        post-cfg) _fbp_src="$SETUP_PC" ;;
        *)        _fbp_src="$SETUP_WD" ;;
    esac
    rm -rf "$FBP_DIR"; mkdir -p "$FBP_DIR/cfg"
    printf 'RESOLVER_ID=abc123\nDNS_TYPE=doh3\nCTRLD_VERSION=1.5.7\nDNS_PORT=5355\n' \
        > "$FBP_DIR/cfg/controld.env"
    # Strip the heredoc delimiters, then send every /cfg path into the sandbox.
    printf '%s\n' "$_fbp_src" | sed '1d;$d' | sed "s#/cfg/#${FBP_DIR}/cfg/#g" \
        > "$FBP_DIR/whole.sh"
    # The bootstrap if/else is the first block in both, so its "fi" is the first
    # one in the file. Cutting there keeps the probe clear of anything that
    # would start ctrld or touch iptables.
    _fbp_end="$(grep -n '^fi$' "$FBP_DIR/whole.sh" | head -1 | cut -d: -f1)"
    sed -n "1,${_fbp_end}p" "$FBP_DIR/whole.sh" > "$FBP_DIR/probe.sh"
    printf '\nprintf "%%s" "$DNS_PORT"\n' >> "$FBP_DIR/probe.sh"
    assert_eq "${_fbp}.sh keeps a moved port when lib.sh is gone" "5355" \
        "$(sh "$FBP_DIR/probe.sh" 2>/dev/null)"
    # And the library path it has to agree with, so the test fails if either
    # side of the invariant moves.
    cp "$SCRIPT_DIR/lib.sh" "$FBP_DIR/cfg/lib.sh"
    assert_eq "${_fbp}.sh keeps it on the library path too" "5355" \
        "$(sh "$FBP_DIR/probe.sh" 2>/dev/null)"
done
rm -rf "$FBP_DIR"
unset _fbp _fbp_src _fbp_end FBP_DIR

# Drift count from an audit run's summary; 0 when it reports none. Lets a test
# assert an item's severity from what audit.sh did, not from how it is written.
audit_drift_count() {
    _adc="$(printf '%s\n' "$1" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) drift item(s).*/\1/p' | head -1)"
    printf '%s' "${_adc:-0}"
}

# Review count, from either summary line: "No drift. N item(s) to review above."
# or "N drift item(s), M to review." A finding printed from inside a pipeline
# increments a counter in a subshell and never reaches either, which is how
# four flat bridges came to be summarised as one review item.
audit_review_count() {
    _arc="$(printf '%s\n' "$1" \
        | sed -n -e 's/.*[^0-9]\([0-9][0-9]*\) item(s) to review.*/\1/p' \
                 -e 's/.*drift item(s), \([0-9][0-9]*\) to review.*/\1/p' | head -1)"
    printf '%s' "${_arc:-0}"
}

describe "audit.sh — a wiped firewall.user block must not pass as healthy"

# An empty firewall.user with an install recorded means the redirects exist in
# the live table but nowhere that survives a firewall reload. The watchdog
# rewrites the block, so this only bites while cron is dead as well, and a
# firmware update resetting /etc can take both, so it is not left to that.
FW_BIN="$TMPDIR/fwbin"; mkdir -p "$FW_BIN"
for _fs in uci iptables ip nslookup logread pidof netstat crontab; do
    printf '#!/bin/sh\nexit 1\n' > "$FW_BIN/$_fs"; chmod +x "$FW_BIN/$_fs"
done
FW_EMPTY="$TMPDIR/fw-empty.user"; : > "$FW_EMPTY"

# Sandboxed /cfg, so the gate comes from this fixture rather than from whatever
# the machine running the suite happens to have installed. The bare-checkout
# case was skipped on every real router otherwise, which is the one place the
# on-router run was supposed to add something.
FW_CFG="$TMPDIR/fw-cfg"; mkdir -p "$FW_CFG"
for _fws in audit.sh lib.sh; do
    sed -e "s|/cfg/|${FW_CFG}/|g" "$SCRIPT_DIR/$_fws" > "$FW_CFG/$_fws"
done
chmod +x "$FW_CFG/audit.sh"
fw_run() {   # $1 = recorded|bare, $2 = the firewall.user to present
    if [ "$1" = "recorded" ]; then
        printf 'RESOLVER_ID=abc123\nCTRLD_VERSION=1.5.7\nDNS_TYPE=doh3\n' > "$FW_CFG/controld.env"
    else
        printf 'RESOLVER_ID=abc123\nDNS_TYPE=doh3\n' > "$FW_CFG/controld.env"
    fi
    ( PATH="$FW_BIN:$PATH"; FW_USER="$2" sh "$FW_CFG/audit.sh" ) 2>/dev/null || true
}

FW_OUT="$(fw_run recorded "$FW_EMPTY")"
assert_contains "an empty firewall.user is reported when an install is recorded" \
    "$FW_OUT" "will not survive a firewall reload"
# Severity from the count, for the same reason.
printf '# controld-dns-redirect BEGIN\n# controld-dns-redirect END\n' > "$TMPDIR/fw-ok.user"
FW_OK="$(fw_run recorded "$TMPDIR/fw-ok.user")"
assert_eq "an empty firewall.user adds exactly one drift item" \
    "$(( $(audit_drift_count "$FW_OK") + 1 ))" "$(audit_drift_count "$FW_OUT")"

# Nothing installed: an empty firewall.user is simply correct.
assert_not_contains "but not when nothing is installed" \
    "$(fw_run bare "$FW_EMPTY")" "will not survive a firewall reload"

describe "audit.sh — a wiped crontab must not pass as healthy"

# The neighbouring check inspects only the jobs that are present, so an empty
# crontab walks its loop zero times and prints OK. That is precisely what a
# firmware update leaves behind when it resets /etc, and it is the worst state
# to miss: the watchdog reconciles the protocol, restores the redirects and
# drives the fallback chain, so losing it switches off every other self-heal
# while the install still reads as healthy.
#
# An outcome test on audit.sh's real output, and it runs everywhere: the check
# is gated on CTRLD_VERSION, which is an environment value, so neither this nor
# the crontab stub needs a real install or a write to /cfg.
CJ_BIN="$TMPDIR/cronbin"; mkdir -p "$CJ_BIN"
for _cs in uci iptables ip nslookup logread pidof netstat; do
    printf '#!/bin/sh\nexit 1\n' > "$CJ_BIN/$_cs"; chmod +x "$CJ_BIN/$_cs"
done
# A healthy firewall.user throughout: the sibling check is gated on
# CTRLD_VERSION too, so leaving it to the default would make the gate-off /
# gate-on comparison below differ by two items instead of one.
CJ_FW="$TMPDIR/cj-fw.user"
printf '# controld-dns-redirect BEGIN\n# controld-dns-redirect END\n' > "$CJ_FW"

# audit.sh runs against a sandboxed /cfg, not the router's. It reads
# controld.env through load_env, so the file wins over anything the test
# exports, and a router that had opted out of auto-update turned two of the
# assertions below red: the updater is then not expected, so it is neither
# named as missing nor counted in "Both cron jobs are in the crontab". That is
# the failure CONTRIBUTING.md describes, arriving on the exact device state the
# hardware plan asks for. Staging the file here also retires the two skips this
# block used to take on any real install, so these run on the router too.
CJ_CFG="$TMPDIR/cj-cfg"; mkdir -p "$CJ_CFG"
for _cjs in audit.sh lib.sh; do
    sed -e "s|/cfg/|${CJ_CFG}/|g" "$SCRIPT_DIR/$_cjs" > "$CJ_CFG/$_cjs"
done
chmod +x "$CJ_CFG/audit.sh"
# No AUTO_UPDATE line: both cron jobs are expected, which is what this block
# is about. The opt-out has its own fixture further down.
cj_audit() {   # $1 = recorded|bare, deciding whether the install is recorded
    if [ "$1" = "recorded" ]; then
        printf 'RESOLVER_ID=abc123\nCTRLD_VERSION=1.5.7\nDNS_TYPE=doh3\n' > "$CJ_CFG/controld.env"
    else
        printf 'RESOLVER_ID=abc123\nDNS_TYPE=doh3\n' > "$CJ_CFG/controld.env"
    fi
    ( PATH="$CJ_BIN:$PATH"; FW_USER="$CJ_FW" sh "$CJ_CFG/audit.sh" ) 2>/dev/null || true
}

# Crontab empty, install recorded: both jobs must be named as never running.
printf '#!/bin/sh\nexit 0\n' > "$CJ_BIN/crontab"; chmod +x "$CJ_BIN/crontab"
CJ_GONE="$(cj_audit recorded)"
assert_contains "an empty crontab is reported, not passed over" \
    "$CJ_GONE" "no cron job, so never run"
assert_contains "the watchdog is named"       "$CJ_GONE" "never run:.*watchdog\.sh"
assert_contains "and so is the updater"       "$CJ_GONE" "controld-update\.sh"
# Severity is the whole point. Reported as a review note it would print and
# still exit 0, which is the failure this check exists to end, and asserting
# only the message text does not catch that, as reverting it proved.

# Only the watchdog missing: the updater alone must not mask it.
printf '#!/bin/sh\necho "0 3 * * 1 %s/controld-update.sh"\n' "$CJ_CFG" > "$CJ_BIN/crontab"
chmod +x "$CJ_BIN/crontab"
CJ_HALF="$(cj_audit recorded)"
assert_contains "one job present does not excuse the other" \
    "$CJ_HALF" "never run:.*watchdog\.sh"

# Both present: silent.
printf '#!/bin/sh\necho "*/5 * * * * %s/watchdog.sh"\necho "0 3 * * 1 %s/controld-update.sh"\n' \
    "$CJ_CFG" "$CJ_CFG" > "$CJ_BIN/crontab"
chmod +x "$CJ_BIN/crontab"
CJ_OK="$(cj_audit recorded)"
assert_not_contains "a complete crontab says nothing" "$CJ_OK" "no cron job"
assert_contains "and confirms both are there" "$CJ_OK" "Both cron jobs are in the crontab"

# No install recorded: silent either way, so a bare checkout is not accused.
# This used to skip on any real install, because the gate came from the
# router's own controld.env. The sandbox supplies it, so the case runs
# everywhere now, on the router included.
printf '#!/bin/sh\nexit 0\n' > "$CJ_BIN/crontab"; chmod +x "$CJ_BIN/crontab"
CJ_NONE="$(cj_audit bare)"
assert_not_contains "no recorded install means no cron complaint" \
    "$CJ_NONE" "no cron job"
    # Severity from what audit did, not from how the line is written: as a
    # review note the count would not move and the exit code would not carry
    # it. Measured against the same empty crontab with the gate off, which is
    # the only pair that differs by this check alone, since comparing against a
    # populated crontab instead just trades this drift item for the
    # neighbouring "points at missing script(s)" one.
assert_eq "and with one recorded it is drift, not a review note" \
    "$(( $(audit_drift_count "$CJ_NONE") + 1 ))" "$(audit_drift_count "$CJ_GONE")"

describe "readouts — an opt-out must not read as a broken install"

# Run against a sandboxed /cfg rather than gated on the real one. These used to
# skip whenever /cfg/controld.env existed, which is every router, so the
# on-router run CONTRIBUTING.md prescribes said nothing at all about this
# feature, and on a dev box the flag came from the environment and never from
# the file the code actually reads. Rewriting the /cfg paths in copies of the
# readouts, and putting a real controld.env in that sandbox, is what
# CONTRIBUTING.md means by deriving the expected values from wherever the code
# under test will read them.
# Named apart from the version-drift block's RO_BIN 2000 lines above, which
# stubs the same directory differently. Nothing depended on the collision,
# but neither block said it shared a directory.
RDO_CFG="$TMPDIR/rdo-cfg"; RDO_BIN="$TMPDIR/rdo-bin"; RDO_TAB="$TMPDIR/rdo.crontab"
mkdir -p "$RDO_CFG" "$RDO_BIN"
export RDO_TAB

for _rdos in audit.sh status.sh lib.sh; do
    sed -e "s|/cfg/|${RDO_CFG}/|g" "$SCRIPT_DIR/$_rdos" > "$RDO_CFG/$_rdos"
done
chmod +x "$RDO_CFG/audit.sh" "$RDO_CFG/status.sh"

for _rdostub in uci iptables ip nslookup logread pidof netstat; do
    printf '#!/bin/sh\nexit 1\n' > "$RDO_BIN/$_rdostub"; chmod +x "$RDO_BIN/$_rdostub"
done
printf '#!/bin/sh\ncat "$RDO_TAB" 2>/dev/null\n' > "$RDO_BIN/crontab"
chmod +x "$RDO_BIN/crontab"
RDO_FW="$TMPDIR/ro-fw.user"
printf '# controld-dns-redirect BEGIN\n# controld-dns-redirect END\n' > "$RDO_FW"

rdo_env() {   # $1 = the AUTO_UPDATE line, or empty for none
    { printf 'RESOLVER_ID=abc123\nBOOTSTRAP_IP=76.76.2.22\nCTRLD_VERSION=1.5.7\n'
      printf 'DNS_TYPE=doh3\nPREFERRED_PROTOCOL=doh3\nFORCED_DNS=0\nDNS_PORT=5354\n'
      [ -z "$1" ] || printf '%s\n' "$1"
    } > "$RDO_CFG/controld.env"
}
rdo_cron() {  # $1 = with|without the updater job
    if [ "$1" = "with" ]; then
        printf '*/5 * * * * %s/watchdog.sh\n0 3 * * 1 %s/controld-update.sh\n' \
            "$RDO_CFG" "$RDO_CFG" > "$RDO_TAB"
    else
        printf '*/5 * * * * %s/watchdog.sh\n' "$RDO_CFG" > "$RDO_TAB"
    fi
}
rdo_run() { ( PATH="$RDO_BIN:$PATH"; FW_USER="$RDO_FW" sh "$RDO_CFG/$1" ) 2>/dev/null || true; }

# Opted out, cron gone: the steady state after a toggle.
rdo_env 'AUTO_UPDATE=0'; rdo_cron without
RDO_AUDIT_OFF="$(rdo_run audit.sh)"
RDO_ST_OFF="$(rdo_run status.sh)"
assert_not_contains "a cron removed on purpose is not drift" \
    "$RDO_AUDIT_OFF" "never run:.*controld-update\.sh"
assert_contains "and the audit says why it is absent" \
    "$RDO_AUDIT_OFF" "auto-update off by choice"
assert_not_contains "status.sh does not call a deliberate opt-out a failure" \
    "$RDO_ST_OFF" "No auto-update cron job"
assert_contains "it says the update is off and where the setting lives" \
    "$RDO_ST_OFF" "off by choice"
assert_contains "and how to put it back" "$RDO_ST_OFF" "reconfigure.sh --auto-update"
assert_contains "reported with the info marker" "$RDO_ST_OFF" '\[--\].*off by choice'
assert_not_contains "and no failure marker in the cron section" \
    "$(printf '%s\n' "$RDO_ST_OFF" | sed -n '/Cron Jobs/,/^$/p')" '\[!!\]'

# The same crontab with no opt-out recorded: still drift, still a failure, or
# the assertions above would pass on readouts that had stopped looking.
rdo_env ''; rdo_cron without
RDO_AUDIT_ON="$(rdo_run audit.sh)"
RDO_ST_ON="$(rdo_run status.sh)"
assert_contains "with no opt-out the same missing cron is still drift" \
    "$RDO_AUDIT_ON" "never run:.*controld-update\.sh"
assert_contains "and status.sh still calls it a failure" \
    "$RDO_ST_ON" "No auto-update cron job"
assert_eq "and the opt-out takes one item off the drift count" \
    "$(( $(audit_drift_count "$RDO_AUDIT_ON") - 1 ))" \
    "$(audit_drift_count "$RDO_AUDIT_OFF")"

# A quoted opt-out, which only a reader that sources the file will honour.
rdo_env 'AUTO_UPDATE="0"'; rdo_cron without
assert_contains "the readouts honour a quoted opt-out too" \
    "$(rdo_run audit.sh)" "auto-update off by choice"

# Opted out but the cron is still installed. It replaces the LAN's resolver on
# Monday whatever controld.env says, so both readouts must flag it.
rdo_env 'AUTO_UPDATE=0'; rdo_cron with
RDO_AUDIT_Z="$(rdo_run audit.sh)"
RDO_ST_Z="$(rdo_run status.sh)"
assert_contains "audit reports a cron that outlived the opt-out" \
    "$RDO_AUDIT_Z" "AUTO_UPDATE=0 but the update cron is installed"
# A review note, not drift: the updater carries the same flag and declines, so
# nothing is replaced, and the boot hook takes the job out at the next boot.
# Pinning audit.sh at exit 1 for a hand-edited opt-out is the outcome its own
# comment says this block exists to avoid. Severity asserted by the counts, so
# promoting or demoting it fails here rather than passing on the wording.
assert_eq "and counts it as a review note, not drift" \
    "$(( $(audit_review_count "$RDO_AUDIT_OFF") + 1 ))" "$(audit_review_count "$RDO_AUDIT_Z")"
assert_eq "and does not raise the drift count" \
    "$(audit_drift_count "$RDO_AUDIT_OFF")" "$(audit_drift_count "$RDO_AUDIT_Z")"
assert_contains "status.sh flags it too" \
    "$RDO_ST_Z" "off in controld.env but its cron is installed"
assert_not_contains "and does not call that healthy" \
    "$(printf '%s\n' "$RDO_ST_Z" | sed -n '/Cron Jobs/,/^$/p')" "Weekly auto-update cron installed"

describe "audit.sh — a boot hook that never runs must fail the audit"

# Reported as `review` once, so audit.sh exited 0 while boot persistence was
# dead: nothing would reinstall cron, restore the redirects or re-apply forced
# DNS at the next boot, and nothing self-heals it in the meantime. Every other
# review item either self-corrects on a healthy watchdog cycle or is cosmetic.
# A firmware update resetting /etc is how this arises, and the exit code is
# what gets checked afterwards.
#
# Source assertion, not an outcome test: this arm fires only when /cfg/rc.local
# exists and /etc/rc.local does not source it, and staging that means writing
# to /etc/rc.local, which on a router is the live boot hook. Nothing in this
# suite is worth breaking a router's boot to assert.
assert_true "a boot hook that is never sourced is drift, not a review note" \
    code_grep "$SCRIPT_DIR/audit.sh" -E \
    '^[[:space:]]*drift "/cfg/rc\.local exists but /etc/rc\.local does not source it'

describe "audit.sh version drift — which way round"

# The else branch hardcoded "the router is behind the checkout", so auditing an
# up-to-date router from an older checkout reported the drift backwards.
AD_DIR="$TMPDIR/auditlib"; mkdir -p "$AD_DIR"
sed "s/^VERSION=.*/VERSION=\"99.0.0\"/" "$SCRIPT_DIR/lib.sh" > "$AD_DIR/lib.sh"
AD_AHEAD="$(INSTALLED_LIB="$AD_DIR/lib.sh" sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_contains "a router ahead of the checkout is reported as such" \
    "$AD_AHEAD" "the checkout is behind the router"
sed "s/^VERSION=.*/VERSION=\"0.0.1\"/" "$SCRIPT_DIR/lib.sh" > "$AD_DIR/lib.sh"
AD_BEHIND="$(INSTALLED_LIB="$AD_DIR/lib.sh" sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_contains "and a router behind it, the other way" \
    "$AD_BEHIND" "the router is behind the checkout"

describe "version_gt() — a re-install must not roll ctrld back to the pin"

assert_true  "a newer patch"         version_gt 1.5.8 1.5.7
assert_true  "a newer minor"         version_gt 1.6.0 1.5.7
assert_true  "a newer major"         version_gt 2.0.0 1.9.9
assert_false "the same version"      version_gt 1.5.7 1.5.7
assert_false "an older patch"        version_gt 1.5.6 1.5.7
assert_false "an older minor"        version_gt 1.4.9 1.5.7
# A string compare gets this backwards, and it is the case the updater reaches
# first once ctrld passes 1.9.
assert_true  "1.10.0 is newer than 1.9.0"  version_gt 1.10.0 1.9.0
assert_false "1.9.0 is not newer than 1.10.0" version_gt 1.9.0 1.10.0
assert_true  "a shorter version compares by field" version_gt 1.6 1.5.7
assert_false "trailing zeros are not newer"        version_gt 1.5.7 1.5.7.0

# The pin is a starting point; the weekly updater moves CTRLD_VERSION past it.
# Downloading it unconditionally rewound both the binary and the record.
assert_true "setup.sh keeps an installed ctrld newer than the pin" \
    code_grep "$SCRIPT_DIR/setup.sh" 'version_gt "$CTRLD_INSTALLED" "$CTRLD_PIN"'
assert_false "setup.sh no longer records the pin unconditionally" \
    code_grep "$SCRIPT_DIR/setup.sh" -E '^CTRLD_VERSION="\$\{CTRLD_PIN\}"$'
# Deleting this writes an empty CTRLD_VERSION into controld.env, which breaks
# post-cfg.sh's self-heal and the weekly updater. Nothing covered it.
assert_true "the keep branch records the version it kept" \
    code_grep "$SCRIPT_DIR/setup.sh" 'CTRLD_VERSION="$CTRLD_INSTALLED"'
assert_true "a kept binary must prove it runs" \
    code_grep "$SCRIPT_DIR/setup.sh" '/cfg/ctrld --version'

describe "write_env_file() — a rewrite must not drop the keys it does not manage"

# The six managed keys were emitted and everything else was truncated away, so
# any reconfigure.sh --protocol/--resolver/--benchmark, and every setup.sh
# re-install, silently deleted DNS_PORT, LAN_IFACES and LAN_IFACES_EXCLUDE,
# the documented overrides, along with POLICY_UPSTREAMS.
WEF="$TMPDIR/wef.env"
cat > "$WEF" << 'WEFTESTEOF'
RESOLVER_ID=old123
BOOTSTRAP_IP=76.76.2.22
CTRLD_VERSION=1.5.7
DNS_TYPE=doh3
PREFERRED_PROTOCOL=doh3
FORCED_DNS=1
DNS_PORT=5355
LAN_IFACES_EXCLUDE="br-lan_40"
POLICY_UPSTREAMS=2
WEFTESTEOF

WEF_SAVED_PATH="$PATH"
mkdir -p "$TMPDIR/wefbin"
printf '#!/bin/sh\nexit 1\n' > "$TMPDIR/wefbin/uci"   # no uci to fall back to
chmod +x "$TMPDIR/wefbin/uci"
PATH="$TMPDIR/wefbin:$PATH"

RESOLVER_ID=new456
BOOTSTRAP_IP=76.76.2.22
CTRLD_VERSION=1.5.7
DNS_TYPE=doq
PREFERRED_PROTOCOL=doq
write_env_file "$WEF"
PATH="$WEF_SAVED_PATH"

assert_file_contains "the managed keys are updated"       "$WEF" '^RESOLVER_ID=new456$'
assert_file_contains "the protocol change is recorded"    "$WEF" '^DNS_TYPE=doq$'
assert_file_contains "forced DNS is still preserved"      "$WEF" '^FORCED_DNS=1$'
assert_file_contains "a moved DNS port survives"          "$WEF" '^DNS_PORT=5355$'
assert_file_contains "an excluded VLAN survives"          "$WEF" '^LAN_IFACES_EXCLUDE="br-lan_40"$'
assert_file_contains "unknown keys survive"               "$WEF" '^POLICY_UPSTREAMS=2$'
assert_eq "no key is duplicated" "9" "$(grep -c '=' "$WEF" | tr -d ' ')"
assert_eq "the old resolver is gone" "0" "$(grep -c 'old123' "$WEF" | tr -d ' ')"

# Round-tripping must be stable: a second rewrite may not keep growing the file.
write_env_file "$WEF" 2>/dev/null
assert_eq "a second rewrite changes nothing" "9" "$(grep -c '=' "$WEF" | tr -d ' ')"

# A comment or a blank line is not a key and must not be re-emitted as one.
printf '\n# hand-added note\n' >> "$WEF"
write_env_file "$WEF" 2>/dev/null
assert_eq "comments are not carried into the key list" "0" \
    "$(grep -c '^#' "$WEF" | tr -d ' ')"
# controld.env is sourced, so a malformed line like `FOO=bar baz` runs `baz` on
# every load. Carrying arbitrary KEY=… lines forward made that permanent, where
# the truncating version at least dropped it on the next rewrite.
printf 'EVIL=bar baz\nALSO_EVIL=x;touch %s/pwned\n' "$TMPDIR" >> "$WEF"
write_env_file "$WEF" 2>/dev/null
assert_false "a value with an unquoted space is not carried" grep -q '^EVIL=' "$WEF"
assert_false "a value with a command separator is not carried" grep -q '^ALSO_EVIL=' "$WEF"
assert_file_contains "a quoted multi-word value still is" "$WEF" '^LAN_IFACES_EXCLUDE="br-lan_40"$'
# Double quotes were treated as proof a value was inert. They are not: they
# stop word splitting and globbing and leave $(...), `...` and ${...} alone,
# and this file is sourced. A quoted substitution therefore survived the
# rewrite and ran on every load_env afterwards, which is the one outcome the
# filter above exists to prevent. The three forms are asserted separately
# because they are three different pieces of shell syntax, not one.
printf 'SUBST="$(touch %s/wef-pwned)"\n' "$TMPDIR" >> "$WEF"
printf 'BACKTICK="`touch %s/wef-pwned2`"\n' "$TMPDIR" >> "$WEF"
printf 'BRACE="${HOME}"\n' >> "$WEF"
write_env_file "$WEF" 2>/dev/null
assert_false "a quoted command substitution is not carried" grep -q '^SUBST=' "$WEF"
assert_false "a quoted backtick is not carried"             grep -q '^BACKTICK=' "$WEF"
assert_false "a quoted parameter expansion is not carried"  grep -q '^BRACE=' "$WEF"
# The whole point of carrying unmanaged keys forward is the documented
# overrides, so prove the tighter filter still keeps every one of them.
assert_file_contains "a moved DNS port still survives the tighter filter" "$WEF" '^DNS_PORT=5355$'

# A trailing comment used to take the setting with it. README line 246 and
# troubleshooting.md both tell people to write exactly this, and any rewrite
# deleted it: LAN_IFACES_EXCLUDE is how a guest VLAN is kept off ControlD, so
# the watchdog started intercepting that VLAN within five minutes of an
# unrelated protocol change, with nothing said.
#
# Its own file, not the one above. Appending a commented copy to a file that
# already carries a clean LAN_IFACES_EXCLUDE proves nothing: the clean line
# satisfies the assertion whatever the filter does to the commented one, and
# reverting the filter left the whole suite green.
WEFC="$TMPDIR/wef-comment.env"
wefc_rewrite() {
    printf 'RESOLVER_ID=abc123\n' > "$WEFC"
    printf '%s\n' "$1" >> "$WEFC"
    ( RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22; CTRLD_VERSION=1.5.7
      DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3
      write_env_file "$WEFC" ) >/dev/null 2>&1
    cat "$WEFC"
}

assert_contains "a commented exclude keeps its setting" \
    "$(wefc_rewrite 'LAN_IFACES_EXCLUDE="br-lan_40"              # cover everything except these')" \
    'LAN_IFACES_EXCLUDE="br-lan_40"'
assert_contains "a commented port keeps its setting" \
    "$(wefc_rewrite 'DNS_PORT=5355   # moved off the default')" \
    'DNS_PORT=5355'
# The comment itself is not preserved, here or anywhere: standalone comment
# lines are dropped too, and were before this. Writing back less than came in
# is the direction this filter should err in.
assert_not_contains "and the comment is not carried" \
    "$(wefc_rewrite 'LAN_IFACES_EXCLUDE="br-lan_40"              # cover everything except these')" \
    '#'

# A # inside quotes belongs to the value. Stripping at the first one produced
# an unbalanced quote, and the shell reads NOTE="a # b" as a single word.
assert_contains "a hash inside quotes is part of the value" \
    "$(wefc_rewrite 'HASHY="a # b"')" 'HASHY="a # b"'
wefc_rewrite 'HASHY="a # b"' >/dev/null
assert_eq "and it still agrees with what the shell sets" "a # b" \
    "$(sh -c '. "$1" >/dev/null 2>&1; printf "%s" "${HASHY:-}"' _ "$WEFC")"

# Only a # that begins a word is a comment, so this is the value 5355#x, which
# the character class rejects exactly as it did before.
assert_not_contains "a hash with no blank before it is not a comment" \
    "$(wefc_rewrite 'TIGHT=5355#x')" 'TIGHT='

# The comment must not become a way past the filter. Each of these is rejected
# on the whole line before any comment handling runs.
assert_not_contains "a substitution in a comment is not carried" \
    "$(wefc_rewrite "CSUB=ok   # \$(touch $TMPDIR/c-pwned)")" 'CSUB='
assert_not_contains "a backtick in a comment is not carried" \
    "$(wefc_rewrite 'CTICK=ok   # `touch /tmp/c-pwned2`')" 'CTICK='
assert_not_contains "a backslash in a comment is not carried" \
    "$(wefc_rewrite 'CBACK=ok   # trailing\\')" 'CBACK='
assert_false "and none of them ran" test -e "$TMPDIR/c-pwned"

# An unbalanced quote cannot be measured to a closing quote, and a file
# carrying one cannot be sourced at all.
assert_not_contains "an unbalanced quote is not carried" \
    "$(wefc_rewrite 'UNBAL="oops')" 'UNBAL='

# Until now a rejected line just vanished. Everything this filter refuses is
# something a person typed into the file on purpose, and the guest VLAN that
# stopped being excluded is what a silent drop costs, so the keys are named at
# the moment they stop being carried. On stderr, so a caller capturing the
# writer's output is unaffected.
wefc_stderr() {
    printf 'RESOLVER_ID=abc123\n' > "$WEFC"
    printf '%s\n' "$1" >> "$WEFC"
    # stdout discarded inside, stderr of the subshell out: the report is on
    # stderr and the writer prints nothing else worth reading here.
    ( RESOLVER_ID=abc123; BOOTSTRAP_IP=76.76.2.22; CTRLD_VERSION=1.5.7
      DNS_TYPE=doh3; PREFERRED_PROTOCOL=doh3
      write_env_file "$WEFC" >/dev/null ) 2>&1
}
assert_contains "a dropped key is named"      "$(wefc_stderr 'EVIL=bar baz')" "EVIL"
# The substitution is the case most worth naming, and the first version of this
# report missed it: the dangerous-character test returns before the reporting
# line, so the one value that would run on every load was the one dropped in
# silence.
assert_contains "a command substitution is named"  "$(wefc_stderr 'SUBST="$(id)"')"  "SUBST"
assert_contains "a backtick is named"              "$(wefc_stderr 'TICK=`id`')"      "TICK"
assert_contains "an unbalanced quote is named"     "$(wefc_stderr 'UNBAL="oops')"    "UNBAL"
# A managed key is rewritten rather than dropped, so it must not be reported as
# lost; nor may a value that survives.
assert_not_contains "a carried key is not reported" \
    "$(wefc_stderr 'LAN_IFACES_EXCLUDE="br-lan_40"   # guest')" "LAN_IFACES_EXCLUDE"
assert_eq "and a file with nothing to drop says nothing" "" \
    "$(wefc_stderr 'DNS_PORT=5355')"
assert_not_contains "a managed key is not reported as dropped" \
    "$(wefc_stderr 'DNS_TYPE=doq')" "DNS_TYPE"
assert_file_contains "an excluded VLAN still survives"      "$WEF" '^LAN_IFACES_EXCLUDE="br-lan_40"$'
assert_file_contains "an unknown key still survives"        "$WEF" '^POLICY_UPSTREAMS=2$'
# Sourcing what was written must not run anything. If a substitution had been
# carried, this is where it would fire.
# shellcheck source=/dev/null
( . "$WEF" ) >/dev/null 2>&1 || true
assert_false "and sourcing the result executes nothing" test -e "$TMPDIR/wef-pwned"
assert_false "nor by way of a backtick" test -e "$TMPDIR/wef-pwned2"

# Backslash, which the character class below the quoting test cannot handle and
# which the two awks disagree about. BusyBox awk reads the \/ in that class as
# also admitting a literal backslash and GNU awk does not, so the first of these
# was dropped in CI and kept on the router: a value ending in a backslash is a
# line continuation, so it swallows the DNS_PORT line under it and load_env then
# reports no port at all. The second passes the quoting test in both awks, since
# a backslash is not a quote, and makes the file a syntax error: load_env sources
# with `.`, a special builtin, so every script dies at exit 2 printing nothing.
printf 'TRAILING=ends-with\\\n' >> "$WEF"
printf 'QUOTED="also ends with\\"\n' >> "$WEF"
write_env_file "$WEF" 2>/dev/null
assert_false "an unquoted value ending in a backslash is not carried" grep -q '^TRAILING=' "$WEF"
assert_false "a quoted value ending in a backslash is not carried"   grep -q '^QUOTED=' "$WEF"
# The outcome both of those protect: the file still sources cleanly, and the key
# under them still arrives. A continuation would swallow it and report empty.
assert_true "the rewritten file still sources without error" sh -c '. "$1" >/dev/null 2>&1' _ "$WEF"
assert_eq "and the port under them is still readable" "5355" \
    "$(sh -c '. "$1" >/dev/null 2>&1; printf "%s" "${DNS_PORT:-}"' _ "$WEF")"
unset DNS_PORT LAN_IFACES_EXCLUDE POLICY_UPSTREAMS

describe "stop_ctrld() — kills every instance, not one packed argument"

# pidof prints every PID on one line, and `kill "$(pidof ctrld)"` quoted them
# into a single argument: kill rejects "4143 4144" wholesale and nothing dies.
# It only bites once a second ctrld exists, a benchmark or the self-upgrade
# probe, which is exactly when stopping cleanly matters, and why a single
# instance made it look fine for so long.
#
# kill is a builtin, so a PATH stub cannot see it; overriding it as a function
# does, in both dash and BusyBox ash. The defect is the argument packing, so
# the calls made are the thing to assert on.
SC_LOG="$TMPDIR/kill-calls.log"
: > "$SC_LOG"
(
    kill()  { printf '%s\n' "$*" >> "$SC_LOG"; }
    pidof() { echo "4143 4144"; }
    sleep() { :; }
    stop_ctrld
)
assert_eq "one kill call per PID"  "2"    "$(grep -c . "$SC_LOG" | tr -d ' ')"
assert_eq "the first PID, alone"   "4143" "$(sed -n 1p "$SC_LOG")"
assert_eq "the second PID, alone"  "4144" "$(sed -n 2p "$SC_LOG")"

# The same expression was copied into the generated scripts and the benchmark
# and update paths, so no caller may reintroduce it.
for _ks in lib.sh setup.sh reconfigure.sh uninstall.sh benchmark.sh status.sh audit.sh; do
    assert_false "${_ks} does not pack multiple PIDs into one kill" \
        code_grep "$SCRIPT_DIR/$_ks" -E 'kill (-9 )?"\$\(pidof'
done

describe "start_ctrld() — a timeout in seconds, not one per slow probe"

# `timeout` was an iteration count, and every iteration ran an nslookup against
# the DNS port. On a Route 10 a query to a closed port costs the resolver's own
# timeout, about 5s, so start_ctrld(15) took roughly 90 seconds. The watchdog's
# worst case is one start plus three fallback attempts, which put a full recovery
# cycle at over six minutes against a five-minute cron interval: instances
# overlapped, raced over the fail-count file, and the teardown was never reached.
# Invisible in a sandbox, where a query to a closed local port fails instantly.
#
# Both halves of the fix are asserted: no query is made while the port is closed,
# and a slow query cannot outrun the timeout.
SC_PROBES="$TMPDIR/start-probes.log"

: > "$SC_PROBES"
SC_T0=$(date +%s)
if (
    DNS_PORT=15354
    port_in_use() { return 1; }
    check_dns()   { echo probe >> "$SC_PROBES"; sleep 3; return 1; }
    nohup()       { :; }
    start_ctrld /dev/null 2
); then SC_R=0; else SC_R=1; fi
SC_ELAPSED=$(( $(date +%s) - SC_T0 ))

assert_eq "a start that never binds is reported as failed" "1" "$SC_R"
assert_eq "no DNS query is made while the port is closed" "0" \
    "$(grep -c . "$SC_PROBES" | tr -d ' ')"
SC_FAST=no; [ "$SC_ELAPSED" -le 6 ] && SC_FAST=yes
assert_eq "a failed start costs about the timeout, not a probe timeout per iteration" \
    "yes" "$SC_FAST"

# Port open but the resolver slow to answer: the wall-clock bound must still hold,
# so the loop stops at the first probe that crosses the deadline rather than
# running `timeout` probes of unknown cost.
: > "$SC_PROBES"
SC_T0=$(date +%s)
if (
    DNS_PORT=15354
    port_in_use() { return 0; }
    check_dns()   { echo probe >> "$SC_PROBES"; sleep 3; return 1; }
    nohup()       { :; }
    start_ctrld /dev/null 2
); then SC_R=0; else SC_R=1; fi
SC_ELAPSED=$(( $(date +%s) - SC_T0 ))

assert_eq "a slow probe stops at the deadline, not after timeout probes" "1" \
    "$(grep -c . "$SC_PROBES" | tr -d ' ')"
SC_BOUNDED=no; [ "$SC_ELAPSED" -le 6 ] && SC_BOUNDED=yes
assert_eq "a slow probe cannot outrun the timeout" "yes" "$SC_BOUNDED"

# The success path still works, and costs nothing extra.
if (
    DNS_PORT=15354
    port_in_use() { return 0; }
    check_dns()   { return 0; }
    nohup()       { :; }
    start_ctrld /dev/null 2
); then SC_R=0; else SC_R=1; fi
assert_eq "a listener that answers is reported ready" "0" "$SC_R"

# The generated watchdog carries its own copy of start_ctrld for the case where
# lib.sh is missing. It ran the same unguarded loop, so it needs the same gate,
# that copy is heredoc text and nothing else in this suite executes it.
assert_eq "the generated watchdog's inline start_ctrld gates on the port too" "1" \
    "$(sed -n "/^cat > \/cfg\/watchdog.sh << 'WATCHDOG'/,/^WATCHDOG$/p" "$SCRIPT_DIR/setup.sh" \
        | grep -c 'port_in_use "$DNS_PORT" && check_dns' | tr -d ' ')"

# setup.sh carried a private _port_in_use with the same two commands. The dead-code
# scan only catches an unused function, not a duplicated one.
assert_false "setup.sh no longer carries a private copy of the port check" \
    code_grep "$SCRIPT_DIR/setup.sh" '_port_in_use()'

describe "list_upstreams() / policy_rule_count() — what the readouts report"

# status.sh and reconfigure.sh --show both walked upstream blocks with
# `grep -A<n>` at a fixed offset, and both had it wrong: -A1 stops at
# bootstrap_ip so every name printed empty, -A3 stops at name so no protocol
# ever printed. Both rule counts matched `="` / `=\[` while the rules this
# project writes are `{"key" = [...]}` with spaces, so both were always 0.
LU="$TMPDIR/upstreams.toml"
write_ctrld_config "$LU" abc123 76.76.2.22 doh3
cat >> "$LU" << 'LUEOF'

[upstream.1]
    bootstrap_ip = "76.76.2.22"
    endpoint = "kids5678.dns.controld.com"
    name = "ControlD-Kids"
    timeout = 5000
    type = "doq"
    send_client_info = true

[upstream.10]
    endpoint = "https://dns.quad9.net/dns-query"
    name = "Quad9"
    type = "doh"

[network.1]
    cidrs = ["192.168.10.0/24"]
    name = "Kids"

[listener.0.policy]
    name = "Split DNS Policy"
    networks = [
    {"network.1" = ["upstream.1"]},
    ]
    macs = [
    {"AA:BB:CC:DD:EE:01" = ["upstream.1"]},
    {"aa:bb:cc:dd:ee:02" = ["upstream.1"]},
    ]
LUEOF

LU_OUT="$(list_upstreams "$LU")"
assert_eq "one line per upstream" "3" "$(printf '%s\n' "$LU_OUT" | wc -l | tr -d ' ')"
assert_contains "the main upstream carries its name and type" "$LU_OUT" "0.*ControlD.*doh3"
assert_contains "a policy upstream keeps its own name and type" "$LU_OUT" "1.*ControlD-Kids.*doq"
# A grep for "[upstream.1]" also matches [upstream.10]. The parse must not.
assert_contains "a two-digit index is read whole" "$LU_OUT" "10.*Quad9.*doh"
# Checked on the real tab-separated fields. The previous form used `sh -c` with
# an unexported variable AND `\t` inside an ERE, where it means a literal "t",
# it could not fail, and an empty name shifts the protocol into the name column
# because tab is IFS whitespace.
assert_eq "no upstream reports an empty name"     "0" \
    "$(list_upstreams "$LU" | $AWK -F'\t' '$2 == "" { n++ } END { print n + 0 }')"
assert_eq "no upstream reports an empty protocol" "0" \
    "$(list_upstreams "$LU" | $AWK -F'\t' '$3 == "" { n++ } END { print n + 0 }')"
# A block with no name at all must still occupy its column.
LU_NONAME="$TMPDIR/noname.toml"
printf '[upstream.0]\n    type = "doq"\n' > "$LU_NONAME"
assert_eq "a nameless upstream keeps three fields" "(unnamed)" \
    "$(list_upstreams "$LU_NONAME" | $AWK -F'\t' '{ print $2 }')"
assert_eq "and its protocol stays in the protocol column" "doq" \
    "$(list_upstreams "$LU_NONAME" | $AWK -F'\t' '{ print $3 }')"

assert_eq "MAC rules are counted, in either case"  "2" "$(policy_rule_count "$LU" mac)"
assert_eq "network rules are counted"              "1" "$(policy_rule_count "$LU" network)"
# A bare config has a policy-free [network.0]; neither count may invent rules.
assert_eq "a config with no policy reports no MAC rules"     "0" "$(policy_rule_count "$TEST_CONF" mac)"
assert_eq "a config with no policy reports no network rules" "0" "$(policy_rule_count "$TEST_CONF" network)"
assert_eq "a missing file reports zero" "0" "$(policy_rule_count "$TMPDIR/no-such.toml" mac)"

describe "resolver_from_endpoint() — identity extraction"
assert_eq "DoH form"  "abc123" "$(resolver_from_endpoint https://dns.controld.com/abc123)"
assert_eq "DoQ form"  "abc123" "$(resolver_from_endpoint abc123.dns.controld.com)"
assert_false "rejects a non-ControlD endpoint" resolver_from_endpoint https://dns.quad9.net/dns-query
assert_false "rejects empty input"             resolver_from_endpoint ""
# retarget must agree with get_endpoint, or the two would drift apart
assert_eq "agrees with get_endpoint for doq" "$(get_endpoint doq abc123)" "abc123.dns.controld.com"
assert_eq "agrees with get_endpoint for doh3" "$(get_endpoint doh3 abc123)" "https://dns.controld.com/abc123"

describe "split-DNS config survives a rewrite"

# The exact extraction apply_and_restart uses to carry policy config across a
# regenerated ctrld.toml. Copying header lines without their bodies (what this
# used to do) leaves ctrld with empty tables and it refuses to start.
SPLIT_BAK="$TMPDIR/split.toml.bak"
cat > "$SPLIT_BAK" << 'SPLITEOF'
[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "Everyone"
[upstream.0]
    endpoint = "https://dns.controld.com/main"
    name = "ControlD"
[listener.0]
    ip = "0.0.0.0"
    port = 5354
[upstream.1]
    endpoint = "https://dns.controld.com/kids"
    name = "ControlD-Kids"
    type = "doh3"
[network.3]
    cidrs = ["192.168.30.0/24"]
    name = "Kids"
[listener.0.policy]
    name = "Split DNS Policy"
    networks = [
    {"network.3" = ["upstream.1"]}
    ]
SPLITEOF

SPLIT_NEW="$TMPDIR/split-rewritten.toml"
write_ctrld_config "$SPLIT_NEW" "main" "76.76.2.22" "doq"
{
    toml_blocks "$SPLIT_BAK" '[upstream.' '[upstream.0]'
    toml_blocks "$SPLIT_BAK" '[network.' '[network.0]'
    toml_blocks "$SPLIT_BAK" '[listener.0.policy]'
} >> "$SPLIT_NEW"

assert_file_contains "policy upstream survives"      "$SPLIT_NEW" '\[upstream.1\]'
assert_file_contains "with its endpoint body"        "$SPLIT_NEW" 'dns.controld.com/kids'
assert_file_contains "policy network survives"       "$SPLIT_NEW" '\[network.3\]'
assert_file_contains "with its cidrs body"           "$SPLIT_NEW" '192.168.30.0/24'
assert_file_contains "the policy table survives"     "$SPLIT_NEW" 'network.3" = \["upstream.1"\]'
assert_file_contains "main upstream took the new protocol" "$SPLIT_NEW" 'endpoint = "main.dns.controld.com"'
# Every table the policy points at must exist with a body, or ctrld refuses the config
assert_eq "no empty [upstream.N] tables" "0" \
    "$(awk '/^\[upstream\./ { if (prev ~ /^\[/) n++ } { prev = $0 } END { print n + 0 }' "$SPLIT_NEW")"
assert_eq "policy allocates past the preserved blocks" "4" \
    "$(next_toml_index "$SPLIT_NEW" network)"

describe "wait_for() — a boot-time wait must be bounded"

# post-cfg.sh runs from rc.local at every boot and waited on two conditions with
# a bare "while ! cmd; do sleep N; done" and no limit: the https-dns-proxy uci
# section appearing, and an ICMP reply from the bootstrap host. Either can fail
# to arrive on an ordinary router, and the self-heal then spins forever with no
# timeout, no fallback and nothing logged — the router boots and DNS is simply
# never configured.
#
# That this assertion returns at all is the proof: an unbounded wait_for would
# hang the suite here rather than fail it.
assert_false "gives up once the tries are spent"      wait_for 3 0 false
assert_true  "returns as soon as the command succeeds" wait_for 3 0 true

WF_TRIES="$TMPDIR/wf.tries"
wf_always_fails() { printf 'x' >> "$WF_TRIES"; return 1; }
: > "$WF_TRIES"
# "|| true": this returns 1 by design, and the suite runs under set -e (line 6),
# where a bare failing command at top level ends the run — silently, mid-file,
# which is exactly what it did when this test was first written.
wait_for 4 0 wf_always_fails || true
assert_eq "tries exactly as many times as asked" "4" "$(wc -c < "$WF_TRIES" | tr -d ' ')"

wf_third_time_lucky() {
    printf 'x' >> "$WF_TRIES"
    [ "$(wc -c < "$WF_TRIES" | tr -d ' ')" -ge 3 ]
}
: > "$WF_TRIES"
assert_true "succeeds on a later try"     wait_for 5 0 wf_third_time_lucky
assert_eq   "and stops trying once it has" "3" "$(wc -c < "$WF_TRIES" | tr -d ' ')"

# The generated boot script, checked two ways: no bare unbounded wait survives,
# and the lib.sh-absent block carries its own bounded copy. Without that copy a
# router missing lib.sh would call an undefined wait_for — "not found" returns
# non-zero, so the wait would read as failed on the first try instead of waiting.
WF_PC="$TMPDIR/wait-for-post-cfg.sh"
sed -n "/cat > \/cfg\/post-cfg.sh << 'BOOTSCRIPT'/,/^BOOTSCRIPT$/p" "$SCRIPT_DIR/setup.sh" > "$WF_PC"
assert_false "no unbounded 'while ! ...; do sleep' remains in post-cfg.sh" \
    grep -qE 'while ! .*do sleep' "$WF_PC"

WF_FN="$(sed -n '/^    wait_for() {/,/^    }$/p' "$WF_PC")"
assert_true "the lib.sh-absent block carries wait_for too" [ -n "$WF_FN" ]
assert_false "and that copy is bounded as well" sh -c "${WF_FN}
wait_for 3 0 false"

describe "post-cfg.sh must not call a helper its fallback block lacks"

# The lib.sh-absent block defines a deliberately minimal helper set. Anything
# post-cfg.sh calls that is not in it has to be guarded with command -v, or a
# router recovering without lib.sh prints "<name>: not found" into its boot log
# — harmless, because every such call carries "|| true", but it reads as a
# failure in exactly the log someone is combing through to find out what broke.
#
# Observed on the router during the 1.10.0 sweep: set_fallback_resolver was
# called bare while its two neighbours were guarded. Checked for all three by
# name rather than for the one that was wrong, so a fourth cannot slip in.
PCG_FILE="$TMPDIR/post-cfg-guards.sh"
sed -n "/cat > \/cfg\/post-cfg.sh << 'BOOTSCRIPT'/,/^BOOTSCRIPT$/p" "$SCRIPT_DIR/setup.sh" > "$PCG_FILE"
assert_true "the boot script extracts" [ -s "$PCG_FILE" ]

for _pcg in set_fallback_resolver ensure_firewall_user_rules ensure_forced_dns; do
    # Comment lines are excluded: they name these helpers when explaining why
    # the guard is there, and a comment cannot invoke anything.
    _pcg_bare="$(grep -F "$_pcg" "$PCG_FILE" \
        | grep -v 'command -v' \
        | grep -v '^[[:space:]]*#' || true)"
    assert_eq "post-cfg.sh guards ${_pcg}" "" "$_pcg_bare"
done
unset _pcg _pcg_bare

# dnsmasq reads leasetime from the per-interface "config dhcp" sections and from
# "config host", in dhcp_add() and dhcp_host_add(). It never reads it from the
# "config dnsmasq" section, so setting it there wrote a key nothing consumes.
# The router's real lease time comes from dhcp.lan*.leasetime and is not ours.
#
# Inherited from the original project and carried through this fork, where it
# read as a DHCP setting the installer had quietly taken over. It never was one.
assert_false "post-cfg.sh does not write leasetime on the dnsmasq section" \
    grep -q 'dnsmasq\[0\]\.leasetime' "$PCG_FILE"

describe "next_toml_index() — index allocation"
IDX_CONF="$TMPDIR/idx.toml"
cat > "$IDX_CONF" << 'IDXEOF'
[network.0]
    cidrs = ["0.0.0.0/0"]
[upstream.0]
    name = "a"
[upstream.5]
    name = "b"
[network.3]
    cidrs = ["192.168.9.0/24"]
IDXEOF
assert_eq "next network index skips gaps"  "4" "$(next_toml_index "$IDX_CONF" network)"
assert_eq "next upstream index skips gaps" "6" "$(next_toml_index "$IDX_CONF" upstream)"
assert_eq "missing config starts at 0"     "0" "$(next_toml_index "$TMPDIR/none.toml" network)"

describe "toml_blocks() — whole-table extraction"
POL_CONF="$TMPDIR/policy.toml"
cat > "$POL_CONF" << 'POLEOF'
[upstream.0]
    name = "ControlD"
[upstream.1]
    name = "Kids"
    endpoint = "kid123.dns.controld.com"
[listener.0.policy]
    networks = [
    {"network.1" = ["upstream.1"]},
    ]
POLEOF
extra_up="$(toml_blocks "$POL_CONF" '[upstream.' '[upstream.0]')"
assert_contains "extracts the extra upstream header" "$extra_up" "\[upstream.1\]"
assert_contains "extracts its body too"              "$extra_up" "kid123.dns.controld.com"
assert_not_contains "does not take upstream.0" "$extra_up" "ControlD"
pol="$(toml_blocks "$POL_CONF" '[listener.0.policy]')"
assert_contains "extracts the policy table" "$pol" 'network.1'

# ══════════════════════════════════════════════════════════════════
# ENV FILE TESTS
# ══════════════════════════════════════════════════════════════════

describe "load_env() — env file parsing"

cat > "$TMPDIR/test.env" << 'EOF'
RESOLVER_ID=test123
BOOTSTRAP_IP=1.2.3.4
CTRLD_VERSION=1.5.0
DNS_TYPE=doq
EOF
load_env "$TMPDIR/test.env"
assert_eq "resolver from env"     "test123" "$RESOLVER_ID"
assert_eq "bootstrap from env"    "1.2.3.4" "$BOOTSTRAP_IP"
assert_eq "version from env"      "1.5.0"   "$CTRLD_VERSION"
assert_eq "type from env"         "doq"     "$DNS_TYPE"
assert_eq "PREFERRED_PROTOCOL defaults to DNS_TYPE" "doq" "$PREFERRED_PROTOCOL"

# Test defaults for missing values (reset variables first)
DNS_TYPE=""
PREFERRED_PROTOCOL=""
BOOTSTRAP_IP=""
cat > "$TMPDIR/test-minimal.env" << 'EOF'
RESOLVER_ID=abc
CTRLD_VERSION=1.5.0
EOF
load_env "$TMPDIR/test-minimal.env"
assert_eq "default DNS_TYPE is doh3"      "doh3"        "$DNS_TYPE"
assert_eq "default PREFERRED_PROTOCOL follows DNS_TYPE" "doh3" "$PREFERRED_PROTOCOL"
assert_eq "default bootstrap IP"          "76.76.2.22"  "$BOOTSTRAP_IP"

# Test load_env failure on missing file
assert_false "missing env file returns error" load_env "$TMPDIR/nonexistent.env"

# ══════════════════════════════════════════════════════════════════
# SCRIPT FLAG TESTS
# ══════════════════════════════════════════════════════════════════

describe "write_env_file() — the rewrite must not lose the old value"

# `cat > file << EOF` truncates the target before the here-document expands, so
# reading the same file from inside the here-doc always saw it empty. setup.sh
# did exactly that for FORCED_DNS. preserved_forced_dns was tested on its own
# and passed; the bug lived in the sequence around it, and only the uci
# fallback hid it. uci is stubbed to say "off" here so nothing can mask it.
WEF_SAVED_PATH="$PATH"
mkdir -p "$TMPDIR/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMPDIR/bin/uci"   # uci knows nothing
chmod +x "$TMPDIR/bin/uci"
PATH="$TMPDIR/bin:$PATH"

RESOLVER_ID=newid123
BOOTSTRAP_IP=76.76.2.22
CTRLD_VERSION=1.5.7
DNS_TYPE=doh3
PREFERRED_PROTOCOL=doh3

WEF_ENV="$TMPDIR/wef.env"
printf 'RESOLVER_ID=oldid999\nFORCED_DNS=1\n' > "$WEF_ENV"
write_env_file "$WEF_ENV"

assert_file_contains "forced DNS survives the rewrite" "$WEF_ENV" "FORCED_DNS=1"
assert_file_contains "the new resolver is written"     "$WEF_ENV" "RESOLVER_ID=newid123"
assert_false "the old resolver is gone" grep -q 'oldid999' "$WEF_ENV"

# A disabled install must stay disabled: the preserve must not be a hardcoded 1
printf 'FORCED_DNS=0\n' > "$WEF_ENV"
write_env_file "$WEF_ENV"
assert_file_contains "a disabled install stays disabled" "$WEF_ENV" "FORCED_DNS=0"

# First install: no file at all
rm -f "$WEF_ENV"
write_env_file "$WEF_ENV"
assert_file_contains "a fresh install starts disabled" "$WEF_ENV" "FORCED_DNS=0"
assert_file_contains "fresh install records the protocol" "$WEF_ENV" "PREFERRED_PROTOCOL=doh3"

PATH="$WEF_SAVED_PATH"
unset RESOLVER_ID BOOTSTRAP_IP CTRLD_VERSION DNS_TYPE PREFERRED_PROTOCOL

# Both writers must go through it, or the bug comes back in one of them
assert_true "setup.sh writes the env file through the helper" \
    code_grep "$SCRIPT_DIR/setup.sh" '^write_env_file /cfg/controld.env'
assert_true "reconfigure.sh does too" \
    code_grep "$SCRIPT_DIR/reconfigure.sh" 'write_env_file /cfg/controld.env'
assert_false "no here-doc reads the file it is truncating" \
    code_grep "$SCRIPT_DIR/setup.sh" 'FORCED_DNS=$(preserved_forced_dns'

describe "set_fallback_resolver() — the backstop must rotate too"

# https-dns-proxy answers whenever ctrld is down. Before this existed,
# reconfigure.sh --resolver changed ctrld but not the fallback, so a resolver
# rotated away from, a leaked one say, kept resolving for the whole LAN
# every time ctrld restarted.
FBR_SAVED_PATH="$PATH"
PATH="$TMPDIR/ucibin:$PATH"          # stateful fake uci from the section above
UCI_STORE="$TMPDIR/fbr.store"; export UCI_STORE
: > "$UCI_STORE"
uci set https-dns-proxy.@https-dns-proxy[0]=https-dns-proxy
uci set https-dns-proxy.@https-dns-proxy[1]=https-dns-proxy

set_fallback_resolver newid123 76.76.2.22 >/dev/null 2>&1 || true

assert_eq "instance 0 moved to the new resolver" "https://dns.controld.com/newid123" \
    "$(uci -q get 'https-dns-proxy.@https-dns-proxy[0].resolver_url')"
assert_eq "instance 1 moved too" "https://dns.controld.com/newid123" \
    "$(uci -q get 'https-dns-proxy.@https-dns-proxy[1].resolver_url')"
assert_eq "bootstrap follows the resolver" "76.76.2.22" \
    "$(uci -q get 'https-dns-proxy.@https-dns-proxy[0].bootstrap_dns')"
# Only instances that exist are touched: no phantom third one is created
assert_eq "no instance is invented" "" \
    "$(uci -q get 'https-dns-proxy.@https-dns-proxy[2].resolver_url')"

# With no instances configured it reports failure rather than silently passing
: > "$UCI_STORE"
# assert_false, not `assert_true sh -c "! ..."`. sh -c starts a new shell that
# has never sourced lib.sh, so the function is not defined there: the shell
# reported 127, `!` turned that into 0, and the assertion passed whatever the
# function did. assert_false runs it in this shell, where it exists.
assert_false "reports failure when there is nothing to update" \
    set_fallback_resolver x 1.1.1.1

PATH="$FBR_SAVED_PATH"
unset UCI_STORE

# Both callers must use it: setup.sh on install, reconfigure.sh on rotation
assert_true "setup.sh points the fallback at ControlD" \
    code_grep "$SCRIPT_DIR/setup.sh" 'set_fallback_resolver "$RESOLVER_ID"'
RECONF_DO_RESOLVER="$(code_only "$SCRIPT_DIR/reconfigure.sh" \
    | sed -n '/^do_resolver/,/^}/p')"
assert_contains "reconfigure.sh rotates the fallback with the resolver" \
    "$RECONF_DO_RESOLVER" "set_fallback_resolver"

describe "setup.sh — a re-install must replace the installed lib.sh"

# README calls re-running setup.sh the upgrade path. On it, LIB_DIR is /tmp and
# /cfg/lib.sh always exists, and the preamble tried /cfg/lib.sh before the
# network: the installer sourced the old library, and the install step found
# nothing to copy and left /cfg/lib.sh alone. The five utility scripts are
# re-downloaded unconditionally, so an upgrade replaced them and not the
# library all five source — and a new audit.sh against a lib.sh with no
# dns_redirect_rules in it prints a pass for a check that never ran, which is
# the exact failure this suite exists to catch.
#
# The two real blocks are lifted out of setup.sh and run against a sandbox:
# a fake wget, a fake LIB_DIR, and /cfg rewritten to a temp directory, since a
# test cannot write to the real one. What is asserted is which lib.sh is in
# place afterwards.
UPG="$TMPDIR/upgrade"
upg_frag() {
    # $1 = sandbox cfg dir. Preamble, then the install step, with /cfg rebound.
    {
        printf 'REPO_BASE="https://example.invalid/master"\n'
        # No line cap: the range already stops at the first column-0 `fi`,
        # which closes this block. A cap silently sliced it mid-if the moment
        # the preamble grew.
        code_only "$SCRIPT_DIR/setup.sh" | sed -n '/^LIB_DIR="\$(dirname "\$0")"/,/^fi$/p'
        printf '\n'
        code_only "$SCRIPT_DIR/setup.sh" \
            | sed -n '/^if \[ -f "\${LIB_DIR}\/lib.sh" \] \&\& \[ "\${LIB_DIR}\/lib.sh" != "\/cfg\/lib.sh" \]/,/^fi$/p'
        printf '\nprintf "SOURCED:%%s\\n" "$LIB_MARKER"\n'
    } | sed "s#/cfg/#${1}/#g"
}
upg_run() {
    # $1 = sandbox root, $2 = "online" or "offline", $3 = what sits in LIB_DIR:
    # "" nothing, "stale" a lone leftover lib.sh, "checkout" a lib.sh with the
    # rest of the project beside it, "staged" one put there by hand.
    rm -rf "$1"; mkdir -p "$1/bin" "$1/cfg" "$1/tmp"
    if [ "$2" = "online" ]; then
        cat > "$1/bin/wget" << 'UPGWGETEOF'
#!/bin/sh
_o=""; while [ $# -gt 0 ]; do case "$1" in -O) _o="$2"; shift 2 ;; *) shift ;; esac; done
printf 'LIB_MARKER=fresh-from-master
' > "$_o"; exit 0
UPGWGETEOF
    else
        printf '#!/bin/sh\nexit 1\n' > "$1/bin/wget"
    fi
    chmod +x "$1/bin/wget"
    printf 'LIB_MARKER=old-on-router\n' > "$1/cfg/lib.sh"
    case "${3:-}" in
        stale)    printf 'LIB_MARKER=stale-in-tmp\n'   > "$1/tmp/lib.sh" ;;
        staged)   printf 'LIB_MARKER=staged-by-hand\n' > "$1/tmp/lib.sh" ;;
        checkout) printf 'LIB_MARKER=from-checkout\n'  > "$1/tmp/lib.sh"
                  printf '#\n' > "$1/tmp/uninstall.sh" ;;
    esac
    upg_frag "$1/cfg" > "$1/tmp/frag.sh"
    ( PATH="$1/bin:$PATH"; sh "$1/tmp/frag.sh" 2>/dev/null )
    printf 'INSTALLED:'; cat "$1/cfg/lib.sh"
}

# The upgrade path: a fresh library must reach /cfg, and the installer must run
# against that one rather than the copy it is replacing.
UPG_ON="$(upg_run "$UPG/on" online)"
assert_contains "a re-install sources the freshly downloaded lib.sh" \
    "$UPG_ON" "SOURCED:fresh-from-master"
assert_contains "and installs it over the old one" \
    "$UPG_ON" "INSTALLED:LIB_MARKER=fresh-from-master"
assert_not_contains "so the old library is gone afterwards" \
    "$UPG_ON" "INSTALLED:LIB_MARKER=old-on-router"

# Offline on a router that already has one: keep going with what is installed
# rather than refusing to run, and do not overwrite it with a failed download.
UPG_OFF="$(upg_run "$UPG/off" offline)"
assert_contains "an offline re-install falls back to the installed lib.sh" \
    "$UPG_OFF" "SOURCED:old-on-router"
assert_contains "and leaves it in place" \
    "$UPG_OFF" "INSTALLED:LIB_MARKER=old-on-router"

# A lone lib.sh in LIB_DIR is debris, not a checkout. On the documented path
# only setup.sh is downloaded, to /tmp, and lib.sh lands beside it — so a second
# run in the same boot used that leftover however old it was. /tmp is tmpfs, so
# only a reboot cleared it.
UPG_STALE="$(upg_run "$UPG/stale" online stale)"
assert_contains "a leftover lib.sh in /tmp is replaced, not reused" \
    "$UPG_STALE" "SOURCED:fresh-from-master"
assert_not_contains "the leftover is not what runs" "$UPG_STALE" "SOURCED:stale-in-tmp"

# With the rest of the project beside it, it is a checkout and its lib.sh is
# the one under test. Downloading master's over it would mean nobody could ever
# test a local change to lib.sh through setup.sh.
UPG_CO="$(upg_run "$UPG/checkout" online checkout)"
assert_contains "a checkout's own lib.sh is used" "$UPG_CO" "SOURCED:from-checkout"
assert_not_contains "and master's is not fetched over it" "$UPG_CO" "fresh-from-master"

# Offline, a lib.sh staged by hand next to setup.sh wins over the installed
# one — the failure message tells the reader to put it exactly there, and on an
# upgrade it is the newer of the two.
UPG_STAGED="$(upg_run "$UPG/staged" offline staged)"
assert_contains "a hand-staged lib.sh is preferred when offline" \
    "$UPG_STAGED" "SOURCED:staged-by-hand"
assert_not_contains "not the installed copy" "$UPG_STAGED" "SOURCED:old-on-router"

# And a failed download must not have destroyed it. wget -O truncates its
# target before it knows whether the transfer will work, so downloading onto
# the staged file would leave nothing to fall back to.
assert_contains "the staged copy survives the failed download" \
    "$UPG_STAGED" "INSTALLED:LIB_MARKER=staged-by-hand"

describe "setup.sh — the closing verdict follows the checks"

# Step 5 printed its checks and then, whatever they said, a green "Setup
# Complete!" and "Your DNS is now routed through ControlD", and exited 0. A
# mistyped resolver ID produced a failed ctrld check, no redirects and no
# system DNS, followed by that banner, and a script or agent driving the
# installer saw success.
#
# So run the whole installer. Every absolute path it touches is rewritten into
# a sandbox, including /etc/init.d and /tmp, because this suite also runs on a
# router and must not restart the real dnsmasq. The stub ctrld is a real sleep
# the sandbox owns, so stop_ctrld only ever kills something started here.
SV="$TMPDIR/setup-verdict"
sv_run() {
    # $1 = sandbox root, $2 = "good" or "broken" (ctrld runs but never answers),
    # $3 = answers to feed the interactive installer. Without it the run is
    # the non-interactive form, with SV_RESOLVER (default abc123) and
    # SV_PROTOCOL (default doh3). SV_BENCH_FAIL is an ERE: a throwaway ctrld on the benchmark port
    # whose config matches it does not answer, which is how a resolver ID
    # ControlD refuses or a protocol the network blocks looks to the check.
    # SV_REUSE=1 runs again over the sandbox a previous run left, and SV_KEEP=1
    # leaves its ctrld running for that, which is a re-install.
    _sv="$1"
    if [ -z "${SV_REUSE:-}" ]; then
    rm -rf "$_sv"
    mkdir -p "$_sv/src" "$_sv/cfg" "$_sv/bin" "$_sv/initd" "$_sv/tmp" \
             "$_sv/sys/br-lan" "$_sv/pkg/dist/ctrld_${CTRLD_PIN}_linux_arm64"
    for _svf in "$SCRIPT_DIR"/*.sh; do
        sed -e "s|/tmp/|${_sv}/tmp/|g" -e "s|-C /tmp|-C ${_sv}/tmp|g" -e "s|/cfg/|${_sv}/cfg/|g" \
            -e "s| /cfg ]| ${_sv}/cfg ]|g" -e "s|/etc/init.d/|${_sv}/initd/|g" \
            "$_svf" > "$_sv/src/${_svf##*/}"
    done
    # A benchmark-port run exits at once: it is asked through the netstat and
    # nslookup stubs below, and a daemon there would outlive the sandbox.
    printf '#!/bin/sh\ncase "$1" in --version) echo ctrld; exit 0 ;; esac\ncase "$*" in *ctrld-bench*) exit 0 ;; esac\necho $$ > "%s/ctrld.pid"\nexec /bin/sleep 300\n' \
        "$_sv" > "$_sv/pkg/dist/ctrld_${CTRLD_PIN}_linux_arm64/ctrld"
    chmod +x "$_sv/pkg/dist/ctrld_${CTRLD_PIN}_linux_arm64/ctrld"
    ( cd "$_sv/pkg" && tar czf "$_sv/ctrld.tgz" dist )

    printf '#!/bin/sh\necho aarch64\n' > "$_sv/bin/uname"
    printf '#!/bin/sh\n_p="$(cat "%s/ctrld.pid" 2>/dev/null)"\n[ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && echo "$_p"\n' \
        "$_sv" > "$_sv/bin/pidof"
    # The benchmark port is taken while its throwaway config exists, which is
    # from the moment probe_resolver writes it to the moment it removes it.
    printf '#!/bin/sh\n"$(dirname "$0")/pidof" >/dev/null && echo "udp 0 0 0.0.0.0:5354 0.0.0.0:* 1/ctrld"\n[ -f "%s/tmp/ctrld-bench.toml" ] && echo "udp 0 0 127.0.0.1:5360 0.0.0.0:* 1/ctrld"\nexit 0\n' \
        "$_sv" > "$_sv/bin/netstat"
    printf '#!/bin/sh\ncase "${2:-}" in\n  *#5360) [ -f "%s/tmp/ctrld-bench.toml" ] || exit 1\n          [ -f "%s/bench.fail" ] && grep -qE "$(cat "%s/bench.fail")" "%s/tmp/ctrld-bench.toml" && exit 1\n          exit 0 ;;\nesac\n"$(dirname "$0")/pidof" >/dev/null && [ ! -f "%s/dns.broken" ]\n' \
        "$_sv" "$_sv" "$_sv" "$_sv" "$_sv" > "$_sv/bin/nslookup"
    # The ctrld release tarball is the only download that succeeds. Everything
    # else, checksums.txt included, fails the way an unreachable network does.
    printf '#!/bin/sh\n_o=""; _u=""\nwhile [ $# -gt 0 ]; do case "$1" in -O) _o="$2"; shift 2 ;; -*) shift ;; *) _u="$1"; shift ;; esac; done\ncase "$_u" in *ctrld_*_linux_arm64.tar.gz) cp "%s/ctrld.tgz" "$_o"; exit 0 ;; esac\nexit 1\n' \
        "$_sv" > "$_sv/bin/wget"
    # Rules are recorded by their match, with the verb and position stripped,
    # so -C finds what -I added.
    printf '#!/bin/sh\n_v=""; _r=""\nwhile [ $# -gt 0 ]; do case "$1" in -t) shift 2 ;; -A|-C|-D) _v="$1"; shift 2 ;; -I) _v="$1"; shift 2; case "${1:-}" in [0-9]*) shift ;; esac ;; *) _r="$_r $1"; shift ;; esac; done\ncase "$_v" in\n  -C) grep -qxF -- "$_r" "%s/rules" 2>/dev/null ;;\n  -I|-A) printf "%%s\\n" "$_r" >> "%s/rules" ;;\n  *) exit 0 ;;\nesac\n' \
        "$_sv" "$_sv" > "$_sv/bin/iptables"
    printf '#!/bin/sh\ncase "$1" in -l) cat "%s/crontab" 2>/dev/null ;; -) cat > "%s/crontab.new" && mv "%s/crontab.new" "%s/crontab" ;; esac\n' \
        "$_sv" "$_sv" "$_sv" "$_sv" > "$_sv/bin/crontab"
    for _svf in uci iptables-save; do printf '#!/bin/sh\nexit 1\n' > "$_sv/bin/$_svf"; done
    for _svf in sleep logger ping; do printf '#!/bin/sh\nexit 0\n' > "$_sv/bin/$_svf"; done
    for _svf in dnsmasq https-dns-proxy; do printf '#!/bin/sh\nexit 0\n' > "$_sv/initd/$_svf"; done
    chmod +x "$_sv/bin"/* "$_sv/initd"/*
    fi
    rm -f "$_sv/dns.broken" "$_sv/bench.fail"
    [ "$2" = "broken" ] && : > "$_sv/dns.broken"
    [ -n "${SV_BENCH_FAIL:-}" ] && printf '%s' "$SV_BENCH_FAIL" > "$_sv/bench.fail"

    ( PATH="$_sv/bin:$PATH"; FW_USER="$_sv/firewall.user"; SYSFS_NET="$_sv/sys"
      DEGRADED_FLAG="$_sv/tmp/degraded"; export FW_USER SYSFS_NET DEGRADED_FLAG
      if [ -n "${3:-}" ]; then
          printf '%b' "$3" | sh "$_sv/src/setup.sh"
      else
          sh "$_sv/src/setup.sh" --resolver "${SV_RESOLVER:-abc123}" \
              --protocol "${SV_PROTOCOL:-doh3}" </dev/null
      fi
      echo "rc=$?" ) 2>&1 || true
    [ -n "${SV_KEEP:-}" ] || kill "$(cat "$_sv/ctrld.pid" 2>/dev/null)" 2>/dev/null || true
}

SV_GOOD="$(sv_run "$SV/good" good)"
assert_contains "an install whose checks pass says it is complete" "$SV_GOOD" "Setup Complete!"
assert_contains "and exits 0" "$SV_GOOD" "rc=0"
assert_contains "the sandboxed install really redirected DNS" \
    "$(cat "$SV/good/rules" 2>/dev/null)" "--dport 53 -j REDIRECT --to-port 5354"

SV_BAD="$(sv_run "$SV/broken" broken)"
assert_not_contains "an install whose checks fail does not say it is complete" \
    "$SV_BAD" "Setup Complete!"
assert_not_contains "nor that DNS goes through ControlD" "$SV_BAD" "Your DNS is now routed"
assert_contains "it says DNS is not working yet" "$SV_BAD" "DNS is not working yet"
assert_contains "and exits non-zero" "$SV_BAD" "rc=1"
assert_contains "while still listing what it installed" "$SV_BAD" "Installed on router"

# The policy wizard writes a name straight into name = "...". A double quote
# there makes ctrld.toml invalid TOML, and setup.sh has no rollback, so ctrld
# would never start. Answers: resolver, default bootstrap, DoH3, yes to split
# DNS, a policy resolver, a bad name, route by network, a CIDR, then an empty
# resolver to finish. That is a complete policy for a wizard that accepts the
# name, so one that does gets as far as writing it. One that refuses the name
# reads the route type and the CIDR as resolver IDs, skips both as invalid,
# and finishes on the empty line.
SV_POL="$(sv_run "$SV/policy" good 'abc123\n\n1\ny\nxyz789\nKid "A"\n1\n192.168.50.0/24\n\n')"
assert_contains "the installer's wizard refuses a quote in a policy name" \
    "$SV_POL" 'Policy name cannot contain'
assert_not_contains "and writes nothing for it" "$(cat "$SV/policy/cfg/ctrld.toml" 2>/dev/null)" 'Kid'
assert_contains "and the install still completes" "$SV_POL" "Setup Complete!"

describe "setup.sh — the resolver is checked before anything changes"

# A resolver ID ControlD refuses only showed itself after the install had run:
# the https-dns-proxy fallback had moved onto it too, and on a Route 10 a
# re-install with a mistyped ID left no client on the LAN with any DNS until
# the installer was run again. The check asks a throwaway ctrld on the
# benchmark port instead, before a file is written or ctrld is stopped.
assert_contains "a good install says the resolver answered" "$SV_GOOD" \
    "ControlD answers for abc123 over DoH3 (HTTP/3)"

SV_ID="$(SV_RESOLVER=zzbad99 SV_BENCH_FAIL=zzbad sv_run "$SV/bad-id" good)"
assert_contains "a resolver ID ControlD refuses stops a fresh install" "$SV_ID" \
    "ControlD did not answer for resolver ID zzbad99"
assert_contains "with the exit status saying so" "$SV_ID" "rc=1"
assert_contains "and says where to find the ID" "$SV_ID" "the part after the last slash"
assert_false "before controld.env is written" [ -f "$SV/bad-id/cfg/controld.env" ]
assert_false "or ctrld.toml" [ -f "$SV/bad-id/cfg/ctrld.toml" ]
assert_false "or the boot script" [ -f "$SV/bad-id/cfg/post-cfg.sh" ]
assert_false "and before any redirect goes in" [ -s "$SV/bad-id/rules" ]

# A blocked protocol looks the same to the first question, so DoH is asked as
# well and the answer decides which of the two the user is told.
SV_PROTO="$(SV_PROTOCOL=doq SV_BENCH_FAIL='type = "doq"' sv_run "$SV/blocked" good)"
assert_contains "a protocol the network blocks is named as the problem" "$SV_PROTO" \
    "ControlD answers over DoH but not DoQ (QUIC)"
assert_not_contains "rather than blaming the resolver ID" "$SV_PROTO" "did not answer for resolver ID"
assert_contains "and it stops the install too" "$SV_PROTO" "rc=1"
assert_false "with nothing written" [ -f "$SV/blocked/cfg/controld.env" ]

# The case that took a real LAN down: a re-install over a working router. The
# check has to come before Step 2 stops the running ctrld.
SV_KEEP=1 sv_run "$SV/reinstall" good >/dev/null
SV_RE="$(SV_KEEP=1 SV_REUSE=1 SV_RESOLVER=zzbad99 SV_BENCH_FAIL=zzbad sv_run "$SV/reinstall" good)"
assert_contains "a refused ID stops a re-install" "$SV_RE" "rc=1"
assert_not_contains "before the step that stops ctrld" "$SV_RE" "Existing ControlD configuration found"
assert_contains "leaving the installed ID in place" "$(cat "$SV/reinstall/cfg/controld.env")" "RESOLVER_ID=abc123"
assert_true "and the running ctrld still running" kill -0 "$(cat "$SV/reinstall/ctrld.pid")"
kill "$(cat "$SV/reinstall/ctrld.pid" 2>/dev/null)" 2>/dev/null || true

describe "post-cfg.sh — follows Alta's Use DoH, never rewrites dnsmasq's servers"

# post-cfg.sh runs at every boot and on every settings save in Alta's UI, after
# the firmware has written dnsmasq's servers. On a Route 10 running 1.5h those
# said what Use DoH was set to: the three local https-dns-proxy ports with it
# on, one port with one custom DoH server, the ISP's servers alone with it off.
# post-cfg.sh wrote the three ports back and restarted dnsmasq whenever they
# differed, which undid DoH off and pointed dnsmasq at ports nothing listened
# on. Run the post-cfg.sh the sandboxed install wrote with uci answering each
# of those ways.
PD="$SV/good"
for _pdi in dnsmasq https-dns-proxy; do
    printf '#!/bin/sh\necho "$*" >> "%s/%s.calls"\n' "$PD" "$_pdi" > "$PD/initd/$_pdi"
done
cat > "$PD/bin/uci" << PDUCIEOF
#!/bin/sh
echo "\$*" >> "$PD/uci.calls"
case "\$*" in
    "-q get dhcp.@dnsmasq[0].server") cat "$PD/servers" 2>/dev/null; exit 0 ;;
    "-q get dhcp.@dnsmasq[0].noresolv") echo 0; exit 0 ;;
    "get https-dns-proxy.@https-dns-proxy[0]") exit 0 ;;
esac
exit 1
PDUCIEOF
chmod +x "$PD/initd/dnsmasq" "$PD/initd/https-dns-proxy" "$PD/bin/uci"
pd_run() {
    printf '%s\n' "$1" > "$PD/servers"
    rm -f "$PD/dnsmasq.calls" "$PD/https-dns-proxy.calls" "$PD/uci.calls"
    ( PATH="$PD/bin:$PATH"; FW_USER="$PD/firewall.user"; SYSFS_NET="$PD/sys"
      DEGRADED_FLAG="$PD/tmp/degraded"; export FW_USER SYSFS_NET DEGRADED_FLAG
      sh "$PD/cfg/post-cfg.sh" ) >/dev/null 2>&1 || true
    kill "$(cat "$PD/ctrld.pid" 2>/dev/null)" 2>/dev/null || true
}

pd_run "127.0.0.1#5053 127.0.0.1#5054 127.0.0.1#5055"
assert_true "with Use DoH on, https-dns-proxy is started" \
    grep -q restart "$PD/https-dns-proxy.calls"
assert_false "dnsmasq is not restarted" grep -q restart "$PD/dnsmasq.calls"
assert_false "and its servers are not rewritten" grep -Eq "^(add_list|delete|set) dhcp\." "$PD/uci.calls"

pd_run "127.0.0.1#5053"
assert_true "with one custom DoH server, https-dns-proxy is still started" \
    grep -q restart "$PD/https-dns-proxy.calls"
assert_false "and dnsmasq keeps the one port the firmware gave it" \
    grep -Eq "^(add_list|delete|set) dhcp\." "$PD/uci.calls"
assert_false "without a restart" grep -q restart "$PD/dnsmasq.calls"

pd_run "75.153.171.68#53 75.153.171.124#53"
assert_false "with Use DoH off, https-dns-proxy is left stopped" \
    grep -q restart "$PD/https-dns-proxy.calls"
assert_false "dnsmasq keeps the ISP servers the firmware gave it" \
    grep -Eq "^(add_list|delete|set) dhcp\." "$PD/uci.calls"
assert_false "without a restart" grep -q restart "$PD/dnsmasq.calls"
unset _pdi
unset PD
unset -f pd_run
unset SV SV_GOOD SV_BAD SV_POL SV_ID SV_PROTO SV_RE _sv _svf

describe "config/post-cfg.sh.example — bounded waits, redirects at the head"

# The manual-setup example waited for https-dns-proxy and for a ping reply with
# no limit, and appended its redirects. The generated post-cfg.sh fixed all
# three, and the firmware runs /cfg/post-cfg.sh itself while applying its
# config, so a loop that never ends there stalls the router's boot. Run the
# example against stubs where uci and ping never succeed: it has to finish,
# and every redirect it adds has to be an insert at position 1.
#
# Under timeout, so a regression fails this test rather than hanging the
# suite. Skipped where there is no timeout to run it under.
if command -v timeout >/dev/null 2>&1; then
    PX="$TMPDIR/post-cfg-example"
    mkdir -p "$PX/bin" "$PX/cfg" "$PX/initd" "$PX/sys/br-lan" "$PX/sys/br-lan_10"
    sed -e "s|/cfg/|${PX}/cfg/|g" -e "s|/etc/init.d/|${PX}/initd/|g" \
        -e "s|/sys/class/net/|${PX}/sys/|g" \
        "$SCRIPT_DIR/config/post-cfg.sh.example" > "$PX/post-cfg.sh"
    for _px in uci ping; do printf '#!/bin/sh\nexit 1\n' > "$PX/bin/$_px"; done
    for _px in sleep logger nslookup; do printf '#!/bin/sh\nexit 0\n' > "$PX/bin/$_px"; done
    printf '#!/bin/sh\nexit 0\n' > "$PX/cfg/ctrld"
    for _px in dnsmasq https-dns-proxy; do printf '#!/bin/sh\nexit 0\n' > "$PX/initd/$_px"; done
    printf '#!/bin/sh\ncase " $* " in *" -C "*) exit 1 ;; esac\nprintf "%%s\\n" "$*" >> "%s/iptables.log"\n' \
        "$PX" > "$PX/bin/iptables"
    chmod +x "$PX/bin"/* "$PX/cfg/ctrld" "$PX/initd"/*
    unset _px
    assert_true "the example finishes when uci and ping never answer" \
        sh -c "PATH='$PX/bin:$PATH' timeout 30 sh '$PX/post-cfg.sh' >/dev/null 2>&1"
    assert_eq "it adds a udp and a tcp redirect on each of two bridges" "4" \
        "$(grep -c 'REDIRECT --to-port 5354' "$PX/iptables.log" 2>/dev/null || echo 0)"
    assert_eq "every one inserted at the head of PREROUTING" "4" \
        "$(grep -c -- '-I PREROUTING 1 ' "$PX/iptables.log" 2>/dev/null || echo 0)"
    unset PX
else
    skip "config/post-cfg.sh.example run (no timeout command here)"
fi

describe "prune_stale_redirects() — a rule for a port nothing listens on"

# Found on a router, not here. The DNS port moved 5354 to 5355 and back, and
# the 5355 rules were never removed: iptables evaluates PREROUTING in order, so
# they sat above the working ones and took the traffic. 27,338 packets on one
# bridge went to a closed port while ctrld was healthy on 5354, status.sh
# reported every bridge covered and audit.sh reported no drift, because all
# three only ever looked at rules already matching the current port.
#
# A stateful fake iptables, because the behaviour is which rules survive, and
# the suite's existing stub just exits 0. It rejects an argument containing a
# space the way the real one does, which is what keeps the neighbouring
# word-splitting fix honest.
PSR_BIN="$TMPDIR/psrbin"
mkdir -p "$PSR_BIN"
IPT_STORE="$TMPDIR/psr.rules"; export IPT_STORE
cat > "$PSR_BIN/iptables-save" << 'PSRSAVEEOF'
#!/bin/sh
cat "$IPT_STORE" 2>/dev/null
PSRSAVEEOF
cat > "$PSR_BIN/iptables" << 'PSRIPTEOF'
#!/bin/sh
if [ "$1" = "-t" ] && [ "$2" = "nat" ] && [ "$3" = "-D" ] && [ "$4" = "PREROUTING" ]; then
    shift 4
    # Real iptables parses argv, so a whole rule spec arriving as one argument
    # is an error, not a rule. Rejoining $* without this would hide exactly the
    # word-splitting bug this test exists to catch.
    for _a in "$@"; do
        case "$_a" in *" "*) exit 1 ;; esac
    done
    _line="-A PREROUTING $*"
    grep -qxF -- "$_line" "$IPT_STORE" || exit 1
    grep -vxF -- "$_line" "$IPT_STORE" > "$IPT_STORE.new" && mv "$IPT_STORE.new" "$IPT_STORE"
    exit 0
fi
exit 0
PSRIPTEOF
chmod +x "$PSR_BIN/iptables-save" "$PSR_BIN/iptables"

PSR_SAVED_PATH="$PATH"
PATH="$PSR_BIN:$PATH"
PSR_SAVED_IFACES="${LAN_IFACES:-}"
LAN_IFACES="br-lan br-lan_10"; export LAN_IFACES

cat > "$IPT_STORE" << 'PSRRULEEOF'
-A PREROUTING -i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan -p tcp -m tcp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan_10 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5355
-A PREROUTING -i br-lan_10 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5355
-A PREROUTING -i br-lan -p tcp -m tcp --dport 853 -j REDIRECT --to-ports 5355
-A PREROUTING -i br-lan_99 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 3128
PSRRULEEOF

PSR_N="$(prune_stale_redirects 5354)"
PSR_LEFT="$(cat "$IPT_STORE")"

# The four that cannot work: three pointing at 5355, one on a bridge that is
# gone. Removing them is the whole point.
assert_eq "four unusable rules are removed" "4" "$PSR_N"
assert_not_contains "no rule points at the old port any more" "$PSR_LEFT" '5355'
assert_not_contains "the vanished bridge's rule is gone" "$PSR_LEFT" '-i br-lan_99 '

# And the three that do work are untouched. A prune that takes these out is
# worse than the bug it fixes.
assert_contains "the current udp rule survives" "$PSR_LEFT" \
    '-i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354$'
assert_contains "the current tcp rule survives" "$PSR_LEFT" \
    '-i br-lan -p tcp -m tcp --dport 53 -j REDIRECT --to-ports 5354$'
assert_contains "the VLAN's current rule survives" "$PSR_LEFT" \
    '-i br-lan_10 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354$'

# Nothing outside ports 53 and 853 is ours to touch, whatever it redirects to.
assert_contains "someone else's proxy redirect is left alone" "$PSR_LEFT" \
    '--dport 80 -j REDIRECT --to-ports 3128$'

# What this function assumes, written down, because setup.sh now calls it on
# every install and the assumption is the whole reason that is safe.
#
# A DNS redirect in PREROUTING, on a current LAN bridge, pointing at a port
# this install does not listen on, is taken to be one of ours from an earlier
# port and is removed. It cannot be told apart from another daemon's: the two
# are the same rule. Narrowing the match to rules we can prove are ours would
# retire the function, since a rule pointing at a port we no longer use is by
# definition one we can no longer recognise.
#
# The assumption holds on a Route 10 because the other DNS service present,
# https-dns-proxy, writes its force_dns redirects into the fw3 zone chains, and
# the ^-A PREROUTING filter never sees those. The rule below is what that
# daemon would look like if it ever wrote one at the top level. It is removed,
# and this asserts that rather than leaving it to be discovered on a router.
cat > "$IPT_STORE" << 'PSRFOREIGNEOF'
-A PREROUTING -i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5053
-A PREROUTING -p udp -m udp --dport 53 -j REDIRECT --to-ports 5053
-A PREROUTING -i eth0 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5053
PSRFOREIGNEOF
PSR_FN="$(prune_stale_redirects 5354)"
PSR_FLEFT="$(cat "$IPT_STORE")"
assert_eq "a top-level DNS redirect to another port is taken as ours" "2" "$PSR_FN"
assert_not_contains "and removed from a LAN bridge" "$PSR_FLEFT" \
    '-i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5053'
assert_not_contains "and from an interface that is not a LAN bridge" "$PSR_FLEFT" \
    '-i eth0 '
# A rule with no -i at all applies everywhere, including the WAN, so it is
# nobody's to guess at. redirect_rule_iface returns nothing and the loop skips
# it; that is deliberate, not an oversight.
assert_contains "a rule bound to no interface is never touched" "$PSR_FLEFT" \
    '^-A PREROUTING -p udp -m udp --dport 53 -j REDIRECT --to-ports 5053$'
assert_contains "and the install's own rule survives" "$PSR_FLEFT" \
    '--to-ports 5354$'

# setup.sh prunes too, and where it does so is the whole of whether it is safe.
#
# A re-install that changes the port leaves the old rules in the live table:
# post-cfg.sh adds the new ones and removes nothing, so audit.sh reports drift
# on a router someone has just installed, and only reconfigure.sh --repair
# cleared it. The installer is where that is someone's to notice.
#
# Ordering is the assertion, not presence. Called before Step 9c settles the
# port, it would prune against a port about to move and delete the rules the
# install is about to need; called before the health check, ctrld might not be
# answering on that port at all. A source assertion because installing needs
# /cfg, uci and iptables, and it checks position rather than the line itself.
PSR_SETUP_CONFLICT=$(code_lineno "$SCRIPT_DIR/setup.sh" -F 'is already in use by another process')
PSR_SETUP_HEALTH=$(code_lineno "$SCRIPT_DIR/setup.sh" -F 'ctrld DNS responding on port')
PSR_SETUP_PRUNE=$(code_lineno "$SCRIPT_DIR/setup.sh" -F '_pruned="$(prune_stale_redirects')
assert_true "setup.sh prunes stale redirects at all" [ -n "$PSR_SETUP_PRUNE" ]
PSR_SETUP_ORDER=no
if [ -n "$PSR_SETUP_CONFLICT" ] && [ -n "$PSR_SETUP_HEALTH" ] && [ -n "$PSR_SETUP_PRUNE" ] \
        && [ "$PSR_SETUP_CONFLICT" -lt "$PSR_SETUP_PRUNE" ] \
        && [ "$PSR_SETUP_HEALTH" -lt "$PSR_SETUP_PRUNE" ]; then
    PSR_SETUP_ORDER=yes
fi
assert_eq "and only once the port is settled and ctrld answers on it" \
    "yes" "$PSR_SETUP_ORDER"
# post-cfg.sh must not: a reboot rebuilds the nat table and firewall.user is
# regenerated from the current port, so there is nothing stale left to find.
assert_false "post-cfg.sh does not prune, having nothing to prune at boot" \
    code_grep "$SCRIPT_DIR/setup.sh" -E '^\s+prune_stale_redirects'

# Running it again must be a no-op rather than finding new things to delete.
assert_eq "a second run removes nothing" "0" "$(prune_stale_redirects 5354)"

# uninstall.sh must sweep every port too. It worked from DNS_PORT alone, so an
# uninstall left every rule from a port the install had used earlier: pointing
# at a closed port, with this project removed and nothing left to explain them.
#
# The sweep is lifted out and run against the same fake iptables, rather than
# grepping uninstall.sh for the line that does it. A source assertion passes on
# that exact line however broken the logic around it, and fails on a correct
# rewrite that phrases it differently, which is neither of the things worth
# knowing. What is asserted is which rules are left in the table.
cat > "$IPT_STORE" << 'PSRUNEOF'
-A PREROUTING -i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan -p tcp -m tcp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan_10 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5355
-A PREROUTING -i br-lan -p tcp -m tcp --dport 853 -j REDIRECT --to-ports 5355
-A PREROUTING -i br-lan -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 3128
PSRUNEOF
PSR_SWEEP="$(code_only "$SCRIPT_DIR/uninstall.sh" \
    | sed -n '/^dns_redirect_rules | while read -r _rule; do$/,/^done$/p')"
assert_true "the uninstall sweep extracts" test -n "$PSR_SWEEP"
( PATH="$PSR_BIN:$PATH"; eval "$PSR_SWEEP" ) >/dev/null 2>&1
PSR_AFTER="$(cat "$IPT_STORE")"

# Every rule this project could have written goes, whatever port it points at.
assert_not_contains "uninstall removes the rules on the port in use" \
    "$PSR_AFTER" '--to-ports 5354'
assert_not_contains "and the ones from a port it used earlier" \
    "$PSR_AFTER" '--to-ports 5355'
# And nothing else is touched, with this project on its way out.
assert_contains "but leaves a redirect that was never ours" \
    "$PSR_AFTER" '--dport 80 -j REDIRECT --to-ports 3128$'

PATH="$PSR_SAVED_PATH"
if [ -n "$PSR_SAVED_IFACES" ]; then LAN_IFACES="$PSR_SAVED_IFACES"; else unset LAN_IFACES; fi
unset IPT_STORE

describe "CI must run on every pull request, not only ones based on master"

# With `branches: [master]` on the pull_request trigger, a PR based on another
# branch got no checks at all — not pending, not failing, simply absent. Three
# PRs in this project's 1.10.0 stack sat that way, and the absence reads like
# CI has not started yet. Retargeting one to master afterwards does not fire it
# either: that is a pull_request "edited" event, outside the default activity
# types, so the checks only appear on the next push.
#
# There is no behavioural test for a CI config — the runner is not here. What
# is asserted is the one line whose absence caused it, in every workflow.
#
# One workflow, and still a loop: a second one added later gets checked
# without anyone remembering to check it. The Forgejo mirror this used to
# iterate is gone.
#
# SC2043 is a warning, so the first shellcheck pass reports it and this
# directive is the thing keeping that pass green. Delete the directive and
# that pass goes red on the spot, which is the guard, unlike the SC2086 ones
# that needed a second narrow pass built for them.
# shellcheck disable=SC2043  # one workflow today, and the loop is for the next one
for _wf in .github/workflows/ci.yml; do
    if [ ! -f "$SCRIPT_DIR/$_wf" ]; then
        skip "$_wf not found"
        continue
    fi
    # The pull_request trigger and whatever is indented under it, up to the
    # next top-level key.
    _wf_pr="$(sed -n '/^  pull_request:/,/^[a-z]/p' "$SCRIPT_DIR/$_wf" | sed '$d')"
    assert_true "$_wf has a pull_request trigger" test -n "$_wf_pr"
    assert_not_contains "$_wf does not filter pull requests by branch" \
        "$_wf_pr" "branches:"
done

# push stays filtered: a run per push to every feature branch would double
# every PR's CI for nothing. Brackets escaped — an assertion needle is a regex,
# and "[master]" unescaped matches any one of m, a, s, t, e or r.
#
# Guarded like the three above. This one was not, and the workflows are not
# among the files the suite's preflight requires — correctly, since a router
# has no use for CI config and nobody should have to copy it there. So on the
# router the sed found no file, the needle matched nothing, and the assertion
# failed for the absence of something it was never entitled to expect.
if [ -f "$SCRIPT_DIR/.github/workflows/ci.yml" ]; then
    assert_contains "pushes are still limited to master" \
        "$(sed -n '/^  push:/,/^  pull_request:/p' "$SCRIPT_DIR/.github/workflows/ci.yml")" \
        'branches: \[master\]'
else
    skip "push trigger (.github/workflows/ci.yml not found)"
fi

describe "the suite must refuse a partial checkout, not die inside one"

# Run where setup.sh is absent — which is what /cfg is, since an install puts
# lib.sh and five utility scripts there and nothing else — the suite used to
# get 420 assertions in and then exit 2 from a failed command substitution
# under set -e, printing no summary. 38 of the failures before it were the same
# missing file. Someone reading a wall of PASS lines that stops at a prompt has
# no reason to think anything went wrong.
#
# A partial tree is built and the real suite is run inside it. The preflight
# makes this cheap: it exits before the first assertion.
PF_DIR="$TMPDIR/partial"
mkdir -p "$PF_DIR/docs"
for _pf in lib.sh test.sh status.sh benchmark.sh reconfigure.sh audit.sh \
           uninstall.sh README.md docs/technical-details.md; do
    cp "$SCRIPT_DIR/$_pf" "$PF_DIR/$_pf"
done
# Everything but setup.sh, exactly as an install leaves it.
PF_OUT="$( cd "$PF_DIR" && sh ./test.sh 2>&1 </dev/null )" && PF_RC=0 || PF_RC=$?

assert_eq "a missing source is refused, not stumbled over" "1" "$PF_RC"
assert_contains "it names the file that is missing" "$PF_OUT" "setup.sh"
assert_contains "and says where the suite is meant to run" "$PF_OUT" "/tmp/controld"
assert_not_contains "no assertion runs at all" "$PF_OUT" "PASS"
assert_not_contains "so nothing fails for the wrong reason" "$PF_OUT" "FAIL"

# No companion check that a complete tree still runs: the copy above is this
# suite, so a nested full run re-enters this very block and recurses until it
# is killed. The outer run is that check — it has every source beside it and is
# executing these assertions right now.

describe "the readouts must report interception, not rule presence"

# status.sh printed "per-device visibility enabled" from a rule count, and
# audit.sh called a bridge with rules and no traffic "idle VLAN, or clients
# bypassing". On the router this came from, three of six bridges had correct
# rules sitting below a firewall zone chain carrying https-dns-proxy's own
# port-53 redirect: 45,563 queries went to dnsmasq while both tools reported
# healthy. A rule that exists is not a rule that runs.
RI_BIN="$TMPDIR/ribin"; mkdir -p "$RI_BIN"
for _rs in uci ip nslookup logread pidof netstat crontab; do
    printf '#!/bin/sh\nexit 1\n' > "$RI_BIN/$_rs"; chmod +x "$RI_BIN/$_rs"
done
RI_CHAIN="$TMPDIR/ri.chain"; export RI_CHAIN
RI_COUNTS="$TMPDIR/ri.counts"; export RI_COUNTS
# Like the real iptables, -L -v prints counters abbreviated (261K) unless -x
# asks for exact ones. RI_COUNTS is the abbreviated listing; a file beside it
# named .exact, when present, is what -x returns.
cat > "$RI_BIN/iptables" << 'RIEOF'
#!/bin/sh
_want=""; _exact=0
for _a in "$@"; do
    case "$_a" in
        -S) _want=S ;; -C) _want=C ;; -L) [ -z "$_want" ] && _want=L ;;
        --*) ;; -*x*) _exact=1 ;;
    esac
done
case "$_want" in
    S) cat "$RI_CHAIN" 2>/dev/null; exit 0 ;;
    C) exit 0 ;;
    L) if [ "$_exact" = "1" ] && [ -f "${RI_COUNTS}.exact" ]; then
           cat "${RI_COUNTS}.exact"
       else
           cat "$RI_COUNTS" 2>/dev/null
       fi
       exit 0 ;;
esac
exit 1
RIEOF
chmod +x "$RI_BIN/iptables"

# br-lan_10's redirect sits below its own zone jump; br-lan_20's is ahead of
# its own and carrying traffic.
cat > "$RI_CHAIN" << 'RICEOF'
-A PREROUTING -i br-lan_10 -m comment --comment "!fw3" -j zone_lan_prerouting
-A PREROUTING -i br-lan_20 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan_20 -m comment --comment "!fw3" -j zone_v20zone_prerouting
-A PREROUTING -i br-lan_10 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
RICEOF
cat > "$RI_COUNTS" << 'RIVEOF'
    0     0 REDIRECT   udp  --  br-lan_10 *       0.0.0.0/0    0.0.0.0/0    udp dpt:53 redir ports 5354
13941 1015K REDIRECT   udp  --  br-lan_20 *       0.0.0.0/0    0.0.0.0/0    udp dpt:53 redir ports 5354
RIVEOF

RI_OUT="$(PATH="$RI_BIN:$PATH" DNS_PORT=5354 CTRLD_VERSION=1.5.7 LAN_IFACES="br-lan_10 br-lan_20" \
    sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"

assert_contains "an outranked bridge is named" "$RI_OUT" \
    "br-lan_10: redirect sits below a firewall zone chain"
assert_contains "and says where its clients actually land" "$RI_OUT" "reach dnsmasq, not ctrld"
assert_contains "the working bridge still reports its packets" "$RI_OUT" \
    "br-lan_20: 13941 packet(s) redirected"

# Drift, not review. Those clients are resolving through the wrong resolver now.
cat > "$RI_CHAIN" << 'RICOKEOF'
-A PREROUTING -i br-lan_10 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan_10 -m comment --comment "!fw3" -j zone_lan_prerouting
-A PREROUTING -i br-lan_20 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan_20 -m comment --comment "!fw3" -j zone_v20zone_prerouting
RICOKEOF
RI_OK="$(PATH="$RI_BIN:$PATH" DNS_PORT=5354 CTRLD_VERSION=1.5.7 LAN_IFACES="br-lan_10 br-lan_20" \
    sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_eq "an outranked bridge adds exactly one drift item" \
    "$(( $(audit_drift_count "$RI_OK") + 1 ))" "$(audit_drift_count "$RI_OUT")"
assert_not_contains "a chain with our rules first is clean" "$RI_OK" \
    "sits below a firewall zone chain"

# The zero-packet finding used to be printed from inside a pipeline, so the
# counter it incremented lived in a subshell and was discarded: a router with
# four flat bridges reported "1 item(s) to review". It has to reach the summary.
assert_contains "a flat bridge is still reported" "$RI_OK" \
    "br-lan_10: 0 packets"
assert_true "and now counts toward the summary" \
    test "$(audit_review_count "$RI_OK")" -ge 1

# iptables -L -v abbreviates any counter above 99999, so a busy bridge's
# 261,417 packets are listed as 261K, and awk reads 261K as 261. Found on a
# Route 10, where audit.sh reported a VLAN carrying a quarter of a million
# queries as having redirected about 1,600.
cat > "$RI_COUNTS" << 'RIBIGEOF'
    0     0 REDIRECT   udp  --  br-lan_10 *       0.0.0.0/0    0.0.0.0/0    udp dpt:53 redir ports 5354
 261K   17M REDIRECT   udp  --  br-lan_20 *       0.0.0.0/0    0.0.0.0/0    udp dpt:53 redir ports 5354
RIBIGEOF
cat > "${RI_COUNTS}.exact" << 'RIBIGXEOF'
       0        0 REDIRECT   udp  --  br-lan_10 *       0.0.0.0/0    0.0.0.0/0    udp dpt:53 redir ports 5354
  261417 17548675 REDIRECT   udp  --  br-lan_20 *       0.0.0.0/0    0.0.0.0/0    udp dpt:53 redir ports 5354
RIBIGXEOF
RI_BIG="$(PATH="$RI_BIN:$PATH" DNS_PORT=5354 CTRLD_VERSION=1.5.7 LAN_IFACES="br-lan_10 br-lan_20" \
    sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_contains "a busy bridge reports its exact packet count" "$RI_BIG" \
    "br-lan_20: 261417 packet(s) redirected"
rm -f "${RI_COUNTS}.exact"

# status.sh made the same claim from the same evidence. Back to the outranked
# chain — the clean one above was written for the drift comparison.
cat > "$RI_CHAIN" << 'RICBADEOF'
-A PREROUTING -i br-lan_10 -m comment --comment "!fw3" -j zone_lan_prerouting
-A PREROUTING -i br-lan_20 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan_20 -m comment --comment "!fw3" -j zone_v20zone_prerouting
-A PREROUTING -i br-lan_10 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
RICBADEOF
RI_ST="$(PATH="$RI_BIN:$PATH" DNS_PORT=5354 CTRLD_VERSION=1.5.7 LAN_IFACES="br-lan_10 br-lan_20" \
    sh "$SCRIPT_DIR/status.sh" 2>/dev/null || true)"
assert_contains "status.sh flags the outranked bridge" "$RI_ST" \
    "br-lan_10 has a redirect, but a firewall zone takes DNS first"
assert_contains "the count says only that rules are present" "$RI_ST" \
    "redirect rule(s) present"
assert_not_contains "and no longer calls rule presence per-device visibility" \
    "$RI_ST" "per-device visibility enabled"

# With Use DoH off in Alta, post-cfg.sh leaves https-dns-proxy stopped on
# purpose, so status.sh must not report that as a failure. The firmware says
# DoH is off by giving dnsmasq the ISP's servers alone.
printf '#!/bin/sh\ncase "$*" in *dnsmasq*server*) echo "75.153.171.68#53 75.153.171.124#53" ;; *) exit 1 ;; esac\n' \
    > "$RI_BIN/uci"
RI_ST="$(PATH="$RI_BIN:$PATH" DNS_PORT=5354 CTRLD_VERSION=1.5.7 LAN_IFACES="br-lan_10 br-lan_20" \
    sh "$SCRIPT_DIR/status.sh" 2>/dev/null || true)"
assert_contains "status.sh explains a stopped fallback while Use DoH is off" "$RI_ST" \
    "https-dns-proxy is stopped — Use DoH is off in Alta"
assert_not_contains "rather than calling it a failure" "$RI_ST" "https-dns-proxy is not running"
printf '#!/bin/sh\ncase "$*" in *dnsmasq*server*) echo "127.0.0.1#5053" ;; *) exit 1 ;; esac\n' \
    > "$RI_BIN/uci"
RI_ST="$(PATH="$RI_BIN:$PATH" DNS_PORT=5354 CTRLD_VERSION=1.5.7 LAN_IFACES="br-lan_10 br-lan_20" \
    sh "$SCRIPT_DIR/status.sh" 2>/dev/null || true)"
assert_contains "with Use DoH on, a stopped fallback is still a failure" "$RI_ST" \
    "https-dns-proxy is not running"
printf '#!/bin/sh\nexit 1\n' > "$RI_BIN/uci"
unset RI_CHAIN RI_COUNTS

describe "audit.sh — a redirect pointing at a port nothing listens on"

# The drift this project could not see. audit.sh's coverage count and
# status.sh's bridge check both selected rules by the current port first, so a
# rule left over from a previous port was invisible to every check while it sat
# above the working ones in PREROUTING and took all the traffic.
#
# An outcome test on audit.sh's real output, so it runs off-device like its
# neighbours: a fake iptables-save supplies the table.
APD_BIN="$TMPDIR/apdbin"; mkdir -p "$APD_BIN"
for _as in uci iptables ip nslookup logread pidof netstat crontab; do
    printf '#!/bin/sh\nexit 1\n' > "$APD_BIN/$_as"; chmod +x "$APD_BIN/$_as"
done
APD_TABLE="$TMPDIR/apd.rules"; export APD_TABLE
cat > "$APD_BIN/iptables-save" << 'APDSAVEEOF'
#!/bin/sh
cat "$APD_TABLE" 2>/dev/null
APDSAVEEOF
chmod +x "$APD_BIN/iptables-save"

# One rule on the port in use and one left behind on a port that moved.
cat > "$APD_TABLE" << 'APDSTALEEOF'
-A PREROUTING -i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5355
APDSTALEEOF
APD_OUT="$(PATH="$APD_BIN:$PATH" DNS_PORT=5354 CTRLD_VERSION=1.5.7 \
    sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_contains "the leftover rule is reported" \
    "$APD_OUT" "port nothing listens on"
assert_contains "and it is named by bridge and port" "$APD_OUT" "br-lan->5355"

# Drift, not review: DNS is down for that bridge's clients until it is removed.
cat > "$APD_TABLE" << 'APDOKEOF'
-A PREROUTING -i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
APDOKEOF
APD_OK="$(PATH="$APD_BIN:$PATH" DNS_PORT=5354 CTRLD_VERSION=1.5.7 \
    sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_eq "the leftover rule adds exactly one drift item" \
    "$(( $(audit_drift_count "$APD_OK") + 1 ))" "$(audit_drift_count "$APD_OUT")"
assert_not_contains "a table with only current rules is clean" \
    "$APD_OK" "port nothing listens on"

# A redirect on some other port is not ours, whatever it points at.
cat > "$APD_TABLE" << 'APDFOREIGNEOF'
-A PREROUTING -i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5354
-A PREROUTING -i br-lan -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 3128
APDFOREIGNEOF
APD_FOREIGN="$(PATH="$APD_BIN:$PATH" DNS_PORT=5354 CTRLD_VERSION=1.5.7 \
    sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_not_contains "someone else's proxy redirect is not reported as ours" \
    "$APD_FOREIGN" "port nothing listens on"
unset APD_TABLE

describe "reset_fallback_resolver() — an uninstall must clear every instance"

# uninstall.sh reset instances 0, 1 and 2 as three copied blocks. The Route 10
# ships three, so it worked there, and it assumed exactly what
# set_fallback_resolver reads from uci rather than assuming, for the reason
# stated in its own comment. On a router with a fourth instance that one kept
# pointing at the user's ControlD profile after an uninstall run to stop being
# routed through it.
RFR_SAVED_PATH="$PATH"
PATH="$TMPDIR/ucibin:$PATH"          # the same stateful fake uci
UCI_STORE="$TMPDIR/rfr.store"; export UCI_STORE
: > "$UCI_STORE"

# Four instances, one more than the hardcoded three, each on ControlD.
for _rfr_n in 0 1 2 3; do
    uci set "https-dns-proxy.@https-dns-proxy[${_rfr_n}]=https-dns-proxy"
done
set_fallback_resolver leaked99 76.76.2.22 >/dev/null 2>&1 || true
assert_eq "the fourth instance was on ControlD to begin with" \
    "https://dns.controld.com/leaked99" \
    "$(uci -q get 'https-dns-proxy.@https-dns-proxy[3].resolver_url')"

reset_fallback_resolver "https://dns.quad9.net/dns-query" "9.9.9.9" >/dev/null 2>&1 || true

for _rfr_n in 0 1 2 3; do
    assert_eq "instance ${_rfr_n} no longer resolves through ControlD" \
        "https://dns.quad9.net/dns-query" \
        "$(uci -q get "https-dns-proxy.@https-dns-proxy[${_rfr_n}].resolver_url")"
    assert_eq "instance ${_rfr_n}'s bootstrap moved with it" "9.9.9.9" \
        "$(uci -q get "https-dns-proxy.@https-dns-proxy[${_rfr_n}].bootstrap_dns")"
done
# The whole point: no ControlD URL is left anywhere after the reset.
assert_eq "no ControlD resolver survives the uninstall" "0" \
    "$(grep -c 'dns.controld.com' "$UCI_STORE" || true)"
# Instances that do not exist are not created, the same as set_fallback_resolver.
assert_eq "no instance is invented" "" \
    "$(uci -q get 'https-dns-proxy.@https-dns-proxy[4].resolver_url')"

# Every write was `|| true`, so the only failure it could report was "no
# instance at all": a uci that accepted the query and refused every set still
# returned 0, and uninstall.sh printed "https-dns-proxy restarted (Quad9)" over
# a run that changed nothing. set_fallback_resolver, its stated counterpart,
# does not swallow. The point of this function is that a retired ControlD
# profile stops answering, so claiming that when it might still answer is the
# one thing it must not do.
RFR_FAILDIR="$TMPDIR/ucifail"
mkdir -p "$RFR_FAILDIR"
# The real calls are `uci -q get ...` and `uci set ...`, so this has to look at
# every argument rather than $1: a stub keyed on $1 fails the query too, the
# loop is never entered, and the assertion then passes because no instance was
# found rather than because a failed write was reported.
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in get) exit 0 ;; set) exit 1 ;; esac; done\nexit 1\n' > "$RFR_FAILDIR/uci"
chmod +x "$RFR_FAILDIR/uci"
RFR_FAIL_PATH="$PATH"
PATH="$RFR_FAILDIR:$PATH"
assert_false "a reset whose writes all failed does not report success" \
    reset_fallback_resolver https://dns.quad9.net/dns-query 9.9.9.9
PATH="$RFR_FAIL_PATH"

: > "$UCI_STORE"
# assert_false, for the reason given on its twin above: sh -c starts a shell
# that has never sourced lib.sh, so the function is undefined there, the shell
# returns 127, and `!` turned that into a pass whatever the function did.
assert_false "reports failure when there is nothing to reset" \
    reset_fallback_resolver https://dns.quad9.net/dns-query 9.9.9.9

PATH="$RFR_SAVED_PATH"
unset UCI_STORE

# And the uninstaller must go through it rather than naming instances again.
assert_true "uninstall.sh resets the fallback through the loop" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'reset_fallback_resolver "https://dns.quad9.net/dns-query"'
assert_false "uninstall.sh names no instance by index" \
    code_grep "$SCRIPT_DIR/uninstall.sh" -E 'https-dns-proxy\[[0-9]\]'

describe "audit.sh — reports without touching anything"

# The whole value of an audit is that running it cannot itself cause drift.
# Rather than grep the source for writes, run it against stubs that record
# every call and assert nothing mutating was attempted.
mkdir -p "$TMPDIR/auditbin"
AUDIT_LOG="$TMPDIR/audit-calls.log"; : > "$AUDIT_LOG"
for _cmd in uci iptables crontab logger; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "$(basename "$0")" "$*" >> "$AUDIT_CALL_LOG"\nexit 1\n' \
        > "$TMPDIR/auditbin/$_cmd"
    chmod +x "$TMPDIR/auditbin/$_cmd"
done
AUDIT_SAVED_PATH="$PATH"
PATH="$TMPDIR/auditbin:$PATH"
AUDIT_CALL_LOG="$AUDIT_LOG"; export AUDIT_CALL_LOG
sh "$SCRIPT_DIR/audit.sh" >/dev/null 2>&1 || true
PATH="$AUDIT_SAVED_PATH"

assert_true "audit.sh actually inspected the system" [ -s "$AUDIT_LOG" ]
assert_not_contains "audit.sh never writes uci" "$(cat "$AUDIT_LOG")" "uci set"
assert_not_contains "audit.sh never deletes uci" "$(cat "$AUDIT_LOG")" "uci delete"
assert_not_contains "audit.sh never commits uci" "$(cat "$AUDIT_LOG")" "uci commit"
assert_not_contains "audit.sh never adds iptables rules" "$(cat "$AUDIT_LOG")" "iptables -t nat -A"
assert_not_contains "audit.sh never inserts iptables rules" "$(cat "$AUDIT_LOG")" "iptables -t nat -I"
assert_not_contains "audit.sh never deletes iptables rules" "$(cat "$AUDIT_LOG")" "iptables -t nat -D"
# `crontab -l` is a read; anything else (-r, a file argument) rewrites it
assert_eq "audit.sh only ever reads the crontab" "" \
    "$(grep '^crontab' "$AUDIT_LOG" | grep -v '^crontab -l$')"
# No in-place edits or removals anywhere in the source either
assert_false "audit.sh contains no in-place sed" code_grep "$SCRIPT_DIR/audit.sh" 'sed -i'
assert_false "audit.sh contains no rm"           code_grep "$SCRIPT_DIR/audit.sh" -E '(^|[^a-z-])rm '

# An audit that names the wrong version is worse than none: audit.sh can be run
# from a checkout in /tmp while the router runs something older.
VER_FIX="$TMPDIR/verfix"
mkdir -p "$VER_FIX"
printf 'VERSION="%s"\n' "$VERSION" > "$VER_FIX/match.sh"
printf 'VERSION="0.0.1"\n' > "$VER_FIX/old.sh"

VER_OUT="$(INSTALLED_LIB="$VER_FIX/match.sh" sh "$SCRIPT_DIR/audit.sh" 2>&1 || true)"
assert_contains "reports the installed version" "$VER_OUT" "Scripts $VERSION"

VER_OUT="$(INSTALLED_LIB="$VER_FIX/old.sh" sh "$SCRIPT_DIR/audit.sh" 2>&1 || true)"
assert_contains "names the installed version when it is older" "$VER_OUT" "are 0.0.1"
assert_contains "names the version being run"                  "$VER_OUT" "audit is $VERSION"
assert_contains "says which way the skew runs"                 "$VER_OUT" "behind the checkout"

VER_OUT="$(INSTALLED_LIB="$VER_FIX/absent.sh" sh "$SCRIPT_DIR/audit.sh" 2>&1 || true)"
assert_contains "reports a missing install rather than claiming a version" \
    "$VER_OUT" "nothing installed"

# uninstall.sh deletes its own rules one at a time, and the docs warn against
# flushing PREROUTING by name. Its help said it flushed them, which would put
# anyone with port forwards off running it.
assert_not_contains "uninstall.sh --help does not claim to flush iptables" \
    "$(sh "$SCRIPT_DIR/uninstall.sh" --help 2>&1 || true)" "flush"

# setup.sh --help is the one place someone reads what an install will put on
# the router before running it. It listed six of the thirteen files.
SETUP_HELP="$(sh "$SCRIPT_DIR/setup.sh" --help 2>&1 || true)"
for _sh_f in controld.env ctrld ctrld.toml post-cfg.sh controld-update.sh \
             watchdog.sh rc.local lib.sh $(sed -n 's/^UTILITY_SCRIPTS="\(.*\)"$/\1/p' "$SCRIPT_DIR/setup.sh"); do
    assert_contains "setup.sh --help lists /cfg/${_sh_f}" "$SETUP_HELP" "/cfg/${_sh_f} "
done
unset _sh_f SETUP_HELP

# Drift must be reported through the exit status, so it can gate a script
assert_true "audit.sh --help exits 0" sh -c "sh '$SCRIPT_DIR/audit.sh' --help >/dev/null 2>&1"
assert_true "audit.sh rejects unknown flags" sh -c "! sh '$SCRIPT_DIR/audit.sh' --nope >/dev/null 2>&1"

# It must be installed and, just as importantly, removed again
assert_true "setup.sh installs audit.sh" \
    code_grep "$SCRIPT_DIR/setup.sh" 'UTILITY_SCRIPTS=.*audit\.sh'
assert_true "uninstall.sh removes audit.sh" \
    code_grep "$SCRIPT_DIR/uninstall.sh" '/cfg/audit\.sh'
# An interrupted reconfigure leaves this behind, holding the previous resolver ID
assert_true "uninstall.sh removes a stale ctrld.toml.bak" \
    code_grep "$SCRIPT_DIR/uninstall.sh" '/cfg/ctrld\.toml\.bak'
# backup.sh stored its backup on the partition it existed to protect, and its
# file list was five files short of a working install
assert_false "backup.sh is gone" [ -f "$SCRIPT_DIR/backup.sh" ]
assert_true "uninstall.sh removes the directory it left behind" \
    code_grep "$SCRIPT_DIR/uninstall.sh" 'rm -rf /cfg/controld-backup'

describe "--help flags on all scripts"
for script in setup.sh status.sh benchmark.sh uninstall.sh reconfigure.sh audit.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        HELP_OUT=$(sh "$SCRIPT_DIR/$script" --help 2>&1 || true)
        assert_contains "$script --help mentions usage" "$HELP_OUT" "Usage"
        assert_contains "$script --help mentions --help" "$HELP_OUT" "\-\-help"
        # Both assertions above pass on a help that prints "\033[1mUsage:" as
        # eight literal characters, because the word they look for is in that
        # output too. reconfigure.sh shipped exactly that for as long as it had
        # a --help: its usage text was a here-document, which expands the colour
        # variables but leaves the escape sequence inside them uninterpreted.
        # Assert on what reaches the terminal, not on a word being somewhere in
        # it.
        assert_not_contains "$script --help renders its colours" "$HELP_OUT" '\\033'
        # The assertions above all look for something near the top of the help,
        # so they pass on a help that stops halfway. That is a reachable state:
        # when the text is printf's format string rather than its argument, a
        # single % in it truncates the output there and exits 2. Check the exit
        # status and the tail, not just that some words appeared.
        assert_true "$script --help exits 0 and prints it all" sh "$SCRIPT_DIR/$script" --help
        assert_not_contains "$script --help does not trip printf" "$HELP_OUT" \
            'invalid directive\|invalid format\|not completely converted'
    else
        skip "$script not found"
    fi
done

describe "--version flags"

# Every script, not just setup.sh. show_version lives in lib.sh and all six
# source it, but only setup.sh had it wired to a flag, so the other five died
# with "Unknown option: --version" and a non-zero exit. That is the first thing
# someone reaches for when README's Verification Status asks them to say what
# they are running in a bug report.
#
# The SC2043 directive that used to sit here existed only because the loop had
# one item. Six items, no directive needed.
#
# The flag has to answer before the script needs an install: three of these
# load_env and die without one, and a version that only prints on a working
# router is no use when diagnosing a broken one. Running the suite off-device
# is itself that check, since there is no /cfg here.
for script in setup.sh status.sh benchmark.sh uninstall.sh reconfigure.sh audit.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        VER_OUT=$(sh "$SCRIPT_DIR/$script" --version 2>&1 || true)
        assert_contains "$script --version shows the tools version" "$VER_OUT" "$VERSION"
        assert_contains "$script --version shows the pinned ctrld" "$VER_OUT" "$CTRLD_PIN"
        assert_true "$script --version exits 0" sh "$SCRIPT_DIR/$script" --version
        # -v is the short form everywhere or nowhere.
        VER_SHORT=$(sh "$SCRIPT_DIR/$script" -v 2>&1 || true)
        assert_contains "$script -v does the same" "$VER_SHORT" "$VERSION"
    else
        skip "$script not found"
    fi
done

# ══════════════════════════════════════════════════════════════════
# PROTOCOL FALLBACK CHAIN TESTS
# ══════════════════════════════════════════════════════════════════

describe "Protocol fallback chain completeness"
# Walk the chain with intermediate vars (clearer; avoids nested-command-substitution warnings)
_a=$(next_proto doq);  _b=$(next_proto "$_a"); _c=$(next_proto "$_b")
assert_eq "doq -> doh3 -> doh -> doh3 (443-only cycle)" "doh3" "$_c"
_a=$(next_proto doh3); _b=$(next_proto "$_a")
assert_eq "doh3 -> doh -> doh3 (cycle)" "doh3" "$_b"

# ══════════════════════════════════════════════════════════════════
# INTEGRATION TESTS: only run on actual router
# ══════════════════════════════════════════════════════════════════

# $TMPDIR/bin holds stubs — a logger that writes nothing, a uci that always
# exits 1 — and three separate tests prepend it to PATH for the remainder of
# the file rather than scoping it to a subshell as every other fake does.
#
# The integration block below executes the router's real scripts as children:
# post-cfg.sh and benchmark.sh. They inherit that PATH. post-cfg.sh waits on
#
#     while ! uci get https-dns-proxy.@https-dns-proxy[0] >/dev/null 2>&1; do sleep 1; done
#
# so a uci stubbed to exit 1 makes that condition true forever: the destructive
# run hung on a real router with no output at all, because the logger stub had
# swallowed every message that would have said where it was.
#
# Restore the real PATH before running anything of the router's, and assert a
# child process actually resolves the system uci — asserting on what a child
# sees, not on the shape of the PATH string.
describe "the router's own scripts must not inherit the suite's stubs"
PATH="$TS_REAL_PATH"
TS_PROBE="$TMPDIR/probe-path.sh"
printf '#!/bin/sh\ncommand -v uci || echo no-uci-on-this-host\n' > "$TS_PROBE"
chmod +x "$TS_PROBE"
assert_not_contains "a child process resolves the real uci, not the stub" \
    "$(sh "$TS_PROBE")" "$TMPDIR"

describe "Router integration tests"
if ! is_alta_router 2>/dev/null; then
    skip "Not running on Alta router — skipping integration tests"
    skip "DNS resolution test"
    skip "ctrld process test"
    skip "iptables rules test"
    skip "cron jobs test"
    skip "watchdog health test"
    skip "self-healing test"
    skip "benchmark test"
else
    # The port this install actually uses, not the default. These three
    # assertions hardcoded 5354, so on an install that moved off it — which
    # setup.sh does by itself when 5354 is taken — every one of them failed
    # against a router that was working correctly, and the suite reported a
    # dead resolver on a healthy device. installed_dns_port reads what the
    # install recorded and falls back to 5354, so the default case is
    # unchanged.
    IT_PORT="$(installed_dns_port /cfg/controld.env)"

    # Integration: DNS resolution
    assert_true  "DNS resolves via ctrld on ${IT_PORT}" check_dns "127.0.0.1#${IT_PORT}"
    assert_true  "System DNS works"          check_dns

    # Integration: ctrld process
    assert_true  "ctrld process running"     pidof ctrld

    # Integration: iptables. Matched on the whole field, not a bare grep for
    # the number: a loose match also counts a leftover rule pointing at a port
    # this install no longer uses, which is the one case where a redirect
    # existing proves nothing.
    # "|| true": grep -c exits 1 when the count is zero, and an assignment from
    # a failing command substitution ends a set -e shell on the spot. The suite
    # then stopped mid-file with no Results block, which reads as a pass to
    # anything scanning for the word FAIL, and it did that only on a router
    # with no matching redirect rule, which is the state most worth reporting.
    RULES=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "redir ports ${IT_PORT}$" || true)
    assert_true "iptables rules active ($RULES)" [ "$RULES" -gt 0 ]

    # Integration: cron jobs (wrap pipeline in sh -c so assert_true runs the
    # whole check in-process, not in a pipeline subshell, which set -e aborts
    # on.)
    assert_true "watchdog cron installed"     cron_has /cfg/watchdog.sh
    assert_true "update cron installed"       cron_has /cfg/controld-update.sh

    # Integration: config files exist
    for f in /cfg/controld.env /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh /cfg/watchdog.sh /cfg/controld-update.sh; do
        assert_true "$f exists" [ -f "$f" ]
    done

    # Integration: self-healing (delete toml, regenerate from env).
    #
    # Opt-in, because this is surgery on a live router, not a test. It deletes
    # /cfg/ctrld.toml and runs the whole boot sequence: post-cfg.sh restarts
    # https-dns-proxy, rewrites dhcp uci and restarts dnsmasq, then stops and
    # starts ctrld, so the LAN loses DNS for the duration. Worse, post-cfg.sh
    # waits on `while ! ping -c1 "$BOOTSTRAP_IP"` with no attempt limit, so if
    # the bootstrap host does not answer ICMP this never returns; interrupting
    # it then skips the restore below and leaves the config as post-cfg
    # regenerated it. CONTRIBUTING.md documents running this suite on the
    # router as a routine step, and a routine step must not do any of that.
    if [ "${CONTROLD_TEST_DESTRUCTIVE:-0}" = "1" ]; then
        BACKUP_TOML=$(cat /cfg/ctrld.toml)
        rm /cfg/ctrld.toml
        sh /cfg/post-cfg.sh >/dev/null 2>&1 || true
        assert_true "self-healing restored ctrld.toml" [ -f /cfg/ctrld.toml ]
        assert_true "DNS still works after self-heal"   check_dns "127.0.0.1#${IT_PORT}"
        # Restore original in case self-heal used different proto
        printf "%s" "$BACKUP_TOML" > /cfg/ctrld.toml
    else
        skip "self-healing (destructive: set CONTROLD_TEST_DESTRUCTIVE=1 to run)"
        skip "DNS after self-heal (same)"
    fi


    # Integration: benchmark runs successfully. Also opt-in: it starts and stops
    # a ctrld per protocol and takes a minute or more, which reads as a hang.
    if [ "${CONTROLD_TEST_DESTRUCTIVE:-0}" != "1" ]; then
        skip "benchmark (slow: set CONTROLD_TEST_DESTRUCTIVE=1 to run)"
    elif [ -f /cfg/benchmark.sh ]; then
        BENCH_OUT=$(sh /cfg/benchmark.sh --queries 3 2>&1)
        assert_contains "benchmark produces results" "$BENCH_OUT" "avg"
        assert_contains "benchmark shows recommendation" "$BENCH_OUT" "Recommended"
    else
        skip "benchmark.sh not installed"
    fi
fi

# ══════════════════════════════════════════════════════════════════
# RESULTS
# ══════════════════════════════════════════════════════════════════

printf "\n  ${BOLD}═══════════════════════════════════════════════════${RESET}\n"
printf "  Results:  "
if [ "$FAIL" -eq 0 ]; then
    printf "${GREEN}${BOLD}ALL PASSED${RESET}\n"
else
    printf "${RED}${BOLD}%d FAILED${RESET}\n" "$FAIL"
fi
printf "  ${GREEN}Pass: %d${RESET}  ${RED}Fail: %d${RESET}  ${YELLOW}Skip: %d${RESET}  Total: %d\n" "$PASS" "$FAIL" "$SKIP" "$TOTAL"
printf "  ${BOLD}═══════════════════════════════════════════════════${RESET}\n\n"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
