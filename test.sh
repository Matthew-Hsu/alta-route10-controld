#!/bin/sh
# test.sh — comprehensive test suite for Alta Route 10 + ControlD
# Run locally: sh test.sh
# Run on router: sh /cfg/test.sh

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

assert_contains() {
    TOTAL=$((TOTAL + 1))
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
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
    if echo "$haystack" | grep -q "$needle"; then
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
    if echo "$actual" | grep -qE "$pattern"; then
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
    if [ -f "$file" ] && grep -q "$pattern" "$file"; then
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
# satisfied by a comment that merely mentions it — including the comment left
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
# `FORCED_DNS=$(preserved_forced_dns` makes grep exit on "Unmatched (" — an
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
TMPDIR=$(mktemp -d 2>/dev/null || echo "/tmp/controld-test-$$")
mkdir -p "$TMPDIR"

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
# UNIT TESTS — lib.sh functions
# ══════════════════════════════════════════════════════════════════

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
    "PREROUTING -i br-lan_10 -p udp --dport 53 -j REDIRECT --to-port 5354"
assert_contains "covers VLAN 20 on tcp" "$cmds" \
    "PREROUTING -i br-lan_20 -p tcp --dport 53 -j REDIRECT --to-port 5354"
both="$(SYSFS_NET="$FAKE_NET" dns_redirect_commands 5354 53 853)"
assert_eq "port 853 doubles the rule count" "16" "$(printf '%s\n' "$both" | wc -l | tr -d ' ')"

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

# It is sourced by /etc/rc.local, which runs its own logic afterwards: an exit
# or set -e here would silently skip the rest of the router's boot script.
assert_false "generated hook has no exit"   grep -qE '^[[:space:]]*exit' "$RCGEN"
assert_false "generated hook has no set -e" grep -qE '^[[:space:]]*set -e' "$RCGEN"
assert_true  "generated hook warns that it is sourced" grep -q 'sources' "$RCGEN"

describe "watchdog — a ctrld that will not start must still reach the teardown"

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
# and after a teardown all of that is gone — so exiting on a successful restart
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
# router's syslog, sharing the fail-count file — where one instance's reset
# erases another's debounce — and rewriting ctrld.toml underneath each other
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

# retarget_upstreams stays real — it is what rewrites the file — while ctrld can
# never start, which is the case that walks the whole loop.
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
# invisible to it — while it printed the recorded protocol as an OK line — is
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
# "1.3.6" and "doh3" made this pass only where /cfg does not exist — a
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
# it — these are source assertions, comment-blind, like its existing ones.
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
# failed, and attempt 3 does it again — one attempt in three tries anything
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

# reconcile_dns_type and retarget_upstreams stay real — they are what this
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
# convention everywhere in this project — every split-DNS profile is
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
# — and a half-written config is squarely in scope, since an interrupted write
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
# between — the observed case — leaves ctrld.toml on one protocol while
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
# assert_true, not a bare call — a mutated reconcile_dns_type that fails here
# must show as a clean FAIL, not crash the whole suite under set -e.
assert_true "reports a correction was made" \
    reconcile_dns_type "$RC_DIR/controld.env" "$RC_DIR/ctrld.toml"
assert_eq "and updates DNS_TYPE in the caller's shell" "doh" "$DNS_TYPE"
assert_file_contains "and persists it to the env file" "$RC_DIR/controld.env" '^DNS_TYPE=doh$'
assert_false "PREFERRED_PROTOCOL is never touched — that is what the user asked for" \
    grep -q '^PREFERRED_PROTOCOL=doh$' "$RC_DIR/controld.env"
assert_file_contains "it stays what it was" "$RC_DIR/controld.env" '^PREFERRED_PROTOCOL=doh3$'

# Already-correct state must report nothing to do, and touch nothing — the
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
# this function's problem to report — it must fail closed, not correct
# DNS_TYPE to garbage.
DNS_TYPE=doh3
assert_false "an unreadable config reports nothing to correct" \
    reconcile_dns_type "$RC_DIR/controld.env" "$RC_DIR/does-not-exist.toml"
assert_file_contains "and DNS_TYPE is left alone on disk" "$RC_DIR/controld.env" '^DNS_TYPE=doh$'

# Nor is a protocol this project does not manage adopted — on disk or in the
# caller's shell, which is where do_upgrade_check and reconfigure.sh read it
# from for every decision they make after the call.
DNS_TYPE=doh3
assert_false "a protocol this project does not manage is not adopted" \
    reconcile_dns_type "$RC_DIR/controld.env" "$RP_DIR/bogus.toml"
assert_eq "and the caller's DNS_TYPE is left alone" "doh3" "$DNS_TYPE"
assert_file_contains "and so is the file" "$RC_DIR/controld.env" '^DNS_TYPE=doh$'

# An env file old enough to have no DNS_TYPE line at all is still supported —
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
# handling (already tested directly above) — the same technique the watchdog
# tests already use to isolate a caller's control flow from its
# collaborators. Everything happens inside a subshell: PATH, the stub
# definition and DNS_TYPE/PREFERRED_PROTOCOL are all gone the moment it exits,
# so nothing here can leak into a test that runs after it. Only what actually
# landed on disk — the log file, the counter file — is asserted on, outside
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
# like every other script here — running it as a real subprocess would write
# to those paths and restart production ctrld if this ever executed on a
# router, which test.sh is explicitly meant to support. Nothing in this suite
# runs reconfigure.sh or status.sh as a subprocess for that reason, so this
# checks wiring and ordering — the real reconciliation logic is exercised
# directly above, safely, against sandbox paths.
# code_lineno, not a bare grep -n: the comment above the call mentions
# reconcile_dns_type, and so does the comment left behind if the call is ever
# commented out — which is exactly how a reverted fix used to slip past this
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
# somewhere in the file — a comment referencing running_protocol elsewhere
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
# fallback under the router's ash, or dash — bash is the outlier that runs it.
# reconfigure.sh, benchmark.sh and uninstall.sh all bootstrapped that way, and
# with stderr discarded on top they produced no output whatsoever and exit 2
# when run from a directory with no lib.sh beside them. Their /cfg fallback,
# written for exactly that case, was unreachable. uninstall.sh is the one that
# mattered: the README teaches fetching a single script into /tmp, and doing
# that with the uninstaller removed nothing while looking like it had run.
#
# The invariant holds in every environment, which is what makes it testable
# here and on a router: never silent. Where /cfg/lib.sh exists the fallback
# now works and the script prints its usage; where it does not, it says so.
BS_DIR="$TMPDIR/bootstrap"; rm -rf "$BS_DIR"; mkdir -p "$BS_DIR"
for _bs in reconfigure.sh benchmark.sh uninstall.sh status.sh audit.sh; do
    cp "$SCRIPT_DIR/$_bs" "$BS_DIR/$_bs"
    # --help exits before any of these touches the system, uninstall included.
    _bs_out="$(cd "$BS_DIR" && sh "./$_bs" --help 2>&1 || true)"
    rm -f "$BS_DIR/$_bs"
    assert_true "${_bs} says something when lib.sh is not beside it" \
        [ -n "$_bs_out" ]
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
# correctly — capture the PID, then print one line — so this matches it, and
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

# The redirect port is per-install (setup.sh moves off 5354 when it is taken),
# so uninstall must read controld.env before it removes anything. Without it,
# DNS_PORT was lib.sh's 5354 default and a moved install kept every redirect —
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
# reload", and then called disable_forced_dns — which sets FORCED_DNS=0 and
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
# rules persisted — that is what this call is for, and the guard above must not
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

# setup.sh must actually preserve it — this fix was once described in a commit
# before it was in the diff, and no test noticed. The assertion that replaced
# that gap checked for the literal `FORCED_DNS=$(preserved_forced_dns ...)`
# inside setup.sh's here-doc, and passed for months while that exact line read
# an already-truncated file. Both are now covered by running the real writer
# against a real file, in "write_env_file()" below.

describe "force_dns_port — a package default, not ours to delete"

# 53 and 853 are the ports https-dns-proxy ships in its own /etc/config, and the
# same pair is the init script's fallback when the option is absent. Deleting
# them on uninstall removed a vendor default and did not stick either — the
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
# comment, and never called from anywhere — setup.sh carried its own private
# _port_in_use rather than using the shared one. A library function with no
# caller still has to be read and maintained, and reads as available API.
#
# Every function must be referenced somewhere beyond its own definition and
# Usage comment: another script, a doc, or a test.
# The file list is built from globs, using no external tool at all: BusyBox
# grep has no --include, so `grep -r --include` failed on every real router
# while passing in CI, and CONTRIBUTING.md documents `sh /cfg/test.sh` as an
# on-router step. find would work but is one more implementation to depend on.
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
# Route 10 runs `syslogd -n -b 2 -t -u` — no -C — so logread fails outright and
# every logger call this project makes appeared lost. They are not: syslogd
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

# An actual invocation — command substitution or a pipe — not the word. The
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
# — and docs/troubleshooting.md already claimed status.sh handled these files.
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

# An event only in the rotated file must still be found — the case the router hit.
rm -f "$LR_DIR/messages.0" "$LR_DIR/messages.1"
printf 'Sep 4 11:00 h watchdog: added DNS redirect rules\n' > "$LR_DIR/messages.0"
printf 'Sep 5 00:00 h crond: something else entirely\n'     > "$LR_DIR/messages"
LR_OUT2="$(LOG_FILES="$LR_DIR/messages" log_lines watchdog 10 || true)"
assert_contains "an event that has already rotated is still reported" \
    "$LR_OUT2" "added DNS redirect rules"

# Every tag this project logs under must be covered by status.sh's activity
# filter. forced-dns and controld were not, so the lines a restore cycle emits —
# the port-853 rules and the firewall.user rewrite — were invisible under a
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
# reported twice — once as a known leftover, again as unexpected in /cfg.
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
AU_BIN="$TMPDIR/auditbin"; mkdir -p "$AU_BIN"
printf '#!/bin/sh\necho 0\n' > "$AU_BIN/uci"; chmod +x "$AU_BIN/uci"
AU_OUT="$(PATH="$AU_BIN:$PATH" FORCED_DNS=1 sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_contains "the env flag wins over live uci" "$AU_OUT" "forced DNS 1"
# The fallback can only be exercised where nothing supplies the flag: audit.sh
# reads /cfg/controld.env through load_env, and on a configured router that file
# sets FORCED_DNS — so this asserted something the environment controls, and
# failed on a real install with forced DNS on. Skip rather than assert a lie.
if [ -f /cfg/controld.env ] && grep -q '^FORCED_DNS=' /cfg/controld.env 2>/dev/null; then
    skip "uci fallback (this router's controld.env supplies FORCED_DNS)"
else
    AU_OUT0="$(PATH="$AU_BIN:$PATH" sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
    assert_contains "and uci is the fallback when the flag is unset" "$AU_OUT0" "forced DNS 0"
fi

describe "bench_domain() — the benchmark must query real hostnames"

# setup.sh's copy read: awk "{print \$(((_bi - 1) % 5 + 1))}". _bi is a shell
# variable and awk never saw it, so awk evaluated an uninitialised zero, the
# expression came out as $0, and every query looked up all five domains joined
# by spaces as a single hostname. All ten failed, every protocol reported
# FAILED (0/10), and setup fell through to "All protocols failed benchmark.
# Defaulting to DoH3." — the menu option never once produced a result.
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

describe "bench_stop() — never the production resolver"

# reconfigure.sh's benchmark ran `kill $(pidof ctrld)` before each of three
# protocols. That is the resolver every LAN client is redirected to, so the
# whole network lost DNS for the run — and a failure between the kill and the
# restart left it that way until the watchdog's next cycle. The throwaway
# daemon is identified by the config path it was started with instead.
assert_true "bench_stop matches on the config path" \
    code_grep "$SCRIPT_DIR/lib.sh" 'trld run -c ${_bs_conf}'
# Scoped to the benchmark regions: a stop_ctrld elsewhere is meant to stop the
# production daemon, and only a benchmark must never do so.
# setup.sh's region is delimited by a section comment, so it has to be sliced
# before comments are blanked, not after — code_only reads the slice from
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
# routing rule — on the operation the README calls "always safe", and silently
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
# over a carried policy — two [listener.0.policy] tables is invalid TOML and
# ctrld would not start at all.
# Run the real thing. Three greps for `cp`, `carry_policy_blocks` and the
# CARRIED_POLICY guard used to stand in for this; they checked those strings
# appeared, not that they ran in an order that works — deleting the
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

describe "policy_add_rule() — a reported rule must actually be in the file"

# The callers anchored an insert on the list header, so adding the first rule
# of a kind the policy did not already carry was a silent no-op: sed matched
# nothing, exited 0, and "Device rule added" was printed over a config that had
# gained an orphan upstream and no rule. Both orderings are reachable from a
# first run of the setup wizard, which writes macs-only or networks-only
# depending on the route type chosen.

# 1. No policy table at all — one must be created around the rule
PA1="$TMPDIR/pol-none.toml"
write_ctrld_config "$PA1" abc123 76.76.2.22 doh3
assert_true "a first MAC rule creates the policy" \
    policy_add_rule "$PA1" mac "aa:bb:cc:dd:ee:01" 1
assert_file_contains "the policy table is there" "$PA1" '^\[listener.0.policy\]'
assert_eq "and carries the rule" "1" "$(policy_rule_count "$PA1" mac)"

# 2. A networks-only policy, adding a MAC rule — the case that silently failed
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

# 3. A macs-only policy, adding a network rule — the mirror case
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

# A policy table must never be created twice — that is invalid TOML.
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

# Drift count from an audit run's summary; 0 when it reports none. Lets a test
# assert an item's severity from what audit.sh did, not from how it is written.
audit_drift_count() {
    _adc="$(printf '%s\n' "$1" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) drift item(s).*/\1/p' | head -1)"
    printf '%s' "${_adc:-0}"
}

describe "audit.sh — a wiped firewall.user block must not pass as healthy"

# An empty firewall.user with an install recorded means the redirects exist in
# the live table but nowhere that survives a firewall reload. The watchdog
# rewrites the block, so this only bites while cron is dead as well — and a
# firmware update resetting /etc can take both, so it is not left to that.
FW_BIN="$TMPDIR/fwbin"; mkdir -p "$FW_BIN"
for _fs in uci iptables ip nslookup logread pidof netstat crontab; do
    printf '#!/bin/sh\nexit 1\n' > "$FW_BIN/$_fs"; chmod +x "$FW_BIN/$_fs"
done
FW_EMPTY="$TMPDIR/fw-empty.user"; : > "$FW_EMPTY"

FW_OUT="$(PATH="$FW_BIN:$PATH" FW_USER="$FW_EMPTY" CTRLD_VERSION=1.5.7 \
    sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_contains "an empty firewall.user is reported when an install is recorded" \
    "$FW_OUT" "will not survive a firewall reload"
# Severity from the count, for the same reason.
printf '# controld-dns-redirect BEGIN\n# controld-dns-redirect END\n' > "$TMPDIR/fw-ok.user"
FW_OK="$(PATH="$FW_BIN:$PATH" FW_USER="$TMPDIR/fw-ok.user" CTRLD_VERSION=1.5.7 \
    sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_eq "an empty firewall.user adds exactly one drift item" \
    "$(( $(audit_drift_count "$FW_OK") + 1 ))" "$(audit_drift_count "$FW_OUT")"

# Nothing installed: an empty firewall.user is simply correct.
if [ -f /cfg/controld.env ] && grep -q '^CTRLD_VERSION=' /cfg/controld.env 2>/dev/null; then
    skip "bare checkout (this router's controld.env supplies CTRLD_VERSION)"
else
    FW_NONE="$(PATH="$FW_BIN:$PATH" FW_USER="$FW_EMPTY" sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
    assert_not_contains "but not when nothing is installed" \
        "$FW_NONE" "will not survive a firewall reload"
fi

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

# Crontab empty, install recorded: both jobs must be named as never running.
printf '#!/bin/sh\nexit 0\n' > "$CJ_BIN/crontab"; chmod +x "$CJ_BIN/crontab"
CJ_GONE="$(PATH="$CJ_BIN:$PATH" FW_USER="$CJ_FW" CTRLD_VERSION=1.5.7 sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_contains "an empty crontab is reported, not passed over" \
    "$CJ_GONE" "no cron job, so never run"
assert_contains "the watchdog is named"       "$CJ_GONE" "never run:.*watchdog\.sh"
assert_contains "and so is the updater"       "$CJ_GONE" "controld-update\.sh"
# Severity is the whole point. Reported as a review note it would print and
# still exit 0, which is the failure this check exists to end — and asserting
# only the message text does not catch that, as reverting it proved.

# Only the watchdog missing — the updater alone must not mask it.
cat > "$CJ_BIN/crontab" <<'CJSTUB1'
#!/bin/sh
echo "0 3 * * 1 /cfg/controld-update.sh"
CJSTUB1
chmod +x "$CJ_BIN/crontab"
CJ_HALF="$(PATH="$CJ_BIN:$PATH" FW_USER="$CJ_FW" CTRLD_VERSION=1.5.7 sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_contains "one job present does not excuse the other" \
    "$CJ_HALF" "never run:.*watchdog\.sh"

# Both present: silent.
cat > "$CJ_BIN/crontab" <<'CJSTUB2'
#!/bin/sh
echo "*/5 * * * * /cfg/watchdog.sh"
echo "0 3 * * 1 /cfg/controld-update.sh"
CJSTUB2
chmod +x "$CJ_BIN/crontab"
CJ_OK="$(PATH="$CJ_BIN:$PATH" FW_USER="$CJ_FW" CTRLD_VERSION=1.5.7 sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
assert_not_contains "a complete crontab says nothing" "$CJ_OK" "no cron job"
assert_contains "and confirms both are there" "$CJ_OK" "Both cron jobs are in the crontab"

# No install recorded: silent either way, so a bare checkout is not accused.
# Only assertable where nothing supplies the gate: audit.sh reads
# /cfg/controld.env through load_env, and on a real install that file sets
# CTRLD_VERSION, so exporting nothing here proves nothing there.
printf '#!/bin/sh\nexit 0\n' > "$CJ_BIN/crontab"; chmod +x "$CJ_BIN/crontab"
if [ -f /cfg/controld.env ] && grep -q '^CTRLD_VERSION=' /cfg/controld.env 2>/dev/null; then
    skip "bare checkout (this router's controld.env supplies CTRLD_VERSION)"
    skip "cron severity by drift count (needs the gate-off run above)"
else
    CJ_NONE="$(PATH="$CJ_BIN:$PATH" FW_USER="$CJ_FW" sh "$SCRIPT_DIR/audit.sh" 2>/dev/null || true)"
    assert_not_contains "no recorded install means no cron complaint" \
        "$CJ_NONE" "no cron job"
    # Severity from what audit did, not from how the line is written: as a
    # review note the count would not move and the exit code would not carry
    # it. Measured against the same empty crontab with the gate off, which is
    # the only pair that differs by this check alone — comparing against a
    # populated crontab instead just trades this drift item for the
    # neighbouring "points at missing script(s)" one.
    assert_eq "and with one recorded it is drift, not a review note" \
        "$(( $(audit_drift_count "$CJ_NONE") + 1 ))" "$(audit_drift_count "$CJ_GONE")"
fi

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
# to /etc/rc.local — which on a router is the live boot hook. Nothing in this
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
# re-install, silently deleted DNS_PORT, LAN_IFACES and LAN_IFACES_EXCLUDE —
# the documented overrides — along with POLICY_UPSTREAMS.
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
unset DNS_PORT LAN_IFACES_EXCLUDE POLICY_UPSTREAMS

describe "stop_ctrld() — kills every instance, not one packed argument"

# pidof prints every PID on one line, and `kill "$(pidof ctrld)"` quoted them
# into a single argument: kill rejects "4143 4144" wholesale and nothing dies.
# It only bites once a second ctrld exists — a benchmark, or the self-upgrade
# probe — which is exactly when stopping cleanly matters, and why a single
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
# timeout — about 5s — so start_ctrld(15) took roughly 90 seconds. The watchdog's
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
# lib.sh is missing. It ran the same unguarded loop, so it needs the same gate —
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
# A grep for "[upstream.1]" also matches [upstream.10] — the parse must not.
assert_contains "a two-digit index is read whole" "$LU_OUT" "10.*Quad9.*doh"
# Checked on the real tab-separated fields. The previous form used `sh -c` with
# an unexported variable AND `\t` inside an ERE, where it means a literal "t" —
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

# A disabled install must stay disabled — the preserve must not be a hardcoded 1
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
# rotated away from — a leaked one, say — kept resolving for the whole LAN
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
# Only instances that exist are touched — no phantom third one is created
assert_eq "no instance is invented" "" \
    "$(uci -q get 'https-dns-proxy.@https-dns-proxy[2].resolver_url')"

# With no instances configured it reports failure rather than silently passing
: > "$UCI_STORE"
assert_true "reports failure when there is nothing to update" \
    sh -c "! set_fallback_resolver x 1.1.1.1 >/dev/null 2>&1"

PATH="$FBR_SAVED_PATH"
unset UCI_STORE

# Both callers must use it — setup.sh on install, reconfigure.sh on rotation
assert_true "setup.sh points the fallback at ControlD" \
    code_grep "$SCRIPT_DIR/setup.sh" 'set_fallback_resolver "$RESOLVER_ID"'
RECONF_DO_RESOLVER="$(code_only "$SCRIPT_DIR/reconfigure.sh" \
    | sed -n '/^do_resolver/,/^}/p')"
assert_contains "reconfigure.sh rotates the fallback with the resolver" \
    "$RECONF_DO_RESOLVER" "set_fallback_resolver"

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

# Drift must be reported through the exit status, so it can gate a script
assert_true "audit.sh --help exits 0" sh -c "sh '$SCRIPT_DIR/audit.sh' --help >/dev/null 2>&1"
assert_true "audit.sh rejects unknown flags" sh -c "! sh '$SCRIPT_DIR/audit.sh' --nope >/dev/null 2>&1"

# It must be installed and, just as importantly, removed again
assert_true "setup.sh installs audit.sh" \
    code_grep "$SCRIPT_DIR/setup.sh" 'UTILITY_SCRIPTS=.*audit\.sh'
assert_true "uninstall.sh removes audit.sh" \
    code_grep "$SCRIPT_DIR/uninstall.sh" '/cfg/audit\.sh'
# A failed reconfigure leaves this behind, holding the previous resolver ID
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
    else
        skip "$script not found"
    fi
done

describe "--version flags"
# shellcheck disable=SC2043  # only setup.sh supports --version; single-item loop is intentional
for script in setup.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        VER_OUT=$(sh "$SCRIPT_DIR/$script" --version 2>&1 || true)
        assert_contains "$script --version shows the tools version" "$VER_OUT" "$VERSION"
        assert_contains "$script --version shows the pinned ctrld" "$VER_OUT" "$CTRLD_PIN"
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
# INTEGRATION TESTS — only run on actual router
# ══════════════════════════════════════════════════════════════════

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
    # Integration: DNS resolution
    assert_true  "DNS resolves via ctrld"    check_dns "127.0.0.1#5354"
    assert_true  "System DNS works"          check_dns

    # Integration: ctrld process
    assert_true  "ctrld process running"     pidof ctrld

    # Integration: iptables
    RULES=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c 5354)
    assert_true "iptables rules active ($RULES)" [ "$RULES" -gt 0 ]

    # Integration: cron jobs (wrap pipeline in sh -c so assert_true runs the
    # whole check in-process — not in a pipeline subshell, which set -e aborts on)
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
    # starts ctrld — so the LAN loses DNS for the duration. Worse, post-cfg.sh
    # waits on `while ! ping -c1 "$BOOTSTRAP_IP"` with no attempt limit, so if
    # the bootstrap host does not answer ICMP this never returns; interrupting
    # it then skips the restore below and leaves the config as post-cfg
    # regenerated it. CONTRIBUTING.md documents `sh /cfg/test.sh` as a routine
    # step, and a routine step must not do any of that.
    if [ "${CONTROLD_TEST_DESTRUCTIVE:-0}" = "1" ]; then
        BACKUP_TOML=$(cat /cfg/ctrld.toml)
        rm /cfg/ctrld.toml
        sh /cfg/post-cfg.sh >/dev/null 2>&1 || true
        assert_true "self-healing restored ctrld.toml" [ -f /cfg/ctrld.toml ]
        assert_true "DNS still works after self-heal"   check_dns "127.0.0.1#5354"
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
