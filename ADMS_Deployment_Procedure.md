# ADMS Prototype: Step-by-Step Deployment Procedure

This document walks through every step from bare hardware to running the full evaluation suite and collecting M1–M5 metrics. Each step includes verification commands so you know it worked before moving on.

The procedure has three phases: Phase A sets up a bare-metal host and validates the controller logic without any kernel-level components. Phase B adds the eBPF sensor layer and real enforcement. Phase C runs the full evaluation and collects the paper's metrics. An optional Phase D covers Kubernetes deployment.

---

## Prerequisites

**Hardware:**
- x86_64 host, 2+ cores, 4 GB RAM minimum
- Two network interfaces recommended (one for management/break-glass, one for workload testing)
- Console or IPMI access (critical for LOCKDOWN testing recovery)

**Software:**
- Ubuntu 22.04 LTS or 24.04 LTS (fresh install preferred)
- Kernel 5.15+ (Ubuntu 22.04 ships 5.15; Ubuntu 24.04 ships 6.8)

**Network:**
- SSH access on a dedicated management interface
- Outbound internet access for package installation (can be removed after setup)

---

## Phase A: Controller Logic Validation (No Root Required)

This phase installs Go, builds the controller, and runs unit tests. It validates that the state machine works correctly before touching any kernel-level components. You can run this on any Linux machine, VM, or even WSL.

### Step A1: Install Go

```bash
# Check if Go is already installed
go version 2>/dev/null && echo "Go already installed" && exit 0

# Download and install Go 1.22
wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz -O /tmp/go.tar.gz
sudo tar -C /usr/local -xzf /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
export PATH=$PATH:/usr/local/go/bin
```

**Verify:**
```bash
go version
# Expected: go version go1.22.0 linux/amd64
```

### Step A2: Extract and prepare the prototype

```bash
# Extract the tarball
tar xzf adms-prototype.tar.gz
cd adms-prototype

# Initialize Go modules
go mod tidy
```

**Verify:**
```bash
ls cmd/controller/main.go pkg/controller/controller.go
# Both files should exist
```

### Step A3: Run unit tests

This executes all 15 controller logic tests including the n=50 determinism test that validates the paper's M1 claim.

```bash
go test -v -count=1 ./pkg/controller/...
```

**Expected output (all must pass):**
```
=== RUN   TestS1_ExecutionDrift_NormalToObserve
--- PASS: TestS1_ExecutionDrift_NormalToObserve
=== RUN   TestS2_PrivilegeEscalation_ObserveToRestricted
--- PASS: TestS2_PrivilegeEscalation_ObserveToRestricted
=== RUN   TestS3_PersistenceAfterPrivilege_RestrictedToLockdown
--- PASS: TestS3_PersistenceAfterPrivilege_RestrictedToLockdown
=== RUN   TestS4_NetworkDrift_NormalToObserve
--- PASS: TestS4_NetworkDrift_NormalToObserve
=== RUN   TestPrecedence_SimultaneousPD_Lockdown
--- PASS: TestPrecedence_SimultaneousPD_Lockdown
=== RUN   TestPrecedence_IdentityDrift_DirectToLockdown
--- PASS: TestPrecedence_IdentityDrift_DirectToLockdown
=== RUN   TestPrecedence_HighestWins
--- PASS: TestPrecedence_HighestWins
=== RUN   TestMonotonicEscalation_NeverDescendOnDrift
--- PASS: TestMonotonicEscalation_NeverDescendOnDrift
=== RUN   TestAuthorizedDrift_NoEscalation
--- PASS: TestAuthorizedDrift_NoEscalation
=== RUN   TestAuthorizedDrift_PrivilegeAndPersistence_NoEscalation
--- PASS: TestAuthorizedDrift_PrivilegeAndPersistence_NoEscalation
=== RUN   TestRollback_StepwiseFromLockdown
--- PASS: TestRollback_StepwiseFromLockdown
=== RUN   TestRollback_BlockedDuringActiveDrift
--- PASS: TestRollback_BlockedDuringActiveDrift
=== RUN   TestRollback_BlockedByIdentityDrift
--- PASS: TestRollback_BlockedByIdentityDrift
=== RUN   TestHysteresis_DwellTimeRespected
--- PASS: TestHysteresis_DwellTimeRespected
=== RUN   TestBreakGlass_ForcesNormal
--- PASS: TestBreakGlass_ForcesNormal
=== RUN   TestDeterminism_SameInputSameOutput
--- PASS: TestDeterminism_SameInputSameOutput
PASS
```

