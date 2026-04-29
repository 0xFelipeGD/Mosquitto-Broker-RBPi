#!/usr/bin/env bash
# =============================================================================
# deploy.sh — One-shot deploy wizard for the RCS broker stack
# =============================================================================
# Usage (on a fresh VPS):
#
#   ssh root@<VPS_IP>
#   git clone https://github.com/0xFelipeGD/Mosquitto-Broker-RBPi.git
#   cd Mosquitto-Broker-RBPi
#   bash deploy.sh
#
# Walks the operator through every step needed to bring the broker stack up:
#   1. Pre-flight (root/sudo, OS detection, repo layout)
#   2. Plan summary + confirmation
#   3. Docker install (idempotent)
#   4. Optional cleanup of any legacy native install
#   5. Interactive .env build (or reuse/edit existing)
#   6. init.sh + docker compose pull + up + wait-for-healthy
#   7. UFW rules (optional)
#   8. test.sh smoke test
#   9. Summary with credentials and next steps
#
# Non-interactive mode (--non-interactive): all values must be supplied via the
# environment. Useful for CI/CD. Required env vars in non-interactive mode:
#   VPS_EXTERNAL_IP, RCS_OPERATOR_PASSWORD, UGV_CLIENT_PASSWORD
# Optional: TURN_USERNAME, TURN_PASSWORD, INSTALL_DOCKER (yes/no),
#           CLEANUP_LEGACY (yes/no), CONFIGURE_UFW (yes/no)
# =============================================================================
set -euo pipefail
# Restrict word splitting to newline+tab so variable expansion inside `read -r` / `ask()` helpers does not split on spaces in user input
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Color helpers (tput, with fallback) ──────────────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    OK_GREEN="$(tput setaf 2)"
    WARN_YELLOW="$(tput setaf 3)"
    ERR_RED="$(tput setaf 1)"
    INFO_CYAN="$(tput setaf 6)"
    BOLD="$(tput bold)"
    RESET="$(tput sgr0)"
else
    OK_GREEN=""
    WARN_YELLOW=""
    ERR_RED=""
    INFO_CYAN=""
    BOLD=""
    RESET=""
fi

ok()   { printf "%s[OK]%s    %s\n" "$OK_GREEN" "$RESET" "$*"; }
info() { printf "%s[..]%s    %s\n" "$INFO_CYAN" "$RESET" "$*"; }
warn() { printf "%s[WARN]%s  %s\n" "$WARN_YELLOW" "$RESET" "$*"; }
err()  { printf "%s[ERR]%s   %s\n" "$ERR_RED" "$RESET" "$*" >&2; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

# ── Non-interactive mode flag ────────────────────────────────────────────────
INTERACTIVE=true
for arg in "$@"; do
    case "$arg" in
        --non-interactive|--yes|-y)
            INTERACTIVE=false
            ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
    esac
done

# Helper that wraps `read` so non-interactive mode can use a default fallback.
# Usage: ask <var-name> <prompt> <default>
ask() {
    local __varname="$1"
    local __prompt="$2"
    local __default="${3:-}"
    if [[ "$INTERACTIVE" != "true" ]]; then
        # In non-interactive mode, only set if the var is empty.
        if [[ -z "${!__varname:-}" ]]; then
            printf -v "$__varname" '%s' "$__default"
        fi
        return 0
    fi
    local __reply
    if [[ -n "$__default" ]]; then
        read -r -p "$__prompt [$__default]: " __reply || true
        printf -v "$__varname" '%s' "${__reply:-$__default}"
    else
        read -r -p "$__prompt: " __reply || true
        printf -v "$__varname" '%s' "$__reply"
    fi
}

# ask_yes_no <prompt> <default y|n>  --> sets REPLY_YN to "y" or "n"
ask_yes_no() {
    local __prompt="$1"
    local __default="${2:-y}"
    if [[ "$INTERACTIVE" != "true" ]]; then
        REPLY_YN="$__default"
        return 0
    fi
    local __hint="[Y/n]"
    [[ "$__default" == "n" ]] && __hint="[y/N]"
    local __reply
    read -r -p "$__prompt $__hint " __reply || true
    __reply="${__reply:-$__default}"
    case "${__reply,,}" in
        y|yes) REPLY_YN="y" ;;
        n|no)  REPLY_YN="n" ;;
        *)     REPLY_YN="$__default" ;;
    esac
}

