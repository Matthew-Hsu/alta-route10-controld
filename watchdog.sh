#!/bin/sh
# watchdog.sh — ControlD health monitor with automatic protocol fallback
# Runs via cron every 5 minutes.
# Uses lib.sh for shared helpers and state.
# shellcheck source=lib.sh

# ── Bootstrap lib.sh ─────────────────────────────────────────────────────────
LIB_DIR="$(dirname "$0")"
# shellcheck source=lib.sh
. "$LIB_DIR/lib.sh"

# ── Constants ────────────────────────────────────────────────────────────────

MAX_RESTART_ATTEMPTS=3
CONFIG_FILE="/cfg/ctrld.toml"
ENV_FILE="/cfg/controld.env"

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    _name="$(basename "$0")"
    cat <<EOF
Usage: ${_name} [OPTIONS]

ControlD health monitor with automatic protocol fallback.

Runs as a cron job every 5 minutes. Checks that ctrld is alive,
DNS resolves, and iptables rules are present. Automatically falls
back through the protocol chain (doq -> doh3 -> doh) on failure.

Options:
  --help      Show this help message and exit
  --dry-run   Check health and report what would be done, but make no changes
EOF
}

# ── Parse arguments ──────────────────────────────────────────────────────────

DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            usage
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        *)
            printf "Unknown option: %s\n" "$arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ── Guard: must have env file ────────────────────────────────────────────────

if [ ! -f "$ENV_FILE" ]; then
    logger -t watchdog "env file ${ENV_FILE} not found, exiting"
    exit 0
fi

if ! load_env "$ENV_FILE"; then
    logger -t watchdog "failed to load ${ENV_FILE}, exiting"
    exit 0
fi

# ── Wrapper: log actions, respect dry-run ────────────────────────────────────

do_log() {
    logger -t watchdog "$1"
}

do_restart_ctrld() {
    if [ "$DRY_RUN" -eq 1 ]; then
        print_ok "DRY-RUN: would restart ctrld with config $1"
        return 0
    fi
    do_log "restarting ctrld"
    restart_ctrld "$1"
    return $?
}

do_write_config() {
    _outfile="$1"
    _resolver="$2"
    _bootstrap="$3"
    _type="$4"
    if [ "$DRY_RUN" -eq 1 ]; then
        print_ok "DRY-RUN: would write config ${_outfile} with protocol ${_type}"
        return 0
    fi
    do_log "writing config ${_outfile} (protocol ${_type})"
    write_ctrld_config "$_outfile" "$_resolver" "$_bootstrap" "$_type"
}

do_ensure_iptables() {
    if [ "$DRY_RUN" -eq 1 ]; then
        _port="${1:-$DNS_PORT}"
        _count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "$_port")
        if [ "$_count" -eq 0 ]; then
            print_ok "DRY-RUN: would install iptables redirect rules for port ${_port}"
        else
            print_ok "DRY-RUN: iptables rules already present (${_count} rule(s))"
        fi
        return 0
    fi
    ensure_iptables "$1"
    _ret=$?
    if [ "$_ret" -eq 0 ]; then
        do_log "restored missing iptables redirect rules"
    fi
    return "$_ret"
}

do_save_env() {
    _key="$1"
    _val="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        print_ok "DRY-RUN: would update ${ENV_FILE}: ${_key}=${_val}"
        return 0
    fi
    sed -i "s/^${_key}=.*/${_key}=${_val}/" "$ENV_FILE"
    do_log "updated ${ENV_FILE}: ${_key}=${_val}"
}

do_stop_ctrld() {
    if [ "$DRY_RUN" -eq 1 ]; then
        print_ok "DRY-RUN: would stop ctrld process"
        return 0
    fi
    stop_ctrld
}

# (do_upgrade_check lives in lib.sh — sourced above — so this watchdog and the
# setup.sh-generated one share a single implementation.)

# ── Health Check 1: Is ctrld running? ────────────────────────────────────────

ctrld_pid=$(pidof ctrld 2>/dev/null)

if [ -z "$ctrld_pid" ]; then
    do_log "ctrld not running, restarting"
    do_write_config "$CONFIG_FILE" "$RESOLVER_ID" "$BOOTSTRAP_IP" "$DNS_TYPE"
    if do_restart_ctrld "$CONFIG_FILE"; then
        do_log "ctrld restarted successfully ($(proto_label "$DNS_TYPE"))"
    else
        do_log "ctrld restart failed"
    fi
    exit 0
fi

# ── Health Check 2: Does DNS resolve through ctrld? ──────────────────────────
# Debounce: only fall back / restart ctrld after FAIL_THRESHOLD consecutive
# failed cycles, so a single transient nslookup blip does NOT restart ctrld or
# churn the DNS protocol — both of which cause re-registration bursts that
# duplicate devices in the ControlD device-clients list.
FAIL_COUNT_FILE="/tmp/controld-dns-fail.count"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"

if check_dns "127.0.0.1#${DNS_PORT}"; then
    # DNS healthy — self-heal forced-DNS state (drift only) + check discovery inputs
    command -v ensure_forced_dns >/dev/null 2>&1 && ensure_forced_dns
    if [ -f /cfg/dhcp.leases ] && find /cfg/dhcp.leases -mmin +120 2>/dev/null | grep -q .; then
        do_log "dhcp.leases stale (>2h) — device discovery may degrade"
    fi
    rm -f "$FAIL_COUNT_FILE"
    command -v do_upgrade_check >/dev/null 2>&1 && do_upgrade_check
    exit 0
fi
fails=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
fails=$((fails + 1))
echo "$fails" > "$FAIL_COUNT_FILE"
if [ "$fails" -lt "$FAIL_THRESHOLD" ]; then
    do_log "DNS check failed (${fails}/${FAIL_THRESHOLD}) — waiting before restart to avoid churn"
    exit 0
fi
rm -f "$FAIL_COUNT_FILE"

# ── Sustained DNS failure — attempt recovery ─────────────────────────────────

do_log "DNS resolution failed on $(proto_label "$DNS_TYPE") after ${FAIL_THRESHOLD} consecutive checks — starting protocol fallback"

# ── Health Check 3: Are iptables rules present? ─────────────────────────────

do_ensure_iptables "$DNS_PORT"

# ── Protocol fallback chain ──────────────────────────────────────────────────

attempt=0
proto="$DNS_TYPE"

while [ "$attempt" -lt "$MAX_RESTART_ATTEMPTS" ]; do
    proto=$(next_proto "$proto")
    attempt=$((attempt + 1))

    do_log "trying protocol $(proto_label "$proto") (attempt ${attempt}/${MAX_RESTART_ATTEMPTS})"

    do_write_config "$CONFIG_FILE" "$RESOLVER_ID" "$BOOTSTRAP_IP" "$proto"

    if do_restart_ctrld "$CONFIG_FILE"; then
        do_save_env "DNS_TYPE" "$proto"
        do_log "fallback to $(proto_label "$proto") succeeded"
        exit 0
    fi

    do_log "protocol $(proto_label "$proto") failed"
done

# ── All protocols exhausted ──────────────────────────────────────────────────

do_log "all protocols failed, ctrld may be down. Using https-dns-proxy fallback."
