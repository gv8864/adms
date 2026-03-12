#!/bin/bash
# SAFETY: HOST-SAFE
# PAPER ROLE: M3 analytical contraction proxy
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# C2-M3-contraction-proxy.sh
# Computes M3: contraction proxy C_k from enforcement profile design
# Run as: bash C2-M3-contraction-proxy.sh (no sudo needed)
set -euo pipefail

LOG="/tmp/adms-C2-M3.log"
echo "=== C2: M3 Contraction Proxy ===" | tee "$LOG"
echo "Started: $(date)" | tee -a "$LOG"

python3 - << 'PYEOF' | tee -a "$LOG"
# C_k = 1 - |T_k| / |T_0|
# T_0 = transition classes permitted under NORMAL
# T_k = transition classes permitted under posture k

# Define all transition classes available under NORMAL
normal_transitions = {
    "persistence_write":   True,  # write to systemd/cron/init
    "module_load":         True,  # insmod/finit_module
    "capability_gain":     True,  # cap escalation
    "egress_any":          True,  # outbound to any destination
    "exec_writable":       True,  # exec from /tmp, /dev/shm
    "namespace_change":    True,  # unshare, setns
    "uid_change":          True,  # setuid, setgid
    "mount_change":        True,  # mount, remount
    "rootfs_write":        True,  # write to rootfs
}

# OBSERVE: audit only, nothing blocked
observe_blocked = set()

# RESTRICTED: persistence, modules, broad egress, capabilities, mounts blocked
restricted_blocked = {
    "persistence_write",
    "module_load",
    "egress_any",
    "capability_gain",
    "mount_change",
}

# LOCKDOWN: nearly everything blocked
lockdown_blocked = {
    "persistence_write",
    "module_load",
    "egress_any",
    "capability_gain",
    "mount_change",
    "exec_writable",
    "namespace_change",
    "uid_change",
    "rootfs_write",
}

t0 = len(normal_transitions)

for level, name, blocked in [
    (1, "OBSERVE",    observe_blocked),
    (2, "RESTRICTED", restricted_blocked),
    (3, "LOCKDOWN",   lockdown_blocked),
]:
    tk = t0 - len(blocked)
    ck = 1.0 - (tk / t0)
    permitted = sorted(set(normal_transitions.keys()) - blocked)
    
    print(f"\n--- Posture {level}: {name} ---")
    print(f"  Permitted transitions ({tk}/{t0}): {', '.join(permitted)}")
    print(f"  Blocked transitions ({len(blocked)}/{t0}): {', '.join(sorted(blocked)) if blocked else '(none)'}")
    print(f"  C_{level} = 1 - {tk}/{t0} = {ck:.4f}")

print(f"\n--- Summary ---")
c1 = 1.0 - (t0 - len(observe_blocked)) / t0
c2 = 1.0 - (t0 - len(restricted_blocked)) / t0
c3 = 1.0 - (t0 - len(lockdown_blocked)) / t0
print(f"  C_1 (OBSERVE)    = {c1:.2f}")
print(f"  C_2 (RESTRICTED) = {c2:.2f}")
print(f"  C_3 (LOCKDOWN)   = {c3:.2f}")
print(f"  Monotone C_1 < C_2 < C_3: {c1 < c2 < c3}")
PYEOF

echo "" | tee -a "$LOG"
echo "=== C2 Complete ===" | tee -a "$LOG"
echo "Full log: $LOG"
