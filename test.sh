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
( PATH="$WD_BIN:$PATH"; FAIL_THRESHOLD=1; export FAIL_THRESHOLD; sh "$WDGEN" ) >/dev/null 2>&1
WD_OUT="$(cat "$WD_LOG" 2>/dev/null)"

assert_contains "it tries to restart the dead ctrld" "$WD_OUT" "restart-attempt"
assert_contains "a failed restart does not end the run" "$WD_OUT" "falling through"
assert_contains "it works the protocol fallback chain"  "$WD_OUT" "trying doh"
assert_contains "and tears the redirects down when nothing resolves" "$WD_OUT" "teardown"

# The healthy path must still stop early — the teardown is a last resort, not
# something every cycle walks into.
cat > "$WD_CFG/lib.sh" << WDLIBEOF2
. "$SCRIPT_DIR/lib.sh"
check_dns()                  { return 0; }
ensure_iptables()            { return 1; }
ensure_firewall_user_rules() { return 1; }
ensure_forced_dns()          { :; }
do_upgrade_check()           { :; }
restart_ctrld()              { echo "restart-attempt" >> "\$WD_LOG"; return 0; }
remove_dns_redirects()       { echo "teardown" >> "\$WD_LOG"; }
WDLIBEOF2
: > "$WD_LOG"
( PATH="$WD_BIN:$PATH"; sh "$WDGEN" ) >/dev/null 2>&1
WD_OUT2="$(cat "$WD_LOG" 2>/dev/null)"
assert_contains     "a successful restart ends the cycle" "$WD_OUT2" "ctrld restarted"
assert_not_contains "and never reaches the teardown"      "$WD_OUT2" "teardown"

describe "uninstall.sh — a full purge, not just file removal"

# Leaving force_dns set means https-dns-proxy keeps hijacking 53 and 853 after
# the app is gone: someone uninstalling to get their DNS back is still caught.
assert_true "uninstall disables forced DNS" \
    grep -q 'disable_forced_dns' "$SCRIPT_DIR/uninstall.sh"
# force_dns_port is not ours: see the dedicated section below. Uninstall must
# never delete it, and must say why it is still listed.
assert_false "uninstall does not delete the package port list" \
    grep -q 'uci delete https-dns-proxy.config.force_dns_port' "$SCRIPT_DIR/uninstall.sh"
assert_true "uninstall explains the port list it leaves behind" \
    grep -q 'stock package default, inert with force_dns=0' "$SCRIPT_DIR/uninstall.sh"
assert_true "uninstall removes the empty /etc/controld ctrld creates" \
    grep -q 'rmdir /etc/controld' "$SCRIPT_DIR/uninstall.sh"
assert_true "uninstall clears runtime state" \
    grep -q 'controld-degraded' "$SCRIPT_DIR/uninstall.sh"
assert_true "uninstall checks rc.local ownership" \
    grep -q 'is_our_rc_local' "$SCRIPT_DIR/uninstall.sh"
assert_true "uninstall restores a pre-install rc.local" \
    grep -q 'rc.local.pre-controld' "$SCRIPT_DIR/uninstall.sh"
assert_false "rc.local is not in the blind removal list" \
    grep -qE '^\s+/cfg/rc.local ' "$SCRIPT_DIR/uninstall.sh"
assert_true "setup backs up a foreign rc.local" \
    grep -q 'rc.local.pre-controld' "$SCRIPT_DIR/setup.sh"

# The redirect port is per-install (setup.sh moves off 5354 when it is taken),
# so uninstall must read controld.env before it removes anything. Without it,
# DNS_PORT was lib.sh's 5354 default and a moved install kept every redirect —
# pointing at a port with nothing behind it. A source assertion because the
# behaviour needs /cfg, uci and iptables; it checks ordering, not presence,
# since a load_env below the first use would be no better than none.
UNINST_LOADS=$(grep -n '^load_env' "$SCRIPT_DIR/uninstall.sh" | head -1 | cut -d: -f1)
UNINST_USES=$(grep -n 'remove_dns_redirects "' "$SCRIPT_DIR/uninstall.sh" | head -1 | cut -d: -f1)
UNINST_ORDER=no
if [ -n "$UNINST_LOADS" ] && [ -n "$UNINST_USES" ] && [ "$UNINST_LOADS" -lt "$UNINST_USES" ]; then
    UNINST_ORDER=yes
fi
assert_eq "uninstall loads the install's config before removing rules" "yes" "$UNINST_ORDER"
assert_false "uninstall does not hardcode the default port" \
    grep -qE 'grep -c "5354"|--to-ports 5354' "$SCRIPT_DIR/uninstall.sh"

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
        "$(grep -vE '^[[:space:]]*#' "$SCRIPT_DIR/$_cs" \
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
    grep -q '^FORCED_DNS=0$' "$SCRIPT_DIR/setup.sh"

describe "version split — tools version vs pinned ctrld"

assert_match "VERSION is semver"    "$VERSION"    '^[0-9]+\.[0-9]+\.[0-9]+$'
assert_match "CTRLD_PIN is semver"  "$CTRLD_PIN"  '^[0-9]+\.[0-9]+\.[0-9]+$'
# These moved together once, and bumping the tools version silently repointed
# setup.sh at a ctrld release that does not exist.
assert_false "the two versions are not the same variable" [ "$VERSION" = "$CTRLD_PIN" ]
assert_true  "download URLs use the pin, not the tools version" \
    grep -q 'releases/download/v${CTRLD_PIN}' "$SCRIPT_DIR/setup.sh"