**If any test fails:** Do not proceed. The controller logic must be correct before deploying enforcement.

### Step A4: Build the controller binary

```bash
make build
```

**Verify:**
```bash
./bin/adms-controller --help
# Should print flag descriptions for --tau, --q, --delta, etc.
```

### Step A5: Smoke test with manual drift injection

Start the controller in dry-run mode (no enforcement, no sensors) with fast parameters for testing:

```bash
# Terminal 1: Start controller
./bin/adms-controller \
    --dry-run \
    --sensor=inject \
    --tau=1s \
    --q=3 \
    --delta=1 \
    --http=:8080
```

```bash
# Terminal 2: Test the HTTP API

# Check starting posture
curl -s http://localhost:8080/posture | python3 -m json.tool
# Expected: {"level": 0, "name": "NORMAL"}

# Inject execution drift (ΔE)
curl -s -X POST http://localhost:8080/inject \
    -H "Content-Type: application/json" \
    -d '{"dimension": "E"}'

# Wait 2 seconds for controller tick
sleep 2

# Check posture
curl -s http://localhost:8080/posture | python3 -m json.tool
# Expected: {"level": 1, "name": "OBSERVE"}

# Inject privilege drift (ΔP)
curl -s -X POST http://localhost:8080/inject \
    -d '{"dimension": "P"}'
sleep 2

curl -s http://localhost:8080/posture | python3 -m json.tool
# Expected: {"level": 2, "name": "RESTRICTED"}

# Inject persistence drift (ΔD) — with prior ΔP, triggers LOCKDOWN
curl -s -X POST http://localhost:8080/inject \
    -d '{"dimension": "D"}'
sleep 2

curl -s http://localhost:8080/posture | python3 -m json.tool
# Expected: {"level": 3, "name": "LOCKDOWN"}

# Break-glass reset
curl -s -X POST http://localhost:8080/breakglass \
    -d '{"reason": "smoke test"}'

curl -s http://localhost:8080/posture | python3 -m json.tool
# Expected: {"level": 0, "name": "NORMAL"}

# Export metrics
curl -s http://localhost:8080/metrics | python3 -m json.tool
```

Stop the controller with Ctrl+C in Terminal 1.

**If the posture transitions match the expected values above, Phase A is complete.** The controller logic is validated and the binary works. Everything from here adds kernel-level capabilities.

---

## Phase B: Sensor Layer and Enforcement (Requires Root)

This phase installs Tetragon for eBPF-based event detection, configures the enforcement backend, sets up authorization signing keys, and installs the break-glass mechanism. All commands require root.

### Step B1: Install system dependencies

```bash
sudo apt-get update
sudo apt-get install -y \
    linux-tools-common \
    linux-tools-$(uname -r) \
    auditd \
    nftables \
    jq \
    curl \
    openssl \
    attr \
    e2fsprogs
```

**Verify:**
```bash
nft --version
auditctl --version
chattr --version 2>&1 | head -1
```

### Step B2: Verify kernel eBPF support

```bash
# Check kernel version
uname -r
# Must be 5.15 or higher

# Check BTF support (required by Tetragon)
ls /sys/kernel/btf/vmlinux
# File must exist

# Check BPF LSM is enabled
cat /boot/config-$(uname -r) | grep CONFIG_BPF_LSM
# Should show: CONFIG_BPF_LSM=y

# If BPF_LSM is not enabled, check if it's a module
cat /boot/config-$(uname -r) | grep CONFIG_BPF_SYSCALL
# Must show: CONFIG_BPF_SYSCALL=y
```

