# ADMS Prototype Lab Architecture Guide

## Overview

This guide provides a complete architecture for implementing the Autonomous Defensive Maneuver Systems (ADMS) prototype described in the paper. The prototype validates controller semantics, enforcement feasibility, and the five evaluation metrics (M1–M5).

---

## Repository Structure

```
adms-prototype/
├── cmd/
│   └── controller/
│       └── main.go                  # Controller entrypoint
├── pkg/
│   ├── controller/
│   │   ├── controller.go            # Core posture state machine
│   │   ├── controller_test.go       # Unit tests (transition correctness)
│   │   ├── transition.go            # Transition rules (eqs 10–13)
│   │   └── rollback.go              # Rollback logic (q, δ tracking)
│   ├── signals/
│   │   ├── drift.go                 # B(t) drift vector types
│   │   ├── authorization.go         # A(t) mask computation
│   │   └── effective.go             # B̃(t) = B(t) ∧ ¬A(t)
│   ├── enforcement/
│   │   ├── enforcement.go           # Posture-to-control mapping interface
│   │   ├── seccomp.go               # Seccomp profile switching
│   │   ├── capabilities.go          # Capability bounding
│   │   ├── network.go               # Egress policy (iptables/nftables)
│   │   ├── filesystem.go            # Mount/write restrictions
│   │   └── process.go               # Process freeze/kill (LOCKDOWN)
│   └── metrics/
│       ├── latency.go               # L_contain measurement
│       ├── contraction.go           # C_k computation
│       └── prometheus.go            # Optional: expose metrics
├── sensors/
│   ├── tetragon/
│   │   ├── policy-privilege.yaml    # TracingPolicy for ΔP
│   │   ├── policy-persistence.yaml  # TracingPolicy for ΔD
│   │   ├── policy-execution.yaml    # TracingPolicy for ΔE
│   │   ├── policy-network.yaml      # TracingPolicy for ΔN
│   │   └── policy-identity.yaml     # TracingPolicy for ΔI
│   └── raw-ebpf/                    # Alternative: raw eBPF programs
│       ├── priv_escalation.bpf.c
│       ├── persistence_write.bpf.c
│       ├── exec_context.bpf.c
│       ├── network_egress.bpf.c
│       └── identity_drift.bpf.c
├── enforcement-profiles/
│   ├── seccomp-normal.json
│   ├── seccomp-observe.json
│   ├── seccomp-restricted.json
│   ├── seccomp-lockdown.json
│   ├── netpolicy-normal.yaml        # Cilium/K8s NetworkPolicy
│   ├── netpolicy-observe.yaml
│   ├── netpolicy-restricted.yaml
│   └── netpolicy-lockdown.yaml
├── authorization/
│   ├── spire/
│   │   ├── server.conf              # SPIRE server config
│   │   └── agent.conf               # SPIRE agent config
│   └── simple/
│       ├── sign-manifest.sh         # Sign deployment intent
│       └── verify-token.go          # Validate A(t) at drift time
├── test/
│   ├── scenarios/
│   │   ├── s1-foothold.sh           # Trigger ΔE
│   │   ├── s2-privilege.sh          # Trigger ΔP
│   │   ├── s3-persistence.sh        # Trigger ΔD (after ΔP)
│   │   ├── s4-egress.sh             # Trigger ΔN
│   │   └── authorized-cicd.sh       # 200 authorized rollout cycles
│   ├── run-all.sh                   # Execute S1–S4 + authorized ops
│   └── analyze-results.py           # Compute M1–M5 from logs
├── deploy/
│   ├── bare-metal/
│   │   └── install.sh               # Bare-metal setup
│   └── kubernetes/
│       ├── workloads.yaml           # nginx, batch job, CI/CD pod
│       ├── controller-deploy.yaml   # Controller DaemonSet
│       └── tetragon-values.yaml     # Helm values for Tetragon
├── breakglass/
│   └── reset.sh                     # Force T=0, log audit trail
├── go.mod
├── go.sum
└── Makefile
```

---

## Component 1: Sensor Layer

### Option A: Tetragon (recommended)

Tetragon provides structured eBPF-based event streams that map directly to the five drift dimensions.

**ΔP — Privilege escalation detection:**

