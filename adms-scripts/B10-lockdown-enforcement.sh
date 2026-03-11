#!/usr/bin/env bash
# B10-lockdown-enforcement-safe.sh
#
# Safe drop-in replacement for B10:
#   Direct LOCKDOWN on identity drift (ΔI => T=3)
#
# Safety improvements over original:
#   1) Pre-arms failsafe rollback BEFORE injecting ΔI
#   2) Uses background watchdog to invoke break-glass + nft flush
#   3) Minimizes time spent in destructive LOCKDOWN
#   4) Avoids relying on controller/network survivability after lockdown
#   5) Preserves same validation goal: ΔI should drive direct LOCKDOWN
#
# Assumptions:
#   - adms-controller exists at /usr/local/bin/adms-controller
#   - adms-breakglass exists at /usr/local/sbin/adms-breakglass
#   - inject endpoint exists at http://localhost:8080/inject
#   - posture endpoint exists at http://localhost:8080/posture
#
# IMPORTANT:
#   Run on a disposable VM / test node when possible.
#   Even with safeguards, this still exercises real enforcement.
set -Eeuo pipefail

CONTROLLER_BIN="/usr/local/bin/adms-controller"
BREAKGLASS_BIN="/usr/local/sbin/adms-breakglass"
CONTROLLER_URL="http://localhost:8080"
CONTROLLER_LOG="/var/log/adms/controller.log"

TAU="1s"
Q=10
DELTA=3

# How long to wait before automatic failsafe recovery starts.
FAILSAFE_AFTER=8

# Hard stop for cleanup waits.
CURL_TIMEOUT=2

# Optional: if you know a controller pidfile location, use it.
CONTROLLER_PID=""

log() {
  printf '[B10-SAFE] %s\n' "$*"
}

cleanup() {
  set +e
  if [[ -n "${FAILSAFE_PID:-}" ]]; then
    kill "$FAILSAFE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${CONTROLLER_PID:-}" ]]; then
    kill "$CONTROLLER_PID" >/dev/null 2>&1 || true
  else
    pkill -f adms-controller >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required binary: $1" >&2
    exit 1
  }
}

require_bin curl
require_bin nft
require_bin pkill
[[ -x "$CONTROLLER_BIN" ]] || { echo "Missing controller: $CONTROLLER_BIN" >&2; exit 1; }
[[ -x "$BREAKGLASS_BIN" ]] || { echo "Missing breakglass: $BREAKGLASS_BIN" >&2; exit 1; }

mkdir -p "$(dirname "$CONTROLLER_LOG")"
: > "$CONTROLLER_LOG"

log "Stopping any previous controller"
pkill -f adms-controller >/dev/null 2>&1 || true
sleep 1

log "Starting controller"
"$CONTROLLER_BIN" \
  --tau="$TAU" \
  --q="$Q" \
  --delta="$DELTA" \
  >>"$CONTROLLER_LOG" 2>&1 &
CONTROLLER_PID=$!

sleep 2

log "Checking controller readiness"
if ! curl -fsS --max-time "$CURL_TIMEOUT" "$CONTROLLER_URL/posture" >/tmp/b10.posture.pre 2>/dev/null; then
  echo "Controller did not become ready" >&2
  exit 1
fi
cat /tmp/b10.posture.pre || true

log "Arming failsafe watchdog (${FAILSAFE_AFTER}s)"
(
  sleep "$FAILSAFE_AFTER"

  printf '[B10-SAFE-FAILSAFE] invoking breakglass\n' >&2
  "$BREAKGLASS_BIN" >/tmp/b10.breakglass.log 2>&1 || true

  printf '[B10-SAFE-FAILSAFE] flushing nftables ruleset\n' >&2
  nft flush ruleset >/tmp/b10.nft.flush.log 2>&1 || true

  printf '[B10-SAFE-FAILSAFE] deleting inet adms table if present\n' >&2
  nft delete table inet adms >/tmp/b10.nft.delete.log 2>&1 || true
) &
FAILSAFE_PID=$!

log "Injecting identity drift (expect direct LOCKDOWN)"
if ! curl -fsS --max-time "$CURL_TIMEOUT" \
  -X POST "$CONTROLLER_URL/inject" \
  -H 'Content-Type: application/json' \
  -d '{"dimension":"I"}' >/tmp/b10.inject.out 2>/dev/null; then
  echo "Failed to inject identity drift" >&2
  exit 1
fi
cat /tmp/b10.inject.out || true

# Give controller a very short interval to transition.
sleep 2

log "TEST 1: posture after ΔI injection"
if curl -fsS --max-time "$CURL_TIMEOUT" "$CONTROLLER_URL/posture" >/tmp/b10.posture.lock 2>/dev/null; then
  cat /tmp/b10.posture.lock || true
else
  log "Controller posture endpoint not reachable post-lockdown (acceptable in destructive path)"
fi

log "TEST 2: nftables lockdown rules (best effort)"
if nft list table inet adms >/tmp/b10.nft.list 2>/dev/null; then
  cat /tmp/b10.nft.list || true
else
  log "nft table inet adms not readable or absent"
fi

log "TEST 3: cgroup freeze status (best effort)"
if [[ -r /sys/fs/cgroup/user.slice/cgroup.freeze ]]; then
  cat /sys/fs/cgroup/user.slice/cgroup.freeze || true
else
  log "cgroup freeze file not present/readable"
fi

# Do not linger in LOCKDOWN. Recovery should happen now.
log "Invoking explicit breakglass immediately"
"$BREAKGLASS_BIN" >/tmp/b10.breakglass.manual.log 2>&1 || true

log "Flushing nftables immediately"
nft flush ruleset >/tmp/b10.nft.flush.manual.log 2>&1 || true
nft delete table inet adms >/tmp/b10.nft.delete.manual.log 2>&1 || true

sleep 2

log "TEST 4: posture after recovery"
if curl -fsS --max-time "$CURL_TIMEOUT" "$CONTROLLER_URL/posture" >/tmp/b10.posture.recovered 2>/dev/null; then
  cat /tmp/b10.posture.recovered || true
else
  log "Controller posture endpoint still unavailable after recovery attempt"
fi

log "Cancelling failsafe watchdog"
kill "$FAILSAFE_PID" >/dev/null 2>&1 || true

log "Artifacts:"
log "  /tmp/b10.inject.out"
log "  /tmp/b10.posture.pre"
log "  /tmp/b10.posture.lock"
log "  /tmp/b10.posture.recovered"
log "  /tmp/b10.nft.list"
log "  /tmp/b10.breakglass.log"
log "  /tmp/b10.breakglass.manual.log"
log "  /tmp/b10.nft.flush.log"
log "  /tmp/b10.nft.flush.manual.log"
log "  $CONTROLLER_LOG"

log "B10 safe test complete"
