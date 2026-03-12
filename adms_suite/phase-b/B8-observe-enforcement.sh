#!/bin/bash
# SAFETY: HOST-SAFE
# PAPER ROLE: Phase B OBSERVE enforcement
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# B8-observe-enforcement.sh
# Tests OBSERVE posture with real audit rules (safe — no blocking)
# Run as: sudo bash B8-observe-enforcement.sh
set -euo pipefail

LOG="/tmp/adms-B8.log"
echo "=== B8: OBSERVE Enforcement Test ===" | tee "$LOG"
echo "Started: $(date)" | tee -a "$LOG"

# Kill any existing controller
pkill -f adms-controller 2>/dev/null || true
sleep 2

# Clear old controller log
> /var/log/adms/controller.log

# Start controller with REAL enforcement (not dry-run)
/usr/local/bin/adms-controller \
    --sensor=inject \
    --tau=1s \
    --q=10 \
    --delta=3 \
    --http=:8080 \
    --log=/var/log/adms/controller.log &
CTRL_PID=$!
sleep 3

echo "" | tee -a "$LOG"
echo "--- Starting posture ---" | tee -a "$LOG"
curl -s http://localhost:8080/posture | tee -a "$LOG"
echo "" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Audit rules BEFORE (should have no adms rules) ---" | tee -a "$LOG"
auditctl -l 2>&1 | grep adms | tee -a "$LOG" || echo "(none)" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Injecting ΔE (expect OBSERVE) ---" | tee -a "$LOG"
curl -s -X POST http://localhost:8080/inject -d '{"dimension": "E"}' | tee -a "$LOG"
echo "" | tee -a "$LOG"
sleep 2

echo "--- Posture after ΔE ---" | tee -a "$LOG"
curl -s http://localhost:8080/posture | tee -a "$LOG"
echo "" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Audit rules AFTER (should have adms-observe rules) ---" | tee -a "$LOG"
auditctl -l 2>&1 | grep adms | tee -a "$LOG" || echo "(none — PROBLEM)" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Break-glass reset ---" | tee -a "$LOG"
curl -s -X POST http://localhost:8080/breakglass -d '{"reason": "B8 test"}' | tee -a "$LOG"
echo "" | tee -a "$LOG"
sleep 2

echo "" | tee -a "$LOG"
echo "--- Audit rules AFTER RESET (should have no adms rules) ---" | tee -a "$LOG"
auditctl -l 2>&1 | grep adms | tee -a "$LOG" || echo "(none — correct)" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Controller log ---" | tee -a "$LOG"
cat /var/log/adms/controller.log | tee -a "$LOG"

# Clean up
kill $CTRL_PID 2>/dev/null || true
wait $CTRL_PID 2>/dev/null || true

echo "" | tee -a "$LOG"
echo "=== B8 Complete ===" | tee -a "$LOG"
echo "Full log: $LOG"