assert_false "no download URL is built from VERSION" \
    grep -q 'releases/download/v${VERSION}' "$SCRIPT_DIR/setup.sh"

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
    _self=$(grep -cE "^${_fn}\(\)|^# Usage: ${_fn}\b" "$SCRIPT_DIR/lib.sh")
    [ "$((_refs - _self))" -gt 0 ] || LIB_DEAD="${LIB_DEAD} ${_fn}"
done
assert_eq "every lib.sh function has a caller" "" "$LIB_DEAD"

describe "audit.sh — report our own artifacts as ours"

# ctrld.prev is the updater's rollback copy and the README documents it, but it
# fell through to the "not installed by this project" arm. It, ctrld.toml.bak
# and rc.local.pre-controld were also absent from the manifest, so each was
# reported twice — once as a known leftover, again as unexpected in /cfg.
# The arm itself, not its wording: matching the message text passes even if the
# case label is changed to something else entirely.
assert_true "ctrld.prev has its own case arm" \
    grep -qE '^\s*/cfg/ctrld\.prev\)' "$SCRIPT_DIR/audit.sh"
for _ak in ctrld.prev ctrld.toml.bak rc.local.pre-controld; do
    assert_true "${_ak} is on the manifest" \
        grep -q "^KNOWN=.* ${_ak} " "$SCRIPT_DIR/audit.sh"
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
    grep -q 'trld run -c ${_bs_conf}' "$SCRIPT_DIR/lib.sh"
# Scoped to the benchmark regions: a stop_ctrld elsewhere is meant to stop the
# production daemon, and only a benchmark must never do so.
SETUP_BENCH="$(sed -n '/── Inline benchmark ──/,/rm -f "\$BENCH_CONF"/p' "$SCRIPT_DIR/setup.sh")"
RECONF_BENCH="$(sed -n '/^do_benchmark() {/,/^}/p' "$SCRIPT_DIR/reconfigure.sh")"
assert_not_contains "setup.sh's benchmark does not reach for pidof"     "$SETUP_BENCH"  "pidof"
assert_not_contains "reconfigure.sh's benchmark does not reach for pidof" "$RECONF_BENCH" "pidof"
assert_contains     "setup.sh's benchmark uses the shared runner"       "$SETUP_BENCH"  "bench_protocol"
assert_contains     "reconfigure.sh's benchmark uses the shared runner" "$RECONF_BENCH" "bench_protocol"
assert_eq "benchmark.sh never kills ctrld by pidof" "" \
    "$(grep -n 'pidof ctrld' "$SCRIPT_DIR/benchmark.sh" || true)"
# netstat prints the local address before the PID column, so the old
# leftover-sweep pattern could never match.
assert_false "no PID-to-port correlation is left" \
    grep -q 'netstat -tlnp.*\${_p}' "$SCRIPT_DIR/benchmark.sh"

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
    grep -q 'version_gt "$CTRLD_INSTALLED" "$CTRLD_PIN"' "$SCRIPT_DIR/setup.sh"
assert_false "setup.sh no longer records the pin unconditionally" \
    grep -qE '^CTRLD_VERSION="\$\{CTRLD_PIN\}"$' "$SCRIPT_DIR/setup.sh"
# Deleting this writes an empty CTRLD_VERSION into controld.env, which breaks
# post-cfg.sh's self-heal and the weekly updater. Nothing covered it.
assert_true "the keep branch records the version it kept" \
    grep -q 'CTRLD_VERSION="$CTRLD_INSTALLED"' "$SCRIPT_DIR/setup.sh"
assert_true "a kept binary must prove it runs" \
    grep -q '/cfg/ctrld --version' "$SCRIPT_DIR/setup.sh"

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
        grep -qE 'kill (-9 )?"\$\(pidof' "$SCRIPT_DIR/$_ks"
done

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
    grep -q '^write_env_file /cfg/controld.env' "$SCRIPT_DIR/setup.sh"
assert_true "reconfigure.sh does too" \
    grep -q 'write_env_file /cfg/controld.env' "$SCRIPT_DIR/reconfigure.sh"
assert_false "no here-doc reads the file it is truncating" \
    grep -q 'FORCED_DNS=$(preserved_forced_dns' "$SCRIPT_DIR/setup.sh"

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
    grep -q 'set_fallback_resolver "$RESOLVER_ID"' "$SCRIPT_DIR/setup.sh"
assert_true "reconfigure.sh rotates the fallback with the resolver" \
    sh -c "sed -n '/^do_resolver/,/^}/p' '$SCRIPT_DIR/reconfigure.sh' | grep -q set_fallback_resolver"

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
assert_false "audit.sh contains no in-place sed" grep -q 'sed -i' "$SCRIPT_DIR/audit.sh"
assert_false "audit.sh contains no rm"           grep -qE '(^|[^a-z-])rm ' "$SCRIPT_DIR/audit.sh"

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
    grep -q 'UTILITY_SCRIPTS=.*audit\.sh' "$SCRIPT_DIR/setup.sh"
assert_true "uninstall.sh removes audit.sh" \
    grep -q '/cfg/audit\.sh' "$SCRIPT_DIR/uninstall.sh"
# A failed reconfigure leaves this behind, holding the previous resolver ID
assert_true "uninstall.sh removes a stale ctrld.toml.bak" \
    grep -q '/cfg/ctrld\.toml\.bak' "$SCRIPT_DIR/uninstall.sh"
# backup.sh stored its backup on the partition it existed to protect, and its
# file list was five files short of a working install
assert_false "backup.sh is gone" [ -f "$SCRIPT_DIR/backup.sh" ]
assert_true "uninstall.sh removes the directory it left behind" \
    grep -q 'rm -rf /cfg/controld-backup' "$SCRIPT_DIR/uninstall.sh"

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
