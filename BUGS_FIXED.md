# BUGS_FIXED — Mosquitto-Broker-RBPi

## BUG-001 — TLS hostname mismatch in test.sh causes false failures and false passes

**Date:** 2026-04-03
**File:** `test.sh`
**Severity:** High — pub/sub tests always failed; security tests gave false PASS

### Root cause

The self-signed server certificate is generated with the VPS external IP as the
CN/SAN (e.g. `72.60.132.162`). Every `mosquitto_pub`/`mosquitto_sub` call in the
script connected with `--host localhost`, which does not match the certificate's
CN. This caused an `sslv3 alert bad certificate` TLS handshake error before the
MQTT session could be established.

**Section 5 (pub/sub tests):** both directions silently failed — the subscriber
received nothing, so the test always reported FAIL.

**Section 6 (security tests):** the TLS error also produced a non-zero exit code,
which the `if` checks mistakenly interpreted as auth rejection. Both "anonymous"
and "wrong password" tests reported PASS even though the broker never evaluated
the credentials at all.

### Fix

Added `--insecure` to every `mosquitto_pub` and `mosquitto_sub` call in the
script (sections 5 and 6). This flag instructs the Mosquitto client to skip
hostname verification while still using TLS encryption and still validating the
certificate chain against the provided `--cafile`. TLS integrity is preserved;
only the hostname-match step is bypassed, which is appropriate for a local
loopback functional test.

The `--cafile` argument is retained on all commands (belt-and-suspenders: the CA
chain is still verified).

An explanatory comment was added above each affected block so the intent is clear
to future maintainers.

### No other changes

The fix is strictly minimal. No other logic, structure, or test coverage was
altered.

## CHANGE-003 — Containerize broker with docker-compose

**Date:** 2026-04-08
**Files:** `docker-compose.yml` (new), `init.sh` (new), `.env.example` (new),
`.gitignore` (new), `test.sh` (rewritten), `README.md` (rewritten),
`CLAUDE.md` (rewritten), `setup.sh` (deleted)
**Severity:** Deployment — reproducibility + ops

### Motivation

The old `setup.sh` interactive wizard required root on the VPS, modified the
host system (apt, systemd, UFW, /etc/mosquitto), and was brittle across Ubuntu
releases. Reproducing the same install on a new VPS meant walking through ~15
prompts while hoping the PPA still existed. Rollback was manual.

### Change

Replaced the entire interactive installer with a two-service docker compose
stack plus a one-shot bootstrap script:

1. **`docker-compose.yml`** — `mosquitto` (eclipse-mosquitto:2) on a bridge
   network exposing 8883, and `coturn` (coturn/coturn:latest) using
   `network_mode: host` so the TURN relay port range (49152-65535/udp) and
   external-ip advertisement work. Both services have `restart: unless-stopped`
   and real healthchecks:
   - mosquitto: TLS `mosquitto_sub` on `$SYS/broker/uptime` using a dedicated
     `health` user with a random password (isolated from the two real users so
     a broken healthcheck cannot lock the operator out).
   - coturn: `nc -zu 127.0.0.1 3478`.

2. **`.env.example` + `.env`** — single source of secrets. Required:
   `VPS_EXTERNAL_IP`, `RCS_OPERATOR_PASSWORD`, `UGV_CLIENT_PASSWORD`.
   `.env` is gitignored.

3. **`init.sh`** — idempotent bootstrap: validates `.env`, generates a
   self-signed CA + server cert (SAN includes both IP and hostname when they
   differ), writes `mosquitto.conf` + `conf.d/rcs.conf`, builds the `passwd`
   file by invoking `mosquitto_passwd` inside the eclipse-mosquitto image
   (so the host doesn't need mosquitto-clients installed), writes the ACL
   (matching INTERFACE_CONTRACT.md plus a read-only `$SYS/broker/uptime` entry
   for the health user), and writes `turnserver.conf`. Re-running is a no-op
   for existing certs; passwords are always re-applied so rotation is a
   one-command flow.

4. **`test.sh`** — rewritten: checks `docker compose ps` healthy state, runs
   a TLS pub/sub round trip using host mosquitto-clients when available or
   `docker compose exec mosquitto` as fallback, and verifies coturn is
   listening on UDP 3478.

5. **`setup.sh` and `uninstall.sh` deleted.** Full rollback is now
   `docker compose down && rm -rf data/ .env` — no host cleanup needed
   because nothing was ever installed on the host in the first place.

6. **UFW is the operator's responsibility** — documented in README but not
   touched by any script. This separation is intentional: one layer per tool.

### New deploy flow (on the VPS)

```
git clone ... && cd Mosquitto-Broker-RBPi
cp .env.example .env && nano .env
bash init.sh
docker compose up -d
docker compose ps
bash test.sh
```

No host packages installed, no systemd units touched, no files in /etc. Full
rollback is `docker compose down && rm -rf data/ .env`.

## CHANGE-002 — Consolidate setup_coturn.sh into setup.sh

**Date:** 2026-04-08
**Files:** `setup.sh`, `setup_coturn.sh` (deleted), `README.md`, `CLAUDE.md`, `test.sh`
**Severity:** UX improvement — single-script wizard

### Motivation

Operators previously had to run two scripts on the VPS (`setup.sh` followed by
`setup_coturn.sh`) to bring up the broker plus the STUN/TURN server needed for
the WebRTC camera feed. This was error-prone and easy to forget.

### Change

Merged the entire `setup_coturn.sh` flow into `setup.sh` as an optional Step 6
inside the existing wizard. The wizard now has 7 steps total:

1. Configuration (TLS, MQTT users, ACL, **coturn opt-in**, UFW)
2. Install Mosquitto
3. TLS certificates
4. Create MQTT users
5. Write Mosquitto config (ACL + rcs.conf)
6. **Install + configure coturn (optional, default Y)**
7. Firewall (handles 8883/tcp + 3478/udp+tcp + 49152-65535/udp when coturn enabled)

The coturn prompt defaults to Yes. Credentials remain `ugv` / `ugvturn2026`.
External IP is auto-detected (or reused from the broker host when self-signed).
The UFW step was reordered to run AFTER coturn so a single firewall pass opens
both Mosquitto and coturn ports atomically.

The final summary now reports coturn status (installed/skipped) and prints the
STUN/TURN URLs plus the matching `camera:` block for `config.yaml`.

`setup_coturn.sh` was deleted. `README.md`, `CLAUDE.md` and `test.sh` were
updated to reference only `setup.sh`. No mosquitto behavior (TLS modes, users,
ACL, ports, limits) was changed.
