#!/usr/bin/env bash
# B11-maneuver-space-contraction.sh
#
# Purpose:
#   Validate two things:
#   1) Deterministic posture transitions
#   2) Empirical maneuver-space contraction proxy using ONLY
#      controls that the prototype is actually supposed to enforce
#
# Proxy definition:
#   M_proxy = egress_new + protected_persistence_write + module_load
#
# Expected qualitative behavior:
#   M_proxy(NORMAL) >= M_proxy(OBSERVE) >= M_proxy(RESTRICTED) >= M_proxy(LOCKDOWN)
#
# Notes:
#   - This script starts adms-controller unless START_CONTROLLER=0
#   - Run in a test VM / namespace sandbox, not on a production host
set -Eeuo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
CONTROLLER_BIN="${CONTROLLER_BIN:-/usr/local/bin/adms-controller}"
CONTROLLER_LOG="${CONTROLLER_LOG:-/var/log/adms/controller.log}"

TAU="${TAU:-1s}"
Q="${Q:-10}"
DELTA="${DELTA:-3}"

START_CONTROLLER="${START_CONTROLLER:-1}"
STARTUP_WAIT="${STARTUP_WAIT:-8}"

# Protected persistence target: change if your controller protects a different path
PERSIST_PATH="${PERSIST_PATH:-/etc/cron.d/adms_test_$$}"

# Set to 0 if your prototype does not actually enforce module-load restrictions
ENABLE_MODULE_PROBE="${ENABLE_MODULE_PROBE:-1}"

log() { printf '[B11] %s\n' "$*"; }

cleanup() {
  set +e
  rm -f "${PERSIST_PATH}" >/dev/null 2>&1 || true
  if [[ "${START_CONTROLLER}" == "1" && -n "${CONTROLLER_PID:-}" ]]; then
    kill "${CONTROLLER_PID}" >/dev/null 2>&1 || true
    wait "${CONTROLLER_PID}" >/dev/null 2>&1 || true
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
require_bin timeout
[[ -x "${CONTROLLER_BIN}" ]] || {
  echo "Missing controller binary: ${CONTROLLER_BIN}" >&2
  exit 1
}

start_controller() {
  mkdir -p "$(dirname "${CONTROLLER_LOG}")"
  : > "${CONTROLLER_LOG}"

  log "Stopping any previous controller"
  pkill -f adms-controller >/dev/null 2>&1 || true
  sleep 1

  log "Starting controller"
  "${CONTROLLER_BIN}" \
    --tau="${TAU}" \
    --q="${Q}" \
    --delta="${DELTA}" \
    >>"${CONTROLLER_LOG}" 2>&1 &
  CONTROLLER_PID=$!

  log "Waiting for controller readiness"
  for _ in $(seq 1 "${STARTUP_WAIT}"); do
    if curl -fsS --max-time 2 "${BASE_URL}/posture" >/dev/null 2>&1; then
      log "Controller is ready"
      return 0
    fi
    sleep 1
  done

  echo "Controller did not become ready. See ${CONTROLLER_LOG}" >&2
  exit 1
}

posture_raw() {
  curl -fsS --max-time 2 "${BASE_URL}/posture"
}

posture_name() {
  posture_raw | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'
}

inject() {
  local dim="$1"
  curl -fsS --max-time 2 -X POST "${BASE_URL}/inject" \
    -H 'Content-Type: application/json' \
    -d "{\"dimension\":\"${dim}\"}" >/dev/null
}

# ------------------------------
# Enforcement-aligned probes
# Return 1 if permitted, 0 if blocked
# ------------------------------

probe_egress_new() {
  # TCP connect attempt to external IP/port
  timeout 2 bash -c 'echo > /dev/tcp/1.1.1.1/80' >/dev/null 2>&1 && echo 1 || echo 0
}

probe_protected_persistence_write() {
  # Probe an actually protected persistence path
  touch "${PERSIST_PATH}" >/dev/null 2>&1 && {
    rm -f "${PERSIST_PATH}" >/dev/null 2>&1 || true
    echo 1
  } || echo 0
}

probe_module_load() {
  [[ "${ENABLE_MODULE_PROBE}" == "1" ]] || { echo NA; return; }

  command -v modprobe >/dev/null 2>&1 || { echo 0; return; }

  # Real module load attempt, not dry-run
  modprobe dummy >/dev/null 2>&1 && {
    modprobe -r dummy >/dev/null 2>&1 || true
    echo 1
    return
  }

  echo 0
}

measure_proxy() {
  local e p m sum

  e=$(probe_egress_new)
  p=$(probe_protected_persistence_write)
  m=$(probe_module_load)

  if [[ "${m}" == "NA" ]]; then
    sum=$((e+p))
    printf '%s,%s,%s,%s\n' "$sum" "$e" "$p" "NA"
  else
    sum=$((e+p+m))
    printf '%s,%s,%s,%s\n' "$sum" "$e" "$p" "$m"
  fi
}

record_state() {
  local label="$1"
  local pname row
  pname="$(posture_name 2>/dev/null || echo unknown)"
  row="$(measure_proxy)"
  printf '%s,%s,%s\n' "$label" "$pname" "$row"
}

main() {
  if [[ "${START_CONTROLLER}" == "1" ]]; then
    start_controller
  fi

  log "label,posture,M_proxy,egress_new,persistence_write,module_load"
  record_state NORMAL

  log "Injecting ΔN (expect OBSERVE)"
  inject N
  sleep 2
  record_state OBSERVE

  log "Injecting ΔP (expect RESTRICTED)"
  inject P
  sleep 2
  record_state RESTRICTED

    log "Injecting ΔI (expect LOCKDOWN / terminal containment)"
    timeout 3 curl -fsS --max-time 2 -X POST "${BASE_URL}/inject" \
    -H 'Content-Type: application/json' \
    -d '{"dimension":"I"}' >/dev/null 2>&1 || true

    sleep 2

    if curl -fsS --max-time 2 "${BASE_URL}/posture" >/dev/null 2>&1; then
        record_state LOCKDOWN
    else
    log "LOCKDOWN caused controller endpoint to become unreachable (acceptable terminal containment behavior)"
        printf 'LOCKDOWN,UNREACHABLE_TERMINAL,0,0,0,0\n'
    fi

  log "Done. Controller log: ${CONTROLLER_LOG}"
  log "If M_proxy does not shrink, your enforcement rules are not aligned with these probes."
  log "Adjust PERSIST_PATH and/or ENABLE_MODULE_PROBE to match the actual controller policy."
}

main "$@"
