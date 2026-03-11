package signals

import (
	"fmt"
	"time"
)

// Dimension identifies which integrity boundary is involved.
type Dimension int

const (
	DimIdentity   Dimension = iota // I
	DimPrivilege                   // P
	DimDurability                  // D
	DimExecution                   // E
	DimNetwork                     // N
	DimCount                       // sentinel — always last
)

func (d Dimension) String() string {
	switch d {
	case DimIdentity:
		return "I"
	case DimPrivilege:
		return "P"
	case DimDurability:
		return "D"
	case DimExecution:
		return "E"
	case DimNetwork:
		return "N"
	default:
		return fmt.Sprintf("Unknown(%d)", int(d))
	}
}

// DriftVector represents B(t) = (ΔI, ΔP, ΔD, ΔE, ΔN).
// Each field is true when drift has been observed in that dimension
// during the current controller interval.
type DriftVector struct {
	Identity   bool
	Privilege  bool
	Durability bool
	Execution  bool
	Network    bool
}

// IsZero returns true when no drift is observed: B(t) = 0.
func (d DriftVector) IsZero() bool {
	return !d.Identity && !d.Privilege && !d.Durability &&
		!d.Execution && !d.Network
}

// Dimensions returns which dimensions have drifted.
func (d DriftVector) Dimensions() []Dimension {
	var dims []Dimension
	if d.Identity {
		dims = append(dims, DimIdentity)
	}
	if d.Privilege {
		dims = append(dims, DimPrivilege)
	}
	if d.Durability {
		dims = append(dims, DimDurability)
	}
	if d.Execution {
		dims = append(dims, DimExecution)
	}
	if d.Network {
		dims = append(dims, DimNetwork)
	}
	return dims
}

func (d DriftVector) String() string {
	b := func(v bool) int {
		if v {
			return 1
		}
		return 0
	}
	return fmt.Sprintf("(%d,%d,%d,%d,%d)",
		b(d.Identity), b(d.Privilege), b(d.Durability),
		b(d.Execution), b(d.Network))
}

// DriftEvent is a single boundary-crossing event from the sensor layer.
type DriftEvent struct {
	Timestamp   time.Time
	Dimension   Dimension
	PID         uint32
	UID         uint32
	Comm        string // process name
	Detail      string // human-readable detail
	KernelNanos uint64 // bpf_ktime_get_ns() for latency measurement
}
