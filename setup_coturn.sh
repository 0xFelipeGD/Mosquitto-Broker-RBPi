#!/usr/bin/env bash
# ============================================================
# Coturn STUN + TURN Server — VPS Setup Wizard
# Provides NAT traversal for WebRTC video streaming (UGV camera)
# ============================================================
set -euo pipefail

# -- Colors & helpers ----------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/coturn_setup_$(date +%Y%m%d_%H%M%S).log"

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

ask_yn() {
    local prompt="$1" default="${2:-y}" reply
    read -rp "$(echo -e "${CYAN}?${NC} ${prompt} [${default}]: ")" reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# ── Phase 1: Pre-flight checks ────────────────────────────
preflight() {
    banner "Coturn STUN + TURN Server — VPS Setup Wizard"

    echo -e "This wizard will install and configure coturn as a STUN + TURN server"
    echo -e "for WebRTC NAT traversal (UGV camera streaming).\n"
    echo -e "Log file: ${YELLOW}${LOG_FILE}${NC}\n"

    # Root check
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use: sudo ./setup_coturn.sh)"
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

# ── Phase 2: Gather information ───────────────────────────
gather_info() {
    banner "Step 1/4 — Configuration"

    local detected_ip
    detected_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++)if($i=="src")print $(i+1);exit}' || hostname -I | awk '{print $1}')

    VPS_EXTERNAL_IP=$(ask "VPS external IP address" "$detected_ip")
    if [[ -z "$VPS_EXTERNAL_IP" ]]; then
        err "External IP cannot be empty."
        exit 1
    fi

    REALM=$(ask "STUN realm (domain or IP)" "$VPS_EXTERNAL_IP")

    # Summary
    banner "Configuration Summary"
    echo -e "  External IP:    ${BOLD}${VPS_EXTERNAL_IP}${NC}"
    echo -e "  Realm:          ${BOLD}${REALM}${NC}"
    echo -e "  Listening port: ${BOLD}3478${NC} (UDP + TCP)"
    echo -e "  Mode:           ${BOLD}STUN + TURN relay${NC}"
    echo -e "  Auth:           ${BOLD}long-term credentials${NC} (user: ugv)"
    echo -e "  Relay ports:    ${BOLD}49152-65535${NC} (UDP)"
    echo ""

    if ! ask_yn "Proceed with installation?" "y"; then
        info "Aborted."
        exit 0
    fi
}

# ── Phase 3: Install coturn ───────────────────────────────
install_coturn() {
    banner "Step 2/4 — Installing Coturn"

    info "Updating package lists..."
    log_cmd apt-get update

    info "Installing coturn..."
    log_cmd apt-get install -y coturn

    local version
    version=$(turnserver --version 2>&1 | head -1 || echo "unknown")
    ok "Installed: $version"
}

# ── Phase 4: Configure coturn ─────────────────────────────
configure_coturn() {
    banner "Step 3/4 — Configuration"

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
# Generated by setup_coturn.sh on $(date -Iseconds)
# Mode: STUN + TURN relay
# ============================================================

# -- Listening ----------------------------------------------
listening-port=3478

# -- External IP / Realm ------------------------------------
external-ip=${VPS_EXTERNAL_IP}
realm=${REALM}

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

    ok "Configuration written: /etc/turnserver.conf"
}

# ── Phase 5: Firewall + service ───────────────────────────
setup_firewall_and_service() {
    banner "Step 4/4 — Firewall & Service"

    # UFW rules
    if command -v ufw &>/dev/null; then
        info "Configuring UFW firewall rules..."
        ufw allow 3478/udp >> "$LOG_FILE" 2>&1 || true
        ufw allow 3478/tcp >> "$LOG_FILE" 2>&1 || true
        ufw allow 49152:65535/udp >> "$LOG_FILE" 2>&1 || true
        ok "UFW: 3478/udp ALLOW, 3478/tcp ALLOW, 49152:65535/udp ALLOW (TURN relay)"
    else
        warn "UFW not found — make sure port 3478 (UDP+TCP) and 49152-65535 (UDP) are open in your firewall"
    fi

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
        ok "Port 3478 is listening"
    else
        warn "Port 3478 not detected — check logs"
    fi
}

# ── Summary ───────────────────────────────────────────────
print_summary() {
    banner "Setup Complete!"

    echo -e "  ${GREEN}Coturn STUN + TURN server is running and ready.${NC}\n"

    echo -e "  ${BOLD}Connection Details:${NC}"
    echo -e "    External IP:  ${CYAN}${VPS_EXTERNAL_IP}${NC}"
    echo -e "    Port:         ${CYAN}3478${NC} (UDP + TCP)"
    echo -e "    Mode:         ${CYAN}STUN + TURN relay${NC}"
    echo -e "    Realm:        ${CYAN}${REALM}${NC}"
    echo -e "    TURN user:    ${CYAN}ugv${NC}"
    echo -e "    Relay ports:  ${CYAN}49152-65535${NC} (UDP)"
    echo ""

    echo -e "  ${BOLD}ICE Configuration (for RCS and UGV config.yaml):${NC}"
    echo -e "    ${CYAN}camera:${NC}"
    echo -e "    ${CYAN}  stun_servers:${NC}"
    echo -e "    ${CYAN}    - \"stun:${VPS_EXTERNAL_IP}:3478\"${NC}"
    echo -e "    ${CYAN}  turn_servers:${NC}"
    echo -e "    ${CYAN}    - url: \"turn:${VPS_EXTERNAL_IP}:3478\"${NC}"
    echo -e "    ${CYAN}      username: \"ugv\"${NC}"
    echo -e "    ${CYAN}      credential: \"ugvturn2026\"${NC}"
    echo ""

    echo -e "  ${BOLD}Useful commands:${NC}"
    echo -e "    Status:   ${CYAN}sudo systemctl status coturn${NC}"
    echo -e "    Logs:     ${CYAN}sudo journalctl -u coturn -f${NC}"
    echo -e "    Log file: ${CYAN}cat /var/log/coturn/turnserver.log${NC}"
    echo ""

    echo -e "  Setup log: ${YELLOW}${LOG_FILE}${NC}"
    echo ""
}

# ── Main ──────────────────────────────────────────────────
main() {
    preflight
    gather_info
    install_coturn
    configure_coturn
    setup_firewall_and_service
    print_summary
}

main "$@"
