# BUGS_FIXED — Mosquitto-Broker-RBPi

## CHANGE-005 — Fresh-VPS deploy fixes

**Date:** 2026-04-08
**Files:** `init.sh`, `docker-compose.yml`, `deploy.sh`
**Severity:** Deployment — four blockers found while deploying to a clean Ubuntu VPS

### Motivation

The CHANGE-004 wizard worked end-to-end on a developer machine but hit four
distinct failures on a brand-new VPS. Each one stopped `bash deploy.sh`
midway and required manual intervention. They all surfaced together because
the cleanroom environment had no leftover state to mask them.

### Change

1. **`6a335d5` — `init.sh` `mosquitto_passwd` file-exists bug.** The script
   was pre-creating an empty `TMP_PASSWD_FILE` and then calling
   `mosquitto_passwd -c`, which on recent mosquitto refuses to overwrite an
   existing file. Removed the pre-creation; let `mosquitto_passwd -c` create
   the file fresh on its first call. Also added `--user $(id -u):$(id -g)`
   to the `docker run eclipse-mosquitto` invocation so the resulting passwd
   file is owned by the host user and the subsequent `cp` can read it
   without sudo.

2. **`ce698d6` — container read-permission bug.** The mosquitto container
   runs as UID 1883 inside its own namespace, which maps to "other" relative
   to whoever owns the host bind-mounted files. The previous `chmod 640` on
   passwd, ACL, `ca.crt`, `server.crt`, and `server.key` made the files
   unreadable from inside the container, so mosquitto refused to start.
   Switched all five to `chmod 644`. `ca.key` stays `chmod 600` because it
   is only used locally by openssl at init time and never mounted into any
   container. Also added `sys_interval 2` to `rcs.conf` so
   `$SYS/broker/uptime` publishes every 2s — the healthcheck `mosquitto_sub`
   uses a 5s `-W` window, and the default 10s sys_interval left a race
   window where the probe could time out before any uptime message arrived.

3. **`c8913bf` — coturn healthcheck bug.** The `coturn/coturn` Debian slim
   image does NOT ship `nc` (netcat). The previous healthcheck
   `nc -zu 127.0.0.1 3478` therefore exited 127 ("command not found") and
   the container was reported unhealthy forever, even when the relay was
   working perfectly. Replaced it with
   `timeout 3 turnutils_stunclient -p 3478 127.0.0.1` — a real STUN binding
   request issued with coturn's own utility, which is guaranteed to be
   present in the image. The `timeout` wrapper bounds the probe so a hung
   coturn cannot stall the healthcheck.

4. **`209d6af` — `deploy.sh` host mosquitto-clients install.** Without
   `mosquitto-clients` on the host, `test.sh` falls back to
   `docker compose exec mosquitto mosquitto_sub ...`. That fallback has a
   latent signal-propagation bug: a `timeout`-killed `docker exec` leaves
   the in-container `mosquitto_sub` running, and the host-side `wait` then
   hangs indefinitely. Made `deploy.sh` apt-install `mosquitto-clients`
   during the Docker install step (~200 KB) so `test.sh` always uses the
   native host clients and finishes in under 5 seconds.

### Result

A `bash deploy.sh` run on a freshly-provisioned Ubuntu VPS now goes from
`apt update` to "two healthy containers + smoke test passed" in roughly two
minutes with zero manual intervention.

## CHANGE-004 — Add deploy.sh one-shot wizard

**Date:** 2026-04-08
**File:** `deploy.sh` (new), `README.md`, `CLAUDE.md`
**Severity:** Deployment UX — reduces friction from "read the guide and copy-paste 8 commands" to "one command"

### Motivation

The Dockerized stack already collapsed deployment to ~6 manual steps (clone, edit `.env`, `init.sh`, `compose up`, `ufw` rules, `test.sh`), but operators still had to read the root SETUP_GUIDE.md in the parent repo, hand-edit `.env`, and remember the firewall ports. Bringing up a fresh VPS therefore took ~10 minutes of careful copy-paste, and any mistake (wrong IP in the cert SAN, weak passwords, forgotten UFW rule) only surfaced later as opaque TLS failures or unreachable TURN.