```yaml
# sensors/tetragon/policy-privilege.yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: adms-privilege-drift
spec:
  kprobes:
    # Detect capability changes
    - call: "cap_capable"
      syscall: false
      args:
        - index: 0
          type: "nop"    # cred
        - index: 1
          type: "int"    # ns (unused)
        - index: 2
          type: "int"    # cap
      selectors:
        - matchActions:
            - action: Post
              rateLimit: "1m"
    # Detect UID transitions (user -> root)
    - call: "commit_creds"
      syscall: false
      args:
        - index: 0
          type: "cred"
      selectors:
        - matchArgs:
            - index: 0
              operator: "Equal"
              values: ["0"]   # uid=0
          matchActions:
            - action: Post
```

**ΔD — Persistence write detection:**

```yaml
# sensors/tetragon/policy-persistence.yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: adms-persistence-drift
spec:
  kprobes:
    - call: "security_file_open"
      syscall: false
      args:
        - index: 0
          type: "file"
      selectors:
        - matchArgs:
            - index: 0
              operator: "Prefix"
              values:
                - "/etc/systemd/system"
                - "/etc/cron.d"
                - "/etc/cron.daily"
                - "/etc/init.d"
                - "/lib/modules"
                - "/usr/lib/systemd/system"
          matchActions:
            - action: Post
```

**ΔE — Execution context violation:**

```yaml
# sensors/tetragon/policy-execution.yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: adms-execution-drift
spec:
  tracepoints:
    - subsystem: "sched"
      event: "sched_process_exec"
      args:
        - index: 4
          type: "string"    # filename
      selectors:
        # Exec from writable paths
        - matchArgs:
            - index: 4
              operator: "Prefix"
              values:
                - "/tmp"
                - "/dev/shm"
                - "/var/tmp"
                - "/run"
          matchActions:
            - action: Post
  kprobes:
    # Detect namespace escape attempts
    - call: "security_task_setns"
      syscall: false
      selectors:
        - matchActions:
            - action: Post
```

**ΔN — Network egress expansion:**

```yaml
# sensors/tetragon/policy-network.yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: adms-network-drift
spec:
  kprobes:
    - call: "tcp_connect"
      syscall: false
      args:
        - index: 0
          type: "sock"
      selectors:
        # Alert on connections outside allowed destinations
        - matchArgs:
            - index: 0
              operator: "NotDAddr"
              values:
                - "10.0.0.0/8"        # Internal network
                - "172.16.0.0/12"     # Adjust to your allow-list
          matchActions:
            - action: Post
```

**ΔI — Identity drift detection:**

```yaml
# sensors/tetragon/policy-identity.yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: adms-identity-drift
spec:
  kprobes:
    # Detect unsigned binary execution via IMA
    - call: "ima_file_check"
      syscall: false
      args:
        - index: 0
          type: "file"
      selectors:
        - matchActions:
            - action: Post
```

For ΔI, you will also need a userspace component that checks IMA measurement logs or validates image signatures at exec time. Tetragon gives you the exec event; the identity verification logic runs in the controller or a sidecar.

### Option B: Raw eBPF (if you need more control)

Use libbpf-based programs attached to LSM hooks. This gives finer control but requires more engineering:

```c
// sensors/raw-ebpf/priv_escalation.bpf.c
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

struct drift_event {
    __u64 timestamp_ns;
    __u32 pid;
    __u32 uid_before;
    __u32 uid_after;
    __u8  dimension;      // 0=I, 1=P, 2=D, 3=E, 4=N
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} drift_events SEC(".maps");

SEC("lsm/cred_prepare")
int BPF_PROG(detect_priv_escalation,
             struct cred *new, const struct cred *old, gfp_t gfp)
{
    // Check if uid changed to 0 (root)
    if (old->uid.val != 0 && new->uid.val == 0) {
        struct drift_event *evt;
        evt = bpf_ringbuf_reserve(&drift_events,
                                   sizeof(*evt), 0);
        if (!evt) return 0;

        evt->timestamp_ns = bpf_ktime_get_ns();
        evt->pid = bpf_get_current_pid_tgid() >> 32;
        evt->uid_before = old->uid.val;
        evt->uid_after = new->uid.val;
        evt->dimension = 1;  // P

        bpf_ringbuf_submit(evt, 0);
    }
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
```

---

## Component 2: Controller

The controller is the core state machine. It runs as a loop every τ seconds.