**If BTF is missing:** Install debug symbols: `sudo apt-get install linux-image-$(uname -r)-dbgsym`
**If BPF_LSM is not enabled:** You need a kernel rebuild or a newer Ubuntu version. Ubuntu 24.04 has this enabled by default.

### Step B3: Install Tetragon

```bash
# Download latest release
TETRA_VERSION=$(curl -sf https://api.github.com/repos/cilium/tetragon/releases/latest | jq -r .tag_name)
echo "Installing Tetragon $TETRA_VERSION"

curl -sLO "https://github.com/cilium/tetragon/releases/download/${TETRA_VERSION}/tetragon-linux-amd64.tar.gz"
tar xzf tetragon-linux-amd64.tar.gz

sudo install -m 755 tetragon /usr/local/bin/
sudo install -m 755 tetra /usr/local/bin/

# Clean up
rm -f tetragon-linux-amd64.tar.gz tetragon tetra
```

**Verify:**
```bash
sudo tetragon version
# Should print version info

# Quick functional test (run for 5 seconds, check it starts)
timeout 5 sudo tetragon --bpf-lib /var/lib/tetragon/bpf/ 2>&1 | head -5
# Should show startup messages without errors
```

### Step B4: Generate operator signing keys

These keys are used for authorization masking — the A(t) mechanism that prevents authorized CI/CD operations from triggering false escalations.

```bash
sudo mkdir -p /etc/adms /var/run/adms /var/log/adms

# Generate 4096-bit RSA key pair
sudo openssl genrsa -out /etc/adms/operator.key 4096
sudo openssl rsa -in /etc/adms/operator.key -pubout -out /etc/adms/operator.pub

# Restrict private key permissions
sudo chmod 600 /etc/adms/operator.key
sudo chmod 644 /etc/adms/operator.pub
```

**Verify:**
```bash
sudo openssl rsa -in /etc/adms/operator.key -check -noout
# Expected: RSA key ok

openssl rsa -pubin -in /etc/adms/operator.pub -text -noout | head -2
# Expected: Public-Key: (4096 bit)
```

### Step B5: Install the controller binary system-wide

```bash
cd ~/adms-prototype  # or wherever you extracted it
sudo make install
```

**Verify:**
```bash
which adms-controller
# Expected: /usr/local/bin/adms-controller

which adms-breakglass
# Expected: /usr/local/sbin/adms-breakglass
```

### Step B6: Install the break-glass mechanism

This is critical. You must have a way to recover from LOCKDOWN before enabling real enforcement.

```bash
# The install step already placed the script. Verify it:
sudo cat /usr/local/sbin/adms-breakglass | head -5

# Test it (safe — just verifies the script runs)
sudo adms-breakglass
# Should print "ADMS reset to NORMAL" and log to /var/log/adms/breakglass-audit.log

cat /var/log/adms/breakglass-audit.log
# Should show a timestamped BREAK-GLASS entry
```

**CRITICAL:** Before proceeding to Phase C, ensure you have at least one of these out-of-band recovery methods working:
1. Physical console access (KVM, IPMI, or direct keyboard/monitor)
2. SSH on a separate management network interface that is not affected by nftables rules
3. A second SSH session already open on the host

If you lose access during LOCKDOWN testing, you will need console access to run `adms-breakglass`.

### Step B7: Test enforcement in dry-run mode

Start the controller with enforcement logging but no actual enforcement:

```bash
sudo adms-controller \
    --dry-run \
    --sensor=inject \
    --tau=1s \
    --q=5 \
    --delta=2 \
    --http=:8080 \
    --log=/var/log/adms/controller.log &

# Give it a moment to start
sleep 2

# Inject ΔP to trigger RESTRICTED
curl -s -X POST http://localhost:8080/inject -d '{"dimension": "P"}'
sleep 2

# Check the log for dry-run enforcement actions
sudo tail -20 /var/log/adms/controller.log
# Should show: [DRY-RUN] chattr +i /etc/systemd/system
# Should show: [DRY-RUN] sysctl -w kernel.modules_disabled=1
# Should show: [DRY-RUN] nft add table inet adms
# etc.

# Reset
curl -s -X POST http://localhost:8080/breakglass -d '{"reason": "dry-run test"}'

# Stop controller
sudo pkill -f adms-controller
```

**If the dry-run log shows the expected enforcement commands, enforcement wiring is correct.** You can now enable real enforcement.

### Step B8: Test real enforcement (OBSERVE only first)

Start with OBSERVE posture only, which adds audit rules but does not block anything:

```bash
sudo adms-controller \
    --sensor=inject \
    --tau=1s \
    --q=10 \
    --delta=3 \
    --http=:8080 &

sleep 2

# Trigger OBSERVE
curl -s -X POST http://localhost:8080/inject -d '{"dimension": "E"}'
sleep 2

# Check that audit rules were added
sudo auditctl -l | grep adms
# Expected: -a always,exit -S ptrace -k adms-observe
# Expected: -a always,exit -S bpf -k adms-observe

# Reset
curl -s -X POST http://localhost:8080/breakglass -d '{"reason": "observe test"}'
sleep 2

# Verify audit rules were removed
sudo auditctl -l | grep adms
# Expected: no output (rules removed)
```

### Step B9: Test RESTRICTED enforcement

This step blocks persistence writes and restricts egress. Test carefully.

```bash
# Make sure break-glass is accessible
# Open a SECOND terminal with SSH to the same host before proceeding

# Terminal 1: Start controller
sudo adms-controller \
    --sensor=inject \
    --tau=1s \
    --q=10 \
    --delta=3 \
    --http=:8080 &

sleep 2

# Trigger RESTRICTED
curl -s -X POST http://localhost:8080/inject -d '{"dimension": "P"}'
sleep 2

# Verify: persistence loci should be immutable
touch /etc/systemd/system/test-adms 2>&1
# Expected: "Operation not permitted" (chattr +i is active)

# Verify: dynamic module loading disabled
cat /proc/sys/kernel/modules_disabled
# Expected: 1

# Verify: nftables rules active
sudo nft list table inet adms 2>/dev/null
# Expected: shows egress chain with drop policy and allow rules

# RESET IMMEDIATELY
curl -s -X POST http://localhost:8080/breakglass -d '{"reason": "restricted test"}'
sleep 2

# Verify recovery
touch /etc/systemd/system/test-adms 2>&1 && rm -f /etc/systemd/system/test-adms
# Should succeed (immutability removed)

cat /proc/sys/kernel/modules_disabled
# Expected: 0

sudo pkill -f adms-controller
```

### Step B10: Test LOCKDOWN enforcement

**WARNING:** This step will freeze processes, remount rootfs read-only, and quench egress. Have your break-glass ready.

```bash
# PREPARATION:
# 1. Open a SECOND terminal via console or separate SSH
# 2. In that terminal, prepare the break-glass command:
#    sudo adms-breakglass
# 3. Do NOT run it yet — just have it ready

# Terminal 1: Start controller
sudo adms-controller \
    --sensor=inject \
    --tau=1s \
    --q=10 \
    --delta=3 \
    --http=:8080 &

sleep 2

# Trigger LOCKDOWN via identity drift
curl -s -X POST http://localhost:8080/inject -d '{"dimension": "I"}'
sleep 3

# Check posture (may fail if egress blocked curl)
curl -s http://localhost:8080/posture 2>/dev/null || echo "HTTP blocked (expected in LOCKDOWN)"

# IMMEDIATELY execute break-glass from Terminal 2:
# sudo adms-breakglass

# Back in Terminal 1 after break-glass:
curl -s http://localhost:8080/posture | python3 -m json.tool
# Expected: {"level": 0, "name": "NORMAL"}

sudo pkill -f adms-controller
```

