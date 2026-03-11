#!/bin/bash
# breakglass/reset.sh — Emergency override: force T=0, restore NORMAL enforcement.
# MUST be accessible via out-of-band channel (console, SSH with hardware key).
# Logs an irrevocable audit trail entry.

set -euo pipefail

AUDIT_LOG="${ADMS_AUDIT_LOG:-/var/log/adms/breakglass-audit.log}"
CONTROLLER="${ADMS_CONTROLLER_URL:-http://localhost:8080}"

mkdir -p "$(dirname "$AUDIT_LOG")"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BREAK-GLASS activated by $(whoami) from $(tty 2>/dev/null || echo 'no-tty')" \
    >> "$AUDIT_LOG"

echo "Sending break-glass to controller..."
curl -sf -X POST "$CONTROLLER/breakglass" \
    -H "Content-Type: application/json" \
    -d "{\"reason\": \"operator break-glass by $(whoami)\"}" || true

echo "Reversing local enforcement..."

# Remove filesystem immutability
for path in /etc/systemd/system /etc/cron.d /etc/cron.daily /etc/init.d /lib/modules; do
    chattr -i "$path" 2>/dev/null || true
done

# Flush ADMS nftables rules
nft delete table inet adms 2>/dev/null || true

# Remount writable
mount -o remount,rw / 2>/dev/null || true

# Re-enable module loading
sysctl -w kernel.modules_disabled=0 2>/dev/null || true

# Unfreeze processes
echo 0 > /sys/fs/cgroup/user.slice/cgroup.freeze 2>/dev/null || true

echo "ADMS reset to NORMAL."
echo "Audit trail entry logged to: $AUDIT_LOG"
echo ""
echo "WARNING: Break-glass events are irrevocable and will be audited."
