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
