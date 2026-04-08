# Mosquitto MQTT Broker + Coturn — Dockerized VPS Stack

Containerized deployment of the RCS <-> UGV message broker. Runs two services via `docker compose`:

- **mosquitto** — Eclipse Mosquitto 2 with TLS 1.2+ on port 8883
- **coturn** — STUN + TURN relay on port 3478 for WebRTC video NAT traversal

All runtime state (certs, password file, ACLs, persistence, logs) lives under `./data/` and is produced by `init.sh` from a single `.env` file.

## Quick deploy (recommended)

On a fresh Ubuntu/Debian VPS, three commands take you from "nothing installed" to "two healthy containers + firewall rules in place":

```bash
ssh root@<VPS_IP>
git clone -b feature/broker-docker https://github.com/0xFelipeGD/Mosquitto-Broker-RBPi.git
cd Mosquitto-Broker-RBPi
bash deploy.sh
```

`deploy.sh` is an interactive wizard that:

- Installs Docker + the compose plugin (if missing)
- Detects and offers to remove any prior native mosquitto/coturn install
- Builds `.env` interactively (auto-detects the public IP, generates a strong TURN password)
- Runs `init.sh` to generate certs, configs, ACL, passwd
- Brings the stack up with `docker compose up -d` and waits until both containers report `healthy`
- Configures UFW firewall rules
- Runs `test.sh` to validate end-to-end TLS pub/sub
- Prints credentials, URLs, and the next steps

For non-interactive use (CI/CD), run `bash deploy.sh --non-interactive` with `VPS_EXTERNAL_IP`, `RCS_OPERATOR_PASSWORD`, and `UGV_CLIENT_PASSWORD` set in the environment.

The manual flow below remains supported for advanced users who want to control each step.

## Requirements

- Docker 20.10+ with the `compose` plugin (`docker compose version`)
- `openssl` (used by `init.sh` to generate self-signed certs)
- Outbound internet access to pull the two images on first run

## Manual deploy (advanced)

```bash
git clone https://github.com/0xFelipeGD/Mosquitto-Broker-RBPi.git
cd Mosquitto-Broker-RBPi
cp .env.example .env
nano .env                      # fill in VPS_EXTERNAL_IP + the two passwords
bash init.sh                   # generate certs, configs, passwd, acl
docker compose up -d
docker compose ps              # both services should show "running (healthy)"
bash test.sh                   # pub/sub round trip + coturn check
```

Copy `data/certs/ca.crt` to each client (RCS PC and UGV Pi):

```bash
# From your local workstation (not inside the VPS):
scp root@YOUR_VPS_IP:/path/to/Mosquitto-Broker-RBPi/data/certs/ca.crt .
```

## UFW rules required on the VPS

The stack does not touch the host firewall. Open these ports yourself:

```bash
sudo ufw allow 22/tcp                  # ssh (don't lock yourself out)
sudo ufw allow 8883/tcp                # MQTT over TLS
sudo ufw deny 1883/tcp                 # plaintext MQTT — always blocked
sudo ufw allow 3478/udp                # STUN/TURN
sudo ufw allow 3478/tcp                # STUN/TURN (TCP fallback)
sudo ufw allow 49152:65535/udp         # TURN relay range
sudo ufw enable
```

## Operations

```bash
docker compose ps                      # status + health
docker compose logs -f mosquitto       # live mosquitto logs
docker compose logs -f coturn          # live coturn logs
docker compose restart mosquitto       # restart after config edit
docker compose down                    # stop the stack
docker compose up -d                   # bring it back up
```

### Rotating MQTT passwords

1. Edit `.env` (change `RCS_OPERATOR_PASSWORD` / `UGV_CLIENT_PASSWORD`)
2. `bash init.sh` — regenerates `data/mosquitto/config/passwd`
3. `docker compose restart mosquitto`

### Updating

```bash
git pull
docker compose pull
docker compose up -d
```

## Troubleshooting

### mosquitto healthcheck is failing

- Inspect: `docker compose logs mosquitto`
- Common causes: wrong `VPS_EXTERNAL_IP` in `.env` (cert SAN mismatch), missing `HEALTH_PASSWORD`, stale `data/mosquitto/config/passwd`
- Fix: edit `.env`, re-run `bash init.sh`, then `docker compose restart mosquitto`

### coturn healthcheck is failing

- Inspect: `docker compose logs coturn`
- Check UFW: `sudo ufw status | grep 3478`
- Coturn runs with `network_mode: host` — this is intentional so the relay port range works. If port 3478 is already in use on the host, nothing will start.

### TLS certificate expired / needs regeneration

```bash
rm data/certs/ca.crt data/certs/server.crt data/certs/server.key
bash init.sh
docker compose restart mosquitto
```

Then redistribute `data/certs/ca.crt` to each client.

### Port conflict on 8883, 3478, or 49152-65535

Another service is already bound. Stop it or edit the host ports. For 8883 change the `ports:` mapping in `docker-compose.yml`; for coturn you must stop the host-side conflicting process (coturn uses `network_mode: host`).

### I need to start from scratch

```bash
docker compose down
rm -rf data/
bash init.sh
docker compose up -d
```

This nukes certs, persistence, and logs. `.env` is preserved.

## Files

| Path | Purpose |
|------|---------|
| `deploy.sh` | One-shot wizard: Docker install, .env build, init, up, UFW, smoke test |
| `docker-compose.yml` | Two-service stack (mosquitto + coturn) with healthchecks |
| `.env.example` | Template for secrets and settings |
| `init.sh` | Bootstrap: populates `data/` from `.env` |
| `test.sh` | Docker-aware smoke test |
| `data/` | Generated at runtime (gitignored — contains secrets) |

## MQTT interface contract

See `../INTERFACE_CONTRACT.md` for the authoritative topic list, payload schemas, and ACL matrix. Any change to topics or permissions must be made there first, then propagated into `init.sh`'s ACL generator.
