#!/bin/bash
# SAFETY: HOST-SAFE
# PAPER ROLE: M5 rollback and liveness
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# C4-M5-rollback.sh
# Measures M5: rollback time L_rollback and verifies stepwise behavior
# Run as: sudo bash C4-M5-rollback.sh
set -euo pipefail

LOG="/tmp/adms-C4-M5.log"
echo "=== C4: M5 Recovery and Liveness ===" | tee "$LOG"
echo "Started: $(date)" | tee -a "$LOG"

# Kill any existing controller
pkill -f adms-controller 2>/dev/null || true
sleep 2

> /var/log/adms/controller.log

# Use short parameters so rollback completes in reasonable time
# q=10, delta=2: each rollback step takes ~12s, total ~36s
Q_VAL=10
D_VAL=2

echo "Parameters: q=$Q_VAL, delta=$D_VAL" | tee -a "$LOG"
echo "Expected L_rollback: ~$((3 * (Q_VAL + D_VAL)))s" | tee -a "$LOG"

/usr/local/bin/adms-controller \
    --dry-run \
    --sensor=inject \
    --tau=1s \
    --q=$Q_VAL \
    --delta=$D_VAL \
    --http=:8080 \
    --log=/var/log/adms/controller.log \
    --metrics=/tmp/adms-C4-metrics.json &
CTRL_PID=$!
sleep 3

echo "" | tee -a "$LOG"
echo "--- Escalating to LOCKDOWN via ΔI ---" | tee -a "$LOG"
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "I"}' > /dev/null
sleep 2

POSTURE=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])" 2>/dev/null)
echo "Posture after ΔI: $POSTURE" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Waiting for rollback (no further drift) ---" | tee -a "$LOG"
T_START=$(date +%s)

while true; do
    LEVEL=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])" 2>/dev/null || echo "ERROR")
    NAME=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])" 2>/dev/null || echo "ERROR")
    ELAPSED=$(($(date +%s) - T_START))
    echo "  t+${ELAPSED}s: posture=$NAME ($LEVEL)" | tee -a "$LOG"

    if [ "$LEVEL" = "0" ]; then
        echo "" | tee -a "$LOG"
        echo "Rollback complete at t+${ELAPSED}s" | tee -a "$LOG"
        break
    fi

    if [ "$ELAPSED" -gt 300 ]; then
        echo "" | tee -a "$LOG"
        echo "TIMEOUT: rollback did not complete in 300s" | tee -a "$LOG"
        break
    fi

    sleep 5
done

echo "" | tee -a "$LOG"
echo "--- TEST: Rollback blocked during active drift ---" | tee -a "$LOG"
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null
sleep 2

echo "Injected ΔE, posture: $(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")" | tee -a "$LOG"

# Keep injecting drift — rollback should not happen
for i in $(seq 1 5); do
    curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null
    sleep 3
done

POSTURE=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])" 2>/dev/null)
echo "After continuous drift: posture=$POSTURE (should still be OBSERVE, not NORMAL)" | tee -a "$LOG"
if [ "$POSTURE" != "NORMAL" ]; then
    echo "PASS: rollback blocked during active drift" | tee -a "$LOG"
else
    echo "FAIL: rollback occurred during active drift" | tee -a "$LOG"
fi

# Reset
curl -sf -X POST http://localhost:8080/breakglass -d '{"reason": "M5 test complete"}' > /dev/null

echo "" | tee -a "$LOG"
echo "--- Controller log (rollback steps visible) ---" | tee -a "$LOG"
cat /var/log/adms/controller.log | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Verify all rollbacks are stepwise ---" | tee -a "$LOG"
ROLLBACKS=$(grep "ROLLBACK" /var/log/adms/controller.log || true)
echo "$ROLLBACKS" | tee -a "$LOG"

NON_STEPWISE=$(echo "$ROLLBACKS" | grep -v "LOCKDOWN→RESTRICTED\|RESTRICTED→OBSERVE\|OBSERVE→NORMAL" | grep "ROLLBACK" || true)
if [ -z "$NON_STEPWISE" ]; then
    echo "PASS: all rollback steps are stepwise (one level at a time)" | tee -a "$LOG"
else
    echo "FAIL: non-stepwise rollback detected:" | tee -a "$LOG"
    echo "$NON_STEPWISE" | tee -a "$LOG"
fi

kill $CTRL_PID 2>/dev/null || true
wait $CTRL_PID 2>/dev/null || true

echo "" | tee -a "$LOG"
echo "=== C4 Complete ===" | tee -a "$LOG"
echo "Full log: $LOG"