```go
// pkg/controller/controller.go
package controller

import (
    "sync"
    "time"
)

// Posture levels
const (
    NORMAL     = 0
    OBSERVE    = 1
    RESTRICTED = 2
    LOCKDOWN   = 3
)

// DriftVector represents B(t) = (ΔI, ΔP, ΔD, ΔE, ΔN)
type DriftVector struct {
    Identity   bool
    Privilege  bool
    Durability bool
    Execution  bool
    Network    bool
}

func (d DriftVector) IsZero() bool {
    return !d.Identity && !d.Privilege && !d.Durability &&
           !d.Execution && !d.Network
}

// Controller implements the ADMS posture state machine
type Controller struct {
    mu sync.Mutex

    // Current state
    posture       int
    quietCounter  int   // consecutive intervals with B̃(t)=0 and I(t)=0
    dwellCounter  int   // intervals spent in current posture

    // Parameters
    tau           time.Duration  // controller interval (τ)
    q             int            // quiet interval for rollback eligibility
    delta         int            // minimum dwell time before de-escalation

    // Tracking for combined triggers
    priorPrivilege bool          // tracks whether ΔP has been seen

    // Enforcement interface
    enforcer      Enforcer

    // Metrics
    lastDriftTime time.Time
    metrics       *Metrics
}

type Enforcer interface {
    ApplyPosture(level int) error
}

type Metrics struct {
    ContainmentLatencies []time.Duration
    TransitionLog        []TransitionRecord
}

type TransitionRecord struct {
    Timestamp time.Time
    From      int
    To        int
    Drift     DriftVector
    Masked    bool
}

func New(tau time.Duration, q, delta int, enforcer Enforcer) *Controller {
    return &Controller{
        posture:  NORMAL,
        tau:      tau,
        q:        q,
        delta:    delta,
        enforcer: enforcer,
        metrics:  &Metrics{},
    }
}
```

**Transition function (equations 10–13 with precedence):**

```go
// pkg/controller/transition.go
package controller

import "time"

// Tick processes one controller interval.
// raw is the raw drift B(t); authorized indicates A(t).
func (c *Controller) Tick(raw DriftVector, authorized bool) {
    c.mu.Lock()
    defer c.mu.Unlock()

    // Compute effective drift: B̃(t) = B(t) ∧ ¬A(t)
    var effective DriftVector
    if !authorized {
        effective = raw
    }
    // If authorized, effective is all-zero (masked)

    prevPosture := c.posture
    c.dwellCounter++

    if !effective.IsZero() {
        // --- ESCALATION (highest-severity-wins precedence) ---
        c.quietCounter = 0
        now := time.Now()

        // Track cumulative privilege for ΔP∧ΔD rule
        if effective.Privilege {
            c.priorPrivilege = true
        }

        newPosture := c.posture

        // Rule precedence: LOCKDOWN triggers checked first
        // Eq 10: ΔI → LOCKDOWN
        if effective.Identity {
            newPosture = LOCKDOWN
        }
        // Eq 11: ΔP ∧ ΔD → LOCKDOWN
        if effective.Privilege && effective.Durability {
            newPosture = LOCKDOWN
        }
        // Also: prior ΔP + current ΔD → LOCKDOWN
        if c.priorPrivilege && effective.Durability {
            newPosture = LOCKDOWN
        }

        // Eq 12: ΔP → RESTRICTED (if not already LOCKDOWN)
        if effective.Privilege && newPosture < RESTRICTED {
            newPosture = RESTRICTED
        }

        // Eq 13: ΔE → max(T(t), OBSERVE)
        if effective.Execution && newPosture < OBSERVE {
            newPosture = OBSERVE
        }

        // ΔN → max(T(t), OBSERVE)
        if effective.Network && newPosture < OBSERVE {
            newPosture = OBSERVE
        }

        // A1: Monotonic escalation — never go below current
        if newPosture < c.posture {
            newPosture = c.posture
        }

        if newPosture != c.posture {
            c.metrics.ContainmentLatencies = append(
                c.metrics.ContainmentLatencies,
                now.Sub(c.lastDriftTime),
            )
            c.transition(newPosture, effective, false)
        }

        c.lastDriftTime = now
    } else {
        // --- QUIESCENT: check rollback eligibility ---
        // Identity must also be stable (I(t)=0)
        // (raw.Identity indicates drift regardless of authorization)
        if !raw.Identity {
            c.quietCounter++
        } else {
            c.quietCounter = 0
        }

        // Rollback: stepwise, requires q quiet + δ dwell
        if c.posture > NORMAL &&
            c.quietCounter >= c.q &&
            c.dwellCounter >= c.delta {
            c.transition(c.posture-1, effective, false)
            c.quietCounter = 0 // reset for next step
        }
    }
}

func (c *Controller) transition(newPosture int, drift DriftVector, masked bool) {
    record := TransitionRecord{
        Timestamp: time.Now(),
        From:      c.posture,
        To:        newPosture,
        Drift:     drift,
        Masked:    masked,
    }
    c.metrics.TransitionLog = append(c.metrics.TransitionLog, record)

    c.posture = newPosture
    c.dwellCounter = 0

    // Apply enforcement atomically
    if err := c.enforcer.ApplyPosture(newPosture); err != nil {
        // Log but don't change posture back — fail-safe stays escalated
        // In production: alert on enforcement failure
    }
}

func (c *Controller) Posture() int {
    c.mu.Lock()
    defer c.mu.Unlock()
    return c.posture
}
```

