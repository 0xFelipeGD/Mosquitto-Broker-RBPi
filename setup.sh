#!/usr/bin/env bash
# ============================================================
# Mosquitto MQTT Broker — VPS Setup Wizard
# Phase 2: Secure broker for RCS <-> UGV communication
# ============================================================
set -euo pipefail

# ── Colors & helpers ────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/mosquitto_setup_$(date +%Y%m%d_%H%M%S).log"

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
banner(){ echo -e "\n${BOLD}══════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}══════════════════════════════════════════${NC}\n"; }

log_cmd() {
    "$@" >> "$LOG_FILE" 2>&1
}

ask() {
    local prompt="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${CYAN}?${NC} ${prompt} [${default}]: ")" reply
        echo "${reply:-$default}"
    else
        read -rp "$(echo -e "${CYAN}?${NC} ${prompt}: ")" reply
        echo "$reply"
    fi
}

ask_password() {
    local prompt="$1" pass1 pass2
    while true; do
        read -srp "$(echo -e "${CYAN}?${NC} ${prompt}: ")" pass1; echo >&2
        if [[ ${#pass1} -lt 8 ]]; then
            echo -e "${YELLOW}[WARN]${NC}  Password must be at least 8 characters. Try again." >&2
            continue
        fi
        read -srp "$(echo -e "${CYAN}?${NC} Confirm password: ")" pass2; echo >&2
        if [[ "$pass1" == "$pass2" ]]; then
            echo "$pass1"
            return
        fi
        echo -e "${YELLOW}[WARN]${NC}  Passwords don't match. Try again." >&2
    done
}

ask_yn() {
    local prompt="$1" default="${2:-y}" reply
    read -rp "$(echo -e "${CYAN}?${NC} ${prompt} [${default}]: ")" reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# ── Pre-flight checks ──────────────────────────────────────
preflight() {
    banner "Mosquitto MQTT Broker — VPS Setup Wizard"

    echo -e "This wizard will install and configure a secure Mosquitto"
    echo -e "MQTT broker for the RCS <-> UGV communication system.\n"
    echo -e "Log file: ${YELLOW}${LOG_FILE}${NC}\n"

    # Root check
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use: sudo ./setup.sh)"
        exit 1
    fi

    # OS check
    if [[ ! -f /etc/os-release ]]; then
        err "Cannot detect OS. This script supports Ubuntu/Debian."
        exit 1
    fi
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        warn "Detected OS: $PRETTY_NAME — this script is designed for Ubuntu/Debian."
        if ! ask_yn "Continue anyway?" "n"; then
            exit 1
        fi
    else
        info "Detected OS: $PRETTY_NAME"
    fi
}

# ── Step 1: Gather information ─────────────────────────────
gather_info() {
    banner "Step 1/7 — Configuration"

    # TLS mode
    echo -e "  ${BOLD}TLS Certificate Options:${NC}"
    echo -e "    1) Let's Encrypt (requires a domain pointing to this VPS)"
    echo -e "    2) Self-signed (works with IP address, no domain needed)\n"

    local tls_choice
    tls_choice=$(ask "Choose TLS mode (1 or 2)" "1")

    local detected_ip
    detected_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++)if($i=="src")print $(i+1);exit}' || hostname -I | awk '{print $1}')

    if [[ "$tls_choice" == "1" ]]; then
        TLS_MODE="letsencrypt"
        DOMAIN=$(ask "Enter your domain (e.g. mqtt.yourdomain.com)")
        if [[ -z "$DOMAIN" ]]; then
            err "Domain cannot be empty for Let's Encrypt."
            exit 1
        fi
        BROKER_HOST="$DOMAIN"
        info "Will use Let's Encrypt for: $DOMAIN"
    else
        TLS_MODE="selfsigned"
        DOMAIN=""
        BROKER_HOST=$(ask "VPS public IP address" "$detected_ip")
        info "Will use self-signed certificates for: $BROKER_HOST"
    fi

    echo ""

    # MQTT users
    info "Create MQTT user credentials (min 8 characters):"
    echo ""
    echo -e "  ${BOLD}rcs_operator${NC} — used by the Remote Control Station (Linux PC)"
    RCS_PASS=$(ask_password "Password for rcs_operator")
    echo ""
    echo -e "  ${BOLD}ugv_client${NC} — used by the Raspberry Pi on the UGV"
    UGV_PASS=$(ask_password "Password for ugv_client")
    echo ""

    # ACL
    ENABLE_ACL=true
    if ! ask_yn "Enable topic-level ACL? (recommended)" "y"; then
        ENABLE_ACL=false
    fi

    # Coturn (STUN+TURN for WebRTC video)
    echo ""
    echo -e "  ${BOLD}Coturn STUN+TURN server${NC} — needed for the UGV camera WebRTC feed"
    echo -e "  to traverse NAT. Recommended unless you already run a STUN/TURN elsewhere."
    ENABLE_COTURN=true
    if ! ask_yn "Install coturn STUN+TURN server for WebRTC video?" "y"; then
        ENABLE_COTURN=false
    fi

    if [[ "$ENABLE_COTURN" == true ]]; then
        # Auto-detect external IP for coturn (use BROKER_HOST as default if it is an IP)
        local default_ip="$detected_ip"
        if [[ "$TLS_MODE" == "selfsigned" && "$BROKER_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            default_ip="$BROKER_HOST"
        fi
        VPS_EXTERNAL_IP=$(ask "VPS external IP address (for coturn)" "$default_ip")
        if [[ -z "$VPS_EXTERNAL_IP" ]]; then
            err "External IP cannot be empty for coturn."
            exit 1
        fi
        TURN_REALM=$(ask "STUN/TURN realm (domain or IP)" "$VPS_EXTERNAL_IP")
    fi

    # Firewall
    ENABLE_UFW=true
    if ! ask_yn "Configure UFW firewall?" "y"; then
        ENABLE_UFW=false
    fi

    # Summary
    banner "Configuration Summary"
    echo -e "  TLS mode:       ${BOLD}${TLS_MODE}${NC}"
    echo -e "  Broker host:    ${BOLD}${BROKER_HOST}${NC}"
    echo -e "  MQTT port:      ${BOLD}8883${NC} (TLS)"
    echo -e "  Users:          ${BOLD}rcs_operator${NC}, ${BOLD}ugv_client${NC}"
    echo -e "  ACL:            ${BOLD}${ENABLE_ACL}${NC}"
    echo -e "  Coturn:         ${BOLD}${ENABLE_COTURN}${NC}"
    if [[ "$ENABLE_COTURN" == true ]]; then
        echo -e "    External IP:  ${BOLD}${VPS_EXTERNAL_IP}${NC}"
        echo -e "    Realm:        ${BOLD}${TURN_REALM}${NC}"
        echo -e "    TURN port:    ${BOLD}3478${NC} (UDP+TCP)"
        echo -e "    Relay ports:  ${BOLD}49152-65535/udp${NC}"
        echo -e "    TURN user:    ${BOLD}ugv${NC}"
    fi
    echo -e "  UFW firewall:   ${BOLD}${ENABLE_UFW}${NC}"
    echo ""

    if ! ask_yn "Proceed with installation?" "y"; then
        info "Aborted."
        exit 0
    fi
}

# ── Step 2: Install Mosquitto ──────────────────────────────
install_mosquitto() {
    banner "Step 2/7 — Installing Mosquitto"

    info "Adding Mosquitto PPA..."
    log_cmd apt-add-repository ppa:mosquitto-dev/mosquitto-ppa -y || true
    info "Updating package lists..."
    log_cmd apt-get update
    info "Installing mosquitto and mosquitto-clients..."
    log_cmd apt-get install -y mosquitto mosquitto-clients

    systemctl enable mosquitto >> "$LOG_FILE" 2>&1
    systemctl stop mosquitto >> "$LOG_FILE" 2>&1 || true

    # Replace default mosquitto.conf to prevent implicit listener on 1883.
    # The original config may define a listener or allow a default one;
    # we move ALL config into our rcs.conf via conf.d.
    if [[ -f /etc/mosquitto/mosquitto.conf ]]; then
        cp /etc/mosquitto/mosquitto.conf /etc/mosquitto/mosquitto.conf.bak
    fi
    cat > /etc/mosquitto/mosquitto.conf <<'MAINCONF'
# Managed by RCS MQTT setup wizard — all settings in conf.d/rcs.conf
pid_file /run/mosquitto/mosquitto.pid
include_dir /etc/mosquitto/conf.d
MAINCONF

    local version
    version=$(mosquitto -h 2>&1 | head -1 || true)
    ok "Installed: $version"
}

# ── Step 3: TLS certificates ──────────────────────────────
setup_tls() {
    banner "Step 3/7 — TLS Certificates"

    mkdir -p /etc/mosquitto/certs

    if [[ "$TLS_MODE" == "letsencrypt" ]]; then
        setup_tls_letsencrypt
    else
        setup_tls_selfsigned
    fi
}

setup_tls_letsencrypt() {
    info "Installing Certbot..."
    log_cmd apt-get install -y certbot

    info "Requesting certificate for $DOMAIN..."
    info "(Port 80 must be open temporarily for the challenge)"

    # Temporarily open port 80 if ufw is active
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow 80/tcp >> "$LOG_FILE" 2>&1 || true
    fi

    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos \
        --register-unsafely-without-email --preferred-challenges http \
        >> "$LOG_FILE" 2>&1

    # Close port 80 again
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw delete allow 80/tcp >> "$LOG_FILE" 2>&1 || true
    fi

    # Copy certs to mosquitto directory
    cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /etc/mosquitto/certs/server.crt
    cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" /etc/mosquitto/certs/server.key

    # CA file for Let's Encrypt — use the chain
    CA_FILE="/etc/mosquitto/certs/server.crt"
    CERT_FILE="/etc/mosquitto/certs/server.crt"
    KEY_FILE="/etc/mosquitto/certs/server.key"

    chown mosquitto:mosquitto /etc/mosquitto/certs/*
    chmod 640 /etc/mosquitto/certs/*

    # Renewal hook
    info "Setting up auto-renewal hook..."
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/mosquitto.sh <<HOOK
#!/bin/bash
cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem /etc/mosquitto/certs/server.crt
cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem /etc/mosquitto/certs/server.key
chown mosquitto:mosquitto /etc/mosquitto/certs/*
chmod 640 /etc/mosquitto/certs/*
systemctl restart mosquitto
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/mosquitto.sh

    ok "Let's Encrypt certificate installed for $DOMAIN"
    ok "Auto-renewal hook configured"
}

setup_tls_selfsigned() {
    info "Generating self-signed certificates..."

    cd /etc/mosquitto/certs

    # CA
    openssl genrsa -out ca.key 2048 >> "$LOG_FILE" 2>&1
    openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
        -subj "/CN=RCS MQTT CA" >> "$LOG_FILE" 2>&1

    # Server cert
    openssl genrsa -out server.key 2048 >> "$LOG_FILE" 2>&1
    openssl req -new -key server.key -out server.csr \
        -subj "/CN=${BROKER_HOST}" >> "$LOG_FILE" 2>&1

    # Sign with SAN for IP or domain
    local san_ext
    if [[ "$BROKER_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        san_ext="subjectAltName=IP:${BROKER_HOST}"
    else
        san_ext="subjectAltName=DNS:${BROKER_HOST}"
    fi

    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
        -CAcreateserial -out server.crt -days 3650 \
        -extfile <(echo "$san_ext") >> "$LOG_FILE" 2>&1

    rm -f server.csr ca.srl

    CA_FILE="/etc/mosquitto/certs/ca.crt"
    CERT_FILE="/etc/mosquitto/certs/server.crt"
    KEY_FILE="/etc/mosquitto/certs/server.key"

    chown mosquitto:mosquitto /etc/mosquitto/certs/*
    chmod 640 /etc/mosquitto/certs/*

    cd "$SCRIPT_DIR"

    ok "Self-signed certificates generated"
    warn "You must copy ${YELLOW}/etc/mosquitto/certs/ca.crt${NC} to the RCS PC and Raspberry Pi"
}

# ── Step 4: Create MQTT users ──────────────────────────────
create_users() {
    banner "Step 4/7 — MQTT Users"

    # Create password file with first user (-c = create new file)
    mosquitto_passwd -c -b /etc/mosquitto/passwd rcs_operator "$RCS_PASS"

    # Add second user (no -c = append)
    mosquitto_passwd -b /etc/mosquitto/passwd ugv_client "$UGV_PASS"

    chmod 640 /etc/mosquitto/passwd
    chown mosquitto:mosquitto /etc/mosquitto/passwd

    ok "Created users: rcs_operator, ugv_client"
}

# ── Step 5: Write Mosquitto config ─────────────────────────
write_config() {
    banner "Step 5/7 — Mosquitto Configuration"

    # ACL file
    if [[ "$ENABLE_ACL" == true ]]; then
        cat > /etc/mosquitto/acl <<'ACL'
# RCS operator: publish control commands, subscribe to telemetry
user rcs_operator
topic write ugv/joystick
topic write ugv/heartbeat
topic write ugv/ping
topic read ugv/telemetry
topic read ugv/pong
topic write ugv/camera/cmd
topic write ugv/camera/answer
topic write ugv/camera/ice/rcs
topic read ugv/camera/offer
topic read ugv/camera/ice/ugv
topic read ugv/camera/status

# UGV client: subscribe to control commands, publish telemetry
user ugv_client
topic read ugv/joystick
topic read ugv/heartbeat
topic read ugv/ping
topic write ugv/telemetry
topic write ugv/pong
topic read ugv/camera/cmd
topic read ugv/camera/answer
topic read ugv/camera/ice/rcs
topic write ugv/camera/offer
topic write ugv/camera/ice/ugv
topic write ugv/camera/status

# Both users can read $SYS for monitoring
pattern read $SYS/#
ACL
        chmod 640 /etc/mosquitto/acl
        chown mosquitto:mosquitto /etc/mosquitto/acl
        ok "ACL file written: /etc/mosquitto/acl"
    fi

    # Main config
    local acl_line="# acl_file /etc/mosquitto/acl  # Disabled"
    if [[ "$ENABLE_ACL" == true ]]; then
        acl_line="acl_file /etc/mosquitto/acl"
    fi

    cat > /etc/mosquitto/conf.d/rcs.conf <<CONF
# ============================================================
# RCS MQTT Broker Configuration
# Generated by setup wizard on $(date -Iseconds)
# ============================================================

# -- Listener: TLS on port 8883 -----------------------------
listener 8883
protocol mqtt

# -- TLS certificates ---------------------------------------
cafile ${CA_FILE}
certfile ${CERT_FILE}
keyfile ${KEY_FILE}
tls_version tlsv1.2

# -- Authentication -----------------------------------------
allow_anonymous false
password_file /etc/mosquitto/passwd

# -- Access Control -----------------------------------------
${acl_line}

# -- Performance tuning for real-time control ---------------
max_inflight_messages 20
max_queued_messages 100
message_size_limit 4096

# -- Logging ------------------------------------------------
log_dest syslog
log_type error
log_type warning
log_type notice
# log_type information
# log_type debug

# -- Persistence --------------------------------------------
persistence true
persistence_location /var/lib/mosquitto/

# -- Connection limits --------------------------------------
max_connections 10
CONF

    ok "Config written: /etc/mosquitto/conf.d/rcs.conf"

    # Disable default listener (no plaintext MQTT)
    echo "" > /etc/mosquitto/conf.d/default.conf
    ok "Default plaintext listener disabled"
}

# ── Step 6: Coturn STUN+TURN (optional) ───────────────────
setup_coturn() {
    banner "Step 6/7 — Coturn STUN+TURN Server"

    if [[ "$ENABLE_COTURN" != true ]]; then
        info "Coturn installation skipped (user choice)"
        return
    fi

    info "Installing coturn..."
    log_cmd apt-get install -y coturn

    local version
    version=$(turnserver --version 2>&1 | head -1 || echo "unknown")
    ok "Installed: $version"

    # Enable the coturn daemon
    info "Enabling coturn daemon..."
    if [[ -f /etc/default/coturn ]]; then
        cp /etc/default/coturn /etc/default/coturn.bak
        # Uncomment TURNSERVER_ENABLED=1 if commented, or add it
        if grep -q "^#.*TURNSERVER_ENABLED=1" /etc/default/coturn; then
            sed -i 's/^#.*TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
        elif ! grep -q "^TURNSERVER_ENABLED=1" /etc/default/coturn; then
            echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn
        fi
    else
        echo "TURNSERVER_ENABLED=1" > /etc/default/coturn
    fi
    ok "Coturn daemon enabled in /etc/default/coturn"

    # Write turnserver.conf
    info "Writing /etc/turnserver.conf..."
    if [[ -f /etc/turnserver.conf ]]; then
        cp /etc/turnserver.conf /etc/turnserver.conf.bak
    fi

    # Create log directory
    mkdir -p /var/log/coturn

    cat > /etc/turnserver.conf <<CONF
# ============================================================
# Coturn STUN + TURN Server Configuration
# Generated by Mosquitto setup wizard on $(date -Iseconds)
# Mode: STUN + TURN relay
# ============================================================

# -- Listening ----------------------------------------------
listening-port=3478

# -- External IP / Realm ------------------------------------
external-ip=${VPS_EXTERNAL_IP}
realm=${TURN_REALM}

# -- Authentication (long-term credentials for TURN) --------
lt-cred-mech
user=ugv:ugvturn2026

# -- No TLS (MQTT already uses TLS; TURN relay is UDP/TCP) --
no-tls
no-dtls

# -- TURN relay ---------------------------------------------
relay-ip=${VPS_EXTERNAL_IP}
min-port=49152
max-port=65535

# -- Security -----------------------------------------------
fingerprint
no-multicast-peers

# -- Disable the telnet CLI interface -----------------------
no-cli

# -- Logging ------------------------------------------------
log-file=/var/log/coturn/turnserver.log
verbose
CONF

    ok "Coturn configuration written: /etc/turnserver.conf"

    # Enable and start service
    info "Enabling and starting coturn service..."
    systemctl enable coturn >> "$LOG_FILE" 2>&1
    systemctl restart coturn >> "$LOG_FILE" 2>&1

    sleep 2

    if systemctl is-active --quiet coturn; then
        ok "Coturn service is running"
    else
        err "Coturn failed to start! Check logs:"
        journalctl -u coturn -n 20 --no-pager
        echo ""
        err "Full setup log: $LOG_FILE"
        exit 1
    fi

    # Verify port 3478
    if ss -ulnp | grep -q ":3478" || ss -tlnp | grep -q ":3478"; then
        ok "Port 3478 is listening (STUN/TURN)"
    else
        warn "Port 3478 not detected — check logs"
    fi
}

# ── Step 7: Firewall ───────────────────────────────────────
setup_firewall() {
    banner "Step 7/7 — Firewall"

    if [[ "$ENABLE_UFW" != true ]]; then
        warn "Firewall configuration skipped (user choice)"
        return
    fi

    if ! command -v ufw &>/dev/null; then
        info "Installing UFW..."
        log_cmd apt-get install -y ufw
    fi

    ufw allow 22/tcp >> "$LOG_FILE" 2>&1 || true
    ufw allow 8883/tcp >> "$LOG_FILE" 2>&1
    ufw deny 1883/tcp >> "$LOG_FILE" 2>&1

    if [[ "$ENABLE_COTURN" == true ]]; then
        info "Adding coturn firewall rules..."
        ufw allow 3478/udp >> "$LOG_FILE" 2>&1 || true
        ufw allow 3478/tcp >> "$LOG_FILE" 2>&1 || true
        ufw allow 49152:65535/udp >> "$LOG_FILE" 2>&1 || true
    fi

    # Enable non-interactively
    echo "y" | ufw enable >> "$LOG_FILE" 2>&1 || true

    if [[ "$ENABLE_COTURN" == true ]]; then
        ok "UFW configured: 22/tcp ALLOW, 8883/tcp ALLOW, 1883/tcp DENY, 3478/udp+tcp ALLOW, 49152-65535/udp ALLOW"
        ufw status | grep -E "(22|1883|8883|3478|49152|Status)" || true
    else
        ok "UFW configured: 22/tcp ALLOW, 8883/tcp ALLOW, 1883/tcp DENY"
        ufw status | grep -E "(22|1883|8883|Status)" || true
    fi
}

# ── Start & Test ───────────────────────────────────────────
start_and_test() {
    banner "Starting Mosquitto & Running Self-Test"

    info "Starting Mosquitto..."
    systemctl restart mosquitto

    sleep 2

    if systemctl is-active --quiet mosquitto; then
        ok "Mosquitto is running"
    else
        err "Mosquitto failed to start! Check logs:"
        journalctl -u mosquitto -n 20 --no-pager
        echo ""
        err "Full setup log: $LOG_FILE"
        exit 1
    fi

    # Verify port 8883
    if ss -tlnp | grep -q ":8883"; then
        ok "Listening on port 8883 (MQTTS)"
    else
        warn "Port 8883 not detected — check logs"
    fi

    # Verify port 1883 is NOT open
    if ss -tlnp | grep -q ":1883"; then
        warn "Port 1883 is still listening! Attempting to fix..."
        # Force-kill any default listener by ensuring no other config defines one
        grep -r "listener 1883" /etc/mosquitto/ >> "$LOG_FILE" 2>&1 || true
        warn "Check /etc/mosquitto/ for stray 'listener 1883' directives"
    else
        ok "Port 1883 is closed (no plaintext MQTT)"
    fi

    # Self-test: pub/sub
    info "Running pub/sub self-test..."

    local test_msg='{"test":true,"wizard":"setup","t":'"$(date +%s)"'}'
    local received

    # Start subscriber in background
    timeout 10 mosquitto_sub \
        --host localhost --port 8883 \
        --cafile "$CA_FILE" \
        --username rcs_operator --pw "$RCS_PASS" \
        --topic "ugv/telemetry" \
        -C 1 -W 8 \
        > /tmp/mqtt_test_result 2>/dev/null &
    local sub_pid=$!

    sleep 2

    # Publish
    mosquitto_pub \
        --host localhost --port 8883 \
        --cafile "$CA_FILE" \
        --username ugv_client --pw "$UGV_PASS" \
        --topic "ugv/telemetry" \
        --message "$test_msg" 2>/dev/null || true

    wait $sub_pid 2>/dev/null || true
    received=$(cat /tmp/mqtt_test_result 2>/dev/null || echo "")
    rm -f /tmp/mqtt_test_result

    if [[ "$received" == "$test_msg" ]]; then
        ok "Self-test PASSED — pub/sub over TLS works!"
    else
        warn "Self-test could not verify message delivery."
        warn "This may be normal if ACL restricts rcs_operator from reading ugv/telemetry."
        info "Run './test.sh' after setup for a full test."
    fi
}

# ── Save credentials file ──────────────────────────────────
save_credentials() {
    local creds_file="/etc/mosquitto/.credentials"

    # Write credentials with proper quoting for safe sourcing
    {
        echo "# Mosquitto MQTT Broker Credentials"
        echo "# Generated: $(date -Iseconds)"
        echo "# WARNING: Keep this file secure!"
        echo ""
        echo "BROKER_HOST='${BROKER_HOST}'"
        echo "BROKER_PORT='8883'"
        echo "TLS_MODE='${TLS_MODE}'"
        echo "CA_FILE='${CA_FILE}'"
        echo ""
        echo "RCS_USER='rcs_operator'"
        printf "RCS_PASS=%s\n" "'${RCS_PASS//\'/\'\\\'\'}'"
        echo ""
        echo "UGV_USER='ugv_client'"
        printf "UGV_PASS=%s\n" "'${UGV_PASS//\'/\'\\\'\'}'"
    } > "$creds_file"

    chmod 600 "$creds_file"
    chown root:root "$creds_file"
}

# ── Final summary ──────────────────────────────────────────
print_summary() {
    banner "Setup Complete!"

    echo -e "  ${GREEN}Mosquitto MQTT broker is running and secured.${NC}"
    if [[ "$ENABLE_COTURN" == true ]]; then
        echo -e "  ${GREEN}Coturn STUN+TURN server is running for WebRTC video.${NC}"
    else
        echo -e "  ${YELLOW}Coturn STUN+TURN server: skipped${NC}"
    fi
    echo ""

    echo -e "  ${BOLD}MQTT Broker Connection Details:${NC}"
    echo -e "    Host:     ${CYAN}${BROKER_HOST}${NC}"
    echo -e "    Port:     ${CYAN}8883${NC}"
    echo -e "    TLS:      ${CYAN}${TLS_MODE}${NC}"
    echo ""
    echo -e "  ${BOLD}MQTT Users:${NC}"
    echo -e "    rcs_operator  (for the Remote Control Station)"
    echo -e "    ugv_client    (for the Raspberry Pi / UGV)"
    echo ""

    if [[ "$ENABLE_COTURN" == true ]]; then
        echo -e "  ${BOLD}STUN+TURN Server (WebRTC video):${NC}"
        echo -e "    External IP:  ${CYAN}${VPS_EXTERNAL_IP}${NC}"
        echo -e "    Port:         ${CYAN}3478${NC} (UDP + TCP)"
        echo -e "    Realm:        ${CYAN}${TURN_REALM}${NC}"
        echo -e "    TURN user:    ${CYAN}ugv${NC}"
        echo -e "    TURN secret:  ${CYAN}ugvturn2026${NC}"
        echo -e "    Relay ports:  ${CYAN}49152-65535${NC} (UDP)"
        echo -e "    STUN URL:     ${CYAN}stun:${VPS_EXTERNAL_IP}:3478${NC}"
        echo -e "    TURN URL:     ${CYAN}turn:${VPS_EXTERNAL_IP}:3478${NC}"
        echo ""
    fi

    if [[ "$TLS_MODE" == "selfsigned" ]]; then
        echo -e "  ${BOLD}${YELLOW}IMPORTANT:${NC} Copy the CA certificate to your clients:"
        echo -e "    ${CYAN}scp root@${BROKER_HOST}:/etc/mosquitto/certs/ca.crt .${NC}"
        echo ""
    fi

    echo -e "  ${BOLD}RCS config.yaml:${NC}"
    echo -e "    ${CYAN}mqtt:${NC}"
    echo -e "    ${CYAN}  host: \"${BROKER_HOST}\"${NC}"
    echo -e "    ${CYAN}  port: 8883${NC}"
    echo -e "    ${CYAN}  username: \"rcs_operator\"${NC}"
    echo -e "    ${CYAN}  password: \"<your_password>\"${NC}"
    echo -e "    ${CYAN}  tls:${NC}"
    echo -e "    ${CYAN}    enabled: true${NC}"
    if [[ "$TLS_MODE" == "selfsigned" ]]; then
        echo -e "    ${CYAN}    ca_certs: \"/path/to/ca.crt\"${NC}"
    else
        echo -e "    ${CYAN}    ca_certs: \"\"  # empty = system CAs${NC}"
    fi
    if [[ "$ENABLE_COTURN" == true ]]; then
        echo -e "    ${CYAN}camera:${NC}"
        echo -e "    ${CYAN}  stun_servers:${NC}"
        echo -e "    ${CYAN}    - \"stun:${VPS_EXTERNAL_IP}:3478\"${NC}"
        echo -e "    ${CYAN}  turn_servers:${NC}"
        echo -e "    ${CYAN}    - url: \"turn:${VPS_EXTERNAL_IP}:3478\"${NC}"
        echo -e "    ${CYAN}      username: \"ugv\"${NC}"
        echo -e "    ${CYAN}      credential: \"ugvturn2026\"${NC}"
    fi
    echo ""

    echo -e "  ${BOLD}Useful commands:${NC}"
    echo -e "    Mosquitto status: ${CYAN}sudo systemctl status mosquitto${NC}"
    echo -e "    Mosquitto logs:   ${CYAN}sudo journalctl -u mosquitto -f${NC}"
    if [[ "$ENABLE_COTURN" == true ]]; then
        echo -e "    Coturn status:    ${CYAN}sudo systemctl status coturn${NC}"
        echo -e "    Coturn logs:      ${CYAN}sudo journalctl -u coturn -f${NC}"
    fi
    echo -e "    Test:             ${CYAN}sudo ${SCRIPT_DIR}/test.sh${NC}"
    echo -e "    Uninstall:        ${CYAN}sudo ${SCRIPT_DIR}/uninstall.sh${NC}"
    echo ""

    echo -e "  Credentials saved to: ${YELLOW}/etc/mosquitto/.credentials${NC}"
    echo -e "  Setup log: ${YELLOW}${LOG_FILE}${NC}"
    echo ""
}

# ── Main ───────────────────────────────────────────────────
main() {
    preflight
    gather_info
    install_mosquitto
    setup_tls
    create_users
    write_config
    setup_coturn
    setup_firewall
    start_and_test
    save_credentials
    print_summary
}

main "$@"
