#!/usr/bin/env bash
# =============================================================================
# test.sh — Docker-aware smoke test for the RCS broker stack
# =============================================================================
# Validates:
#   1. docker compose ps shows both services as running (healthy)
#   2. TLS pub/sub round trip over port 8883 (rcs_operator -> ugv/joystick,
#      ugv_client -> ugv/telemetry)
#   3. Coturn UDP listener on 127.0.0.1:3478
#
# Uses the host's mosquitto_pub/mosquitto_sub if present, otherwise falls back
# to `docker compose exec mosquitto ...`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FAILURES=0
ok()   { echo -e "  ${GREEN}PASS${NC}  $*"; }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; FAILURES=$((FAILURES+1)); }
info() { echo -e "  ${CYAN}....${NC}  $*"; }
warn() { echo -e "  ${YELLOW}WARN${NC}  $*"; }

echo -e "\n${BOLD}RCS Broker — Docker Smoke Test${NC}\n"

# ── Load .env ────────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    echo -e "${RED}.env not found — run bash init.sh first.${NC}"
    exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

: "${RCS_OPERATOR_PASSWORD:?RCS_OPERATOR_PASSWORD missing in .env}"
: "${UGV_CLIENT_PASSWORD:?UGV_CLIENT_PASSWORD missing in .env}"

CA_FILE_HOST="$SCRIPT_DIR/data/certs/ca.crt"
if [[ ! -f "$CA_FILE_HOST" ]]; then
    echo -e "${RED}CA cert not found at $CA_FILE_HOST — run bash init.sh first.${NC}"
    exit 1
fi

# ── Test 1: compose ps health ────────────────────────────────────────────────
echo -e "${BOLD}1. docker compose status${NC}"

if ! command -v docker >/dev/null 2>&1; then
    fail "docker not installed"
    exit 1
fi

if ! docker compose ps >/dev/null 2>&1; then
    fail "docker compose ps failed — is the stack up? (docker compose up -d)"
    exit 1
fi

for svc in mosquitto coturn; do
    state=$(docker compose ps --format '{{.Service}} {{.State}} {{.Status}}' 2>/dev/null | awk -v s="$svc" '$1==s {for(i=3;i<=NF;i++)printf "%s ",$i; print ""}')
    if [[ -z "$state" ]]; then
        fail "$svc: not found in docker compose ps"
        continue
    fi
    if echo "$state" | grep -qi "healthy"; then
        ok "$svc: $state"
    elif echo "$state" | grep -qi "Up"; then
        # No healthcheck reported yet — still starting or healthcheck disabled.
        warn "$svc: $state (no 'healthy' marker yet)"
    else
        fail "$svc: $state"
    fi
done

# ── Pick a mosquitto client (host or container) ──────────────────────────────
USE_HOST_CLIENT=0
if command -v mosquitto_pub >/dev/null 2>&1 && command -v mosquitto_sub >/dev/null 2>&1; then
    USE_HOST_CLIENT=1
fi

mqtt_sub() {
    # args: topic, user, pass, outfile
    local topic="$1" user="$2" pass="$3" out="$4"
    if (( USE_HOST_CLIENT )); then
        timeout 10 mosquitto_sub \
            --host localhost --port 8883 \
            --cafile "$CA_FILE_HOST" --insecure \
            --username "$user" --pw "$pass" \
            --topic "$topic" \
            -C 1 -W 8 > "$out" 2>/dev/null
    else
        timeout 10 docker compose exec -T mosquitto \
            mosquitto_sub \
            -h localhost -p 8883 \
            --cafile /mosquitto/certs/ca.crt --insecure \
            -u "$user" -P "$pass" \
            -t "$topic" \
            -C 1 -W 8 > "$out" 2>/dev/null
    fi
}

mqtt_pub() {
    local topic="$1" user="$2" pass="$3" msg="$4"
    if (( USE_HOST_CLIENT )); then
        timeout 5 mosquitto_pub \
            --host localhost --port 8883 \
            --cafile "$CA_FILE_HOST" --insecure \
            --username "$user" --pw "$pass" \
            --topic "$topic" --message "$msg" 2>/dev/null
    else
        timeout 5 docker compose exec -T mosquitto \
            mosquitto_pub \
            -h localhost -p 8883 \
            --cafile /mosquitto/certs/ca.crt --insecure \
            -u "$user" -P "$pass" \
            -t "$topic" -m "$msg" 2>/dev/null
    fi
}

# ── Test 2: TLS pub/sub round trip ───────────────────────────────────────────
echo -e "\n${BOLD}2. Pub/Sub round trip (TLS on 8883)${NC}"

if (( USE_HOST_CLIENT )); then
    info "using host mosquitto_pub/mosquitto_sub"
else
    info "using 'docker compose exec mosquitto' (host clients not installed)"
fi

TEST_MSG_A="{\"test\":\"fwd\",\"t\":$(date +%s)}"
TMP_A=$(mktemp)

mqtt_sub "ugv/joystick" "ugv_client" "$UGV_CLIENT_PASSWORD" "$TMP_A" &
SUB_PID=$!
sleep 2
mqtt_pub "ugv/joystick" "rcs_operator" "$RCS_OPERATOR_PASSWORD" "$TEST_MSG_A" || true
wait "$SUB_PID" 2>/dev/null || true
RECV_A=$(cat "$TMP_A" 2>/dev/null || echo "")
rm -f "$TMP_A"

if [[ "$RECV_A" == "$TEST_MSG_A" ]]; then
    ok "rcs_operator -> ugv/joystick -> ugv_client"
else
    fail "forward direction failed (got: '$RECV_A')"
fi

TEST_MSG_B="{\"test\":\"rev\",\"t\":$(date +%s)}"
TMP_B=$(mktemp)

mqtt_sub "ugv/telemetry" "rcs_operator" "$RCS_OPERATOR_PASSWORD" "$TMP_B" &
SUB_PID=$!
sleep 2
mqtt_pub "ugv/telemetry" "ugv_client" "$UGV_CLIENT_PASSWORD" "$TEST_MSG_B" || true
wait "$SUB_PID" 2>/dev/null || true
RECV_B=$(cat "$TMP_B" 2>/dev/null || echo "")
rm -f "$TMP_B"

if [[ "$RECV_B" == "$TEST_MSG_B" ]]; then
    ok "ugv_client -> ugv/telemetry -> rcs_operator"
else
    fail "reverse direction failed (got: '$RECV_B')"
fi

# ── Test 3: Coturn UDP listener ──────────────────────────────────────────────
echo -e "\n${BOLD}3. Coturn STUN/TURN${NC}"

if command -v nc >/dev/null 2>&1; then
    if nc -zu -w 2 127.0.0.1 3478 2>/dev/null; then
        ok "coturn UDP 3478 reachable on 127.0.0.1"
    else
        # nc -zu is unreliable (no response) — also probe with ss
        if ss -ulnp 2>/dev/null | grep -q ':3478 '; then
            ok "coturn listening on UDP 3478 (ss check)"
        else
            fail "coturn UDP 3478 not reachable"
        fi
    fi
else
    if ss -ulnp 2>/dev/null | grep -q ':3478 '; then
        ok "coturn listening on UDP 3478 (ss check)"
    else
        fail "coturn UDP 3478 not reachable and nc not installed"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if (( FAILURES == 0 )); then
    echo -e "${GREEN}${BOLD}All checks passed.${NC}\n"
    exit 0
else
    echo -e "${RED}${BOLD}${FAILURES} check(s) failed.${NC}"
    echo -e "Inspect logs: ${CYAN}docker compose logs mosquitto coturn${NC}\n"
    exit 1
fi
