#!/usr/bin/env bash
# =============================================================================
# init.sh — Bootstrap the Dockerized RCS broker stack
# =============================================================================
# Reads .env and populates ./data/ with everything the mosquitto and coturn
# containers need:
#
#   - Self-signed TLS CA + server cert (with SAN for IP and hostname)
#   - mosquitto.conf + conf.d/rcs.conf
#   - passwd (hashed, via eclipse-mosquitto image's mosquitto_passwd)
#   - acl (matches INTERFACE_CONTRACT.md)
#   - turnserver.conf
#
# Idempotent: running twice is a no-op. Existing certs are NOT regenerated
# unless they are missing. Passwords in .env are always re-applied to the
# passwd file (so rotating credentials is just "edit .env && bash init.sh").
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 1. Load .env ─────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    err ".env not found."
    echo "Copy .env.example to .env first:"
    echo "    cp .env.example .env && nano .env"
    exit 1
fi

# shellcheck disable=SC1091
set -a
source .env
set +a

# ── 2. Validate required vars ────────────────────────────────────────────────
missing=()
[[ -z "${VPS_EXTERNAL_IP:-}" ]]        && missing+=("VPS_EXTERNAL_IP")
[[ -z "${RCS_OPERATOR_PASSWORD:-}" ]]  && missing+=("RCS_OPERATOR_PASSWORD")
[[ -z "${UGV_CLIENT_PASSWORD:-}" ]]    && missing+=("UGV_CLIENT_PASSWORD")

