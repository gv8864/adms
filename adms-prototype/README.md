# ADMS Prototype

Implementation of Autonomous Defensive Maneuver Systems (ADMS) as described in
*Integrity Boundary Theory and Autonomous Defensive Maneuver Systems: Toward
Deterministic Runtime Trust Regulation*.

## Hardware and Software Requirements

### Bare-metal host
- **CPU:** Any x86_64, 2+ cores (eBPF overhead is sub-percent)
- **RAM:** 2 GB minimum (controller uses <256 MB)
- **OS:** Ubuntu 22.04+ or Debian 12+
- **Kernel:** 5.15+ (for BPF LSM and ringbuf support)
- **Kernel config:** `CONFIG_BPF_LSM=y`, `CONFIG_BPF_SYSCALL=y`, `CONFIG_DEBUG_INFO_BTF=y`

### Kubernetes node
- Same kernel requirements as bare-metal
- k3s, kind, or kubeadm (single-node sufficient for prototype)
- Helm 3.x (for Tetragon installation)

### Software dependencies
- Go 1.22+
- Tetragon (eBPF sensor layer)
- nftables (egress enforcement)
- OpenSSL (authorization key generation)
- Optional: SPIRE (production-grade workload identity)

## Quick Start (Bare Metal)

```bash
# 1. Install everything
sudo bash deploy/bare-metal/install.sh

# 2. Start controller (dry-run mode first)
adms-controller --dry-run --sensor=inject --tau=1s --q=3 --delta=1 &

# 3. Check posture
curl http://localhost:8080/posture

# 4. Inject test drift
curl -X POST http://localhost:8080/inject -d '{"dimension":"E"}'
curl http://localhost:8080/posture   # should show OBSERVE

# 5. Run full test suite
bash test/run-all.sh

# 6. View metrics
curl http://localhost:8080/metrics | jq .summary
```

## Quick Start (Kubernetes)

```bash
# 1. Build and deploy
make setup-k8s

# 2. Check
kubectl get pods -n adms-test
kubectl port-forward -n adms-test daemonset/adms-controller 8080:8080

# 3. Test
curl http://localhost:8080/posture
bash test/run-all.sh
```

## Architecture

```
┌──────────────────────────────────────────────────┐
│                  Sensor Layer                     │
│  Tetragon eBPF policies → drift events            │
│  (ΔI, ΔP, ΔD, ΔE, ΔN)                           │
└──────────────┬───────────────────────────────────┘
               │ JSON events (stdin pipe)
               ▼
┌──────────────────────────────────────────────────┐
│              Event Collector                      │
│  Classifies events → per-interval DriftVector     │
│  DrainInterval() returns B(t) each τ              │
└──────────────┬───────────────────────────────────┘
               │ B(t), A(t)
               ▼
┌──────────────────────────────────────────────────┐
│           Posture Controller                      │
│  T(t+1) = f(T(t), B̃(t))                          │
│  Eqs 10-13, precedence, rollback (q, δ)           │
│  Monotonic escalation (A1)                        │
└──────────────┬───────────────────────────────────┘
               │ posture level
               ▼
┌──────────────────────────────────────────────────┐
│          Enforcement Layer                        │
│  NORMAL:     baseline seccomp, open egress        │
│  OBSERVE:    audit high-risk syscalls             │
│  RESTRICTED: immutable persistence, cap bound,    │
│              egress allow-list, no module loads    │
│  LOCKDOWN:   quench egress, ro rootfs, freeze     │
└──────────────────────────────────────────────────┘
```

## Controller Parameters

| Parameter | Flag      | Default | Description                              |
|-----------|-----------|---------|------------------------------------------|
| τ         | `--tau`   | 1s      | Controller sampling interval             |
| q         | `--q`     | 60      | Quiet intervals for rollback eligibility |
| δ         | `--delta` | 3       | Minimum dwell before de-escalation       |

## HTTP API

| Endpoint        | Method | Description                          |
|-----------------|--------|--------------------------------------|
| `/posture`      | GET    | Current posture level and name       |
| `/metrics`      | GET    | Full M1-M5 metrics export (JSON)     |
| `/breakglass`   | POST   | Emergency override → NORMAL          |
| `/inject`       | POST   | Manual drift injection (testing)     |

## Testing

```bash
make test-unit          # Go unit tests (n=50 determinism)
make test-integration   # Full scenario suite with live controller
```

## Break-Glass

In case of emergency (e.g., LOCKDOWN blocking legitimate operations):

```bash
sudo adms-breakglass
```

This forces T=0, reverses all enforcement, and logs an irrevocable audit entry.
Always have out-of-band access (console, hardware-key SSH) before testing
RESTRICTED or LOCKDOWN enforcement.

## Project Structure

```
cmd/controller/       Main entrypoint
pkg/controller/       Core state machine, transition rules, metrics
pkg/signals/          Drift vectors, authorization masking
pkg/enforcement/      Linux enforcement backend
pkg/sensors/          Tetragon event reader and classifier
sensors/tetragon/     TracingPolicy YAMLs for 5 drift dimensions
enforcement-profiles/ Seccomp JSON, NetworkPolicy YAML
authorization/        Token signing and verification
test/                 Scenario scripts and results analysis
deploy/               Bare-metal and Kubernetes deployment
breakglass/           Emergency override mechanism
```
