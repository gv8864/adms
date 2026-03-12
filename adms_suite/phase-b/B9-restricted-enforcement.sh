#!/bin/bash
# SAFETY: DISPOSABLE-VM PREFERRED
# PAPER ROLE: Phase B RESTRICTED enforcement
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# B9-restricted-enforcement.sh
# Tests RESTRICTED posture with real enforcement
# WARNING: This blocks persistence writes and restricts egress
# Run as: sudo bash B9-restricted-enforcement.sh
set -euo pipefail

LOG="/tmp/adms-B9.log"
echo "=== B9: RESTRICTED Enforcement Test ===" | tee "$LOG"
echo "Started: $(date)" | tee -a "$LOG"
echo "WARNING: This applies real enforcement. Break-glass is automatic." | tee -a "$LOG"

# Kill any existing controller
pkill -f adms-controller 2>/dev/null || true
sleep 2

# Clear old controller log
> /var/log/adms/controller.log

# Start controller with REAL enforcement
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
echo "--- Injecting ΔP (expect RESTRICTED) ---" | tee -a "$LOG"
curl -s -X POST http://localhost:8080/inject -d '{"dimension": "P"}' | tee -a "$LOG"
echo "" | tee -a "$LOG"
sleep 2

echo "--- Posture after ΔP ---" | tee -a "$LOG"
curl -s http://localhost:8080/posture | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Wait for enforcement to fully apply (controller tick + enforcement execution)
sleep 4

echo "" | tee -a "$LOG"
echo "--- Verify enforcement applied ---" | tee -a "$LOG"
lsattr -d /etc/systemd/system 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- TEST 1: Persistence loci should be immutable ---" | tee -a "$LOG"
if touch /etc/systemd/system/test-adms 2>&1; then
    echo "FAIL: write to persistence locus succeeded (should be blocked)" | tee -a "$LOG"
    rm -f /etc/systemd/system/test-adms 2>/dev/null || true
else
    echo "PASS: write blocked by chattr +i" | tee -a "$LOG"
fi

echo "" | tee -a "$LOG"
echo "--- TEST 2: Module loading should be disabled ---" | tee -a "$LOG"
MODULES_DISABLED=$(cat /proc/sys/kernel/modules_disabled 2>/dev/null || echo "N/A")
echo "kernel.modules_disabled = $MODULES_DISABLED" | tee -a "$LOG"
if [ "$MODULES_DISABLED" = "1" ]; then
    echo "PASS: module loading disabled" | tee -a "$LOG"
else
    echo "INFO: modules_disabled not set (may require reboot to re-enable)" | tee -a "$LOG"
fi

echo "" | tee -a "$LOG"
echo "--- TEST 3: nftables rules should be active ---" | tee -a "$LOG"
nft list table inet adms 2>&1 | tee -a "$LOG" || echo "INFO: nft table not found" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- RESETTING via break-glass ---" | tee -a "$LOG"
curl -s -X POST http://localhost:8080/breakglass -d '{"reason": "B9 test"}' | tee -a "$LOG"
echo "" | tee -a "$LOG"
sleep 3

echo "" | tee -a "$LOG"
echo "--- VERIFY RECOVERY ---" | tee -a "$LOG"

echo "Test write after reset:" | tee -a "$LOG"
if touch /etc/systemd/system/test-adms 2>&1; then
    echo "PASS: write access restored" | tee -a "$LOG"
    rm -f /etc/systemd/system/test-adms
else
    echo "WARN: write still blocked — manual chattr -i may be needed" | tee -a "$LOG"
fi

MODULES_DISABLED=$(cat /proc/sys/kernel/modules_disabled 2>/dev/null || echo "N/A")
echo "kernel.modules_disabled after reset = $MODULES_DISABLED" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Controller log ---" | tee -a "$LOG"
cat /var/log/adms/controller.log | tee -a "$LOG"

# Clean up
kill $CTRL_PID 2>/dev/null || true
wait $CTRL_PID 2>/dev/null || true

echo "" | tee -a "$LOG"
echo "=== B9 Complete ===" | tee -a "$LOG"
echo "Full log: $LOG"
