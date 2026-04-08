# Mosquitto-Broker-RBPi — MQTT Broker (Dockerized)

## Overview

Containerized deployment of Eclipse Mosquitto 2.0+ MQTT broker and Coturn STUN/TURN relay for the RCS <-> UGV system. Runs on a VPS Ubuntu server via `docker compose`.

## Architecture

- **docker compose** two-service stack: `mosquitto` + `coturn`
- **Eclipse Mosquitto 2** (official `eclipse-mosquitto:2` image) on bridge network, port 8883 exposed
- **Coturn** (official `coturn/coturn:latest` image) with `network_mode: host` — required for TURN relay port range
- **TLS only** on port 8883 (plaintext 1883 is never bound)
- **Password auth** via `mosquitto_passwd` run inside the image itself (no host install)
- **ACL** for per-topic access control (always on — matches INTERFACE_CONTRACT.md)
- **Self-signed TLS** by default (Let's Encrypt is planned as a future sidecar)
- **Healthchecks** for both services so `docker compose ps` shows real status
- **UFW firewall** is the operator's responsibility (documented in README.md)

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

A third user, `health` (default), has read-only access to `$SYS/broker/uptime` and exists only to back the mosquitto container healthcheck.

## Key Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Two-service stack with healthchecks and restart policies |
| `.env.example` | Template for all secrets and runtime settings |
| `init.sh` | Bootstrap: reads `.env`, produces everything under `data/` |
| `test.sh` | Docker-aware smoke test (compose ps + TLS pub/sub + coturn UDP check) |
| `uninstall.sh` | Legacy cleanup for pre-Docker installs |
| `prompts/VPS_BROKER_SETUP.md` | Original manual implementation guide (historical) |

## Generated paths (on the VPS, inside `./data/`)

| Path | Content |
|------|---------|
| `data/certs/ca.crt, server.crt, server.key` | Self-signed TLS material |
| `data/mosquitto/config/mosquitto.conf` | Top-level include_dir shim |
| `data/mosquitto/config/conf.d/rcs.conf` | Listener, TLS, auth, ACL, tuning |
| `data/mosquitto/config/passwd` | Hashed MQTT passwords |
| `data/mosquitto/config/acl` | Topic ACL rules |
| `data/mosquitto/data/` | Persistence |
| `data/mosquitto/log/` | Broker logs |
| `data/coturn/turnserver.conf` | Coturn config |
| `data/coturn/log/turnserver.log` | Coturn logs |

`data/` and `.env` are both in `.gitignore` — nothing in them should ever be committed.

## Configuration Limits

- `max_connections`: 10
- `message_size_limit`: 4096 bytes
- `max_inflight_messages`: 20
- `max_queued_messages`: 100

## Running

```bash
cp .env.example .env                # one-time
nano .env                           # fill in VPS_EXTERNAL_IP + passwords
bash init.sh                        # populate data/
docker compose up -d                # start both services
docker compose ps                   # should show "running (healthy)"
bash test.sh                        # pub/sub round trip + coturn check
docker compose logs -f mosquitto    # live logs
docker compose restart mosquitto    # after editing .env + rerunning init.sh
docker compose down                 # stop
```

Password rotation: edit `.env`, `bash init.sh`, `docker compose restart mosquitto`.