# ask_password <var-name> <prompt> <min-length>
ask_password() {
    local __varname="$1"
    local __prompt="$2"
    local __minlen="${3:-8}"
    if [[ "$INTERACTIVE" != "true" ]]; then
        local __cur="${!__varname:-}"
        if [[ -z "$__cur" || ${#__cur} -lt "$__minlen" ]]; then
            err "Non-interactive mode: $__varname must be set in the environment (>= $__minlen chars)"
            exit 1
        fi
        return 0
    fi
    while true; do
        local __pw1 __pw2
        read -r -s -p "$__prompt: " __pw1 || true
        echo
        if [[ -z "$__pw1" ]]; then
            warn "empty input — try again"
            continue
        fi
        if [[ ${#__pw1} -lt "$__minlen" ]]; then
            warn "must be at least $__minlen characters"
            continue
        fi
        read -r -s -p "Confirm: " __pw2 || true
        echo
        if [[ "$__pw1" != "$__pw2" ]]; then
            warn "passwords do not match — try again"
            continue
        fi
        printf -v "$__varname" '%s' "$__pw1"
        return 0
    done
}

# ── 1. Pre-flight ────────────────────────────────────────────────────────────
preflight() {
    info "Pre-flight checks"

    if [[ ! -f docker-compose.yml || ! -f init.sh ]]; then
        err "deploy.sh must be run from the Mosquitto-Broker-RBPi repo root"
        err "  (expected docker-compose.yml and init.sh in $(pwd))"
        exit 1
    fi
    ok "repo layout"

    # Linux check
    if [[ "$(uname -s)" != "Linux" ]]; then
        err "this wizard only supports Linux (got $(uname -s))"
        exit 1
    fi

    # Detect distro
    DISTRO_ID="unknown"
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
    fi
    case "$DISTRO_ID" in
        ubuntu|debian)
            ok "OS: $DISTRO_ID (supported)"
            ;;
        *)
            warn "OS: $DISTRO_ID (not Ubuntu/Debian — continuing on a best-effort basis)"
            ;;
    esac

    # Root or sudo check
    SUDO=""
    if [[ $EUID -eq 0 ]]; then
        ok "running as root"
    else
        if command -v sudo >/dev/null 2>&1; then
            if sudo -v 2>/dev/null; then
                SUDO="sudo"
                ok "running with sudo privileges"
            else
                err "this user does not have sudo privileges"
                err "rerun as root or grant the user sudo access"
                exit 1
            fi
        else
            err "must be run as root (sudo not installed)"
            exit 1
        fi
    fi
    export SUDO
}

# ── 2. Banner + plan ─────────────────────────────────────────────────────────
banner() {
    hr
    printf "%s   RCS Broker Stack — One-Shot Deploy Wizard%s\n" "$BOLD" "$RESET"
    printf "   mosquitto + coturn  via  docker compose\n"
    hr
    cat <<'PLAN'

This wizard will:

  1. Run pre-flight checks (root/sudo, OS, repo layout)
  2. Install Docker + the compose plugin (if missing)
  3. Detect and optionally remove a previous native mosquitto/coturn install
  4. Build .env interactively (or reuse/edit an existing one)
  5. Run init.sh to generate certs, configs, ACL, passwd, turnserver.conf
  6. docker compose pull && docker compose up -d
  7. Wait until both services report (healthy)
  8. Configure UFW firewall rules (optional)
  9. Run test.sh smoke test
 10. Print credentials, URLs, and next steps

PLAN
    ask_yes_no "Proceed?" "y"
    if [[ "$REPLY_YN" != "y" ]]; then
        info "aborted by user"
        exit 0
    fi
}

# ── 3. Docker install ────────────────────────────────────────────────────────
install_docker() {
    hr
    info "Step 3 — Docker engine + compose plugin"

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        local ver
        ver="$(docker --version 2>/dev/null || echo unknown)"
        ok "Docker already installed: $ver"
    else
        warn "Docker or the compose plugin is missing"
        if [[ "$INTERACTIVE" == "true" ]]; then
            ask_yes_no "Install Docker via get.docker.com?" "y"
        else
            REPLY_YN="${INSTALL_DOCKER:-y}"
        fi
        if [[ "$REPLY_YN" != "y" ]]; then
            err "Docker is required — cannot continue"
            exit 1
        fi

        info "downloading and running get.docker.com installer..."
        if ! curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
            err "failed to download get.docker.com"
            exit 1
        fi
        $SUDO sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh

        if ! command -v docker >/dev/null 2>&1; then
            err "docker installation failed"
            exit 1
        fi
        ok "docker installed: $(docker --version)"
    fi

    # Make sure the daemon is enabled and running
    if command -v systemctl >/dev/null 2>&1; then
        $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
        if $SUDO systemctl is-active docker >/dev/null 2>&1; then
            ok "docker daemon is active"
        else
            err "docker daemon is not active — check 'systemctl status docker'"
            exit 1
        fi
    fi

    # Offer to add the invoking user to the docker group (only if not root)
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        if ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw docker; then
            ask_yes_no "Add user '$SUDO_USER' to the 'docker' group?" "y"
            if [[ "$REPLY_YN" == "y" ]]; then
                $SUDO usermod -aG docker "$SUDO_USER"
                warn "$SUDO_USER added to docker group — log out and back in for it to take effect"
            fi
        fi
    fi

    # Install host mosquitto-clients so test.sh (step 8) can run the TLS
    # pub/sub round-trip natively on the host instead of falling back to
    # `docker compose exec mosquitto ...`. The exec-fallback path has a
    # latent signal-propagation bug (timeout-killed exec processes can
    # linger inside the container and the host-side `wait` hangs), which
    # manifests as a frozen smoke test. mosquitto-clients is ~200 KB and
    # ships in the default Ubuntu/Debian repos.
    if ! command -v mosquitto_pub >/dev/null 2>&1 || ! command -v mosquitto_sub >/dev/null 2>&1; then
        info "installing host mosquitto-clients (for test.sh smoke test)..."
        if command -v apt-get >/dev/null 2>&1; then
            $SUDO apt-get update -qq >/dev/null 2>&1 || true
            if $SUDO apt-get install -y -qq mosquitto-clients >/dev/null 2>&1; then
                ok "mosquitto-clients installed"
            else
                warn "apt install mosquitto-clients failed — test.sh will fall back to docker exec"
            fi
        else
            warn "no apt-get on this system — test.sh will fall back to docker exec"
        fi
    else
        ok "mosquitto-clients already installed: $(mosquitto_pub --help 2>&1 | head -n1 | awk '{print $2" "$3}')"
    fi
}

# ── 4. Legacy native-install cleanup ─────────────────────────────────────────
# Replaces the deleted uninstall.sh from the pre-Docker era — detects a native
# mosquitto/coturn install and offers to purge it so host ports 8883/3478 are free.
cleanup_legacy() {
    hr
    info "Step 4 — Legacy native-install detection"

    local found=()
    if dpkg -l mosquitto 2>/dev/null | grep -q '^ii'; then
        found+=("apt package: mosquitto")
    fi
    if dpkg -l coturn 2>/dev/null | grep -q '^ii'; then
        found+=("apt package: coturn")
    fi
    if systemctl list-unit-files mosquitto.service 2>/dev/null | grep -q mosquitto; then
        found+=("systemd unit: mosquitto.service")
    fi
    if systemctl list-unit-files coturn.service 2>/dev/null | grep -q coturn; then
        found+=("systemd unit: coturn.service")
    fi
    if [[ -d /etc/mosquitto ]]; then
        found+=("config dir: /etc/mosquitto")
    fi
    if [[ -f /etc/turnserver.conf ]]; then
        found+=("config file: /etc/turnserver.conf")
    fi

    if (( ${#found[@]} == 0 )); then
        ok "no previous native install detected"
        return 0
    fi

    warn "previous native install detected:"
    for f in "${found[@]}"; do
        printf "       - %s\n" "$f"
    done

    if [[ "$INTERACTIVE" == "true" ]]; then
        ask_yes_no "Clean it up before continuing?" "y"
    else
        REPLY_YN="${CLEANUP_LEGACY:-y}"
    fi

    if [[ "$REPLY_YN" != "y" ]]; then
        warn "skipping cleanup — port conflicts on :8883 / :3478 are likely"
        return 0
    fi

    info "stopping services..."
    $SUDO systemctl stop mosquitto coturn 2>/dev/null || true
    $SUDO systemctl disable mosquitto coturn 2>/dev/null || true

    info "purging packages..."
    $SUDO apt-get remove -y --purge mosquitto coturn 2>/dev/null || true

    info "removing config / log dirs..."
    $SUDO rm -rf /etc/mosquitto /etc/turnserver.conf /var/log/coturn
    $SUDO rm -f /etc/systemd/system/mosquitto.service /etc/systemd/system/coturn.service
    $SUDO systemctl daemon-reload 2>/dev/null || true

    ok "legacy install cleaned up"
}

# ── 5. Build .env ────────────────────────────────────────────────────────────
detect_external_ip() {
    local ip=""
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    fi
    if [[ -z "$ip" ]]; then
        ip="$(curl -fsS --max-time 5 https://icanhazip.com 2>/dev/null || true)"
    fi
    # Strip whitespace
    ip="${ip//[[:space:]]/}"
    printf '%s' "$ip"
}

is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.
    # shellcheck disable=SC2206
    local parts=($ip)
    for p in "${parts[@]}"; do
        (( p >= 0 && p <= 255 )) || return 1
    done
    return 0
}

write_env_file() {
    cat > .env <<ENVFILE
# ── REQUIRED ─────────────────────────────────────────────────────────────────

# External IP of this VPS. Used as the STUN/TURN external-ip and as the
# self-signed TLS certificate SAN.
VPS_EXTERNAL_IP=${VPS_EXTERNAL_IP}

# MQTT user passwords. Choose strong values and never commit the .env file.
RCS_OPERATOR_PASSWORD=${RCS_OPERATOR_PASSWORD}
UGV_CLIENT_PASSWORD=${UGV_CLIENT_PASSWORD}

# ── OPTIONAL (sensible defaults) ─────────────────────────────────────────────

# TLS mode: "self-signed" (default) or "letsencrypt" (not yet implemented).
TLS_MODE=${TLS_MODE:-self-signed}

# Hostname / CN for the self-signed certificate. Leave blank to use
# VPS_EXTERNAL_IP. Set this only if you have a DNS name pointing here.
MQTT_HOSTNAME=${MQTT_HOSTNAME:-}

# TURN credentials. Change these in production.
TURN_USERNAME=${TURN_USERNAME}
TURN_PASSWORD=${TURN_PASSWORD}
TURN_REALM=${TURN_REALM:-}

# Healthcheck user (used by docker healthcheck — separate from the two
# real users so a broken healthcheck can't lock out the operator).
HEALTH_USER=${HEALTH_USER:-health}
HEALTH_PASSWORD=${HEALTH_PASSWORD:-}
ENVFILE
    chmod 600 .env
}

build_env() {
    hr
    info "Step 5 — Build .env"

    if [[ -f .env ]]; then
        warn ".env already exists"
        local choice="r"
        if [[ "$INTERACTIVE" == "true" ]]; then
            read -r -p "  [R]euse / [E]dit values / [O]verwrite [R/e/o]: " choice || true
            choice="${choice:-r}"
        fi
        case "${choice,,}" in
            r|reuse|"")
                info "reusing existing .env"
                set -a
                # shellcheck disable=SC1091
                source .env
                set +a
                # Sanity-check required vars
                if [[ -z "${VPS_EXTERNAL_IP:-}" || -z "${RCS_OPERATOR_PASSWORD:-}" || -z "${UGV_CLIENT_PASSWORD:-}" ]]; then
                    err "existing .env is missing required values — choose [E]dit or [O]verwrite"
                    exit 1
                fi
                chmod 600 .env
                ok ".env reused"
                return 0
                ;;
            e|edit)
                info "editing existing values"
                set -a
                # shellcheck disable=SC1091
                source .env
                set +a
                ;;
            o|overwrite)
                info "overwriting .env"
                rm -f .env
                ;;
        esac
    fi

    # Fresh build (or edit path)
    if [[ ! -f .env && -f .env.example ]]; then
        cp .env.example .env
        chmod 600 .env
    fi

    # VPS_EXTERNAL_IP
    local detected_ip
    detected_ip="$(detect_external_ip)"
    local default_ip="${VPS_EXTERNAL_IP:-$detected_ip}"
    if [[ -n "$detected_ip" && -z "${VPS_EXTERNAL_IP:-}" ]]; then
        info "auto-detected external IP: $detected_ip"
    fi
    while true; do
        if [[ -n "$default_ip" ]]; then
            ask VPS_EXTERNAL_IP "VPS external IP" "$default_ip"
        else
            ask VPS_EXTERNAL_IP "VPS external IP (could not auto-detect)" ""
        fi
        if is_valid_ipv4 "$VPS_EXTERNAL_IP"; then
            break
        fi
        warn "'$VPS_EXTERNAL_IP' is not a valid IPv4 address"
        if [[ "$INTERACTIVE" != "true" ]]; then
            err "non-interactive mode and VPS_EXTERNAL_IP is invalid — aborting"
            exit 1
        fi
        default_ip=""
    done

    # RCS_OPERATOR_PASSWORD
    if [[ "$INTERACTIVE" == "true" ]]; then
        echo
        info "RCS operator password (>= 8 chars)"
        ask_password RCS_OPERATOR_PASSWORD "RCS_OPERATOR_PASSWORD" 8
    else
        ask_password RCS_OPERATOR_PASSWORD "" 8
    fi

    # UGV_CLIENT_PASSWORD (must differ from RCS)
    while true; do
        if [[ "$INTERACTIVE" == "true" ]]; then
            info "UGV client password (>= 8 chars, must differ from RCS)"
            ask_password UGV_CLIENT_PASSWORD "UGV_CLIENT_PASSWORD" 8
        else
            ask_password UGV_CLIENT_PASSWORD "" 8
        fi
        if [[ "$UGV_CLIENT_PASSWORD" == "$RCS_OPERATOR_PASSWORD" ]]; then
            warn "UGV client password must differ from RCS operator password"
            if [[ "$INTERACTIVE" != "true" ]]; then
                err "non-interactive mode and passwords are identical — aborting"
                exit 1
            fi
            continue
        fi
        break
    done

    # TURN_USERNAME
    ask TURN_USERNAME "TURN username" "${TURN_USERNAME:-ugv}"

    # TURN_PASSWORD — auto-generate if empty / placeholder
    local generated_turn=""
    if [[ -z "${TURN_PASSWORD:-}" || "${TURN_PASSWORD:-}" == "ugvturn2026" ]]; then
        generated_turn="$(openssl rand -base64 24 2>/dev/null | tr -d '=+/' | cut -c1-24)"
    fi
    if [[ -n "$generated_turn" ]]; then
        if [[ "$INTERACTIVE" == "true" ]]; then
            echo
            info "auto-generated strong TURN password: $generated_turn"
            ask TURN_PASSWORD "TURN password (Enter to keep generated)" "$generated_turn"
        else
            TURN_PASSWORD="${TURN_PASSWORD:-$generated_turn}"
        fi
    else
        ask TURN_PASSWORD "TURN password" "${TURN_PASSWORD}"
    fi

    # Leave TLS_MODE / MQTT_HOSTNAME / TURN_REALM at defaults unless --advanced
    : "${TLS_MODE:=self-signed}"
    : "${MQTT_HOSTNAME:=}"
    : "${TURN_REALM:=}"

    write_env_file
    ok ".env written (chmod 600)"
}

# ── 6. Bootstrap + start ─────────────────────────────────────────────────────
wait_for_healthy() {
    local timeout="${1:-60}"
    local elapsed=0
    info "waiting up to ${timeout}s for both services to become healthy"
    while (( elapsed < timeout )); do
        local m_status c_status
        m_status="$(docker inspect --format '{{.State.Health.Status}}' rcs-mosquitto 2>/dev/null || echo missing)"
        c_status="$(docker inspect --format '{{.State.Health.Status}}' rcs-coturn 2>/dev/null || echo missing)"
        if [[ "$m_status" == "healthy" && "$c_status" == "healthy" ]]; then
            echo
            ok "mosquitto: $m_status"
            ok "coturn:    $c_status"
            return 0
        fi
        printf '.'
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo
    err "services failed to become healthy within ${timeout}s"
    err "current state:"
    err "  mosquitto: $(docker inspect --format '{{.State.Health.Status}}' rcs-mosquitto 2>/dev/null || echo missing)"
    err "  coturn:    $(docker inspect --format '{{.State.Health.Status}}' rcs-coturn    2>/dev/null || echo missing)"
    err "inspect logs: docker compose logs mosquitto coturn"
    return 1
}

bootstrap_and_start() {
    hr
    info "Step 6 — Bootstrap + start"

    info "running init.sh..."
    if ! bash init.sh; then
        err "init.sh failed"
        exit 1
    fi
    ok "init.sh finished"

    info "docker compose pull..."
    if ! $SUDO docker compose pull; then
        warn "compose pull failed — continuing with local images if any"
    fi

    info "docker compose up -d..."
    if ! $SUDO docker compose up -d; then
        err "docker compose up failed"
        exit 1
    fi
    ok "containers started"

    if ! wait_for_healthy 60; then
        exit 1
    fi
}

# ── 7. Firewall ──────────────────────────────────────────────────────────────
configure_ufw() {
    hr
    info "Step 7 — Firewall (UFW)"

    if ! command -v ufw >/dev/null 2>&1; then
        warn "ufw is not installed — skipping (open the ports manually if needed)"
        return 0
    fi

    if [[ "$INTERACTIVE" == "true" ]]; then
        ask_yes_no "Configure UFW firewall rules now?" "y"
    else
        REPLY_YN="${CONFIGURE_UFW:-y}"
    fi

    if [[ "$REPLY_YN" != "y" ]]; then
        warn "UFW not configured — open these ports manually:"
        cat <<'RULES'

  sudo ufw allow 22/tcp
  sudo ufw allow 8883/tcp
  sudo ufw allow 3478/udp
  sudo ufw allow 3478/tcp
  sudo ufw allow 49152:65535/udp
  sudo ufw deny 1883/tcp
  sudo ufw --force enable

RULES
        return 0
    fi

    info "applying rules..."
    $SUDO ufw allow 22/tcp           >/dev/null || true
    $SUDO ufw allow 8883/tcp         >/dev/null || true
    $SUDO ufw allow 3478/udp         >/dev/null || true
    $SUDO ufw allow 3478/tcp         >/dev/null || true
    $SUDO ufw allow 49152:65535/udp  >/dev/null || true
    $SUDO ufw deny  1883/tcp         >/dev/null || true
    $SUDO ufw --force enable         >/dev/null || true
    ok "UFW rules applied"
    echo
    $SUDO ufw status verbose || true
}

# ── 8. Smoke test ────────────────────────────────────────────────────────────
run_smoke_test() {
    hr
    info "Step 8 — Smoke test (test.sh)"
    if bash test.sh; then
        ok "smoke test passed"
    else
        warn "smoke test reported failures — the stack is up but inspect the output above"
    fi
}

# ── 9. Summary ───────────────────────────────────────────────────────────────
print_summary() {
    hr
    printf "%s%s   DEPLOYMENT COMPLETE%s\n" "$BOLD" "$OK_GREEN" "$RESET"
    hr

    # Re-source .env so HEALTH_PASSWORD (added by init.sh) is available
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a

    cat <<SUMMARY

  ${BOLD}VPS external IP${RESET}     ${VPS_EXTERNAL_IP}
  ${BOLD}MQTT broker${RESET}         ${VPS_EXTERNAL_IP}:8883  (TLS, mqtts://)
  ${BOLD}STUN server${RESET}         stun:${VPS_EXTERNAL_IP}:3478
  ${BOLD}TURN server${RESET}         turn:${VPS_EXTERNAL_IP}:3478

  ${BOLD}MQTT users${RESET}          rcs_operator   (password in .env: RCS_OPERATOR_PASSWORD)
                      ugv_client     (password in .env: UGV_CLIENT_PASSWORD)

  ${BOLD}TURN credentials${RESET}    username: ${TURN_USERNAME}
                      password: ${TURN_PASSWORD}

  ${BOLD}CA certificate${RESET}      ${SCRIPT_DIR}/data/certs/ca.crt

  ${BOLD}Copy CA cert to your operator PC${RESET}
    From your local PC, run:
      scp root@${VPS_EXTERNAL_IP}:${SCRIPT_DIR}/data/certs/ca.crt ~/ca.crt

  ${BOLD}Next steps${RESET}
    1. Copy data/certs/ca.crt to the operator PC and the Raspberry Pi
    2. Configure RCS-Software config/config.yaml (mqtt.host, password, ca_certs)
    3. Configure RBPi_UGV   config/config.yaml (mqtt.host, password, ca_certs, camera.*)

  ${BOLD}Operations quick reference${RESET}
    docker compose ps                    # status + health
    docker compose logs -f mosquitto     # tail mosquitto logs
    docker compose logs -f coturn        # tail coturn logs
    docker compose restart mosquitto     # apply config changes
    docker compose down                  # stop the stack
    bash test.sh                         # rerun smoke test

SUMMARY
    hr
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    preflight
    banner
    install_docker
    cleanup_legacy
    build_env
    bootstrap_and_start
    configure_ufw
    run_smoke_test
    print_summary
}

main "$@"
