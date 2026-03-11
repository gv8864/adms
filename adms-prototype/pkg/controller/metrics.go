package controller

import (
	"time"

	"github.com/adms-prototype/pkg/signals"
)

// TransitionRecord logs a single posture change.
type TransitionRecord struct {
	Timestamp  time.Time          `json:"timestamp"`
	From       int                `json:"from"`
	To         int                `json:"to"`
	Drift      signals.DriftVector `json:"drift"`
	Authorized bool               `json:"authorized"`
	ElapsedMS  int64              `json:"elapsed_ms"`
	LatencyMS  float64            `json:"latency_ms,omitempty"`
	Scenario   string             `json:"scenario,omitempty"`
}

// Metrics collects data for computing M1–M5.
type Metrics struct {
	Transitions          []TransitionRecord `json:"transitions"`
	ContainmentLatencies []float64          `json:"containment_latencies_ms"`
	MaskedDriftCount     int                `json:"masked_drift_count"`
	BreakGlassEvents     []BreakGlassRecord `json:"break_glass_events"`
	AuthorizedCycles     int                `json:"authorized_cycles"`
}

type BreakGlassRecord struct {
	Timestamp    time.Time `json:"timestamp"`
	FromPosture  int       `json:"from_posture"`
	Reason       string    `json:"reason"`
}

// MetricsExport is the JSON-serializable output format.
type MetricsExport struct {
	Transitions          []TransitionRecord `json:"transitions"`
	ContainmentLatencies []float64          `json:"containment_latencies_ms"`
	MaskedDriftCount     int                `json:"masked_drift_count"`
	BreakGlassEvents     []BreakGlassRecord `json:"break_glass_events"`
	AuthorizedCycles     int                `json:"authorized_cycles"`
	Summary              MetricsSummary     `json:"summary"`
}

type MetricsSummary struct {
	TotalTransitions  int     `json:"total_transitions"`
	Escalations       int     `json:"escalations"`
	Rollbacks         int     `json:"rollbacks"`
	FalseEscalations  int     `json:"false_escalations"`
	MedianLatencyMS   float64 `json:"median_latency_ms"`
	MinLatencyMS      float64 `json:"min_latency_ms"`
	MaxLatencyMS      float64 `json:"max_latency_ms"`
	RollbackStepwise  bool    `json:"rollback_all_stepwise"`
}

func NewMetrics() *Metrics {
	return &Metrics{}
}

// RecordContainmentLatency records L_contain from kernel event time to now.
func (m *Metrics) RecordContainmentLatency(kernelNS uint64, now time.Time) {
	// kernelNS is from bpf_ktime_get_ns() (monotonic clock).
	// We approximate: controller receipt time ≈ now.
	// In production, correlate monotonic clocks properly.
	// For prototype: record wall-clock latency from last sensor event.
	// The actual L_contain is computed from sensor timestamps in post-analysis.
}

// RecordContainmentLatencyDirect records a pre-computed latency.
func (m *Metrics) RecordContainmentLatencyDirect(latencyMS float64) {
	m.ContainmentLatencies = append(m.ContainmentLatencies, latencyMS)
}

func (m *Metrics) RecordTransition(r TransitionRecord) {
	m.Transitions = append(m.Transitions, r)
}

func (m *Metrics) RecordMaskedDrift(t time.Time) {
	m.MaskedDriftCount++
	m.AuthorizedCycles++
}

func (m *Metrics) RecordBreakGlass(t time.Time, fromPosture int, reason string) {
	m.BreakGlassEvents = append(m.BreakGlassEvents, BreakGlassRecord{
		Timestamp:   t,
		FromPosture: fromPosture,
		Reason:      reason,
	})
}

// Export computes summary statistics and returns the full export.
func (m *Metrics) Export() MetricsExport {
	summary := MetricsSummary{
		TotalTransitions: len(m.Transitions),
		RollbackStepwise: true,
	}

	for _, t := range m.Transitions {
		if t.To > t.From {
			summary.Escalations++
			if t.Authorized {
				summary.FalseEscalations++
			}
		} else if t.To < t.From {
			summary.Rollbacks++
			if t.From-t.To != 1 {
				summary.RollbackStepwise = false
			}
		}
	}

	if len(m.ContainmentLatencies) > 0 {
		sorted := make([]float64, len(m.ContainmentLatencies))
		copy(sorted, m.ContainmentLatencies)
		sortFloat64s(sorted)
		summary.MinLatencyMS = sorted[0]
		summary.MaxLatencyMS = sorted[len(sorted)-1]
		summary.MedianLatencyMS = median(sorted)
	}

	return MetricsExport{
		Transitions:          m.Transitions,
		ContainmentLatencies: m.ContainmentLatencies,
		MaskedDriftCount:     m.MaskedDriftCount,
		BreakGlassEvents:     m.BreakGlassEvents,
		AuthorizedCycles:     m.AuthorizedCycles,
		Summary:              summary,
	}
}

// --- helpers ---

func sortFloat64s(a []float64) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && a[j] < a[j-1]; j-- {
			a[j], a[j-1] = a[j-1], a[j]
		}
	}
}

func median(sorted []float64) float64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	if n%2 == 0 {
		return (sorted[n/2-1] + sorted[n/2]) / 2
	}
	return sorted[n/2]
}
