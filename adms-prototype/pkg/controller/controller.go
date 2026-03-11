package controller

import (
	"encoding/json"
	"log"
	"os"
	"sync"
	"time"

	"github.com/adms-prototype/pkg/signals"
)

// Posture levels: T(t) ∈ {0, 1, 2, 3}
const (
	NORMAL     = 0
	OBSERVE    = 1
	RESTRICTED = 2
	LOCKDOWN   = 3
)

// PostureName maps level to string.
func PostureName(level int) string {
	switch level {
	case NORMAL:
		return "NORMAL"
	case OBSERVE:
		return "OBSERVE"
	case RESTRICTED:
		return "RESTRICTED"
	case LOCKDOWN:
		return "LOCKDOWN"
	default:
		return "UNKNOWN"
	}
}

// Enforcer applies posture-specific enforcement actions.
type Enforcer interface {
	ApplyPosture(level int) error
}

// Config holds controller parameters.
type Config struct {
	Tau   time.Duration // controller sampling interval
	Q     int           // quiet intervals required for rollback
	Delta int           // minimum dwell time before de-escalation
}

// Controller implements the ADMS posture state machine.
// It is safe for concurrent access.
type Controller struct {
	mu sync.Mutex

	// Current state
	posture      int
	quietCounter int // consecutive quiescent intervals (B̃=0, I=0)
	dwellCounter int // intervals spent in current posture

	// Cumulative tracking
	priorPrivilege bool // ΔP observed at any prior point

	// Configuration
	cfg Config

	// Enforcement backend
	enforcer Enforcer

	// Metrics and logging
	metrics    *Metrics
	logFile    *os.File
	logger     *log.Logger
	startTime  time.Time

	// Last drift timestamp for latency measurement
	lastDriftKernelNS uint64
}

// New creates a controller with the given parameters and enforcer.
func New(cfg Config, enforcer Enforcer, logPath string) (*Controller, error) {
	var logFile *os.File
	var logger *log.Logger

	if logPath != "" {
		f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
		if err != nil {
			return nil, err
		}
		logFile = f
		logger = log.New(f, "", 0)
	} else {
		logger = log.New(os.Stdout, "[ADMS] ", log.LstdFlags)
	}

	c := &Controller{
		posture:   NORMAL,
		cfg:       cfg,
		enforcer:  enforcer,
		metrics:   NewMetrics(),
		logFile:   logFile,
		logger:    logger,
		startTime: time.Now(),
	}

	// Write startup entry so the log file is non-empty immediately
	logger.Printf("ADMS controller initialized: tau=%s q=%d delta=%d",
		cfg.Tau, cfg.Q, cfg.Delta)

	return c, nil
}

// Close releases resources.
func (c *Controller) Close() {
	if c.logFile != nil {
		c.logFile.Close()
	}
}

// Posture returns the current posture level.
func (c *Controller) Posture() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.posture
}

// Tick processes one controller interval. This is the core loop body.
//
// raw:        the raw drift vector B(t) from the sensor layer
// authorized: the authorization mask A(t) for this interval
// kernelNS:   kernel timestamp of the earliest drift event (for latency)
//
// The transition function T(t+1) = f(T(t), B̃(t)) is evaluated here.
func (c *Controller) Tick(raw signals.DriftVector, authorized bool, kernelNS uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := time.Now()

	// Compute effective drift: B̃(t) = B(t) ∧ ¬A(t)
	effective := signals.EffectiveDrift(raw, authorized)

	c.dwellCounter++

	if !effective.IsZero() {
		// ── ESCALATION PATH ──
		c.quietCounter = 0

		// Track cumulative privilege for ΔP∧ΔD combined rule
		if effective.Privilege {
			c.priorPrivilege = true
		}

		newPosture := c.computeEscalation(effective)

		// A1: Monotonic escalation — never descend on unauthorized drift
		if newPosture < c.posture {
			newPosture = c.posture
		}

		if newPosture != c.posture {
			// Measure containment latency
			if kernelNS > 0 {
				c.metrics.RecordContainmentLatency(kernelNS, now)
			}
			c.doTransition(newPosture, effective, authorized, now)
		}

		c.lastDriftKernelNS = kernelNS

	} else {
		// ── QUIESCENT PATH: check rollback eligibility ──
		// Identity must also be stable for the quiet interval.
		// raw.Identity tells us the actual identity state regardless of A(t).
		if !raw.Identity {
			c.quietCounter++
		} else {
			c.quietCounter = 0
		}

		// Rollback: stepwise, requires q quiet intervals + δ dwell
		if c.posture > NORMAL &&
			c.quietCounter >= c.cfg.Q &&
			c.dwellCounter >= c.cfg.Delta {

			newPosture := c.posture - 1
			c.doTransition(newPosture, effective, authorized, now)
			c.quietCounter = 0 // reset for next rollback step

			// Clear cumulative privilege tracking if back to NORMAL
			if newPosture == NORMAL {
				c.priorPrivilege = false
			}
		}
	}

	// Log if authorized drift was masked
	if !raw.IsZero() && authorized {
		c.logger.Printf("MASKED drift=%s (authorized)", raw)
		c.metrics.RecordMaskedDrift(now)
	}
}