### Change

Added `deploy.sh` — a single, idempotent, interactive wizard that handles every deployment step in order:

1. **Pre-flight** — verifies repo layout, Linux + Ubuntu/Debian, root or sudo access.
2. **Plan summary + confirmation** — prints what it's about to do and asks `Proceed? [Y/n]`.
3. **Docker install (idempotent)** — checks `docker compose version`, installs via `get.docker.com` if missing, enables the daemon, optionally adds the invoking user to the `docker` group.
4. **Legacy cleanup (optional)** — detects native mosquitto/coturn (apt packages, systemd units, `/etc/mosquitto`, `/etc/turnserver.conf`) and offers to purge them so the host ports are free.
5. **Interactive `.env` build** — auto-detects the public IP via `api.ipify.org` (with two fallbacks), validates IPv4 format, prompts for both MQTT passwords with confirmation and an 8-char minimum (and rejects identical RCS/UGV passwords), prompts for the TURN username, and **auto-generates a strong TURN password** instead of silently using the `ugvturn2026` placeholder. Existing `.env` files can be reused, edited, or overwritten. The final file is `chmod 600`.
6. **Bootstrap + start** — runs `init.sh`, `docker compose pull`, `docker compose up -d`, then polls `docker inspect ... .State.Health.Status` for both `rcs-mosquitto` and `rcs-coturn` for up to 60s, printing a progress dot every 2s. Aborts with a clear message and a pointer to `docker compose logs` on timeout.
7. **UFW rules (optional)** — applies the canonical rule set (allow 22/8883/3478/49152-65535, deny 1883, force-enable) and prints `ufw status verbose` afterwards.
8. **Smoke test** — runs `test.sh` but does not abort on failure (the stack is already up; the operator can inspect).
9. **Summary** — prints VPS IP, MQTT/TLS endpoint, STUN/TURN URLs, both MQTT users, the auto-generated TURN credentials, the CA cert path, a copy-pasteable `scp` command for the operator PC, the next steps (copy `ca.crt`, configure RCS/UGV `config.yaml`), and an operations cheatsheet.

### Non-interactive mode

The wizard accepts `--non-interactive` (also `--yes` / `-y`) and reads all values from environment variables (`VPS_EXTERNAL_IP`, `RCS_OPERATOR_PASSWORD`, `UGV_CLIENT_PASSWORD`, optional `TURN_*`, `CONFIGURE_UFW`, `CLEANUP_LEGACY`, `INSTALL_DOCKER`). Missing required values cause an immediate error. The implementation is a single global `INTERACTIVE` flag plus an `ask` helper that wraps every prompt — small and self-contained.

### New flow on the VPS

```
ssh root@<VPS_IP>
git clone -b feature/broker-docker https://github.com/0xFelipeGD/Mosquitto-Broker-RBPi.git
cd Mosquitto-Broker-RBPi
bash deploy.sh
```

That is the entire operator workflow. The previous `init.sh` + `compose up` + manual UFW + `test.sh` flow is still documented in README.md for advanced users who want step-by-step control.

### Files touched

- `deploy.sh` — new, executable
- `README.md` — added "Quick deploy" section at the top, renamed the old "First-time setup" section to "Manual deploy (advanced)", added `deploy.sh` to the Files table
- `CLAUDE.md` — added `deploy.sh` row to the Key Files table
- `BUGS_FIXED.md` — this entry

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
`CLAUDE.md` (rewritten), `setup.sh` (deleted), `uninstall.sh` (deleted)
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
   - coturn: `turnutils_stunclient -p 3478 127.0.0.1` (a real STUN binding
     request issued with coturn's own tools — guaranteed available inside the
     `coturn/coturn` image). See CHANGE-005 for the follow-up fixes that
     replaced an earlier `nc`-based probe which broke on the slim image.

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