---

## Component 3: Enforcement Profiles

**Seccomp profiles per posture:**

```json
// enforcement-profiles/seccomp-normal.json
{
    "defaultAction": "SCMP_ACT_ALLOW",
    "syscalls": [
        {
            "names": ["kexec_load", "kexec_file_load"],
            "action": "SCMP_ACT_ERRNO"
        }
    ]
}
```

```json
// enforcement-profiles/seccomp-restricted.json
{
    "defaultAction": "SCMP_ACT_ALLOW",
    "syscalls": [
        {
            "names": [
                "ptrace", "bpf", "init_module", "finit_module",
                "delete_module", "kexec_load", "kexec_file_load",
                "mount", "umount2", "pivot_root", "unshare"
            ],
            "action": "SCMP_ACT_ERRNO"
        }
    ]
}
```

```json
// enforcement-profiles/seccomp-lockdown.json
{
    "defaultAction": "SCMP_ACT_ERRNO",
    "syscalls": [
        {
            "names": [
                "read", "write", "close", "fstat", "lseek",
                "mmap", "mprotect", "munmap", "brk",
                "rt_sigaction", "rt_sigprocmask", "ioctl",
                "exit", "exit_group", "getpid", "getuid",
                "clock_gettime", "nanosleep", "futex",
                "epoll_wait", "epoll_ctl",
                "socket", "connect", "sendto", "recvfrom",
                "poll", "select"
            ],
            "action": "SCMP_ACT_ALLOW"
        }
    ]
}
```

**Kubernetes NetworkPolicy per posture:**

```yaml
# enforcement-profiles/netpolicy-restricted.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: adms-restricted
spec:
  podSelector:
    matchLabels:
      adms-posture: restricted
  policyTypes:
    - Egress
  egress:
    # Allow only DNS and controller/attestation channel
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
    - to:
        - ipBlock:
            cidr: 10.0.1.0/24    # Controller/attestation subnet
      ports:
        - protocol: TCP
          port: 8443
```

```yaml
# enforcement-profiles/netpolicy-lockdown.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: adms-lockdown
spec:
  podSelector:
    matchLabels:
      adms-posture: lockdown
  policyTypes:
    - Egress
  egress:
    # Only allow controller attestation channel
    - to:
        - ipBlock:
            cidr: 10.0.1.1/32    # Controller only
      ports:
        - protocol: TCP
          port: 8443
```

**Enforcement switching implementation:**