**If you recovered successfully, Phase B is complete.** All enforcement levels work and you can recover from any posture.

---

## Phase C: Full Evaluation (Collecting M1–M5 Metrics)

This phase runs the complete test suite that produces the paper's evaluation data.

### Step C1: Configure controller for evaluation

```bash
# Create evaluation configuration
# Use short parameters for faster testing; adjust for production-like runs
cat > /tmp/adms-eval-config.env <<'EOF'
TAU=1s
Q=60
DELTA=3
SENSOR=inject
HTTP=:8080
METRICS=/var/log/adms/eval-metrics.json
LOG=/var/log/adms/eval-controller.log
EOF
```

### Step C2: Run S1–S4 scenario suite (M1: Transition Correctness)

```bash
# Start controller with evaluation parameters
source /tmp/adms-eval-config.env
sudo adms-controller \
    --dry-run \
    --sensor=inject \
    --tau=$TAU \
    --q=3 \
    --delta=1 \
    --http=$HTTP \
    --metrics=$METRICS \
    --log=$LOG &

sleep 2

# Run the automated test suite
bash test/run-all.sh http://localhost:8080

# Stop controller and collect metrics
sudo pkill -f adms-controller
sleep 2

# Analyze results
python3 test/analyze-results.py $METRICS
```

**Expected M1 output:** All transitions correct, 50/50 deterministic.

### Step C3: Measure containment latency (M2)

Containment latency requires real sensor events, not injection. For this measurement:

```bash
# Start controller with Tetragon sensor input
# Terminal 1: Start Tetragon
sudo tetragon \
    --bpf-lib /var/lib/tetragon/bpf/ \
    --tracing-policy sensors/tetragon/policy-privilege.yaml \
    --tracing-policy sensors/tetragon/policy-persistence.yaml \
    --tracing-policy sensors/tetragon/policy-execution.yaml \
    --tracing-policy sensors/tetragon/policy-network.yaml \
    --tracing-policy sensors/tetragon/policy-identity.yaml \
    --export-stdout 2>/dev/null | \
sudo adms-controller \
    --dry-run \
    --sensor=tetragon \
    --tau=1s \
    --q=60 \
    --delta=3 \
    --http=:8080 \
    --metrics=/var/log/adms/latency-metrics.json \
    --log=/var/log/adms/latency-controller.log &

sleep 5

# Terminal 2: Trigger real drift events and record timestamps

# S1: exec from writable path
T_START=$(date +%s%N)
cp /bin/echo /tmp/adms-test-binary
chmod +x /tmp/adms-test-binary
/tmp/adms-test-binary "drift" 2>/dev/null
T_END=$(date +%s%N)
LATENCY_NS=$((T_END - T_START))
echo "S1 trigger-to-response: $((LATENCY_NS / 1000000))ms"

sleep 3

# Check posture changed
curl -s http://localhost:8080/posture
# Expected: OBSERVE

# Record more timing data by repeating across scenarios
# (reset between each with break-glass)

# Clean up
rm -f /tmp/adms-test-binary
curl -s -X POST http://localhost:8080/breakglass -d '{"reason": "latency test"}'
sleep 2
sudo pkill -f adms-controller
sudo pkill -f tetragon
```

**Expected M2 values:** L_contain in the range of 1.2–2.8s with τ=1s.

### Step C4: Compute contraction proxy (M3)

C_k is a design-time property. Compute it from the enforcement profiles:

