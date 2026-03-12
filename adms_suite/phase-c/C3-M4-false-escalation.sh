#!/bin/bash
# SAFETY: HOST-SAFE
# PAPER ROLE: M4 false escalation rate
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# C3-M4-false-escalation.sh
# Measures M4: false escalation rate during authorized operations
# Run as: sudo bash C3-M4-false-escalation.sh
set -euo pipefail

LOG="/tmp/adms-C3-M4.log"
echo "=== C3: M4 False Escalation Rate ===" | tee "$LOG"
echo "Started: $(date)" | tee -a "$LOG"

CYCLES=200

# Kill any existing controller
pkill -f adms-controller 2>/dev/null || true
sleep 2

> /var/log/adms/controller.log

# Generate operator keys if not present
if [ ! -f /etc/adms/operator.key ]; then
    echo "Generating operator keys..." | tee -a "$LOG"
    mkdir -p /etc/adms /var/run/adms
    openssl genrsa -out /etc/adms/operator.key 4096 2>/dev/null
    openssl rsa -in /etc/adms/operator.key -pubout -out /etc/adms/operator.pub 2>/dev/null
    chmod 600 /etc/adms/operator.key
fi

# Start controller with authorization enabled
/usr/local/bin/adms-controller \
    --dry-run \
    --sensor=inject \
    --tau=1s \
    --q=60 \
    --delta=3 \
    --http=:8080 \
    --pubkey=/etc/adms/operator.pub \
    --token-dir=/var/run/adms \
    --log=/var/log/adms/controller.log \
    --metrics=/tmp/adms-C3-metrics.json &
CTRL_PID=$!
sleep 3

echo "" | tee -a "$LOG"
echo "--- Part 1: $CYCLES authorized CI/CD cycles ---" | tee -a "$LOG"

ESCALATIONS=0
for i in $(seq 1 $CYCLES); do
    # Create signed authorization token (TTL=60s)
    EXPIRY=$(($(date +%s) + 60))
    cat > /var/run/adms/auth-token.json <<TOKEOF
{
    "manifest_hash": "test-hash-$i",
    "issued_at": $(date +%s),
    "expires_at": $EXPIRY,
    "workload_id": "cicd-test",
    "deployment_intent": "cycle-$i"
}
TOKEOF
    openssl dgst -sha256 -sign /etc/adms/operator.key \
        -out /var/run/adms/auth-token.sig \
        /var/run/adms/auth-token.json 2>/dev/null

    # Inject drift (should be masked by authorization)
    curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null
    sleep 2

    # Check posture
    POSTURE=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])" 2>/dev/null || echo "ERROR")
    if [ "$POSTURE" != "0" ]; then
        ESCALATIONS=$((ESCALATIONS + 1))
        echo "  ESCALATION at cycle $i: posture=$POSTURE" | tee -a "$LOG"
        # Reset for next cycle
        curl -sf -X POST http://localhost:8080/breakglass -d '{"reason": "false escalation reset"}' > /dev/null
        sleep 2
    fi

    # Clean up token
    rm -f /var/run/adms/auth-token.json /var/run/adms/auth-token.sig

    # Progress
    if [ $((i % 50)) -eq 0 ]; then
        echo "  Progress: $i/$CYCLES (false escalations: $ESCALATIONS)" | tee -a "$LOG"
    fi
done

RATE=$(python3 -c "print(f'{$ESCALATIONS/$CYCLES*100:.1f}')")
echo "" | tee -a "$LOG"
echo "Part 1 Result: $ESCALATIONS/$CYCLES false escalations ($RATE%)" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Part 2: Expired token (should escalate) ---" | tee -a "$LOG"

# Create a token that expires in 1 second
EXPIRY=$(($(date +%s) + 1))
cat > /var/run/adms/auth-token.json <<TOKEOF
{
    "manifest_hash": "expired-test",
    "issued_at": $(date +%s),
    "expires_at": $EXPIRY,
    "workload_id": "cicd-test",
    "deployment_intent": "expired-cycle"
}
TOKEOF
openssl dgst -sha256 -sign /etc/adms/operator.key \
    -out /var/run/adms/auth-token.sig \
    /var/run/adms/auth-token.json 2>/dev/null

echo "  Waiting 3s for token to expire..." | tee -a "$LOG"
sleep 3

curl -sf -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null
sleep 2

POSTURE=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])" 2>/dev/null || echo "ERROR")
if [ "$POSTURE" != "0" ]; then
    echo "  PASS: Expired token caused escalation (posture=$POSTURE)" | tee -a "$LOG"
else
    echo "  FAIL: Expired token did NOT cause escalation" | tee -a "$LOG"
fi

# Clean up
rm -f /var/run/adms/auth-token.json /var/run/adms/auth-token.sig
curl -sf -X POST http://localhost:8080/breakglass -d '{"reason": "M4 test complete"}' > /dev/null

echo "" | tee -a "$LOG"
echo "--- Controller log ---" | tee -a "$LOG"
cat /var/log/adms/controller.log | tee -a "$LOG"

kill $CTRL_PID 2>/dev/null || true
wait $CTRL_PID 2>/dev/null || true

echo "" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
echo "M4 Results:" | tee -a "$LOG"
echo "  Authorized cycles: $ESCALATIONS/$CYCLES false escalations" | tee -a "$LOG"
echo "  Expired token: posture=$POSTURE (should be >0)" | tee -a "$LOG"
echo "  Metrics: /tmp/adms-C3-metrics.json" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
echo "Full log: $LOG"
