# ADMS Evaluation Suite (Reorganized)

This archive reorganizes the submitted ADMS scripts into paper-facing tests, support runners, and archived variants.

## Layout

- `phase-b/` — implementation and enforcement demonstrations
- `phase-c/` — paper-facing evaluation scripts mapped to metrics M1–M5
- `runners/` — convenience wrappers
- `lib/` — shared helper skeleton for future refactoring

## Canonical scripts

### Phase B: Enforcement / implementation demonstrations

| Script | Purpose | Notes |
|---|---|---|
| `B7-dry-run-enforcement.sh` | Safe smoke test for controller, inject, break-glass | Host-safe starting point |
| `B8-observe-enforcement.sh` | OBSERVE posture behavior | Requires environment support for audit tooling |
| `B9-restricted-enforcement.sh` | RESTRICTED enforcement checks | Disposable VM preferred |
| `B10-lockdown-enforcement.sh` | LOCKDOWN enforcement with watchdog / recovery | Canonical B10; destructive path |
| `B11-maneuver-space-contraction.sh` | Empirical contraction proxy and posture progression | Canonical B11 |

### Phase C: Paper-facing evaluation

| Script | Metric / claim | Purpose |
|---|---|---|
| `C1-M1-transition-correctness.sh` | M1 | Deterministic posture transition correctness |
| `C2-M3-contraction-proxy.sh` | M3 | Analytical / model-derived contraction proxy |
| `C3-M4-false-escalation.sh` | M4 | Authorized operations should not trigger unnecessary escalation |
| `C4-M5-rollback.sh` | M5 | Stepwise rollback / liveness behavior |
| `C5-parameter-sweep.sh` | Sensitivity | Effect of `(q, delta)` on safety / liveness |

## Recommended usage

1. Use `phase-c/` as the primary evidence set for paper validation.
2. Use `phase-b/` to demonstrate concrete enforcement behavior and implementation feasibility.
3. Treat `B10` and full terminal LOCKDOWN paths as disposable-VM tests.
4. Refactor repeated controller lifecycle helpers into `lib/common.sh` over time.

## Suggested next refactor

Move repeated logic into `lib/common.sh`:

- controller start / stop / wait
- posture query helpers
- inject helpers
- break-glass helper

That will reduce duplication and make the suite easier to audit.


## New shared infrastructure

- `lib/common.sh` centralizes controller lifecycle, inject/posture helpers, break-glass, reset, and result collection.
- `scripts/reset-testbed.sh` provides best-effort cleanup for nftables, cgroups, mounts, and controller state.
- `scripts/collect-results.sh` bundles `/tmp/adms-*.log`, `/tmp/adms-*.json`, controller logs, and a best-effort final posture snapshot into a timestamped archive.

## Safety labels

Every active script now includes an explicit safety label in the header:

- `HOST-SAFE`
- `DISPOSABLE-VM PREFERRED`
- `DISPOSABLE-VM ONLY`
- `MIXED`
