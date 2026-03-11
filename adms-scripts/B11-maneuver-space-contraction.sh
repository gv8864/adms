#!/usr/bin/env bash
# B11-maneuver-space-contraction.sh
set -Eeuo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
CONTROLLER_BIN="${CONTROLLER_BIN:-/usr/local/bin/adms-controller}"
CONTROLLER_LOG="${CONTROLLER_LOG:-/var/log/adms/controller.log}"

TAU="${TAU:-1s}"
Q="${Q:-10}"
DELTA="${DELTA:-3}"

START_CONTROLLER="${START_CONTROLLER:-1}"
STARTUP_WAIT="${STARTUP_WAIT:-8}"

log() { printf '[B11] %s\n' "$*"; }

cleanup() {
  set +e
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

posture() {
  curl -fsS --max-time 2 "${BASE_URL}/posture"
}

inject() {
  local dim="$1"
  curl -fsS --max-time 2 -X POST "${BASE_URL}/inject" \
    -H 'Content-Type: application/json' \
    -d "{\"dimension\":\"${dim}\"}" >/dev/null
}

# ---- Capability probes ----
# Return 1 if permitted, 0 if blocked.

probe_egress_new() {
  timeout 2 bash -c 'echo > /dev/tcp/1.1.1.1/80' >/dev/null 2>&1 && echo 1 || echo 0
}

probe_persistence_write() {
  local f="/tmp/adms_persist_test_$$"
  touch "$f" 2>/dev/null && rm -f "$f" && echo 1 || echo 0
}

probe_module_load() {
  command -v modprobe >/dev/null 2>&1 || { echo 0; return; }
  modprobe -n dummy >/dev/null 2>&1 && echo 1 || echo 0
}

probe_exec_from_writable() {
  local f="/tmp/adms_exec_test_$$.sh"
  cat > "$f" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$f"
  "$f" >/dev/null 2>&1
  local rc=$?
  rm -f "$f"
  [[ $rc -eq 0 ]] && echo 1 || echo 0
}

probe_cap_gain() {
  command -v capsh >/dev/null 2>&1 || { echo 0; return; }
  capsh --print >/dev/null 2>&1 && echo 1 || echo 0
}

measure_proxy() {
  local e p m x c sum
  e=$(probe_egress_new)
  p=$(probe_persistence_write)
  m=$(probe_module_load)
  x=$(probe_exec_from_writable)
  c=$(probe_cap_gain)
  sum=$((e+p+m+x+c))
  printf '%s,%s,%s,%s,%s,%s\n' "$sum" "$e" "$p" "$m" "$x" "$c"
}

record_state() {
  local label="$1"
  local post row
  post="$(posture 2>/dev/null || echo unknown)"
  row="$(measure_proxy)"
  printf '%s,%s,%s\n' "$label" "$post" "$row"
}

main() {
  if [[ "${START_CONTROLLER}" == "1" ]]; then
    start_controller
  fi

  log "label,posture,M_proxy,egress_new,persistence_write,module_load,exec_from_writable,cap_gain"
  record_state NORMAL

  log "Injecting ΔN (expect OBSERVE)"
  inject N
  sleep 2
  record_state OBSERVE

  log "Injecting ΔP (expect RESTRICTED)"
  inject P
  sleep 2
  record_state RESTRICTED

  log "Injecting ΔI (expect LOCKDOWN)"
  inject I
  sleep 2
  record_state LOCKDOWN

  log "Done. Controller log: ${CONTROLLER_LOG}"
}

main "$@"