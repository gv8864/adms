package controller

import (
	"testing"
	"time"

	"github.com/adms-prototype/pkg/signals"
)

// NoopEnforcer does nothing — used for pure logic testing.
type NoopEnforcer struct {
	LastPosture int
	CallCount   int
}

func (n *NoopEnforcer) ApplyPosture(level int) error {
	n.LastPosture = level
	n.CallCount++
	return nil
}

func newTestController(q, delta int) (*Controller, *NoopEnforcer) {
	e := &NoopEnforcer{}
	cfg := Config{Tau: time.Second, Q: q, Delta: delta}
	c, _ := New(cfg, e, "")
	return c, e
}

// --- M1: Transition correctness tests ---

func TestS1_ExecutionDrift_NormalToObserve(t *testing.T) {
	c, _ := newTestController(60, 3)

	// ΔE=1, unauthorized → T: 0→1
	c.Tick(signals.DriftVector{Execution: true}, false, 0)

	if c.Posture() != OBSERVE {
		t.Fatalf("S1: expected OBSERVE (1), got %s (%d)",
			PostureName(c.Posture()), c.Posture())
	}
}

func TestS2_PrivilegeEscalation_ObserveToRestricted(t *testing.T) {
	c, _ := newTestController(60, 3)

	// Set up: reach OBSERVE via ΔE
	c.Tick(signals.DriftVector{Execution: true}, false, 0)

	// ΔP=1, unauthorized → T: 1→2
	c.Tick(signals.DriftVector{Privilege: true}, false, 0)

	if c.Posture() != RESTRICTED {
		t.Fatalf("S2: expected RESTRICTED (2), got %s (%d)",
			PostureName(c.Posture()), c.Posture())
	}
}

func TestS3_PersistenceAfterPrivilege_RestrictedToLockdown(t *testing.T) {
	c, _ := newTestController(60, 3)

	// Set up: NORMAL→OBSERVE→RESTRICTED
	c.Tick(signals.DriftVector{Execution: true}, false, 0)
	c.Tick(signals.DriftVector{Privilege: true}, false, 0)

	// ΔD=1 with prior ΔP → T: 2→3
	c.Tick(signals.DriftVector{Durability: true}, false, 0)

	if c.Posture() != LOCKDOWN {
		t.Fatalf("S3: expected LOCKDOWN (3), got %s (%d)",
			PostureName(c.Posture()), c.Posture())
	}
}

func TestS4_NetworkDrift_NormalToObserve(t *testing.T) {
	c, _ := newTestController(60, 3)

	// ΔN=1, unauthorized → T: 0→1
	c.Tick(signals.DriftVector{Network: true}, false, 0)

	if c.Posture() != OBSERVE {
		t.Fatalf("S4: expected OBSERVE (1), got %s (%d)",
			PostureName(c.Posture()), c.Posture())
	}
}

// --- Precedence tests ---

func TestPrecedence_SimultaneousPD_Lockdown(t *testing.T) {
	c, _ := newTestController(60, 3)

	// ΔP=1 ∧ ΔD=1 simultaneously → LOCKDOWN (eq 11)
	c.Tick(signals.DriftVector{Privilege: true, Durability: true}, false, 0)

	if c.Posture() != LOCKDOWN {
		t.Fatalf("expected LOCKDOWN from simultaneous ΔP∧ΔD, got %s",
			PostureName(c.Posture()))
	}
}

func TestPrecedence_IdentityDrift_DirectToLockdown(t *testing.T) {
	c, _ := newTestController(60, 3)

	// ΔI=1 → LOCKDOWN from any state (eq 10)
	c.Tick(signals.DriftVector{Identity: true}, false, 0)

	if c.Posture() != LOCKDOWN {
		t.Fatalf("expected LOCKDOWN from ΔI, got %s",
			PostureName(c.Posture()))
	}
}

func TestPrecedence_HighestWins(t *testing.T) {
	c, _ := newTestController(60, 3)

	// ΔE=1 ∧ ΔP=1 ∧ ΔI=1 simultaneously → highest = LOCKDOWN
	c.Tick(signals.DriftVector{
		Execution: true,
		Privilege: true,
		Identity:  true,
	}, false, 0)

	if c.Posture() != LOCKDOWN {
		t.Fatalf("expected LOCKDOWN (highest-severity-wins), got %s",
			PostureName(c.Posture()))
	}
}

// --- Monotonic escalation (A1) ---

func TestMonotonicEscalation_NeverDescendOnDrift(t *testing.T) {
	c, _ := newTestController(60, 3)

	// Escalate to RESTRICTED
	c.Tick(signals.DriftVector{Privilege: true}, false, 0)

	// ΔE alone would suggest OBSERVE, but A1 prevents descent
	c.Tick(signals.DriftVector{Execution: true}, false, 0)

	if c.Posture() != RESTRICTED {
		t.Fatalf("A1 violated: posture should not descend on drift, got %s",
			PostureName(c.Posture()))
	}
}

// --- Authorization masking ---

func TestAuthorizedDrift_NoEscalation(t *testing.T) {
	c, _ := newTestController(60, 3)

	// Same drift as S1, but authorized → no escalation
	c.Tick(signals.DriftVector{Execution: true}, true, 0)

	if c.Posture() != NORMAL {
		t.Fatalf("authorized drift should not escalate, got %s",
			PostureName(c.Posture()))
	}
}