// computeEscalation applies equations 10–13 with highest-severity-wins precedence.
func (c *Controller) computeEscalation(eff signals.DriftVector) int {
	target := c.posture

	// ── Check LOCKDOWN triggers first (highest severity) ──

	// Eq 10: ΔI → LOCKDOWN
	if eff.Identity {
		target = LOCKDOWN
	}

	// Eq 11: ΔP ∧ ΔD → LOCKDOWN (simultaneous)
	if eff.Privilege && eff.Durability {
		target = LOCKDOWN
	}

	// Extended: prior ΔP + current ΔD → LOCKDOWN
	if c.priorPrivilege && eff.Durability && target < LOCKDOWN {
		target = LOCKDOWN
	}

	// ── Check RESTRICTED triggers ──

	// Eq 12: ΔP → RESTRICTED
	if eff.Privilege && target < RESTRICTED {
		target = RESTRICTED
	}

	// ── Check OBSERVE triggers ──

	// Eq 13: ΔE → max(T(t), OBSERVE)
	if eff.Execution && target < OBSERVE {
		target = OBSERVE
	}

	// ΔN → max(T(t), OBSERVE)
	if eff.Network && target < OBSERVE {
		target = OBSERVE
	}

	return target
}

// doTransition performs the posture change and applies enforcement.
func (c *Controller) doTransition(newPosture int, drift signals.DriftVector, authorized bool, now time.Time) {
	prev := c.posture

	record := TransitionRecord{
		Timestamp:  now,
		From:       prev,
		To:         newPosture,
		Drift:      drift,
		Authorized: authorized,
		ElapsedMS:  now.Sub(c.startTime).Milliseconds(),
	}

	c.posture = newPosture
	c.dwellCounter = 0

	// Apply enforcement
	if c.enforcer != nil {
		if err := c.enforcer.ApplyPosture(newPosture); err != nil {
			c.logger.Printf("ERROR: enforcement failed for %s: %v",
				PostureName(newPosture), err)
			// Fail-safe: stay at escalated posture, do not roll back
		}
	}

	c.metrics.RecordTransition(record)

	direction := "ESCALATE"
	if newPosture < prev {
		direction = "ROLLBACK"
	}
	c.logger.Printf("%s %s→%s drift=%s authorized=%v",
		direction, PostureName(prev), PostureName(newPosture),
		drift, authorized)
}

// BreakGlass forces posture to NORMAL, bypassing all checks.
// Logs an irrevocable audit entry.
func (c *Controller) BreakGlass(reason string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	prev := c.posture
	c.posture = NORMAL
	c.quietCounter = 0
	c.dwellCounter = 0
	c.priorPrivilege = false

	if c.enforcer != nil {
		c.enforcer.ApplyPosture(NORMAL)
	}

	c.logger.Printf("BREAK-GLASS %s→NORMAL reason=%q", PostureName(prev), reason)
	c.metrics.RecordBreakGlass(time.Now(), prev, reason)
}

// ExportMetrics returns a JSON-serializable snapshot of all metrics.
func (c *Controller) ExportMetrics() ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return json.MarshalIndent(c.metrics.Export(), "", "  ")
}
