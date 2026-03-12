#!/bin/bash
# SAFETY: HOST-SAFE
# PAPER ROLE: Parameter sensitivity sweep
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# C5-parameter-sweep.sh
# Measures rollback time across different (q, δ) parameter combinations
# Run as: sudo bash C5-parameter-sweep.sh
set -euo pipefail

LOG="/tmp/adms-C5-sweep.log"
echo "=== C5: Parameter Sensitivity Sweep ===" | tee "$LOG"
echo "Started: $(date)" | tee -a "$LOG"

# Kill any existing controller
pkill -f adms-controller 2>/dev/null || true
sleep 2

# Use smaller values so the sweep finishes in reasonable time
# Full paper values (q=60,300) would take 10+ minutes per run
Q_VALUES="5 10 20 30"
D_VALUES="1 3 5"

echo "" | tee -a "$LOG"
echo "Sweep: q ∈ {$Q_VALUES}, δ ∈ {$D_VALUES}" | tee -a "$LOG"
echo "-------------------------------------------" | tee -a "$LOG"
printf "%-8s %-8s %-15s %-10s\n" "q" "δ" "L_rollback(s)" "Flapping" | tee -a "$LOG"
echo "-------------------------------------------" | tee -a "$LOG"

for Q_VAL in $Q_VALUES; do
    for D_VAL in $D_VALUES; do
        pkill -f adms-controller 2>/dev/null || true
        sleep 2
        > /var/log/adms/controller.log

        /usr/local/bin/adms-controller \
            --dry-run \
            --sensor=inject \
            --tau=1s \
            --q=$Q_VAL \
            --delta=$D_VAL \
            --http=:8080 \
            --log=/var/log/adms/controller.log \
            --metrics="/tmp/adms-sweep-q${Q_VAL}-d${D_VAL}.json" &
        CTRL_PID=$!
        sleep 3

        # Escalate to LOCKDOWN
        curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "I"}' > /dev/null
        sleep 2

        # Measure rollback time
        T_START=$(date +%s)
        TIMEOUT=$((3 * (Q_VAL + D_VAL) * 2 + 30))  # generous timeout

        while true; do
            LEVEL=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])" 2>/dev/null || echo "ERROR")
            ELAPSED=$(($(date +%s) - T_START))

            if [ "$LEVEL" = "0" ]; then
                break
            fi
            if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
                ELAPSED="TIMEOUT"
                break
            fi
            sleep 2
        done

        L_ROLLBACK="$ELAPSED"

        # Count flapping events (rapid back-and-forth transitions)
        FLAP_COUNT=$(grep -c "ROLLBACK\|ESCALATE" /var/log/adms/controller.log 2>/dev/null || echo "0")
        # Expected: 1 escalate + 3 rollbacks = 4 transitions. More = flapping.
        if [ "$FLAP_COUNT" -gt 5 ]; then
            FLAPPING="YES($FLAP_COUNT)"
        else
            FLAPPING="NO($FLAP_COUNT)"
        fi

        printf "%-8s %-8s %-15s %-10s\n" "$Q_VAL" "$D_VAL" "$L_ROLLBACK" "$FLAPPING" | tee -a "$LOG"

        kill $CTRL_PID 2>/dev/null || true
        wait $CTRL_PID 2>/dev/null || true
    done
done

echo "-------------------------------------------" | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "Expected pattern:" | tee -a "$LOG"
echo "  - L_rollback increases with q (more quiet time per step)" | tee -a "$LOG"
echo "  - L_rollback increases with δ (more dwell time per step)" | tee -a "$LOG"
echo "  - No flapping at δ≥3" | tee -a "$LOG"
echo "  - L_rollback ≈ 3 × (q + δ) seconds" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "=== C5 Complete ===" | tee -a "$LOG"
echo "Full log: $LOG"