```go
// pkg/enforcement/enforcement.go
package enforcement

import (
    "fmt"
    "os/exec"
)

type LinuxEnforcer struct {
    seccompProfiles map[int]string    // posture -> profile path
    egressRulesets  map[int]string    // posture -> nftables ruleset
    persistenceLoci []string          // paths to protect
    targetPID       int               // workload PID (bare-metal)
}

func NewLinuxEnforcer() *LinuxEnforcer {
    return &LinuxEnforcer{
        seccompProfiles: map[int]string{
            0: "enforcement-profiles/seccomp-normal.json",
            1: "enforcement-profiles/seccomp-observe.json",
            2: "enforcement-profiles/seccomp-restricted.json",
            3: "enforcement-profiles/seccomp-lockdown.json",
        },
        persistenceLoci: []string{
            "/etc/systemd/system",
            "/etc/cron.d",
            "/etc/cron.daily",
            "/etc/init.d",
            "/lib/modules",
        },
    }
}

func (e *LinuxEnforcer) ApplyPosture(level int) error {
    switch level {
    case 0: // NORMAL
        return e.applyNormal()
    case 1: // OBSERVE
        return e.applyObserve()
    case 2: // RESTRICTED
        return e.applyRestricted()
    case 3: // LOCKDOWN
        return e.applyLockdown()
    }
    return fmt.Errorf("unknown posture level: %d", level)
}

func (e *LinuxEnforcer) applyRestricted() error {
    // 1. Tighten capabilities
    exec.Command("capsh", "--drop=cap_sys_admin,cap_net_raw,cap_sys_ptrace").Run()

    // 2. Block persistence writes (make loci immutable)
    for _, path := range e.persistenceLoci {
        exec.Command("chattr", "+i", path).Run()
    }

    // 3. Block dynamic module loading
    exec.Command("sysctl", "-w", "kernel.modules_disabled=1").Run()

    // 4. Restrict egress via nftables
    exec.Command("nft", "-f", "enforcement-profiles/nft-restricted.conf").Run()

    return nil
}

func (e *LinuxEnforcer) applyLockdown() error {
    // 1. Quench egress (except controller channel)
    exec.Command("nft", "-f", "enforcement-profiles/nft-lockdown.conf").Run()

    // 2. Remount rootfs read-only
    exec.Command("mount", "-o", "remount,ro", "/").Run()

    // 3. Freeze non-essential processes
    // (In production: use cgroup freezer; here simplified)
    exec.Command("killall", "-STOP", "-u", "www-data").Run()

    return nil
}

func (e *LinuxEnforcer) applyNormal() error {
    // Reverse all restrictions
    for _, path := range e.persistenceLoci {
        exec.Command("chattr", "-i", path).Run()
    }
    exec.Command("nft", "-f", "enforcement-profiles/nft-normal.conf").Run()
    exec.Command("mount", "-o", "remount,rw", "/").Run()
    return nil
}

func (e *LinuxEnforcer) applyObserve() error {
    // Increase audit verbosity only; no blocking
    exec.Command("auditctl", "-a", "always,exit",
        "-F", "arch=b64", "-S", "ptrace", "-S", "bpf",
        "-k", "adms-observe").Run()
    return nil
}
```

---

## Component 4: Authorization Masking

### Simple approach (file-based signing)

```bash
#!/bin/bash
# authorization/simple/sign-manifest.sh
# Called by CI/CD pipeline before deployment

MANIFEST="$1"
TTL_SECONDS="${2:-300}"  # 5-minute default

EXPIRY=$(date -d "+${TTL_SECONDS} seconds" +%s)

# Create authorization token
cat > /var/run/adms/auth-token.json <<EOF
{
    "manifest_hash": "$(sha256sum $MANIFEST | cut -d' ' -f1)",
    "issued_at": $(date +%s),
    "expires_at": $EXPIRY,
    "workload_id": "$(hostname)",
    "deployment_intent": "$MANIFEST"
}
EOF

# Sign with operator key
openssl dgst -sha256 -sign /etc/adms/operator.key \
    -out /var/run/adms/auth-token.sig \
    /var/run/adms/auth-token.json

echo "Authorization token issued, expires in ${TTL_SECONDS}s"
```

**Controller-side A(t) verification:**

