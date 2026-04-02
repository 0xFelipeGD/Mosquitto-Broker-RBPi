#!/usr/bin/env bash
# ============================================================
# Mosquitto Broker — Test Script
# Verifies the broker is running and pub/sub works over TLS
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}PASS${NC}  $*"; }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; FAILURES=$((FAILURES+1)); }
info() { echo -e "  ${CYAN}....${NC}  $*"; }

FAILURES=0
CREDS_FILE="/etc/mosquitto/.credentials"

echo -e "\n${BOLD}Mosquitto Broker — Test Suite${NC}\n"

# ── Load credentials ────────────────────────────────────────
if [[ ! -f "$CREDS_FILE" ]]; then
    echo -e "${RED}Credentials file not found: ${CREDS_FILE}${NC}"
    echo -e "Run ${CYAN}sudo ./setup.sh${NC} first.\n"
    exit 1
fi

source "$CREDS_FILE"

# ── Test 1: Service running ─────────────────────────────────
echo -e "${BOLD}1. Service Status${NC}"
if systemctl is-active --quiet mosquitto; then
    ok "Mosquitto service is active"
else
    fail "Mosquitto service is NOT active"
fi

# ── Test 2: Port 8883 listening ─────────────────────────────
echo -e "\n${BOLD}2. Port Check${NC}"
if ss -tlnp | grep -q ":8883"; then
    ok "Port 8883 is listening"
else
    fail "Port 8883 is NOT listening"
fi

# Check port 1883 is NOT listening
if ss -tlnp | grep -q ":1883"; then
    fail "Port 1883 is listening (plaintext MQTT should be disabled!)"
else
    ok "Port 1883 is closed (no plaintext)"
fi

# ── Test 3: TLS certificate valid ───────────────────────────
echo -e "\n${BOLD}3. TLS Certificate${NC}"
if [[ -f /etc/mosquitto/certs/server.crt ]]; then
    expiry=$(openssl x509 -enddate -noout -in /etc/mosquitto/certs/server.crt 2>/dev/null | cut -d= -f2)
    if [[ -n "$expiry" ]]; then
        ok "Server certificate exists (expires: $expiry)"
    else
        fail "Cannot read server certificate"
    fi
else
    fail "Server certificate not found"
fi

# ── Test 4: Config files exist ──────────────────────────────
echo -e "\n${BOLD}4. Configuration Files${NC}"
for f in /etc/mosquitto/conf.d/rcs.conf /etc/mosquitto/passwd; do
    if [[ -f "$f" ]]; then
        ok "Found: $f"
    else
        fail "Missing: $f"
    fi
done

if [[ -f /etc/mosquitto/acl ]]; then
    ok "Found: /etc/mosquitto/acl"
else
    info "ACL file not found (optional)"
fi

# ── Test 5: Pub/Sub over TLS ────────────────────────────────
echo -e "\n${BOLD}5. Pub/Sub Test (TLS)${NC}"

TEST_MSG="{\"test\":true,\"t\":$(date +%s)}"

# Subscriber in background
timeout 10 mosquitto_sub \
    --host localhost --port 8883 \
    --cafile "$CA_FILE" \
    --username "$UGV_USER" --pw "$UGV_PASS" \
    --topic "ugv/joystick" \
    -C 1 -W 8 \
    > /tmp/mqtt_test_sub 2>/dev/null &
SUB_PID=$!

sleep 2

# Publish
mosquitto_pub \
    --host localhost --port 8883 \
    --cafile "$CA_FILE" \
    --username "$RCS_USER" --pw "$RCS_PASS" \
    --topic "ugv/joystick" \
    --message "$TEST_MSG" 2>/dev/null || true

wait $SUB_PID 2>/dev/null || true
RECEIVED=$(cat /tmp/mqtt_test_sub 2>/dev/null || echo "")
rm -f /tmp/mqtt_test_sub

if [[ "$RECEIVED" == "$TEST_MSG" ]]; then
    ok "rcs_operator -> ugv/joystick -> ugv_client : delivered"
else
    fail "Message not received (got: '${RECEIVED}')"
    info "Check logs: sudo journalctl -u mosquitto -n 20 --no-pager"
fi

# Test reverse direction: ugv_client publishes telemetry, rcs_operator reads
timeout 10 mosquitto_sub \
    --host localhost --port 8883 \
    --cafile "$CA_FILE" \
    --username "$RCS_USER" --pw "$RCS_PASS" \
    --topic "ugv/telemetry" \
    -C 1 -W 8 \
    > /tmp/mqtt_test_sub2 2>/dev/null &
SUB_PID=$!

sleep 2

mosquitto_pub \
    --host localhost --port 8883 \
    --cafile "$CA_FILE" \
    --username "$UGV_USER" --pw "$UGV_PASS" \
    --topic "ugv/telemetry" \
    --message "$TEST_MSG" 2>/dev/null || true

wait $SUB_PID 2>/dev/null || true
RECEIVED=$(cat /tmp/mqtt_test_sub2 2>/dev/null || echo "")
rm -f /tmp/mqtt_test_sub2

if [[ "$RECEIVED" == "$TEST_MSG" ]]; then
    ok "ugv_client -> ugv/telemetry -> rcs_operator : delivered"
else
    fail "Reverse direction message not received"
fi

# ── Test 6: Reject anonymous ────────────────────────────────
echo -e "\n${BOLD}6. Security Tests${NC}"

# Anonymous should fail
if timeout 5 mosquitto_pub \
    --host localhost --port 8883 \
    --cafile "$CA_FILE" \
    --topic "ugv/test" \
    --message "anon" 2>/dev/null; then
    fail "Anonymous publish was accepted (should be rejected!)"
else
    ok "Anonymous access rejected"
fi

# Wrong password should fail
if timeout 5 mosquitto_pub \
    --host localhost --port 8883 \
    --cafile "$CA_FILE" \
    --username rcs_operator --pw "wrongpassword123" \
    --topic "ugv/test" \
    --message "bad" 2>/dev/null; then
    fail "Wrong password was accepted!"
else
    ok "Wrong password rejected"
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All tests passed!${NC} Broker is ready.\n"
else
    echo -e "${RED}${BOLD}${FAILURES} test(s) failed.${NC} Check the output above.\n"
    exit 1
fi
