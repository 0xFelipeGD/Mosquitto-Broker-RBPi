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