func TestAuthorizedDrift_PrivilegeAndPersistence_NoEscalation(t *testing.T) {
	c, _ := newTestController(60, 3)

	// Even ΔP∧ΔD when authorized → no escalation
	c.Tick(signals.DriftVector{Privilege: true, Durability: true}, true, 0)

	if c.Posture() != NORMAL {
		t.Fatalf("authorized ΔP∧ΔD should not escalate, got %s",
			PostureName(c.Posture()))
	}
}

// --- Rollback (M5) ---

func TestRollback_StepwiseFromLockdown(t *testing.T) {
	c, _ := newTestController(3, 1) // short q and δ for testing

	// Escalate to LOCKDOWN
	c.Tick(signals.DriftVector{Identity: true}, false, 0)
	if c.Posture() != LOCKDOWN {
		t.Fatal("setup failed: not at LOCKDOWN")
	}

	// Quiescent ticks: need q=3 quiet + δ=1 dwell per step
	// Step 1: LOCKDOWN→RESTRICTED (need 3 quiet + 1 dwell = 4 ticks minimum)
	for i := 0; i < 4; i++ {
		c.Tick(signals.DriftVector{}, false, 0)
	}
	if c.Posture() != RESTRICTED {
		t.Fatalf("expected RESTRICTED after first rollback, got %s (after 4 ticks)",
			PostureName(c.Posture()))
	}

	// Step 2: RESTRICTED→OBSERVE
	for i := 0; i < 4; i++ {
		c.Tick(signals.DriftVector{}, false, 0)
	}
	if c.Posture() != OBSERVE {
		t.Fatalf("expected OBSERVE after second rollback, got %s",
			PostureName(c.Posture()))
	}

	// Step 3: OBSERVE→NORMAL
	for i := 0; i < 4; i++ {
		c.Tick(signals.DriftVector{}, false, 0)
	}
	if c.Posture() != NORMAL {
		t.Fatalf("expected NORMAL after third rollback, got %s",
			PostureName(c.Posture()))
	}
}

func TestRollback_BlockedDuringActiveDrift(t *testing.T) {
	c, _ := newTestController(2, 1)

	// Escalate to OBSERVE
	c.Tick(signals.DriftVector{Execution: true}, false, 0)

	// One quiet tick, then drift again — counter should reset
	c.Tick(signals.DriftVector{}, false, 0)
	c.Tick(signals.DriftVector{Network: true}, false, 0)

	// Still at OBSERVE (network drift from OBSERVE stays at OBSERVE by A1)
	// But rollback should NOT have happened
	if c.Posture() != OBSERVE {
		t.Fatalf("expected OBSERVE (rollback blocked by drift), got %s",
			PostureName(c.Posture()))
	}
}

func TestRollback_BlockedByIdentityDrift(t *testing.T) {
	c, _ := newTestController(2, 1)

	// Escalate
	c.Tick(signals.DriftVector{Execution: true}, false, 0)

	// Quiet ticks but with identity drift in raw (even if no unauthorized drift)
	// Identity instability should prevent rollback
	for i := 0; i < 10; i++ {
		c.Tick(signals.DriftVector{Identity: true}, true, 0)
	}

	// Should still be at OBSERVE minimum (identity drift when authorized
	// doesn't escalate, but raw.Identity=true resets quiet counter)
	// Actually: identity drift even when authorized resets quiet counter
	// because I(t)=0 is required for rollback eligibility
	if c.Posture() < OBSERVE {
		t.Fatalf("rollback should be blocked by identity instability, got %s",
			PostureName(c.Posture()))
	}
}

// --- Hysteresis (Lemma 1) ---

func TestHysteresis_DwellTimeRespected(t *testing.T) {
	c, _ := newTestController(1, 5) // q=1 (very short), δ=5

	// Escalate
	c.Tick(signals.DriftVector{Execution: true}, false, 0)

	// Only 3 quiet ticks (δ=5 not met)
	for i := 0; i < 3; i++ {
		c.Tick(signals.DriftVector{}, false, 0)
	}

	if c.Posture() != OBSERVE {
		t.Fatalf("dwell time δ not respected: rollback happened too early, got %s",
			PostureName(c.Posture()))
	}
}

// --- Break-glass ---

func TestBreakGlass_ForcesNormal(t *testing.T) {
	c, _ := newTestController(60, 3)

	// Escalate to LOCKDOWN
	c.Tick(signals.DriftVector{Identity: true}, false, 0)

	c.BreakGlass("test emergency")

	if c.Posture() != NORMAL {
		t.Fatalf("break-glass should force NORMAL, got %s",
			PostureName(c.Posture()))
	}
}

// --- Determinism (A3) ---

func TestDeterminism_SameInputSameOutput(t *testing.T) {
	// Run the same sequence 50 times (matching paper's n=50)
	for run := 0; run < 50; run++ {
		c, _ := newTestController(3, 1)

		c.Tick(signals.DriftVector{Execution: true}, false, 0)
		if c.Posture() != OBSERVE {
			t.Fatalf("run %d: S1 non-deterministic", run)
		}

		c.Tick(signals.DriftVector{Privilege: true}, false, 0)
		if c.Posture() != RESTRICTED {
			t.Fatalf("run %d: S2 non-deterministic", run)
		}

		c.Tick(signals.DriftVector{Durability: true}, false, 0)
		if c.Posture() != LOCKDOWN {
			t.Fatalf("run %d: S3 non-deterministic", run)
		}
	}
}
