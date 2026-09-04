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
TEST_PORT="$BENCH_PORT"
TMP_CONF="$BENCH_CONF"

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

# ── Cleanup ──

# Only the throwaway daemon on the test port, matched by its config path.
# Production ctrld keeps answering for the LAN throughout.
cleanup() {
    bench_stop "$TMP_CONF" >/dev/null
    rm -f "$TMP_CONF"
}
trap cleanup EXIT

# ── Banner ──

print_banner
print_header "DNS Protocol Benchmark"
printf "  Resolver:       ${BOLD}%s${RESET}\n" "$RESOLVER_ID"
printf "  Current proto:  %s\n" "$(proto_label "$DNS_TYPE")"
printf "  Queries/protc:  %d\n" "$QUERIES"
printf "  Test domains:   %d\n" "$BENCH_DOMAIN_COUNT"
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

    bench_protocol "$proto" "$RESOLVER_ID" "$BOOTSTRAP_IP" "$QUERIES" "$TEST_PORT" "$TMP_CONF" || true

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
    # This used to print `rm /cfg/ctrld.toml` + re-run post-cfg.sh, which is the
    # one procedure docs/troubleshooting.md warns discards any split-DNS policy:
    # post-cfg regenerates the config from controld.env alone, and the extra
    # upstreams and the rules pointing at them are not in it. It also edited
    # only DNS_TYPE, leaving PREFERRED_PROTOCOL behind, so the watchdog's
    # self-upgrade check reverted the change about thirty minutes later.
    printf "    ${BOLD}sh /cfg/reconfigure.sh --protocol --to ${fastest_proto}${RESET}\n\n"
    printf "  ${DIM}That keeps your split-DNS policy, moves each upstream onto the${RESET}\n"
    printf "  ${DIM}new transport, and records it as your preferred protocol.${RESET}\n"
else
    printf "  ${DIM}(already active)${RESET}\n"
fi

printf "\n"