```bash
cat <<'EOF' > /tmp/compute_ck.py
# Count transition classes permitted at each posture level
# Based on enforcement-profiles/ configuration

# NORMAL: all transitions permitted
normal_transitions = [
    "persistence_write", "module_load", "capability_gain",
    "egress_any", "exec_writable", "namespace_change",
    "uid_change", "mount_change", "rootfs_write"
]

# OBSERVE: same as NORMAL (audit only, no blocking)
observe_blocked = []

# RESTRICTED: persistence writes, module loads, broad egress blocked
restricted_blocked = [
    "persistence_write", "module_load", "egress_any",
    "capability_gain", "mount_change"
]

# LOCKDOWN: nearly everything blocked
lockdown_blocked = [
    "persistence_write", "module_load", "egress_any",
    "capability_gain", "mount_change", "exec_writable",
    "namespace_change", "uid_change", "rootfs_write"
]

t0 = len(normal_transitions)
c1 = 1.0 - (t0 - len(observe_blocked)) / t0
c2 = 1.0 - (t0 - len(restricted_blocked)) / t0
c3 = 1.0 - (t0 - len(lockdown_blocked)) / t0

print(f"C_1 (OBSERVE):    {c1:.2f}")
print(f"C_2 (RESTRICTED): {c2:.2f}")
print(f"C_3 (LOCKDOWN):   {c3:.2f}")
print(f"Monotone: C_1 < C_2 < C_3 = {c1 < c2 < c3}")
EOF

python3 /tmp/compute_ck.py
```

**Expected M3 values:** C_1 ≈ 0.00–0.12, C_2 ≈ 0.56–0.58, C_3 ≈ 0.89–1.00. The exact values depend on how you define the transition class set.

### Step C5: Measure false escalation rate (M4)

```bash
# Start controller
sudo adms-controller \
    --dry-run \
    --sensor=inject \
    --tau=1s \
    --q=60 \
    --delta=3 \
    --http=:8080 \
    --metrics=/var/log/adms/m4-metrics.json &

sleep 2

# Run 200 authorized CI/CD cycles
ESCALATIONS=0
for i in $(seq 1 200); do
    # Sign a manifest (creates authorization token)
    bash authorization/simple/sign-manifest.sh \
        deploy/kubernetes/workloads.yaml 60 2>/dev/null

    # Inject drift that resembles CI/CD activity
    # (execution context change + persistence write)
    curl -s -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null

    sleep 2

    # Check posture
    POSTURE=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])")
    if [ "$POSTURE" != "0" ]; then
        ESCALATIONS=$((ESCALATIONS + 1))
    fi

    # Clean up token
    sudo rm -f /var/run/adms/auth-token.json /var/run/adms/auth-token.sig

    # Progress indicator
    if [ $((i % 50)) -eq 0 ]; then
        echo "  Completed $i/200 cycles ($ESCALATIONS false escalations so far)"
    fi
done

echo "M4 Result: $ESCALATIONS/200 false escalations"

# Also test with expired token (should escalate)
echo "Testing with expired token..."
bash authorization/simple/sign-manifest.sh deploy/kubernetes/workloads.yaml 1
sleep 3  # wait for token to expire
curl -s -X POST http://localhost:8080/inject -d '{"dimension": "E"}' > /dev/null
sleep 2
POSTURE=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])")
echo "Expired token test: posture=$POSTURE (expected: >0)"

# Clean up
curl -s -X POST http://localhost:8080/breakglass -d '{"reason": "m4 test"}' > /dev/null
sudo pkill -f adms-controller
```

**Expected M4 values:** 0/200 false escalations with correct tokens; 1/1 escalation with expired token.

### Step C6: Measure rollback time (M5)

