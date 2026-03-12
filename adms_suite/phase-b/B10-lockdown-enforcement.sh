#!/usr/bin/env bash
# SAFETY: DISPOSABLE-VM ONLY
# PAPER ROLE: Phase B LOCKDOWN enforcement
# B10-lockdown-enforcement.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

FAILSAFE_AFTER="${FAILSAFE_AFTER:-8}"
LOCKDOWN_WAIT="${LOCKDOWN_WAIT:-15}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/adms-b10}"
FAILSAFE_PID=""

mkdir -p "$ARTIFACT_DIR"

cleanup() {
  set +e
  [[ -n "${FAILSAFE_PID:-}" ]] && kill "$FAILSAFE_PID" >/dev/null 2>&1 || true
  adms_stop_controller >/dev/null 2>&1 || true
}
trap cleanup EXIT

adms_require_bin curl
adms_require_bin nft
[[ -x "$ADMS_BREAKGLASS_BIN" ]] || {
  echo "Missing breakglass: $ADMS_BREAKGLASS_BIN" >&2
  exit 1
}

adms_log "Starting B10 LOCKDOWN enforcement test"
adms_log "Artifacts: $ARTIFACT_DIR"

# Start and verify controller
adms_start_controller
adms_wait_controller

adms_log "Preflight posture"
adms_posture_raw > "$ARTIFACT_DIR/posture.pre.json" 2>/dev/null || true
cat "$ARTIFACT_DIR/posture.pre.json" || true

PRE_LEVEL="$(python3 - <<'PY' 2>/dev/null < "$ARTIFACT_DIR/posture.pre.json" || true
import sys, json
try:
    print(json.load(sys.stdin).get("level", "ERR"))
except Exception:
    print("ERR")
PY
)"
PRE_NAME="$(python3 - <<'PY' 2>/dev/null < "$ARTIFACT_DIR/posture.pre.json" || true
import sys, json
try:
    print(json.load(sys.stdin).get("name", "ERR"))
except Exception:
    print("ERR")
PY
)"

adms_log "Initial posture: level=${PRE_LEVEL:-ERR} name=${PRE_NAME:-ERR}"
if [[ "${PRE_LEVEL:-ERR}" != "0" ]]; then
  adms_log "FAIL: controller did not start in NORMAL posture"
  exit 1
fi

# Failsafe: breakglass + nft flush after timeout
(
  sleep "$FAILSAFE_AFTER"
  "$ADMS_BREAKGLASS_BIN" >"$ARTIFACT_DIR/breakglass.failsafe.log" 2>&1 || true
  nft flush ruleset >"$ARTIFACT_DIR/nft.flush.failsafe.log" 2>&1 || true
  nft delete table inet adms >"$ARTIFACT_DIR/nft.delete.failsafe.log" 2>&1 || true
) &
FAILSAFE_PID=$!

adms_log "Injecting identity drift (expect direct LOCKDOWN)"
if curl -sS -D "$ARTIFACT_DIR/inject.headers.txt" \
  -o "$ARTIFACT_DIR/inject.body.txt" \
  --max-time "$ADMS_HTTP_TIMEOUT" \
  -X POST "$ADMS_BASE_URL/inject" \
  -H 'Content-Type: application/json' \
  -d '{"dimension":"I"}'; then
  adms_log "Inject request completed"
else
  adms_log "FAIL: inject request failed"
  cat "$ARTIFACT_DIR/inject.headers.txt" 2>/dev/null || true
  cat "$ARTIFACT_DIR/inject.body.txt" 2>/dev/null || true
  exit 1
fi

# Wait for posture change or terminal containment
deadline=$((SECONDS + LOCKDOWN_WAIT))
POST_LEVEL="0"
POST_NAME="NORMAL"
POSTURE_REACHABLE="1"