```go
// authorization/simple/verify-token.go
package authorization

import (
    "crypto"
    "crypto/rsa"
    "crypto/sha256"
    "crypto/x509"
    "encoding/json"
    "encoding/pem"
    "os"
    "time"
)

type AuthToken struct {
    ManifestHash   string `json:"manifest_hash"`
    IssuedAt       int64  `json:"issued_at"`
    ExpiresAt      int64  `json:"expires_at"`
    WorkloadID     string `json:"workload_id"`
    DeploymentIntent string `json:"deployment_intent"`
}

func IsAuthorized(tokenPath, sigPath, pubkeyPath string) bool {
    // 1. Read and parse token
    tokenBytes, err := os.ReadFile(tokenPath)
    if err != nil {
        return false
    }

    var token AuthToken
    if err := json.Unmarshal(tokenBytes, &token); err != nil {
        return false
    }

    // 2. Check TTL
    if time.Now().Unix() > token.ExpiresAt {
        return false // expired
    }

    // 3. Verify signature
    sigBytes, err := os.ReadFile(sigPath)
    if err != nil {
        return false
    }

    pubkeyBytes, err := os.ReadFile(pubkeyPath)
    if err != nil {
        return false
    }

    block, _ := pem.Decode(pubkeyBytes)
    pubkey, err := x509.ParsePKIXPublicKey(block.Bytes)
    if err != nil {
        return false
    }

    hash := sha256.Sum256(tokenBytes)
    err = rsa.VerifyPKCS1v15(pubkey.(*rsa.PublicKey), crypto.SHA256,
                              hash[:], sigBytes)
    return err == nil
}
```

### SPIRE approach (production-grade)

For production use, deploy SPIRE to issue workload SVIDs:

```bash
# authorization/spire/setup.sh

# Install SPIRE server
kubectl apply -f https://raw.githubusercontent.com/spiffe/spire/main/support/k8s/spire-server.yaml

# Install SPIRE agent (DaemonSet)
kubectl apply -f https://raw.githubusercontent.com/spiffe/spire/main/support/k8s/spire-agent.yaml

# Register the ADMS controller workload
kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
    -spiffeID spiffe://adms.local/controller \
    -parentID spiffe://adms.local/agent \
    -selector k8s:pod-label:app=adms-controller

# Register CI/CD workloads that need A(t)=1
kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
    -spiffeID spiffe://adms.local/cicd-deployer \
    -parentID spiffe://adms.local/agent \
    -selector k8s:sa:cicd-deployer \
    -ttl 300   # 5-minute SVIDs
```

---

## Component 5: Test Scenarios

```bash
#!/bin/bash
# test/scenarios/s1-foothold.sh
# S1: Induce ΔE=1 via exec from writable path
# Expected: T: 0 → 1 (OBSERVE)

echo "[S1] Triggering execution-context drift..."

# Copy a binary to a writable tmpfs and execute it
cp /bin/echo /tmp/suspicious-binary
chmod +x /tmp/suspicious-binary
/tmp/suspicious-binary "drift triggered"

# Record timestamp for latency measurement
echo "$(date +%s%N)" > /tmp/adms-s1-trigger-time
```

```bash
#!/bin/bash
# test/scenarios/s2-privilege.sh
# S2: Induce ΔP=1 via capability gain
# Expected: T: 1 → 2 (RESTRICTED)

echo "[S2] Triggering privilege drift..."

# Attempt privilege escalation via unshare (requires CAP_SYS_ADMIN)
unshare --user --map-root-user whoami 2>/dev/null

# Alternative: use capsh to request forbidden capability
capsh --addamb=cap_sys_admin -- -c "id" 2>/dev/null

echo "$(date +%s%N)" > /tmp/adms-s2-trigger-time
```

```bash
#!/bin/bash
# test/scenarios/s3-persistence.sh
# S3: Induce ΔD=1 after prior ΔP
# Expected: T: 2 → 3 (LOCKDOWN) because ΔP∧ΔD

echo "[S3] Triggering persistence drift..."

# Attempt to write a systemd unit (should be caught by sensor)
cat > /etc/systemd/system/adms-test-persistence.service <<EOF 2>/dev/null
[Unit]
Description=ADMS Test Persistence

[Service]
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF

echo "$(date +%s%N)" > /tmp/adms-s3-trigger-time
```

```bash
#!/bin/bash
# test/scenarios/s4-egress.sh
# S4: Induce ΔN=1 via unauthorized outbound connection
# Expected: OBSERVE escalation; constrained under RESTRICTED/LOCKDOWN

echo "[S4] Triggering network drift..."

# Attempt connection to external IP outside allow-list
curl -s --connect-timeout 2 http://198.51.100.1:8080 2>/dev/null

echo "$(date +%s%N)" > /tmp/adms-s4-trigger-time
```

