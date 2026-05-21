#!/bin/sh
# Check ControlD status on Alta Labs Route 10
# Run on the router: sh status.sh

echo ""
echo "  ControlD Status - Alta Labs Route 10"
echo "  ====================================="
echo ""

# Check config files
echo "  -- Configuration Files --"
for f in /cfg/controld.env /cfg/ctrld /cfg/ctrld.toml /cfg/post-cfg.sh /cfg/controld-update.sh /cfg/watchdog.sh; do
    if [ -f "$f" ]; then
        echo "  [OK] $f exists"
    else
        echo "  [!!] $f missing"
    fi
done

echo ""

# Check services
echo "  -- Services --"
if pidof ctrld >/dev/null 2>&1; then
    echo "  [OK] ctrld is running (PID $(pidof ctrld))"
else
    echo "  [!!] ctrld is NOT running"
fi

HTTPS_STATUS=$(/etc/init.d/https-dns-proxy status 2>&1)
if [ "$HTTPS_STATUS" = "running" ]; then
    echo "  [OK] https-dns-proxy is running (fallback)"
else
    echo "  [!!] https-dns-proxy is not running"
fi

echo ""

# Check DNS resolution
echo "  -- DNS Resolution --"
if nslookup google.com 127.0.0.1#5354 >/dev/null 2>&1; then
    echo "  [OK] ctrld DNS responding on port 5354"
else
    echo "  [!!] ctrld not responding on port 5354"
fi

if nslookup google.com >/dev/null 2>&1; then
    echo "  [OK] System DNS working"
else
    echo "  [!!] System DNS not working"
fi

echo ""

# Check iptables
echo "  -- iptables Redirect Rules --"
RULES=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c 5354)
if [ "$RULES" -gt 0 ]; then
    echo "  [OK] ${RULES} redirect rules active (per-device visibility enabled)"
else
    echo "  [!!] No redirect rules (per-device visibility disabled)"
fi

echo ""

# Check ControlD endpoint
echo "  -- ControlD Endpoint --"
RESOLVER=$(uci show https-dns-proxy.@https-dns-proxy[0].resolver_url 2>/dev/null | grep -o 'https://dns.controld.com/[a-z0-9]*')
if [ -n "$RESOLVER" ]; then
    echo "  [OK] https-dns-proxy -> $RESOLVER"
else
    echo "  [!!] https-dns-proxy not pointing to ControlD"
fi

if [ -f /cfg/controld.env ]; then
    . /cfg/controld.env
    DNS_TYPE=${DNS_TYPE:-doh}
    case "${DNS_TYPE}" in
        doh3) PROTO_LABEL="DoH3 (HTTP/3)" ;;
        doq)  PROTO_LABEL="DoQ (QUIC)" ;;
        doh)  PROTO_LABEL="DoH (HTTP/2)" ;;
        dot)  PROTO_LABEL="DoT (TLS)" ;;
        *)    PROTO_LABEL="${DNS_TYPE}" ;;
    esac
    echo "  [OK] Resolver ID: ${RESOLVER_ID}"
    echo "  [OK] Protocol: ${PROTO_LABEL}"
    echo "  [OK] Version: ${CURLD_VERSION}"
fi

echo ""

# Check upstreams and policies
echo "  -- Upstreams & Policies --"
if [ -f /cfg/ctrld.toml ]; then
    UPSTREAM_COUNT=$(grep -c '^\[upstream\.' /cfg/ctrld.toml 2>/dev/null || echo 0)
    echo "  [OK] ${UPSTREAM_COUNT} upstream(s) configured"
    grep '^\[upstream\.' /cfg/ctrld.toml 2>/dev/null | while read -r line; do
        idx=$(echo "$line" | grep -o '[0-9]*')
        name=$(grep -A1 "\[upstream.${idx}\]" /cfg/ctrld.toml | grep 'name' | sed 's/.*= "//;s/"//')
        proto=$(grep -A5 "\[upstream.${idx}\]" /cfg/ctrld.toml | grep 'type' | sed 's/.*= "//;s/"//')
        echo "    upstream.${idx}: ${name} (${proto})"
    done
    if grep -q '\[listener.0.policy\]' /cfg/ctrld.toml 2>/dev/null; then
        echo "  [OK] Split DNS policy active"
        MAC_COUNT=$(grep -c '="' /cfg/ctrld.toml 2>/dev/null || echo 0)
        if [ "$MAC_COUNT" -gt 0 ]; then
            echo "       MAC rules: ${MAC_COUNT} device(s)"
        fi
    fi
fi

echo ""

# Check cron
echo "  -- Cron Jobs --"
if crontab -l 2>/dev/null | grep -q controld-update; then
    echo "  [OK] Weekly auto-update cron installed"
else
    echo "  [!!] No auto-update cron job"
fi
if crontab -l 2>/dev/null | grep -q watchdog; then
    echo "  [OK] Watchdog cron installed (5-min health check)"
else
    echo "  [!!] No watchdog cron job"
fi

# Show recent watchdog logs
if [ -f /cfg/watchdog.sh ]; then
    LOG_ENTRIES=$(logread 2>/dev/null | grep watchdog | tail -3)
    if [ -n "$LOG_ENTRIES" ]; then
        echo ""
        echo "  -- Recent Watchdog Activity --"
        echo "$LOG_ENTRIES" | while read -r line; do
            echo "  $(echo "$line" | sed 's/.*watchdog:/  watchdog:/')"
        done
    fi
fi

echo ""
