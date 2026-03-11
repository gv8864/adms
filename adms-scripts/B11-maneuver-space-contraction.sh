#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"

log() { printf '[B11] %s\n' "$*"; }

posture() {
  curl -fsS "${BASE_URL}/posture"
}

inject() {
  local dim="$1"
  curl -fsS -X POST "${BASE_URL}/inject" \
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
  local post
  post="$(posture || echo unknown)"
  local row
  row="$(measure_proxy)"
  printf '%s,%s,%s\n' "$label" "$post" "$row"
}

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