```bash
#!/bin/bash
# test/scenarios/authorized-cicd.sh
# Run 200 authorized CI/CD cycles; verify no false escalations

CYCLES=200
ESCALATIONS=0

for i in $(seq 1 $CYCLES); do
    # Issue authorization token
    bash authorization/simple/sign-manifest.sh deploy/kubernetes/workloads.yaml 60

    # Perform drift-like operations (image swap, restart)
    kubectl rollout restart deployment/nginx-test 2>/dev/null
    sleep 5

    # Check controller posture
    POSTURE=$(curl -s http://localhost:8080/posture | jq -r '.level')
    if [ "$POSTURE" != "0" ]; then
        ESCALATIONS=$((ESCALATIONS + 1))
        echo "  [FAIL] Cycle $i: unexpected escalation to $POSTURE"
    fi

    # Clean up token
    rm -f /var/run/adms/auth-token.json /var/run/adms/auth-token.sig
done

echo "Authorized CI/CD test: $ESCALATIONS/$CYCLES false escalations"
```

---

## Component 6: Results Analysis

```python
#!/usr/bin/env python3
# test/analyze-results.py
"""Compute M1–M5 metrics from controller logs."""

import json
import sys
from statistics import median

def load_log(path):
    with open(path) as f:
        return json.load(f)

def m1_transition_correctness(log):
    """M1: Verify all transitions match expected rules."""
    expected = {
        "S1": (0, 1),   # NORMAL -> OBSERVE
        "S2": (1, 2),   # OBSERVE -> RESTRICTED
        "S3": (2, 3),   # RESTRICTED -> LOCKDOWN
        "S4_from_normal": (0, 1),  # NORMAL -> OBSERVE
    }
    correct = 0
    total = 0
    for entry in log["transitions"]:
        scenario = entry.get("scenario")
        if scenario in expected:
            total += 1
            actual = (entry["from"], entry["to"])
            if actual == expected[scenario]:
                correct += 1
            else:
                print(f"  MISMATCH {scenario}: expected {expected[scenario]}, got {actual}")
    print(f"M1: {correct}/{total} transitions correct")
    return correct == total

def m2_containment_latency(log):
    """M2: Compute L_contain statistics."""
    latencies = [e["latency_ms"] for e in log["transitions"]
                 if e.get("latency_ms")]
    if not latencies:
        print("M2: No latency data")
        return
    print(f"M2: L_contain range: {min(latencies):.1f}ms – {max(latencies):.1f}ms")
    print(f"    Median: {median(latencies):.1f}ms")

def m3_contraction_proxy(enforcement_config):
    """M3: Compute C_k from enforcement profiles."""
    # Count transition classes permitted at each posture
    normal_transitions = enforcement_config["normal_permitted"]
    t0 = len(normal_transitions)

    for level, name in [(1, "OBSERVE"), (2, "RESTRICTED"), (3, "LOCKDOWN")]:
        tk = len(enforcement_config[f"level_{level}_permitted"])
        ck = 1.0 - (tk / t0)
        print(f"M3: C_{level} ({name}) = {ck:.2f}")

def m4_false_escalation(log):
    """M4: Count escalations during authorized operations."""
    authorized_ops = [e for e in log["transitions"] if e.get("authorized")]
    false_esc = [e for e in authorized_ops if e["to"] > e["from"]]
    total = len(authorized_ops) if authorized_ops else log.get("authorized_cycles", 200)
    rate = len(false_esc) / max(total, 1) * 100
    print(f"M4: {len(false_esc)}/{total} false escalations ({rate:.1f}%)")

def m5_recovery(log):
    """M5: Measure rollback time and verify stepwise behavior."""
    rollbacks = [e for e in log["transitions"] if e["to"] < e["from"]]
    for r in rollbacks:
        step = r["from"] - r["to"]
        if step != 1:
            print(f"  WARNING: non-stepwise rollback {r['from']} -> {r['to']}")
    if "rollback_total_ms" in log:
        print(f"M5: L_rollback = {log['rollback_total_ms']/1000:.1f}s")
    print(f"    {len(rollbacks)} rollback steps, all stepwise: "
          f"{all(r['from']-r['to']==1 for r in rollbacks)}")

if __name__ == "__main__":
    log = load_log(sys.argv[1])
    m1_transition_correctness(log)
    m2_containment_latency(log)
    m4_false_escalation(log)
    m5_recovery(log)
```

---

## Setup Sequence

### Bare-metal host

