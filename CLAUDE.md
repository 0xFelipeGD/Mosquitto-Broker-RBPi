# Mosquitto-Broker-RBPi — MQTT Broker

## Overview

Automated setup for Eclipse Mosquitto 2.0+ MQTT broker on a VPS Ubuntu server. Provides TLS-encrypted, password-authenticated message routing between the RCS (operator PC) and UGV (Raspberry Pi).

## Architecture

- **Mosquitto 2.0+** installed from official PPA (not Docker)
- **TLS only** on port 8883 (port 1883 blocked by firewall)
- **Password auth** via `mosquitto_passwd` (2 users)
- **Optional ACL** for per-topic access control
- **UFW firewall** configured automatically
- **Systemd** managed (`systemctl start/stop/restart mosquitto`)

## MQTT Interface

**Always check `../INTERFACE_CONTRACT.md` for the authoritative topic list.**

| Topic | rcs_operator | ugv_client |
|-------|-------------|------------|
| `ugv/joystick` | write | read |
| `ugv/heartbeat` | write | read |
| `ugv/ping` | write | read |
| `ugv/telemetry` | read | write |
| `ugv/pong` | read | write |
| `ugv/camera/cmd` | write | read |
| `ugv/camera/offer` | read | write |
| `ugv/camera/answer` | write | read |
| `ugv/camera/ice/ugv` | read | write |
| `ugv/camera/ice/rcs` | write | read |
| `ugv/camera/status` | read | write |
| `$SYS/#` | read | read |

## Key Files

| File | Purpose |
|------|---------|
| `setup.sh` | Full automated installer (Mosquitto, TLS, users, ACL, firewall) |
| `setup_coturn.sh` | Coturn STUN server installer (WebRTC NAT traversal) |
| `test.sh` | Connectivity and pub/sub validation |
| `uninstall.sh` | Clean removal |
| `prompts/VPS_BROKER_SETUP.md` | Detailed implementation guide |

## TLS Modes

1. **Let's Encrypt** — Automated via Certbot with renewal hook
2. **Self-Signed** — OpenSSL CA + server cert (10-year validity)

## Key Paths on VPS

| Path | Content |
|------|---------|
| `/etc/mosquitto/conf.d/rcs.conf` | Main Mosquitto config |
| `/etc/mosquitto/passwd` | Hashed password file |
| `/etc/mosquitto/acl` | Topic ACL rules (optional) |
| `/etc/mosquitto/certs/` | TLS certificates |
| `/etc/mosquitto/.credentials` | Plaintext credentials backup (chmod 600) |

## Configuration Limits

- `max_connections`: 10
- `message_size_limit`: 4096 bytes
- `max_inflight_messages`: 20
- `max_queued_messages`: 100

## Running

```bash
sudo bash setup.sh         # Interactive Mosquitto installer on VPS
sudo bash setup_coturn.sh  # Interactive coturn STUN server installer
bash test.sh               # Test connectivity (includes coturn check)
sudo bash uninstall.sh     # Clean removal
```
