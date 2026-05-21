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
assert_eq "doh wraps"   "doq"  "$(next_proto doh)"

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
assert_file_contains "LAN network"                "$TEST_CONF" 'cidrs = \["192.168.1.0/24"\]'
assert_file_contains "LAN2 network"               "$TEST_CONF" 'cidrs = \["192.168.2.0/24"\]'

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
# ENV FILE TESTS
# ══════════════════════════════════════════════════════════════════

describe "load_env() — env file parsing"

cat > "$TMPDIR/test.env" << 'EOF'
RESOLVER_ID=test123
BOOTSTRAP_IP=1.2.3.4
CURLD_VERSION=1.5.0
DNS_TYPE=doq
EOF
load_env "$TMPDIR/test.env"
assert_eq "resolver from env"     "test123" "$RESOLVER_ID"
assert_eq "bootstrap from env"    "1.2.3.4" "$BOOTSTRAP_IP"
assert_eq "version from env"      "1.5.0"   "$CURLD_VERSION"
assert_eq "type from env"         "doq"     "$DNS_TYPE"

# Test defaults for missing values (reset variables first)
DNS_TYPE=""
BOOTSTRAP_IP=""
cat > "$TMPDIR/test-minimal.env" << 'EOF'
RESOLVER_ID=abc
CURLD_VERSION=1.5.0
EOF
load_env "$TMPDIR/test-minimal.env"
assert_eq "default DNS_TYPE is doh3"      "doh3"        "$DNS_TYPE"
assert_eq "default bootstrap IP"          "76.76.2.22"  "$BOOTSTRAP_IP"

# Test load_env failure on missing file
assert_false "missing env file returns error" load_env "$TMPDIR/nonexistent.env"

# ══════════════════════════════════════════════════════════════════
# SCRIPT FLAG TESTS
# ══════════════════════════════════════════════════════════════════

describe "--help flags on all scripts"
for script in setup.sh status.sh watchdog.sh benchmark.sh uninstall.sh reconfigure.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        HELP_OUT=$(sh "$SCRIPT_DIR/$script" --help 2>&1 || true)
        assert_contains "$script --help mentions usage" "$HELP_OUT" "Usage"
        assert_contains "$script --help mentions --help" "$HELP_OUT" "\-\-help"
    else
        skip "$script not found"
    fi
done

describe "--version flags"
for script in setup.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        VER_OUT=$(sh "$SCRIPT_DIR/$script" --version 2>&1 || true)
        assert_contains "$script --version shows version" "$VER_OUT" "1.5.0"
    else
        skip "$script not found"
    fi
done

# ══════════════════════════════════════════════════════════════════
# PROTOCOL FALLBACK CHAIN TESTS
# ══════════════════════════════════════════════════════════════════

describe "Protocol fallback chain completeness"
assert_eq "doq -> doh3 -> doh -> doq (full cycle)" "doq" "$(next_proto $(next_proto $(next_proto doq)))"
assert_eq "doh3 -> doh -> doq (3 steps)" "doq" "$(next_proto $(next_proto doh3))"

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

    # Integration: cron jobs
    assert_true "watchdog cron installed"     crontab -l 2>/dev/null | grep -q watchdog
    assert_true "update cron installed"       crontab -l 2>/dev/null | grep -q controld-update

    # Integration: config files exist
    for f in /cfg/controld.env /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh /cfg/watchdog.sh /cfg/controld-update.sh; do
        assert_true "$f exists" [ -f "$f" ]
    done

    # Integration: self-healing (delete toml, regenerate from env)
    BACKUP_TOML=$(cat /cfg/ctrld.toml)
    rm /cfg/ctrld.toml
    sh /cfg/post-cfg.sh >/dev/null 2>&1 || true
    assert_true "self-healing restored ctrld.toml" [ -f /cfg/ctrld.toml ]
    assert_true "DNS still works after self-heal"   check_dns "127.0.0.1#5354"
    # Restore original in case self-heal used different proto
    printf "%s" "$BACKUP_TOML" > /cfg/ctrld.toml

    # Integration: watchdog dry-run
    if grep -q dry-run /cfg/watchdog.sh 2>/dev/null; then
        DRY_OUT=$(sh /cfg/watchdog.sh --dry-run 2>&1)
        assert_contains "watchdog dry-run reports status" "$DRY_OUT" "ctrld"
    else
        skip "watchdog --dry-run not available (old version)"
    fi

    # Integration: benchmark runs successfully
    if [ -f /cfg/benchmark.sh ]; then
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
