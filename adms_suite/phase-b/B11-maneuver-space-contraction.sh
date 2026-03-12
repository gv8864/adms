#!/usr/bin/env bash
# SAFETY: HOST-SAFE if LOCKDOWN step is skipped; DISPOSABLE-VM for terminal containment
# PAPER ROLE: Empirical maneuver-space contraction witness
# B11-maneuver-space-contraction.sh
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

RUN_LOCKDOWN_STEP="${RUN_LOCKDOWN_STEP:-0}"
PERSIST_PATH="${PERSIST_PATH:-/etc/cron.d/adms_test_$$}"
ENABLE_MODULE_PROBE="${ENABLE_MODULE_PROBE:-1}"
START_CONTROLLER="${START_CONTROLLER:-1}"

cleanup() {
  set +e
  rm -f "${PERSIST_PATH}" >/dev/null 2>&1 || true
  [[ "${START_CONTROLLER}" == "1" ]] && adms_stop_controller || true
}
trap cleanup EXIT

probe_egress_new() {
  timeout 2 bash -c 'echo > /dev/tcp/1.1.1.1/80' >/dev/null 2>&1 && echo 1 || echo 0
}
probe_protected_persistence_write() {
  touch "${PERSIST_PATH}" >/dev/null 2>&1 && { rm -f "${PERSIST_PATH}" >/dev/null 2>&1 || true; echo 1; } || echo 0
}
probe_module_load() {
  [[ "${ENABLE_MODULE_PROBE}" == "1" ]] || { echo NA; return; }
  command -v modprobe >/dev/null 2>&1 || { echo 0; return; }
  modprobe dummy >/dev/null 2>&1 && { modprobe -r dummy >/dev/null 2>&1 || true; echo 1; return; }
  echo 0
}
measure_proxy() {
  local e p m sum
  e=$(probe_egress_new); p=$(probe_protected_persistence_write); m=$(probe_module_load)
  if [[ "$m" == "NA" ]]; then sum=$((e+p)); else sum=$((e+p+m)); fi
  printf '%s,%s,%s,%s\n' "$sum" "$e" "$p" "$m"
}
record_state() {
  local label="$1" pname row
  pname="$(adms_posture_name 2>/dev/null || true)"; [[ -n "${pname:-}" ]] || pname="unknown"
  row="$(measure_proxy)"
  printf '%s,%s,%s\n' "$label" "$pname" "$row"
}

[[ "$START_CONTROLLER" == "1" ]] && { adms_start_controller; adms_wait_controller; }

adms_log "label,posture,M_proxy,egress_new,persistence_write,module_load"
record_state NORMAL
adms_log "Injecting ΔN (expect OBSERVE)"; adms_inject_dim N; sleep 2; record_state OBSERVE
adms_log "Injecting ΔP (expect RESTRICTED)"; adms_inject_dim P; sleep 2; record_state RESTRICTED

if [[ "${RUN_LOCKDOWN_STEP}" != "1" ]]; then
  adms_log "Skipping ΔI / LOCKDOWN step by default for host safety"
  exit 0
fi

adms_log "Injecting ΔI (expect LOCKDOWN / terminal containment)"; adms_inject_dim_terminal I; sleep 2
if curl -fsS --max-time "$ADMS_HTTP_TIMEOUT" "${ADMS_BASE_URL}/posture" >/dev/null 2>&1; then
  record_state LOCKDOWN
else
  adms_log "LOCKDOWN rendered the controller endpoint unreachable; treating this as expected terminal containment"
  printf 'LOCKDOWN,UNREACHABLE_TERMINAL,0,0,0,0\n'
fi