```bash
# Start controller with measurable parameters
sudo adms-controller \
    --dry-run \
    --sensor=inject \
    --tau=1s \
    --q=60 \
    --delta=3 \
    --http=:8080 \
    --metrics=/var/log/adms/m5-metrics.json &

sleep 2

# Escalate to LOCKDOWN
curl -s -X POST http://localhost:8080/inject -d '{"dimension": "I"}' > /dev/null
sleep 2

echo "Posture: $(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")"
echo "Starting rollback timer..."

T_START=$(date +%s)

# Wait for rollback: 3 steps × (q=60 + δ=3) seconds each ≈ 189 seconds
# Poll every 10 seconds
while true; do
    LEVEL=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])")
    NAME=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
    ELAPSED=$(($(date +%s) - T_START))
    echo "  t+${ELAPSED}s: posture=$NAME ($LEVEL)"

    if [ "$LEVEL" = "0" ]; then
        echo "Rollback complete at t+${ELAPSED}s"
        break
    fi

    if [ "$ELAPSED" -gt 600 ]; then
        echo "Timeout — rollback did not complete in 10 minutes"
        break
    fi

    sleep 10
done

sudo pkill -f adms-controller
```

**Expected M5 values:** L_rollback ≈ 189s (3.15 min) with q=60, δ=3.
You should see stepwise transitions: LOCKDOWN → RESTRICTED → OBSERVE → NORMAL.

### Step C7: Parameter sensitivity sweep

```bash
echo "Parameter sweep: varying q and δ"
echo "================================="

for Q_VAL in 30 60 120 300; do
    for D_VAL in 1 3 5; do
        echo ""
        echo "--- q=$Q_VAL, δ=$D_VAL ---"

        sudo adms-controller \
            --dry-run \
            --sensor=inject \
            --tau=1s \
            --q=$Q_VAL \
            --delta=$D_VAL \
            --http=:8080 \
            --metrics="/var/log/adms/sweep-q${Q_VAL}-d${D_VAL}.json" &

        sleep 2

        # Escalate to LOCKDOWN
        curl -s -X POST http://localhost:8080/inject -d '{"dimension": "I"}' > /dev/null
        sleep 2

        T_START=$(date +%s)

        # Wait for full rollback
        while true; do
            LEVEL=$(curl -sf http://localhost:8080/posture | python3 -c "import sys,json; print(json.load(sys.stdin)['level'])" 2>/dev/null)
            ELAPSED=$(($(date +%s) - T_START))

            if [ "$LEVEL" = "0" ]; then
                echo "  L_rollback = ${ELAPSED}s"
                break
            fi
            if [ "$ELAPSED" -gt 1200 ]; then
                echo "  L_rollback > 1200s (timeout)"
                break
            fi
            sleep 5
        done

        sudo pkill -f adms-controller
        sleep 2
    done
done
```

### Step C8: Collect and analyze all results

```bash
echo "Collecting all metrics files..."
ls -la /var/log/adms/*.json

echo ""
echo "=== Evaluation Summary ==="
for f in /var/log/adms/eval-metrics.json \
         /var/log/adms/m4-metrics.json \
         /var/log/adms/m5-metrics.json; do
    if [ -f "$f" ]; then
        echo ""
        echo "--- $(basename $f) ---"
        python3 test/analyze-results.py "$f"
    fi
done
```

---

## Phase D: Kubernetes Deployment (Optional)

### Step D1: Install k3s

```bash
curl -sfL https://get.k3s.io | sh -

# Verify
sudo kubectl get nodes
# Should show one Ready node
```

### Step D2: Install Tetragon via Helm

```bash
# Install Helm if not present
curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Add Cilium repo and install Tetragon
helm repo add cilium https://helm.cilium.io
helm repo update
helm install tetragon cilium/tetragon -n kube-system --set tetragon.grpc.enabled=true

# Verify
kubectl get pods -n kube-system | grep tetragon
# Should show tetragon pods running
```

### Step D3: Apply Tetragon tracing policies

```bash
kubectl apply -f sensors/tetragon/policy-privilege.yaml
kubectl apply -f sensors/tetragon/policy-persistence.yaml
kubectl apply -f sensors/tetragon/policy-execution.yaml
kubectl apply -f sensors/tetragon/policy-network.yaml
kubectl apply -f sensors/tetragon/policy-identity.yaml

# Verify
kubectl get tracingpolicies
# Should list all 5 policies
```

### Step D4: Build and load controller image

