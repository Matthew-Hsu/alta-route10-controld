#!/bin/sh
# DNS Protocol Benchmark for Alta Labs Route 10 + ControlD
# Tests query latency for DoQ, DoH3, and DoH using a separate port (5360)
# so live DNS on port 5354 is not disrupted.
#
# Usage: benchmark.sh [--queries N] [--help]

set -e

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

QUERIES=15
PROTOCOLS="doq doh3 doh"
TEST_PORT=5360
DOMAINS="google.com cloudflare.com amazon.com wikipedia.org github.com"
DOMAIN_COUNT=5
TMP_CONF="/tmp/ctrld-bench.toml"

# ── Help ──

usage() {
    printf "  ${BOLD}Usage:${RESET}  benchmark.sh [OPTIONS]

  ${BOLD}Options:${RESET}
    --queries N   Number of queries per protocol (default: 15)
    --help        Show this help message

  ${BOLD}Description:${RESET}
    Benchmarks DNS query latency across DoQ, DoH3, and DoH protocols
    using a temporary ctrld instance on port ${TEST_PORT}.
    Live DNS on port ${DNS_PORT} is not affected.

  ${BOLD}Examples:${RESET}
    benchmark.sh
    benchmark.sh --queries 30
"
    exit 0
}

# ── Parse arguments ──

while [ $# -gt 0 ]; do
    case "$1" in
        --queries)
            [ -n "$2" ] || die "--queries requires a number"
            QUERIES="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            die "Unknown option: $1  (try --help)"
            ;;
    esac
done

# ── Validate ──

[ "$QUERIES" -gt 0 ] 2>/dev/null || die "--queries must be a positive number"

load_env || die "Run setup.sh first.  (/cfg/controld.env not found)"

if [ -z "$RESOLVER_ID" ]; then
    die "RESOLVER_ID is empty.  Check /cfg/controld.env"
fi

# ── Helpers ──

