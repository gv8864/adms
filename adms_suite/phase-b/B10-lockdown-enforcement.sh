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
cleanup() {
  set +e
  [[ -n "${FAILSAFE_PID:-}" ]] && kill "$FAILSAFE_PID" >/dev/null 2>&1 || true
  adms_stop_controller || true
}
trap cleanup EXIT

adms_require_bin curl
adms_require_bin nft
[[ -x "$ADMS_BREAKGLASS_BIN" ]] || { echo "Missing breakglass: $ADMS_BREAKGLASS_BIN" >&2; exit 1; }

adms_start_controller
adms_wait_controller
adms_posture_raw > /tmp/b10.posture.pre 2>/dev/null || true
cat /tmp/b10.posture.pre || true
(
  sleep "$FAILSAFE_AFTER"
  "$ADMS_BREAKGLASS_BIN" >/tmp/b10.breakglass.log 2>&1 || true
  nft flush ruleset >/tmp/b10.nft.flush.log 2>&1 || true
  nft delete table inet adms >/tmp/b10.nft.delete.log 2>&1 || true
) & FAILSAFE_PID=$!

adms_log "Injecting identity drift (expect direct LOCKDOWN)"
adms_inject_dim_terminal I
sleep 2
curl -fsS --max-time "$ADMS_HTTP_TIMEOUT" "$ADMS_BASE_URL/posture" >/tmp/b10.posture.lock 2>/dev/null || true
cat /tmp/b10.posture.lock || adms_log "Controller posture endpoint not reachable post-lockdown"
nft list table inet adms >/tmp/b10.nft.list 2>/dev/null || true
[[ -r /sys/fs/cgroup/user.slice/cgroup.freeze ]] && cat /sys/fs/cgroup/user.slice/cgroup.freeze || true
adms_breakglass
adms_reset_enforcement
sleep 2
curl -fsS --max-time "$ADMS_HTTP_TIMEOUT" "$ADMS_BASE_URL/posture" >/tmp/b10.posture.recovered 2>/dev/null || true
cat /tmp/b10.posture.recovered || adms_log "Controller posture endpoint still unavailable after recovery attempt"
[[ -n "${FAILSAFE_PID:-}" ]] && kill "$FAILSAFE_PID" >/dev/null 2>&1 || true
adms_log "B10 safe test complete"
