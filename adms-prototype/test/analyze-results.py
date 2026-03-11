#!/usr/bin/env python3
"""
test/analyze-results.py — Compute M1–M5 metrics from ADMS controller metrics export.

Usage: python3 test/analyze-results.py /tmp/adms-metrics.json
"""

import json
import sys
from statistics import median as stat_median


def load_metrics(path):
    with open(path) as f:
        return json.load(f)


def m1_transition_correctness(data):
    """M1: Verify all transitions match expected precedence rules."""
    transitions = data.get("transitions", [])
    total = len(transitions)
    violations = []

    for t in transitions:
        frm, to = t["from"], t["to"]
        drift = t.get("drift", {})
        auth = t.get("authorized", False)

        # Escalation during authorized drift = false escalation
        if auth and to > frm:
            violations.append(f"false escalation {frm}→{to} (authorized)")

        # Descent during unauthorized drift = safety violation (A1)
        if not auth and to < frm and not _is_all_zero(drift):
            violations.append(f"A1 violation: descent {frm}→{to} during drift")

    correct = total - len(violations)
    print(f"M1 Transition Correctness: {correct}/{total} correct")
    for v in violations:
        print(f"  VIOLATION: {v}")
    return len(violations) == 0


def m2_containment_latency(data):
    """M2: Compute L_contain statistics."""
    latencies = data.get("containment_latencies_ms", [])
    if not latencies:
        print("M2 Containment Latency: no data")
        return

    print(f"M2 Containment Latency:")
    print(f"  Range:  {min(latencies):.1f}ms – {max(latencies):.1f}ms")
    print(f"  Median: {stat_median(latencies):.1f}ms")
    print(f"  Samples: {len(latencies)}")


def m3_contraction_proxy(data):
    """M3: Compute C_k from transition data.

    C_k is a design-time property of the enforcement profiles.
    We report it from the summary if available, or compute from
    transition class counts.
    """
    summary = data.get("summary", {})
    print("M3 Contraction Proxy:")
    print("  (C_k is computed from enforcement profile design)")
    print("  See enforcement-profiles/ for per-posture transition class counts")

    # If available from extended metrics:
    if "contraction_proxy" in data:
        cp = data["contraction_proxy"]
        for level, val in sorted(cp.items()):
            print(f"  C_{level} = {val:.2f}")


def m4_false_escalation(data):
    """M4: Count escalations during authorized operations."""
    summary = data.get("summary", {})
    false_esc = summary.get("false_escalations", 0)
    authorized_cycles = data.get("authorized_cycles", 0)
    masked = data.get("masked_drift_count", 0)

    total = authorized_cycles if authorized_cycles > 0 else masked
    rate = (false_esc / max(total, 1)) * 100

    print(f"M4 False Escalation Rate: {false_esc}/{total} ({rate:.1f}%)")
    if false_esc == 0 and total > 0:
        print("  Authorization masking: EFFECTIVE")
    elif false_esc > 0:
        print("  WARNING: Check A(t) configuration")


def m5_recovery(data):
    """M5: Verify rollback is stepwise and measure L_rollback."""
    summary = data.get("summary", {})
    transitions = data.get("transitions", [])

    rollbacks = [t for t in transitions if t["to"] < t["from"]]
    stepwise = all(t["from"] - t["to"] == 1 for t in rollbacks)

    print(f"M5 Recovery and Liveness:")
    print(f"  Rollback steps: {len(rollbacks)}")
    print(f"  All stepwise: {stepwise}")

    if summary.get("rollback_all_stepwise") is not None:
        print(f"  Summary flag: {summary['rollback_all_stepwise']}")

    # Compute L_rollback if we can find LOCKDOWN→NORMAL sequence
    lockdown_exits = [t for t in rollbacks if t["from"] == 3]
    normal_entries = [t for t in rollbacks if t["to"] == 0]

    if lockdown_exits and normal_entries:
        first_rb = lockdown_exits[0]["elapsed_ms"]
        last_rb = normal_entries[-1]["elapsed_ms"]
        l_rollback = (last_rb - first_rb) / 1000.0
        print(f"  L_rollback (LOCKDOWN→NORMAL): {l_rollback:.1f}s")


def _is_all_zero(drift):
    if isinstance(drift, dict):
        return not any(drift.get(k, False) for k in
                       ["Identity", "Privilege", "Durability", "Execution", "Network"])
    return True


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 analyze-results.py <metrics.json>")
        sys.exit(1)

    data = load_metrics(sys.argv[1])

    print("=" * 50)
    print("ADMS Metrics Analysis")
    print("=" * 50)
    print()

    m1_transition_correctness(data)
    print()
    m2_containment_latency(data)
    print()
    m3_contraction_proxy(data)
    print()
    m4_false_escalation(data)
    print()
    m5_recovery(data)

    print()
    print("=" * 50)

    # Also print raw summary
    summary = data.get("summary", {})
    if summary:
        print("Raw summary:")
        for k, v in sorted(summary.items()):
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