while (( SECONDS < deadline )); do
  if curl -fsS --max-time "$ADMS_HTTP_TIMEOUT" \
    "$ADMS_BASE_URL/posture" > "$ARTIFACT_DIR/posture.poll.json" 2>/dev/null; then

    POST_LEVEL="$(python3 - <<'PY' 2>/dev/null < "$ARTIFACT_DIR/posture.poll.json" || true
import sys, json
try:
    print(json.load(sys.stdin).get("level", "ERR"))
except Exception:
    print("ERR")
PY
)"
    POST_NAME="$(python3 - <<'PY' 2>/dev/null < "$ARTIFACT_DIR/posture.poll.json" || true
import sys, json
try:
    print(json.load(sys.stdin).get("name", "ERR"))
except Exception:
    print("ERR")
PY
)"
    cp -f "$ARTIFACT_DIR/posture.poll.json" "$ARTIFACT_DIR/posture.lock.json" >/dev/null 2>&1 || true
    adms_log "Observed posture: level=${POST_LEVEL:-ERR} name=${POST_NAME:-ERR}"

    if [[ "${POST_LEVEL:-0}" != "0" ]]; then
      break
    fi
  else
    POSTURE_REACHABLE="0"
    adms_log "Controller posture endpoint became unreachable; treating as possible terminal containment"
    break
  fi

  sleep 1
done

# Capture enforcement evidence
nft list ruleset > "$ARTIFACT_DIR/nft.ruleset.txt" 2>/dev/null || true
nft list table inet adms > "$ARTIFACT_DIR/nft.adms.txt" 2>/dev/null || true

if [[ -r /sys/fs/cgroup/user.slice/cgroup.freeze ]]; then
  cat /sys/fs/cgroup/user.slice/cgroup.freeze > "$ARTIFACT_DIR/cgroup.freeze.txt" 2>/dev/null || true
fi

# Decide outcome
if [[ "$POSTURE_REACHABLE" == "1" && "${POST_LEVEL:-0}" == "0" ]]; then
  adms_log "FAIL: inject did not move posture out of NORMAL within ${LOCKDOWN_WAIT}s"
  adms_log "This suggests inject is not wired, masking is active, or controller is not processing identity drift."
  exit 1
fi

if [[ "$POSTURE_REACHABLE" == "1" ]]; then
  adms_log "LOCKDOWN evidence captured: level=${POST_LEVEL:-ERR} name=${POST_NAME:-ERR}"
else
  adms_log "LOCKDOWN likely caused terminal containment (endpoint unreachable)"
fi

# Recovery
adms_log "Invoking breakglass and reset"
adms_breakglass || true
adms_reset_enforcement || true
sleep 2

if curl -fsS --max-time "$ADMS_HTTP_TIMEOUT" \
  "$ADMS_BASE_URL/posture" > "$ARTIFACT_DIR/posture.recovered.json" 2>/dev/null; then
  cat "$ARTIFACT_DIR/posture.recovered.json" || true
  REC_LEVEL="$(python3 - <<'PY' 2>/dev/null < "$ARTIFACT_DIR/posture.recovered.json" || true
import sys, json
try:
    print(json.load(sys.stdin).get("level", "ERR"))
except Exception:
    print("ERR")
PY
)"
  REC_NAME="$(python3 - <<'PY' 2>/dev/null < "$ARTIFACT_DIR/posture.recovered.json" || true
import sys, json
try:
    print(json.load(sys.stdin).get("name", "ERR"))
except Exception:
    print("ERR")
PY
)"
  adms_log "Recovered posture: level=${REC_LEVEL:-ERR} name=${REC_NAME:-ERR}"
else
  adms_log "Controller posture endpoint still unavailable after recovery attempt"
fi

[[ -n "${FAILSAFE_PID:-}" ]] && kill "$FAILSAFE_PID" >/dev/null 2>&1 || true
adms_log "B10 safe test complete"
adms_log "Artifacts written to: $ARTIFACT_DIR"

