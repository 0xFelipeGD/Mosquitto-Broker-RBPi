# Mosquitto MQTT Broker — VPS Setup

Automated setup wizard for deploying a secure Eclipse Mosquitto MQTT broker on a VPS.
Part of the RCS (Remote Control Station) <-> UGV (Unmanned Ground Vehicle) communication system.

## Architecture

```
[RCS - Linux PC]                       [Raspberry Pi - UGV]
  paho-mqtt client                       paho-mqtt client
       |                                      |
       |  TLS (port 8883)                     |  TLS (port 8883)
       +------------>  [VPS - Mosquitto]  <---+
```

## Quick Start

SSH into your VPS and run:

```bash
git clone https://github.com/0xFelipeGD/Mosquitto-Broker-RBPi.git
cd Mosquitto-Broker-RBPi
sudo ./setup.sh
```

The wizard will ask you:

1. **TLS mode** — Let's Encrypt (need a domain) or self-signed (works with IP)
2. **Passwords** — for `rcs_operator` and `ugv_client` MQTT users
3. **ACL** — enable topic-level access control (recommended)
4. **Firewall** — configure UFW (recommended)

That's it. Everything else is automatic.

## What the wizard does

- Installs Mosquitto 2.0+ from the official PPA
- Generates or obtains TLS certificates
- Creates MQTT users with password authentication
- Writes a hardened broker configuration (TLS-only on port 8883)
- Sets up topic ACLs matching the RCS/UGV topic contract
- Configures UFW firewall (blocks plaintext MQTT on 1883)
- Runs a self-test to verify pub/sub over TLS
- Saves credentials to `/etc/mosquitto/.credentials`

## After Setup

### Verify the broker

```bash
sudo ./test.sh
```

Runs a full test suite: service status, port checks, TLS cert, pub/sub in both directions, and security tests (anonymous/wrong password rejection).

> **Self-signed certs:** the script uses `--insecure` to bypass hostname verification on the loopback interface (the cert is issued for the VPS external IP, not `localhost`). TLS encryption and CA chain validation remain active. This is expected and correct for a local functional test.

### Connect the RCS

In your RCS `config/config.yaml`:

```yaml
mqtt:
  host: "mqtt.yourdomain.com"    # or VPS IP
  port: 8883
  username: "rcs_operator"
  password: "YOUR_PASSWORD"
  tls:
    enabled: true
    ca_certs: ""                  # empty for Let's Encrypt (uses system CAs)
    # ca_certs: "/path/to/ca.crt" # needed for self-signed
```

### Self-signed certs

If you used self-signed TLS, copy the CA cert to each client machine:

```bash
# Run this on your LOCAL machine (not inside the VPS SSH session)
scp root@YOUR_VPS_IP:/etc/mosquitto/certs/ca.crt .
```

### Useful commands

```bash
sudo systemctl status mosquitto       # Service status
sudo journalctl -u mosquitto -f       # Live logs
sudo ./test.sh                        # Run test suite
sudo ./uninstall.sh                   # Remove everything
```

## Uninstall

```bash
sudo ./uninstall.sh
```

Removes Mosquitto, config, certs, users, and firewall rules. Requires typing `YES` to confirm.

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Interactive setup wizard |
| `test.sh` | Post-setup test suite |
| `uninstall.sh` | Clean uninstall |
| `VPS_BROKER_SETUP.md` | Full manual reference (for engineers/AI) |