```bash
# Build Docker image
make docker

# For k3s: import directly
sudo k3s ctr images import <(docker save adms-controller:latest)

# Verify
sudo k3s crictl images | grep adms
```

### Step D5: Create operator key secret

```bash
kubectl create namespace adms-test

kubectl create secret generic adms-operator-keys \
    --from-file=operator.pub=/etc/adms/operator.pub \
    -n adms-test
```

### Step D6: Deploy workloads and controller

```bash
kubectl apply -f deploy/kubernetes/workloads.yaml
kubectl apply -f deploy/kubernetes/controller-deploy.yaml

# Wait for pods
kubectl get pods -n adms-test -w
# Wait until all pods show Running

# Port-forward controller API
kubectl port-forward -n adms-test daemonset/adms-controller 8080:8080 &
```

### Step D7: Run tests against Kubernetes deployment

```bash
# Same test suite works against K8s
bash test/run-all.sh http://localhost:8080
```

---

## Troubleshooting

**Controller won't start:**
- Check Go version: `go version` (need 1.22+)
- Check if port 8080 is in use: `ss -tlnp | grep 8080`
- Try a different port: `--http=:9090`

**Tetragon won't start:**
- Check kernel BTF: `ls /sys/kernel/btf/vmlinux`
- Check BPF support: `bpftool feature probe kernel`
- Try with verbose logging: `sudo tetragon --log-level=debug`

**LOCKDOWN locked you out:**
- Use console/IPMI access
- Run: `sudo /usr/local/sbin/adms-breakglass`
- If break-glass script is inaccessible, manually run:
  ```bash
  nft delete table inet adms 2>/dev/null
  mount -o remount,rw /
  echo 0 > /sys/fs/cgroup/user.slice/cgroup.freeze 2>/dev/null
  sysctl -w kernel.modules_disabled=0
  for p in /etc/systemd/system /etc/cron.d /etc/init.d /lib/modules; do
      chattr -i "$p" 2>/dev/null
  done
  ```

**False escalations during authorized operations:**
- Check token hasn't expired: `cat /var/run/adms/auth-token.json | jq .expires_at`
- Check pubkey matches: verify the signing key and verification key are a pair
- Check controller can read the token directory: permissions on /var/run/adms/

**Sensor not detecting drift events:**
- Check Tetragon is running: `pgrep tetragon`
- Check tracing policies loaded: `sudo tetra tracingpolicy list`
- Test manually: run a drift trigger and check `sudo tetra getevents`

---

## Evaluation Checklist

Before reporting results, verify all of the following:

- [ ] Unit tests pass (15/15) including n=50 determinism
- [ ] S1: ΔE → OBSERVE confirmed
- [ ] S2: ΔP → RESTRICTED confirmed
- [ ] S3: ΔD after ΔP → LOCKDOWN confirmed
- [ ] S4: ΔN → OBSERVE confirmed
- [ ] Precedence: simultaneous ΔP∧ΔD → LOCKDOWN confirmed
- [ ] Precedence: ΔI → direct LOCKDOWN confirmed
- [ ] A1: monotonic escalation verified (no descent on drift)
- [ ] Authorization masking: authorized drift does not escalate
- [ ] Rollback: stepwise LOCKDOWN→RESTRICTED→OBSERVE→NORMAL
- [ ] Rollback blocked during active drift
- [ ] Rollback blocked when I(t)≠0
- [ ] Hysteresis: dwell time δ respected
- [ ] Break-glass: forces NORMAL from any state
- [ ] M1: 50/50 deterministic transitions
- [ ] M2: L_contain measured (range and median)
- [ ] M3: C_k computed (C_1 < C_2 < C_3)
- [ ] M4: 0% false escalation with correct tokens
- [ ] M4: 100% escalation with expired tokens
- [ ] M5: L_rollback measured at multiple (q,δ) settings
- [ ] M5: all rollback steps verified as stepwise
- [ ] Parameter sensitivity sweep completed
- [ ] All metrics exported to JSON
