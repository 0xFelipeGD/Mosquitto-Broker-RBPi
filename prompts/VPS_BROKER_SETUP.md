# Phase 2 — VPS Mosquitto MQTT Broker Setup

> **Purpose**: This document gives an AI (or engineer) all the context needed to deploy and configure the MQTT broker on a VPS. After completing this guide, the RCS (Phase 1) and the Raspberry Pi (Phase 3) will be able to communicate securely.

---

## 1. PROJECT CONTEXT

### What already exists (Phase 1 — DONE)

A **Remote Control Station (RCS)** application runs on a Linux PC. It:

1. Reads a Thrustmaster HOTAS Warthog joystick via `evdev`
2. Publishes joystick commands over **MQTT** at 30-50 Hz
3. Subscribes to telemetry from a UGV (Unmanned Ground Vehicle)
4. Displays everything in a PySide6 GUI

The RCS uses `paho-mqtt` (Python) to connect to an external MQTT broker. That broker is what you are setting up now.

### What comes next (Phase 3 — NOT your scope)

A Raspberry Pi on the UGV will subscribe to joystick commands and publish telemetry back. It connects to the same broker you're setting up.

### Your scope (Phase 2 — THIS TASK)

Deploy **Eclipse Mosquitto** on a VPS with:
- TLS encryption (Let's Encrypt)
- Username/password authentication
- Hardened configuration (no anonymous access, no open ports)
- Firewall rules
- Systemd service management
- A test script to verify everything works

---

## 2. ARCHITECTURE

```
[RCS - Linux PC]                       [Raspberry Pi - UGV]
  paho-mqtt client                       paho-mqtt client
       |                                      |
       |  TLS (port 8883)                     |  TLS (port 8883)
       +------------>  [VPS - Mosquitto]  <---+
                        (this task)
                        
  Publishes:                              Subscribes:
    ugv/joystick  (50 Hz, QoS 0)           ugv/joystick
    ugv/heartbeat (1 Hz, QoS 0)            ugv/heartbeat
    ugv/ping      (0.5 Hz, QoS 0)          ugv/ping
                                          
  Subscribes:                             Publishes:
    ugv/telemetry (QoS 1)                  ugv/telemetry (2 Hz, QoS 1)
    ugv/pong      (QoS 0)                  ugv/pong      (QoS 0)
```

---

## 3. MQTT TOPIC CONTRACT

These topics are fixed. The RCS and Raspberry Pi both depend on these exact names.

| Topic            | Direction        | Rate    | QoS | Payload Format         |
|------------------|------------------|---------|-----|------------------------|
| `ugv/joystick`   | RCS -> Pi        | 50 Hz   | 0   | Compact JSON (below)   |
| `ugv/heartbeat`  | RCS -> Pi        | 1 Hz    | 0   | `{"t": epoch_ms}`      |
| `ugv/ping`       | RCS -> Pi        | 0.5 Hz  | 0   | `{"t": epoch_ms, "seq": int}` |
| `ugv/telemetry`  | Pi -> RCS        | ~2 Hz   | 1   | Telemetry JSON (below) |
| `ugv/pong`       | Pi -> RCS        | On-demand | 0 | `{"t": epoch_ms, "seq": int}` |

### Joystick payload (`ugv/joystick`)

```json
{
  "t": 1712000000000,
  "sa": {"0": 0.1234, "1": -0.5678},
  "ta": {"2": 0.75, "5": 0.50},
  "sb": {"288": true},
  "tb": {},
  "sh": {"H1": [0, -1]},
  "th": {}
}
```

Key abbreviations:
- `t` = epoch milliseconds (int)
- `sa` = stick axes (evdev code as string -> normalized float, 4 decimals)
- `ta` = throttle axes
- `sb` = stick buttons (only pressed ones included, unpressed omitted)
- `tb` = throttle buttons
- `sh` = stick hats (key -> [x, y] where -1/0/+1)
- `th` = throttle hats

### Telemetry payload (`ugv/telemetry`)

```json
{
  "speed": 3.5,
  "bat_v": 24.1,
  "bat_pct": 78,
  "temp_l": 42.3,
  "temp_r": 41.8,
  "rssi": -67,
  "lat": -23.5505,
  "lon": -46.6333
}
```

All fields optional (defaults to 0). Extra fields are passed through.

---

## 4. VPS REQUIREMENTS

| Requirement     | Minimum              | Recommended           |
|-----------------|----------------------|-----------------------|
| OS              | Ubuntu 22.04 LTS     | Ubuntu 24.04 LTS      |
| RAM             | 512 MB               | 1 GB                  |
| CPU             | 1 vCPU               | 1 vCPU                |
| Disk            | 10 GB                | 20 GB                 |
| Network         | Public IPv4           | Public IPv4            |
| Domain          | Optional (for Let's Encrypt) | Recommended   |
| Ports open      | 8883 (MQTTS)         | 8883                  |

Mosquitto is extremely lightweight. The cheapest VPS tier from any provider works.

---

## 5. IMPLEMENTATION CHECKLIST

### 5.1 Install Mosquitto

- [ ] Install Mosquitto from the official PPA (not distro repo — it's usually outdated):

```bash
sudo apt-add-repository ppa:mosquitto-dev/mosquitto-ppa -y
sudo apt-get update
sudo apt-get install -y mosquitto mosquitto-clients
sudo systemctl enable mosquitto
```

- [ ] Verify version is 2.0+:

```bash
mosquitto -h 2>&1 | head -1
```

### 5.2 Create MQTT Users

- [ ] Create a password file with two users:

```bash
# RCS operator (the Linux PC)
sudo mosquitto_passwd -c /etc/mosquitto/passwd rcs_operator

# UGV client (the Raspberry Pi)
sudo mosquitto_passwd /etc/mosquitto/passwd ugv_client
```

- [ ] Choose strong passwords. These go into `config.yaml` on each device.

### 5.3 TLS with Let's Encrypt

> If you have a domain pointing to the VPS (recommended):

- [ ] Install Certbot:

```bash
sudo apt-get install -y certbot
```

- [ ] Get certificate (replace `mqtt.yourdomain.com`):

```bash
sudo certbot certonly --standalone -d mqtt.yourdomain.com
```

- [ ] Note the paths (typically):
  - Certificate: `/etc/letsencrypt/live/mqtt.yourdomain.com/fullchain.pem`
  - Key: `/etc/letsencrypt/live/mqtt.yourdomain.com/privkey.pem`

- [ ] Set up auto-renewal + Mosquitto restart:

```bash
# /etc/letsencrypt/renewal-hooks/deploy/mosquitto.sh
#!/bin/bash
cp /etc/letsencrypt/live/mqtt.yourdomain.com/fullchain.pem /etc/mosquitto/certs/server.crt
cp /etc/letsencrypt/live/mqtt.yourdomain.com/privkey.pem /etc/mosquitto/certs/server.key
chown mosquitto:mosquitto /etc/mosquitto/certs/*
chmod 640 /etc/mosquitto/certs/*
systemctl restart mosquitto
```

```bash
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/mosquitto.sh
```

> If you do NOT have a domain (self-signed):

- [ ] Generate self-signed certs:

```bash
sudo mkdir -p /etc/mosquitto/certs
cd /etc/mosquitto/certs

# CA
openssl genrsa -out ca.key 2048
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=RCS MQTT CA"

# Server
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=$(hostname -I | awk '{print $1}')"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650

sudo chown mosquitto:mosquitto /etc/mosquitto/certs/*
sudo chmod 640 /etc/mosquitto/certs/*
```

- [ ] Copy `ca.crt` to the RCS PC and Raspberry Pi (they need it to verify the server).

### 5.4 Mosquitto Configuration

- [ ] Create `/etc/mosquitto/conf.d/rcs.conf`:

```conf
# ============================================================
# RCS MQTT Broker Configuration
# ============================================================

# ── Listener: TLS on port 8883 ──────────────────────────────
listener 8883
protocol mqtt

# ── TLS certificates ────────────────────────────────────────
# For Let's Encrypt:
cafile /etc/mosquitto/certs/server.crt
certfile /etc/mosquitto/certs/server.crt
keyfile /etc/mosquitto/certs/server.key

# For self-signed (uncomment and adjust):
# cafile /etc/mosquitto/certs/ca.crt
# certfile /etc/mosquitto/certs/server.crt
# keyfile /etc/mosquitto/certs/server.key

# TLS version (minimum 1.2)
tls_version tlsv1.2

# ── Authentication ──────────────────────────────────────────
allow_anonymous false
password_file /etc/mosquitto/passwd

# ── Access Control (optional, basic) ────────────────────────
# For fine-grained ACLs, create /etc/mosquitto/acl and uncomment:
# acl_file /etc/mosquitto/acl

# ── Performance tuning for real-time control ────────────────
# Max inflight QoS 1/2 messages per client
max_inflight_messages 20

# Max queued messages per client (when offline)
max_queued_messages 100

# Message size limit (joystick payloads are ~200 bytes)
message_size_limit 4096

# ── Logging ─────────────────────────────────────────────────
log_dest syslog
log_type error
log_type warning
log_type notice
# log_type information    # Uncomment for debugging
# log_type debug          # Very verbose, only for troubleshooting

# ── Persistence (optional) ──────────────────────────────────
persistence true
persistence_location /var/lib/mosquitto/

# ── Connection limits ───────────────────────────────────────
max_connections 10
```

- [ ] Disable the default listener (no plaintext):

```bash
echo "" | sudo tee /etc/mosquitto/conf.d/default.conf
```

- [ ] Validate config:

```bash
sudo mosquitto -c /etc/mosquitto/mosquitto.conf -t
```

### 5.5 Optional: Access Control List (ACL)

- [ ] Create `/etc/mosquitto/acl` for fine-grained topic permissions:

```
# RCS operator can publish control, subscribe to telemetry
user rcs_operator
topic write ugv/joystick
topic write ugv/heartbeat
topic write ugv/ping
topic read ugv/telemetry
topic read ugv/pong

# UGV client can subscribe to control, publish telemetry
user ugv_client
topic read ugv/joystick
topic read ugv/heartbeat
topic read ugv/ping
topic write ugv/telemetry
topic write ugv/pong
```

- [ ] Uncomment `acl_file /etc/mosquitto/acl` in `rcs.conf` if using this.

### 5.6 Firewall

- [ ] Configure UFW:

```bash
sudo ufw allow 22/tcp       # SSH (already open presumably)
sudo ufw allow 8883/tcp     # MQTTS
sudo ufw deny 1883/tcp      # Block plaintext MQTT explicitly
sudo ufw enable
sudo ufw status
```

- [ ] Do NOT open port 1883. All traffic must be encrypted.

### 5.7 Start and Verify

- [ ] Restart Mosquitto:

```bash
sudo systemctl restart mosquitto
sudo systemctl status mosquitto
```

- [ ] Check it's listening on 8883:

```bash
sudo ss -tlnp | grep 8883
```

- [ ] Check logs for errors:

```bash
sudo journalctl -u mosquitto -n 50 --no-pager
```

### 5.8 Test from the VPS itself

- [ ] Open two terminals. In terminal 1 (subscriber):

```bash
mosquitto_sub \
  --host localhost \
  --port 8883 \
  --cafile /etc/mosquitto/certs/server.crt \
  --username rcs_operator \
  --pw 'YOUR_PASSWORD' \
  --topic "ugv/#" \
  --verbose
```

- [ ] In terminal 2 (publisher):

```bash
mosquitto_pub \
  --host localhost \
  --port 8883 \
  --cafile /etc/mosquitto/certs/server.crt \
  --username ugv_client \
  --pw 'YOUR_PASSWORD' \
  --topic "ugv/telemetry" \
  --message '{"speed":3.5,"bat_v":24.1,"bat_pct":78}'
```

- [ ] Terminal 1 should show the message. If it does, the broker works.

### 5.9 Test from the RCS PC (remote)

- [ ] On the RCS Linux PC, edit `config/config.yaml`:

```yaml
mqtt:
  host: "mqtt.yourdomain.com"    # or VPS IP
  port: 8883
  username: "rcs_operator"
  password: "YOUR_PASSWORD"
  tls:
    enabled: true
    ca_certs: ""                  # Empty = system CAs (works with Let's Encrypt)
    # ca_certs: "/path/to/ca.crt" # Needed for self-signed certs
```

- [ ] Run the RCS: `bash run.sh`
- [ ] The status bar should show "MQTT: ON" in green.

---

## 6. HARDENING CHECKLIST

- [ ] No anonymous access (`allow_anonymous false`)
- [ ] TLS 1.2 minimum (`tls_version tlsv1.2`)
- [ ] Port 1883 blocked by firewall
- [ ] Port 8883 is the only MQTT port open
- [ ] Password file permissions: `chmod 640 /etc/mosquitto/passwd`
- [ ] Certificate key permissions: `chmod 640 /etc/mosquitto/certs/server.key`
- [ ] Max connections limited (`max_connections 10`)
- [ ] Message size limited (`message_size_limit 4096`)
- [ ] ACL file in place (optional but recommended)
- [ ] Certbot auto-renewal configured (if using Let's Encrypt)
- [ ] SSH key-only login on the VPS (disable password auth in sshd_config)

---

## 7. MONITORING

### Check broker is alive

```bash
sudo systemctl is-active mosquitto
```

### Check connected clients

```bash
mosquitto_sub \
  --host localhost --port 8883 \
  --cafile /etc/mosquitto/certs/server.crt \
  --username rcs_operator --pw 'PASSWORD' \
  --topic '$SYS/broker/clients/connected' \
  --retained-only -C 1
```

### Watch all traffic (debugging)

```bash
mosquitto_sub \
  --host localhost --port 8883 \
  --cafile /etc/mosquitto/certs/server.crt \
  --username rcs_operator --pw 'PASSWORD' \
  --topic '#' --verbose
```

### Log rotation

Mosquitto logs via syslog. Ensure logrotate is configured:

```bash
cat /etc/logrotate.d/mosquitto 2>/dev/null || echo "Using syslog — check /etc/logrotate.d/rsyslog"
```

---

## 8. LATENCY NOTES

The broker is on the critical control path. Latency budget:

| Segment                | Target    |
|------------------------|-----------|
| RCS -> VPS (internet)  | 15-60 ms  |
| VPS broker processing  | < 1 ms    |
| VPS -> Pi (4G/LTE)     | 15-60 ms  |
| **Total control path** | **30-120 ms** |

To minimize broker latency:
- Use QoS 0 for control topics (no ACK round-trip)
- Keep `max_inflight_messages` reasonable (20)
- Choose a VPS geographically close to your operating area
- Monitor with the ping/pong mechanism (RCS sends `ugv/ping`, Pi responds `ugv/pong`)

---

## 9. TAILSCALE OVERLAY (OPTIONAL)

For Phase 3 (Raspberry Pi), a **Tailscale** VPN overlay is planned for:
- Remote SSH access to the Pi
- PLC programming via Modbus TCP bridge
- Node-RED diagnostics
- High-res inspection video (non-realtime)

This does NOT affect the MQTT broker setup. Tailscale runs as a separate overlay network alongside MQTT. The broker remains the primary control/telemetry path.

If you want to also install Tailscale on the VPS (for management access):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

This is entirely optional and does not change the MQTT configuration.

---

## 10. DELIVERABLES CHECKLIST

When done, confirm:

- [ ] Mosquitto 2.0+ installed and running as systemd service
- [ ] Listening on port 8883 (TLS only)
- [ ] Port 1883 blocked
- [ ] Two users created: `rcs_operator`, `ugv_client`
- [ ] TLS certificates in place (Let's Encrypt or self-signed)
- [ ] `rcs.conf` written with all settings from section 5.4
- [ ] UFW firewall configured
- [ ] Local test (pub/sub) passes
- [ ] Remote test from RCS PC passes (MQTT: ON in status bar)
- [ ] ACL file in place (if using)
- [ ] Auto-renewal hook for Let's Encrypt (if using)

---

**END OF PHASE 2 GUIDE**
