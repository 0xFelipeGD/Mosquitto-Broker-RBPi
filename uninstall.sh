#!/usr/bin/env bash
# ============================================================
# Mosquitto Broker — Uninstall Script
# Removes Mosquitto and all configuration created by setup.sh
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root: sudo ./uninstall.sh${NC}"
    exit 1
fi

echo -e "\n${BOLD}Mosquitto Broker — Uninstall${NC}\n"
echo -e "${YELLOW}This will remove:${NC}"
echo "  - Mosquitto service and packages"
echo "  - Configuration files (/etc/mosquitto/)"
echo "  - TLS certificates (/etc/mosquitto/certs/)"
echo "  - Password and ACL files"
echo "  - UFW rules for MQTT ports"
echo ""

read -rp "$(echo -e "${RED}Are you sure? (type YES to confirm): ${NC}")" confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# Stop service
echo -e "${CYAN}Stopping Mosquitto...${NC}"
systemctl stop mosquitto 2>/dev/null || true
systemctl disable mosquitto 2>/dev/null || true

# Remove packages
echo -e "${CYAN}Removing packages...${NC}"
apt-get purge -y mosquitto mosquitto-clients 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Remove config and certs
echo -e "${CYAN}Removing configuration and certificates...${NC}"
rm -rf /etc/mosquitto/conf.d/rcs.conf
rm -rf /etc/mosquitto/conf.d/default.conf
rm -rf /etc/mosquitto/certs/
rm -f /etc/mosquitto/passwd
rm -f /etc/mosquitto/acl
rm -f /etc/mosquitto/.credentials

# Remove persistence data
rm -rf /var/lib/mosquitto/

# Remove UFW rules
if command -v ufw &>/dev/null; then
    echo -e "${CYAN}Removing UFW rules...${NC}"
    ufw delete allow 8883/tcp 2>/dev/null || true
    ufw delete deny 1883/tcp 2>/dev/null || true
fi

# Remove certbot renewal hook (if exists)
rm -f /etc/letsencrypt/renewal-hooks/deploy/mosquitto.sh 2>/dev/null || true

echo -e "\n${GREEN}${BOLD}Uninstall complete.${NC}"
echo -e "Note: Let's Encrypt certificates (if any) were NOT removed."
echo -e "Remove them manually: ${CYAN}sudo certbot delete --cert-name <domain>${NC}\n"