write_bench_config() {
    _proto="$1"
    _endpoint=$(get_endpoint "$_proto" "$RESOLVER_ID")
    cat > "$TMP_CONF" << EOF
[service]
    log_level = "error"
    cache_enable = false
[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "bench"
[upstream.0]
    bootstrap_ip = "${BOOTSTRAP_IP}"
    endpoint = "${_endpoint}"
    name = "bench"
    timeout = 5000
    type = "${_proto}"
    send_client_info = false
[listener.0]
    ip = "127.0.0.1"
    port = ${TEST_PORT}
EOF
}

bench_protocol() {
    _proto="$1"

    # Kill any leftover test ctrld (avoid killing the production one)
    _bench_pid="$(pidof ctrld 2>/dev/null)" || true
    # Only kill if ctrld is listening on our test port
    if [ -n "$_bench_pid" ]; then
        for _p in $_bench_pid; do
            if netstat -tlnp 2>/dev/null | grep -q "${_p}.*${TEST_PORT}" \
               || ss -tlnp 2>/dev/null | grep -q "pid=${_p}.*:${TEST_PORT}"; then
                kill "$_p" 2>/dev/null || true
            fi
        done
        sleep 1
    fi

    write_bench_config "$_proto"

    # Start ctrld on test port
    /cfg/ctrld run -c "$TMP_CONF" -d >/dev/null 2>&1 &
    _started_pid=$!

    # Wait for it to be ready
    _n=0
    while [ "$_n" -lt 10 ]; do
        if nslookup google.com "127.0.0.1#${TEST_PORT}" >/dev/null 2>&1; then
            break
        fi
        sleep 1
        _n=$((_n + 1))
    done

    if [ "$_n" -eq 10 ]; then
        kill "$_started_pid" 2>/dev/null || true
        BENCH_AVG="FAIL"
        BENCH_OK=0
        BENCH_FAIL="$QUERIES"
        return
    fi

    # Run queries and measure total time
    _total_ms=0
    _success=0
    _fail=0
    _di=0
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        [ "$_i" -gt "$QUERIES" ] 2>/dev/null && break
        _di=$(( (_i - 1) % DOMAIN_COUNT + 1 ))
        _domain=$(echo "$DOMAINS" | awk "{print \$${_di}}")
        _start=$(date +%s%N 2>/dev/null || date +%s)

        if nslookup "$_domain" "127.0.0.1#${TEST_PORT}" >/dev/null 2>&1; then
            _end=$(date +%s%N 2>/dev/null || date +%s)
            if [ -n "$_start" ] && [ "${#_start}" -gt 9 ]; then
                _elapsed=$(( (_end - _start) / 1000000 ))
            else
                _elapsed=$(( (_end - _start) * 1000 ))
                [ "$_elapsed" -eq 0 ] && _elapsed=1
            fi
            _total_ms=$((_total_ms + _elapsed))
            _success=$((_success + 1))
        else
            _fail=$((_fail + 1))
        fi
    done

    kill "$_started_pid" 2>/dev/null || true
    sleep 1

    if [ "$_success" -eq 0 ]; then
        BENCH_AVG="FAIL"
        BENCH_OK=0
        BENCH_FAIL="$QUERIES"
    else
        BENCH_AVG=$((_total_ms / _success))
        BENCH_OK="$_success"
        BENCH_FAIL="$_fail"
    fi
}

# ── Cleanup ──

cleanup() {
    # Only kill ctrld processes on test port, not production
    _pids="$(pidof ctrld 2>/dev/null)" || true
    for _p in $_pids; do
        if netstat -tlnp 2>/dev/null | grep -q "${_p}.*${TEST_PORT}" \
           || ss -tlnp 2>/dev/null | grep -q "pid=${_p}.*:${TEST_PORT}"; then
            kill "$_p" 2>/dev/null || true
        fi
    done
    rm -f "$TMP_CONF"
}
trap cleanup EXIT

# ── Banner ──

print_banner
print_header "DNS Protocol Benchmark"
printf "  Resolver:       ${BOLD}%s${RESET}\n" "$RESOLVER_ID"
printf "  Current proto:  %s\n" "$(proto_label "$DNS_TYPE")"
printf "  Queries/protc:  %d\n" "$QUERIES"
printf "  Test domains:   %d\n" "$DOMAIN_COUNT"
printf "  Test port:      %d  (production on %d)\n" "$TEST_PORT" "$DNS_PORT"
printf "  Version:        %s\n" "$VERSION"
printf "\n"

# ── Run benchmarks ──

# Table header
printf "  ${BOLD}%-14s %-10s %-12s %-10s${RESET}\n" "Protocol" "Avg (ms)" "Success" "Failed"
printf "  ${DIM}%-14s %-10s %-12s %-10s${RESET}\n" \
    "----------" "---------" "----------" "---------"

fastest_ms=999999
fastest_proto=""
results_found=0

for proto in $PROTOCOLS; do
    label=$(proto_label "$proto")

    bench_protocol "$proto"

    if [ "$BENCH_AVG" = "FAIL" ]; then
        printf "  %-14s ${RED}%-10s${RESET} %-12s %-10s\n" \
            "$label" "FAILED" "${BENCH_OK}/${QUERIES}" "${BENCH_FAIL}"
    else
        results_found=$((results_found + 1))

        # Highlight fastest so far
        if [ "$BENCH_AVG" -lt "$fastest_ms" ]; then
            fastest_ms=$BENCH_AVG
            fastest_proto=$proto
            printf "  %-14s ${GREEN}%-10s${RESET} %-12s %-10s  ${DIM}<-- fastest${RESET}\n" \
                "$label" "${BENCH_AVG}ms" "${BENCH_OK}/${QUERIES}" "${BENCH_FAIL}"
        else
            printf "  %-14s ${BOLD}%-10s${RESET} %-12s %-10s\n" \
                "$label" "${BENCH_AVG}ms" "${BENCH_OK}/${QUERIES}" "${BENCH_FAIL}"
        fi
    fi
done

printf "\n"

# ── Recommendation ──

if [ "$results_found" -eq 0 ]; then
    print_fail "All protocols failed. Check network connectivity."
    exit 1
fi

rec_label=$(proto_label "$fastest_proto")
print_ok "Recommended: ${rec_label}  (${fastest_ms}ms avg)"

if [ "$fastest_proto" != "$DNS_TYPE" ]; then
    printf "\n"
    print_warn "Current protocol is $(proto_label "$DNS_TYPE")."
    printf "  To switch to ${GREEN}${rec_label}${RESET}:\n\n"
    printf "    ${BOLD}sed -i 's/DNS_TYPE=.*/DNS_TYPE=${fastest_proto}/' /cfg/controld.env${RESET}\n"
    printf "    ${BOLD}rm /cfg/ctrld.toml${RESET}\n"
    printf "    ${BOLD}kill \\\$(pidof ctrld); sleep 1; /cfg/post-cfg.sh${RESET}\n"
else
    printf "  ${DIM}(already active)${RESET}\n"
fi

printf "\n"
