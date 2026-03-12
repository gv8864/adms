#!/bin/bash
# SAFETY: HOST-SAFE
# PAPER ROLE: M1 transition correctness
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# C1-M1-transition-correctness.sh
# Validates M1: posture transition correctness across S1-S4 + determinism n=50
# Run as: sudo bash C1-M1-transition-correctness.sh
set -euo pipefail

LOG="/tmp/adms-C1-M1.log"
echo "=== C1: M1 Transition Correctness ===" | tee "$LOG"
echo "Started: $(date)" | tee -a "$LOG"

# Kill any existing controller
pkill -f adms-controller 2>/dev/null || true
sleep 2

> /var/log/adms/controller.log

# Start controller in dry-run (testing logic, not enforcement)
/usr/local/bin/adms-controller \
    --dry-run \
    --sensor=inject \
    --tau=1s \
    --q=3 \
    --delta=1 \
    --http=:8080 \
    --log=/var/log/adms/controller.log \
    --metrics=/tmp/adms-C1-metrics.json &
CTRL_PID=$!
sleep 3

PASS=0
FAIL=0

check_posture() {
    local expected="$1"
    local label="$2"
    sleep 2
    local actual
    actual=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])" 2>/dev/null || echo "ERROR")
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $label — posture=$actual (expected $expected)" | tee -a "$LOG"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label — posture=$actual (expected $expected)" | tee -a "$LOG"
        FAIL=$((FAIL + 1))
    fi
}

reset() {
    curl -sf -X POST http://localhost:8080/breakglass -d '{"reason": "test reset"}' > /dev/null
    sleep 2
}

echo "" | tee -a "$LOG"
echo "--- S1: ΔE → OBSERVE (0→1) ---" | tee -a "$LOG"
reset
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null
check_posture 1 "S1: ΔE"

echo "" | tee -a "$LOG"
echo "--- S2: ΔE then ΔP → RESTRICTED (1→2) ---" | tee -a "$LOG"
reset
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null
sleep 2
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "P"}' > /dev/null
check_posture 2 "S2: ΔP after ΔE"

echo "" | tee -a "$LOG"
echo "--- S3: ΔE→ΔP→ΔD → LOCKDOWN (2→3) ---" | tee -a "$LOG"
reset
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null
sleep 2
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "P"}' > /dev/null
sleep 2
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "D"}' > /dev/null
check_posture 3 "S3: ΔD after ΔP"

echo "" | tee -a "$LOG"
echo "--- S4: ΔN → OBSERVE (0→1) ---" | tee -a "$LOG"
reset
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "N"}' > /dev/null
check_posture 1 "S4: ΔN"

echo "" | tee -a "$LOG"
echo "--- Precedence: ΔP∧ΔD simultaneous → LOCKDOWN ---" | tee -a "$LOG"
reset
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "P"}' > /dev/null
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "D"}' > /dev/null
check_posture 3 "Precedence: ΔP∧ΔD"

echo "" | tee -a "$LOG"
echo "--- Precedence: ΔI → direct LOCKDOWN ---" | tee -a "$LOG"
reset
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "I"}' > /dev/null
check_posture 3 "Precedence: ΔI"

echo "" | tee -a "$LOG"
echo "--- A1: Monotonic escalation (ΔP then ΔE should stay RESTRICTED) ---" | tee -a "$LOG"
reset
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "P"}' > /dev/null
sleep 2
curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null
check_posture 2 "A1: no descent on drift"

echo "" | tee -a "$LOG"
echo "--- Determinism: n=50 (ΔE should always → OBSERVE) ---" | tee -a "$LOG"
DET_FAIL=0
for i in $(seq 1 50); do
    reset
    curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null
    sleep 2
    p=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])" 2>/dev/null || echo "ERROR")
    if [ "$p" != "1" ]; then
        DET_FAIL=$((DET_FAIL + 1))
    fi
    # Progress every 10
    if [ $((i % 10)) -eq 0 ]; then
        echo "  Progress: $i/50 (failures: $DET_FAIL)" | tee -a "$LOG"
    fi
done
if [ "$DET_FAIL" -eq 0 ]; then
    echo "  PASS: 50/50 deterministic" | tee -a "$LOG"
    PASS=$((PASS + 1))
else
    echo "  FAIL: $DET_FAIL/50 non-deterministic" | tee -a "$LOG"
    FAIL=$((FAIL + 1))
fi

# Export metrics
kill $CTRL_PID 2>/dev/null || true
wait $CTRL_PID 2>/dev/null || true
sleep 2

echo "" | tee -a "$LOG"
echo "--- Controller log ---" | tee -a "$LOG"
cat /var/log/adms/controller.log | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
echo "M1 Results: $PASS passed, $FAIL failed" | tee -a "$LOG"
echo "Metrics: /tmp/adms-C1-metrics.json" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
echo "Full log: $LOG"