```bash
# 1. Prerequisites (Ubuntu 22.04+, kernel 5.15+)
sudo apt update
sudo apt install -y linux-tools-common linux-tools-$(uname -r) \
    auditd nftables jq openssl

# 2. Install Go 1.21+
wget https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# 3. Install Tetragon standalone
curl -LO https://github.com/cilium/tetragon/releases/latest/download/tetragon-linux-amd64.tar.gz
tar xzf tetragon-linux-amd64.tar.gz
sudo cp tetragon /usr/local/bin/

# 4. Generate operator signing keys
mkdir -p /etc/adms
openssl genrsa -out /etc/adms/operator.key 4096
openssl rsa -in /etc/adms/operator.key -pubout -out /etc/adms/operator.pub

# 5. Build and start controller
cd adms-prototype
go build -o bin/adms-controller ./cmd/controller/
sudo bin/adms-controller --tau=1s --q=60 --delta=3

# 6. Apply Tetragon policies
sudo tetragon --bpf-lib /usr/local/lib/tetragon/bpf/ \
    --tracing-policy sensors/tetragon/policy-privilege.yaml \
    --tracing-policy sensors/tetragon/policy-persistence.yaml \
    --tracing-policy sensors/tetragon/policy-execution.yaml \
    --tracing-policy sensors/tetragon/policy-network.yaml

# 7. Set up break-glass (CRITICAL: do this before testing LOCKDOWN)
cp breakglass/reset.sh /usr/local/sbin/adms-breakglass
chmod 700 /usr/local/sbin/adms-breakglass
```

### Kubernetes (k3s single-node)

```bash
# 1. Install k3s
curl -sfL https://get.k3s.io | sh -

# 2. Install Tetragon via Helm
helm repo add cilium https://helm.cilium.io
helm install tetragon cilium/tetragon -n kube-system \
    -f deploy/kubernetes/tetragon-values.yaml

# 3. Apply Tetragon tracing policies
kubectl apply -f sensors/tetragon/

# 4. Deploy test workloads
kubectl apply -f deploy/kubernetes/workloads.yaml

# 5. Deploy ADMS controller as DaemonSet
kubectl apply -f deploy/kubernetes/controller-deploy.yaml

# 6. Run test suite
bash test/run-all.sh | tee results.log
python3 test/analyze-results.py results.json
```

---

## Break-Glass Mechanism

```bash
#!/bin/bash
# breakglass/reset.sh
# Emergency override: force T=0, restore all enforcement to NORMAL
# MUST be accessible via out-of-band channel (console, SSH with hardware key)

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BREAK-GLASS activated by $(whoami)" \
    >> /var/log/adms/breakglass-audit.log

# Force controller to NORMAL
curl -X POST http://localhost:8080/breakglass \
    -H "Content-Type: application/json" \
    -d '{"force_posture": 0, "reason": "operator break-glass"}'

# Reverse all enforcement
nft -f enforcement-profiles/nft-normal.conf
for path in /etc/systemd/system /etc/cron.d /etc/cron.daily /etc/init.d /lib/modules; do
    chattr -i "$path" 2>/dev/null
done
mount -o remount,rw / 2>/dev/null
sysctl -w kernel.modules_disabled=0 2>/dev/null

echo "ADMS reset to NORMAL. Audit trail logged."
```

---

## Effort Estimate

| Component | Effort | Notes |
|-----------|--------|-------|
| Sensor layer (Tetragon) | 3–5 days | Policy writing + tuning false positives |
| Sensor layer (raw eBPF) | 2–3 weeks | Significantly more work; use Tetragon |
| Controller | 2–3 days | Core logic is straightforward |
| Enforcement profiles | 2–3 days | Seccomp + network policy + FS restrictions |
| Authorization masking | 2–3 days | Simple signing; 1 week if using SPIRE |
| Test scenarios | 1–2 days | Script writing + validation |
| Integration + debugging | 3–5 days | Getting all pieces working together |
| **Total (Tetragon path)** | **2–3 weeks** | |

The most common failure modes in practice: eBPF sensors producing false positives on legitimate operations (tune selectors carefully), enforcement locking you out of your own test host (always have break-glass ready before testing RESTRICTED/LOCKDOWN), and authorization token timing races during fast CI/CD cycles (set TTL generously during development).
