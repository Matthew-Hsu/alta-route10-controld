#!/bin/sh
# DNS Protocol Benchmark for Alta Labs Route 10
# Tests query latency for DoQ, DoH3, and DoH
# Uses a separate port (5360) to avoid disrupting live DNS

set -e

[ -f /cfg/controld.env ] || { echo "Run setup.sh first."; exit 1; }
. /cfg/controld.env

DNS_TYPE=${DNS_TYPE:-doh3}
BOOTSTRAP_IP=${BOOTSTRAP_IP:-76.76.2.22}
TEST_PORT=5360
QUERIES=15
DOMAINS="google.com cloudflare.com amazon.com wikipedia.org github.com"
PROTOCOLS="doq doh3 doh"

echo ""
echo "  DNS Protocol Benchmark"
echo "  ======================"
echo "  Resolver: ${RESOLVER_ID}"
echo "  Queries per protocol: ${QUERIES}"
echo "  Test domains: $(echo $DOMAINS | wc -w)"
echo ""

# Cleanup on exit
cleanup() {
    kill $(pidof ctrld) 2>/dev/null || true
    rm -f /tmp/ctrld-bench.toml
}
trap cleanup EXIT

get_endpoint() {
    case "$1" in
        doq) echo "${RESOLVER_ID}.dns.controld.com" ;;
        *)   echo "https://dns.controld.com/${RESOLVER_ID}" ;;
    esac
}

write_bench_config() {
    proto="$1"
    endpoint=$(get_endpoint "$proto")
    cat > /tmp/ctrld-bench.toml << EOF
[service]
    log_level = "error"
    cache_enable = false
[network.0]
    cidrs = ["0.0.0.0/0"]
    name = "bench"
[upstream.0]
    bootstrap_ip = "${BOOTSTRAP_IP}"
    endpoint = "${endpoint}"
    name = "bench"
    timeout = 5000
    type = "${proto}"
    send_client_info = false
[listener.0]
    ip = "127.0.0.1"
    port = ${TEST_PORT}
EOF
}

bench_protocol() {
    proto="$1"
    label="$2"

    # Kill any leftover ctrld
    kill $(pidof ctrld) 2>/dev/null || true
    sleep 1

    write_bench_config "$proto"

    # Start ctrld on test port
    /cfg/ctrld run -c /tmp/ctrld-bench.toml -d >/dev/null 2>&1 &

    # Wait for it to be ready
    n=0
    while [ $n -lt 10 ]; do
        if nslookup google.com 127.0.0.1#${TEST_PORT} >/dev/null 2>&1; then
            break
        fi
        sleep 1
        n=$(expr $n + 1)
    done

    if [ $n -eq 10 ]; then
        echo "  ${label}    FAILED (could not start)"
        kill $(pidof ctrld) 2>/dev/null || true
        return
    fi

    # Run queries and measure total time
    total_ms=0
    success=0
    fail=0
    for i in $(seq 1 $QUERIES); do
        domain=$(echo "$DOMAINS" | awk "{print \$$(( (i - 1) % 5 + 1 ))}")
        start=$(date +%s%N 2>/dev/null || date +%s)

        if nslookup "$domain" 127.0.0.1#${TEST_PORT} >/dev/null 2>&1; then
            end=$(date +%s%N 2>/dev/null || date +%s)
            if [ -n "$start" ] && [ ${#start} -gt 9 ]; then
                # Nanosecond precision available
                elapsed=$(( (end - start) / 1000000 ))
            else
                # Second precision only
                elapsed=$(( (end - start) * 1000 ))
                [ $elapsed -eq 0 ] && elapsed=1
            fi
            total_ms=$((total_ms + elapsed))
            success=$((success + 1))
        else
            fail=$((fail + 1))
        fi
    done

    kill $(pidof ctrld) 2>/dev/null || true
    sleep 1

    if [ $success -eq 0 ]; then
        echo "  ${label}    FAILED (0/${QUERIES} queries succeeded)"
        return
    fi

    avg_ms=$((total_ms / success))
    echo "  ${label}    ${avg_ms}ms avg   ${success}/${QUERIES} ok   ${fail} failed"
}

# ── Run benchmarks ──

echo "  Protocol      Latency      Success"
echo "  --------      -------      -------"

results=""
fastest_ms=999999
fastest_proto=""

for proto in $PROTOCOLS; do
    case "$proto" in
        doq)  label="DoQ  (QUIC)" ;;
        doh3) label="DoH3 (H/3) " ;;
        doh)  label="DoH  (H/2) " ;;
    esac

    # Capture output
    output=$(bench_protocol "$proto" "$label" 2>&1)
    echo "$output"

    # Parse average ms for ranking
    avg=$(echo "$output" | grep -o '[0-9]*ms' | head -1 | sed 's/ms//')
    if [ -n "$avg" ] && [ "$avg" -lt "$fastest_ms" ] 2>/dev/null; then
        fastest_ms=$avg
        fastest_proto=$proto
    fi
done

echo ""

if [ -n "$fastest_proto" ]; then
    case "$fastest_proto" in
        doq)  rec_label="DoQ (QUIC)" ;;
        doh3) rec_label="DoH3 (HTTP/3)" ;;
        doh)  rec_label="DoH (HTTP/2)" ;;
    esac
    echo "  Recommended: ${rec_label} (${fastest_ms}ms avg)"

    if [ "$fastest_proto" != "$DNS_TYPE" ]; then
        echo ""
        echo "  Current protocol is ${DNS_TYPE}. To switch:"
        echo "    sed -i 's/DNS_TYPE=.*/DNS_TYPE=${fastest_proto}/' /cfg/controld.env"
        echo "    rm /cfg/ctrld.toml"
        echo "    kill \$(pidof ctrld); sleep 1; /cfg/post-cfg.sh"
    else
        echo "  (already active)"
    fi
else
    echo "  [!] All protocols failed. Check network connectivity."
fi

echo ""
