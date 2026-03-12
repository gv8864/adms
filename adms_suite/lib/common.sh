#!/usr/bin/env bash
# Shared helpers for ADMS evaluation scripts.
# Source from tests/runners to standardize controller lifecycle,
# break-glass, reset, and result collection.

# Do not enable set -e here; let caller control shell strictness.
set -o pipefail

ADMS_BASE_URL="${ADMS_BASE_URL:-http://localhost:8080}"
ADMS_CONTROLLER_BIN="${ADMS_CONTROLLER_BIN:-/usr/local/bin/adms-controller}"
ADMS_BREAKGLASS_BIN="${ADMS_BREAKGLASS_BIN:-/usr/local/sbin/adms-breakglass}"
ADMS_CONTROLLER_LOG="${ADMS_CONTROLLER_LOG:-/var/log/adms/controller.log}"
ADMS_RESULTS_DIR="${ADMS_RESULTS_DIR:-/tmp/adms-results}"
ADMS_TAU="${ADMS_TAU:-1s}"
ADMS_Q="${ADMS_Q:-10}"
ADMS_DELTA="${ADMS_DELTA:-3}"
ADMS_STARTUP_WAIT="${ADMS_STARTUP_WAIT:-8}"
ADMS_HTTP_TIMEOUT="${ADMS_HTTP_TIMEOUT:-2}"

adms_log() { printf '[ADMS] %s\n' "$*"; }

adms_require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required binary: $1" >&2
    return 1
  }
}

adms_prepare_results_dir() {
  mkdir -p "$ADMS_RESULTS_DIR" "$(dirname "$ADMS_CONTROLLER_LOG")"
}

adms_posture_raw() {
  curl -fsS --max-time "$ADMS_HTTP_TIMEOUT" "${ADMS_BASE_URL}/posture"
}

adms_posture_name() {
  adms_posture_raw | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'
}

adms_inject_dim() {
  local dim="$1"
  curl -fsS --max-time "$ADMS_HTTP_TIMEOUT" -X POST "${ADMS_BASE_URL}/inject" \
    -H 'Content-Type: application/json' \
    -d "{\"dimension\":\"${dim}\"}" >/dev/null
}

adms_inject_dim_terminal() {
  local dim="$1"
  timeout 3 curl -fsS --max-time "$ADMS_HTTP_TIMEOUT" -X POST "${ADMS_BASE_URL}/inject" \
    -H 'Content-Type: application/json' \
    -d "{\"dimension\":\"${dim}\"}" >/dev/null 2>&1 || true
}

adms_start_controller() {
  adms_prepare_results_dir
  : > "$ADMS_CONTROLLER_LOG"
  pkill -f adms-controller >/dev/null 2>&1 || true
  sleep 1
  "$ADMS_CONTROLLER_BIN" \
    --tau="$ADMS_TAU" \
    --q="$ADMS_Q" \
    --delta="$ADMS_DELTA" \
    >>"$ADMS_CONTROLLER_LOG" 2>&1 &
  export ADMS_CONTROLLER_PID=$!
}

adms_wait_controller() {
  local i
  for i in $(seq 1 "$ADMS_STARTUP_WAIT"); do
    if curl -fsS --max-time "$ADMS_HTTP_TIMEOUT" "${ADMS_BASE_URL}/posture" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Controller did not become ready" >&2
  return 1
}

adms_stop_controller() {
  if [[ -n "${ADMS_CONTROLLER_PID:-}" ]]; then
    kill "${ADMS_CONTROLLER_PID}" >/dev/null 2>&1 || true
    wait "${ADMS_CONTROLLER_PID}" >/dev/null 2>&1 || true
  else
    pkill -f adms-controller >/dev/null 2>&1 || true
  fi
}

adms_breakglass() {
  [[ -x "$ADMS_BREAKGLASS_BIN" ]] || return 0
  "$ADMS_BREAKGLASS_BIN" >/dev/null 2>&1 || true
}

adms_reset_enforcement() {
  adms_breakglass
  command -v nft >/dev/null 2>&1 && {
    nft flush ruleset >/dev/null 2>&1 || true
    nft delete table inet adms >/dev/null 2>&1 || true
  }
  # Best-effort cgroup thaw across v2 hierarchy.
  if [[ -d /sys/fs/cgroup ]]; then
    while IFS= read -r -d '' f; do
      echo 0 > "$f" 2>/dev/null || true
    done < <(find /sys/fs/cgroup -name cgroup.freeze -print0 2>/dev/null)
  fi
  # Best-effort unmount of known adms temporary mounts.
  while IFS= read -r mp; do
    umount "$mp" >/dev/null 2>&1 || true
  done < <(mount | awk '/adms|\/mnt\/adms|\/run\/adms/ {print $3}')
}

adms_collect_results() {
  local outdir="$1"
  mkdir -p "$outdir"
  cp -f "$ADMS_CONTROLLER_LOG" "$outdir/" 2>/dev/null || true
  cp -f /tmp/adms-*.log "$outdir/" 2>/dev/null || true
  cp -f /tmp/adms-*.json "$outdir/" 2>/dev/null || true
  cp -f /tmp/b10.* "$outdir/" 2>/dev/null || true
  command -v nft >/dev/null 2>&1 && nft list ruleset > "$outdir/nft-ruleset.txt" 2>/dev/null || true
  curl -fsS --max-time "$ADMS_HTTP_TIMEOUT" "${ADMS_BASE_URL}/posture" > "$outdir/final-posture.json" 2>/dev/null || true
}
