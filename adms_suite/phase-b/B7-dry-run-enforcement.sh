#!/bin/bash
# SAFETY: HOST-SAFE
# PAPER ROLE: Phase B smoke test / dry-run enforcement
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# B7-dry-run-enforcement.sh
# Tests enforcement in dry-run mode (safe — no real changes)
# Run as: sudo bash B7-dry-run-enforcement.sh
set -euo pipefail

LOG="/tmp/adms-B7.log"
echo "=== B7: Dry-Run Enforcement Test ===" | tee "$LOG"
echo "Started: $(date)" | tee -a "$LOG"

# Kill any existing controller
pkill -f adms-controller 2>/dev/null || true
sleep 2

# Start controller in dry-run
/usr/local/bin/adms-controller \
    --dry-run \
    --sensor=inject \
    --tau=1s \
    --q=5 \
    --delta=2 \
    --http=:8080 \
    --log=/var/log/adms/controller.log &
CTRL_PID=$!
sleep 3

echo "" | tee -a "$LOG"
echo "--- Starting posture ---" | tee -a "$LOG"
curl -s http://localhost:8080/posture | tee -a "$LOG"
echo "" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Injecting ΔP (expect RESTRICTED) ---" | tee -a "$LOG"
curl -s -X POST http://localhost:8080/inject -d '{"dimension": "P"}' | tee -a "$LOG"
echo "" | tee -a "$LOG"
sleep 2

echo "--- Posture after ΔP ---" | tee -a "$LOG"
curl -s http://localhost:8080/posture | tee -a "$LOG"
echo "" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Controller log ---" | tee -a "$LOG"
cat /var/log/adms/controller.log | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Break-glass reset ---" | tee -a "$LOG"
curl -s -X POST http://localhost:8080/breakglass -d '{"reason": "B7 test"}' | tee -a "$LOG"
echo "" | tee -a "$LOG"
sleep 2

echo "--- Final posture ---" | tee -a "$LOG"
curl -s http://localhost:8080/posture | tee -a "$LOG"
echo "" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Final controller log ---" | tee -a "$LOG"
cat /var/log/adms/controller.log | tee -a "$LOG"

# Export metrics
echo "" | tee -a "$LOG"
echo "--- Metrics ---" | tee -a "$LOG"
curl -s http://localhost:8080/metrics | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Clean up
kill $CTRL_PID 2>/dev/null || true
wait $CTRL_PID 2>/dev/null || true

echo "" | tee -a "$LOG"
echo "=== B7 Complete ===" | tee -a "$LOG"
echo "Full log: $LOG"
echo "Controller log: /var/log/adms/controller.log"