if (( ${#missing[@]} > 0 )); then
    err "Missing required variable(s) in .env: ${missing[*]}"
    exit 1
fi

# ── 3. Defaults for optional vars ────────────────────────────────────────────
: "${TLS_MODE:=self-signed}"
: "${MQTT_HOSTNAME:=$VPS_EXTERNAL_IP}"
: "${TURN_USERNAME:=ugv}"
: "${TURN_PASSWORD:=ugvturn2026}"
: "${TURN_REALM:=$VPS_EXTERNAL_IP}"
: "${HEALTH_USER:=health}"

if [[ "$TLS_MODE" != "self-signed" ]]; then
    err "TLS_MODE='$TLS_MODE' is not supported yet. Only 'self-signed' is implemented."
    exit 1
fi

# Generate HEALTH_PASSWORD if blank and persist it back into .env
if [[ -z "${HEALTH_PASSWORD:-}" ]]; then
    HEALTH_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)
    warn "HEALTH_PASSWORD was empty — generated a random 32-char value and wrote it to .env"
    # Remove any existing HEALTH_PASSWORD= line (empty or not), then append.
    if grep -q '^HEALTH_PASSWORD=' .env; then
        # Use a tmp file so we don't depend on sed -i portability
        awk -v pw="$HEALTH_PASSWORD" '
            /^HEALTH_PASSWORD=/ { print "HEALTH_PASSWORD=" pw; next }
            { print }
        ' .env > .env.tmp && mv .env.tmp .env
    else
        echo "HEALTH_PASSWORD=$HEALTH_PASSWORD" >> .env
    fi
    export HEALTH_PASSWORD
fi

# ── 4. Create directory tree ─────────────────────────────────────────────────
info "Creating data/ directory tree..."
mkdir -p data/mosquitto/config/conf.d
mkdir -p data/mosquitto/data
mkdir -p data/mosquitto/log
mkdir -p data/certs
mkdir -p data/coturn/log

# The eclipse-mosquitto image runs as UID 1883. If the host user cannot chown
# to 1883 (non-root without sudo), the container will still start because the
# data/log dirs are world-writable. We err on the side of permissive here.
chmod 755 data data/mosquitto data/mosquitto/config data/mosquitto/config/conf.d
chmod 777 data/mosquitto/data data/mosquitto/log
chmod 755 data/certs
chmod 777 data/coturn/log

# ── 5. Self-signed CA + server cert ──────────────────────────────────────────
CERT_DIR="data/certs"

if [[ -f "$CERT_DIR/ca.crt" && -f "$CERT_DIR/server.crt" && -f "$CERT_DIR/server.key" ]]; then
    ok "TLS certificates already exist — skipping generation"
else
    info "Generating self-signed CA + server certificate..."

    # CA
    openssl genrsa -out "$CERT_DIR/ca.key" 2048 2>/dev/null
    openssl req -new -x509 -days 3650 \
        -key "$CERT_DIR/ca.key" \
        -out "$CERT_DIR/ca.crt" \
        -subj "/CN=RCS MQTT CA" 2>/dev/null

    # Server key + CSR
    openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null
    openssl req -new \
        -key "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.csr" \
        -subj "/CN=${MQTT_HOSTNAME}" 2>/dev/null

    # Build the SAN extension. Always include the external IP. Include the
    # hostname as DNS if it differs from the IP.
    san_lines=("IP:${VPS_EXTERNAL_IP}")
    if [[ "$MQTT_HOSTNAME" != "$VPS_EXTERNAL_IP" ]]; then
        if [[ "$MQTT_HOSTNAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            san_lines+=("IP:${MQTT_HOSTNAME}")
        else
            san_lines+=("DNS:${MQTT_HOSTNAME}")
        fi
    fi
    san_joined=$(IFS=, ; echo "${san_lines[*]}")

    openssl x509 -req \
        -in "$CERT_DIR/server.csr" \
        -CA "$CERT_DIR/ca.crt" \
        -CAkey "$CERT_DIR/ca.key" \
        -CAcreateserial \
        -out "$CERT_DIR/server.crt" \
        -days 3650 \
        -extfile <(echo "subjectAltName=${san_joined}") 2>/dev/null

    rm -f "$CERT_DIR/server.csr" "$CERT_DIR/ca.srl"

    chmod 644 "$CERT_DIR/ca.crt" "$CERT_DIR/server.crt"
    chmod 640 "$CERT_DIR/ca.key" "$CERT_DIR/server.key"

    ok "Self-signed certs written to $CERT_DIR/"
fi

# ── 6. mosquitto.conf (top-level) ────────────────────────────────────────────
info "Writing data/mosquitto/config/mosquitto.conf..."
cat > data/mosquitto/config/mosquitto.conf <<'MAIN'
# Managed by init.sh — all listener config lives in conf.d/rcs.conf
persistence true
persistence_location /mosquitto/data/
log_dest stdout

include_dir /mosquitto/config/conf.d
MAIN

# ── 7. conf.d/rcs.conf (listener + ACL + tuning) ─────────────────────────────
info "Writing data/mosquitto/config/conf.d/rcs.conf..."
cat > data/mosquitto/config/conf.d/rcs.conf <<'CONF'
# =============================================================================
# RCS MQTT Broker Configuration (Dockerized)
# Generated by init.sh
# =============================================================================

# -- Listener: TLS on port 8883 -----------------------------------------------
listener 8883
protocol mqtt

# -- TLS certificates (mounted from ./data/certs:/mosquitto/certs:ro) ---------
cafile /mosquitto/certs/ca.crt
certfile /mosquitto/certs/server.crt
keyfile /mosquitto/certs/server.key
tls_version tlsv1.2

# -- Authentication -----------------------------------------------------------
allow_anonymous false
password_file /mosquitto/config/passwd

# -- Access Control -----------------------------------------------------------
acl_file /mosquitto/config/acl

# -- Performance tuning for real-time control --------------------------------
max_inflight_messages 20
max_queued_messages 100
message_size_limit 4096

# -- Logging ------------------------------------------------------------------
log_type error
log_type warning
log_type notice

# -- Connection limits -------------------------------------------------------
max_connections 10
CONF

# ── 8. passwd (hashed via mosquitto_passwd inside eclipse-mosquitto:2) ───────
info "Generating passwd file via eclipse-mosquitto:2 container..."

PASSWD_FILE="data/mosquitto/config/passwd"
: > "$PASSWD_FILE"
chmod 640 "$PASSWD_FILE"

# mosquitto_passwd -b needs the password on argv; pipe stdin isn't enough for
# the bulk-add flow. We run three sequential `docker run` calls against a
# temp file mounted into the container.
#
# Important: do NOT pre-create the temp passwd file. `mosquitto_passwd -c`
# on recent mosquitto versions refuses to overwrite an existing file, so
# leaving /work/passwd absent lets the first call create it cleanly. We
# pass `--user` so the mosquitto container writes as the host user and
# the file is readable by the subsequent cp.
TMP_PASSWD_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_PASSWD_DIR"' EXIT
TMP_PASSWD_FILE="$TMP_PASSWD_DIR/passwd"

docker_passwd_add() {
    local user="$1" pass="$2" create_flag="${3:-}"
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        -v "$TMP_PASSWD_DIR:/work" \
        eclipse-mosquitto:2 \
        mosquitto_passwd ${create_flag} -b /work/passwd "$user" "$pass" >/dev/null
}

# -c on the first call creates a fresh file; subsequent calls append.
docker_passwd_add "rcs_operator" "$RCS_OPERATOR_PASSWORD" "-c"
docker_passwd_add "ugv_client"   "$UGV_CLIENT_PASSWORD"   ""
docker_passwd_add "$HEALTH_USER" "$HEALTH_PASSWORD"       ""

cp "$TMP_PASSWD_FILE" "$PASSWD_FILE"
chmod 640 "$PASSWD_FILE"

ok "passwd written with users: rcs_operator, ugv_client, $HEALTH_USER"

# ── 9. ACL (matches INTERFACE_CONTRACT.md) ───────────────────────────────────
info "Writing data/mosquitto/config/acl..."
cat > data/mosquitto/config/acl <<ACL
# =============================================================================
# Mosquitto ACL — matches INTERFACE_CONTRACT.md
# Generated by init.sh
# =============================================================================

# RCS operator: publish control commands, subscribe to telemetry
user rcs_operator
topic write ugv/joystick
topic write ugv/heartbeat
topic write ugv/ping
topic read  ugv/telemetry
topic read  ugv/pong
topic write ugv/camera/cmd
topic write ugv/camera/answer
topic write ugv/camera/ice/rcs
topic read  ugv/camera/offer
topic read  ugv/camera/ice/ugv
topic read  ugv/camera/status

# UGV client: subscribe to control commands, publish telemetry
user ugv_client
topic read  ugv/joystick
topic read  ugv/heartbeat
topic read  ugv/ping
topic write ugv/telemetry
topic write ugv/pong
topic read  ugv/camera/cmd
topic read  ugv/camera/answer
topic read  ugv/camera/ice/rcs
topic write ugv/camera/offer
topic write ugv/camera/ice/ugv
topic write ugv/camera/status

# Healthcheck user: read-only on uptime counter, nothing else
user ${HEALTH_USER}
topic read \$SYS/broker/uptime

# Both real users can read \$SYS for monitoring
pattern read \$SYS/#
ACL
chmod 640 data/mosquitto/config/acl

# ── 10. turnserver.conf ──────────────────────────────────────────────────────
info "Writing data/coturn/turnserver.conf..."
cat > data/coturn/turnserver.conf <<TURNCONF
# =============================================================================
# Coturn STUN + TURN Server Configuration
# Generated by init.sh
# Mode: STUN + TURN relay (no TLS — WebRTC already encrypts media via SRTP)
# =============================================================================

listening-port=3478

# External IP and realm
external-ip=${VPS_EXTERNAL_IP}
realm=${TURN_REALM}

# Long-term credentials (required for TURN allocation)
lt-cred-mech
user=${TURN_USERNAME}:${TURN_PASSWORD}

# No TLS on coturn itself (WebRTC uses SRTP)
no-tls
no-dtls

# TURN relay
min-port=49152
max-port=65535

# Security
fingerprint
no-multicast-peers

# Disable the telnet CLI
no-cli

# Logging to the mounted ./data/coturn/log volume
verbose
log-file=/var/log/turnserver.log
TURNCONF

# ── 11. Final summary ────────────────────────────────────────────────────────
ok "init.sh completed successfully"
echo ""
echo -e "${BOLD}Bootstrap summary${NC}"
echo "  VPS external IP:    $VPS_EXTERNAL_IP"
echo "  MQTT hostname (CN): $MQTT_HOSTNAME"
echo "  MQTT port (TLS):    8883"
echo "  TURN port:          3478 (UDP+TCP)"
echo "  TURN relay range:   49152-65535/udp"
echo "  TURN user:          $TURN_USERNAME"
echo ""
echo -e "${BOLD}Generated files${NC}"
echo "  data/certs/ca.crt, server.crt, server.key"
echo "  data/mosquitto/config/mosquitto.conf"
echo "  data/mosquitto/config/conf.d/rcs.conf"
echo "  data/mosquitto/config/passwd"
echo "  data/mosquitto/config/acl"
echo "  data/coturn/turnserver.conf"
echo ""
echo -e "${BOLD}Next steps${NC}"
echo "  1. docker compose up -d"
echo "  2. docker compose ps"
echo "  3. docker compose logs -f mosquitto"
echo ""
echo -e "${YELLOW}Remember:${NC} copy data/certs/ca.crt to the RCS and UGV clients."
