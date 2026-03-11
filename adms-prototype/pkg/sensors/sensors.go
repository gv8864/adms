package sensors

import (
	"bufio"
	"encoding/json"
	"io"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/adms-prototype/pkg/signals"
)

// TetragonEvent represents a parsed event from Tetragon's JSON export.
type TetragonEvent struct {
	ProcessExec  *ProcessExecEvent  `json:"process_exec,omitempty"`
	ProcessKprobe *ProcessKprobeEvent `json:"process_kprobe,omitempty"`
	Time         string              `json:"time"`
}

type ProcessExecEvent struct {
	Process ProcessInfo `json:"process"`
}

type ProcessKprobeEvent struct {
	Process      ProcessInfo `json:"process"`
	FunctionName string      `json:"function_name"`
	PolicyName   string      `json:"policy_name"`
	Args         []KprobeArg `json:"args"`
}

type ProcessInfo struct {
	Pid        uint32 `json:"pid"`
	Uid        uint32 `json:"uid"`
	Binary     string `json:"binary"`
	Arguments  string `json:"arguments"`
	ParentExecId string `json:"parent_exec_id"`
}

type KprobeArg struct {
	StringArg string `json:"string_arg,omitempty"`
	IntArg    int64  `json:"int_arg,omitempty"`
	FileArg   *FileArg `json:"file_arg,omitempty"`
	SockArg   *SockArg `json:"sock_arg,omitempty"`
}

type FileArg struct {
	Path string `json:"path"`
}

type SockArg struct {
	Family string `json:"family"`
	Daddr  string `json:"daddr"`
	Dport  uint32 `json:"dport"`
}

// EventCollector aggregates sensor events into per-interval drift vectors.
type EventCollector struct {
	mu     sync.Mutex
	logger *log.Logger

	// Current interval accumulator
	currentDrift    signals.DriftVector
	latestKernelNS  uint64
	eventCount      int

	// Persistence loci for ΔD classification
	persistencePrefixes []string

	// Egress allow-list for ΔN classification
	egressAllowedCIDRs []string

	// Writable paths that indicate ΔE for exec
	writablePrefixes []string
}

type EventCollectorConfig struct {
	PersistencePrefixes []string
	EgressAllowedCIDRs  []string
	WritablePrefixes    []string
}

func NewEventCollector(cfg EventCollectorConfig) *EventCollector {
	if len(cfg.PersistencePrefixes) == 0 {
		cfg.PersistencePrefixes = []string{
			"/etc/systemd/system",
			"/etc/cron",
			"/etc/init.d",
			"/lib/modules",
		}
	}
	if len(cfg.WritablePrefixes) == 0 {
		cfg.WritablePrefixes = []string{
			"/tmp/",
			"/dev/shm/",
			"/var/tmp/",
			"/run/",
		}
	}
	return &EventCollector{
		logger:              log.New(os.Stdout, "[SENSOR] ", log.LstdFlags),
		persistencePrefixes: cfg.PersistencePrefixes,
		egressAllowedCIDRs:  cfg.EgressAllowedCIDRs,
		writablePrefixes:    cfg.WritablePrefixes,
	}
}

// DrainInterval returns the accumulated drift vector for the current interval
// and resets the accumulator. Called by the controller once per τ.
func (ec *EventCollector) DrainInterval() (signals.DriftVector, uint64) {
	ec.mu.Lock()
	defer ec.mu.Unlock()

	drift := ec.currentDrift
	kernelNS := ec.latestKernelNS

	// Reset for next interval
	ec.currentDrift = signals.DriftVector{}
	ec.latestKernelNS = 0
	ec.eventCount = 0

	return drift, kernelNS
}

// ProcessTetragonEvent classifies a Tetragon event into the appropriate
// drift dimension and accumulates it.
func (ec *EventCollector) ProcessTetragonEvent(evt TetragonEvent) {
	ec.mu.Lock()
	defer ec.mu.Unlock()

	if evt.ProcessKprobe == nil {
		return
	}

	kp := evt.ProcessKprobe
	switch {
	case isPrivilegePolicy(kp.PolicyName):
		ec.currentDrift.Privilege = true
		ec.logger.Printf("ΔP: pid=%d binary=%s func=%s",
			kp.Process.Pid, kp.Process.Binary, kp.FunctionName)

	case isPersistencePolicy(kp.PolicyName):
		if ec.isPersistencePath(kp) {
			ec.currentDrift.Durability = true
			ec.logger.Printf("ΔD: pid=%d binary=%s path=%s",
				kp.Process.Pid, kp.Process.Binary, ec.extractPath(kp))
		}

	case isExecutionPolicy(kp.PolicyName):
		ec.currentDrift.Execution = true
		ec.logger.Printf("ΔE: pid=%d binary=%s func=%s",
			kp.Process.Pid, kp.Process.Binary, kp.FunctionName)

	case isNetworkPolicy(kp.PolicyName):
		if ec.isUnauthorizedEgress(kp) {
			ec.currentDrift.Network = true
			ec.logger.Printf("ΔN: pid=%d binary=%s dest=%s",
				kp.Process.Pid, kp.Process.Binary, ec.extractDest(kp))
		}

	case isIdentityPolicy(kp.PolicyName):
		ec.currentDrift.Identity = true
		ec.logger.Printf("ΔI: pid=%d binary=%s",
			kp.Process.Pid, kp.Process.Binary)
	}

	ec.eventCount++
}

// StartTetragonReader reads Tetragon JSON events from stdin or a named pipe.
func (ec *EventCollector) StartTetragonReader(reader io.Reader) {
	scanner := bufio.NewScanner(reader)
	// Increase buffer for large events
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}

		var evt TetragonEvent
		if err := json.Unmarshal([]byte(line), &evt); err != nil {
			ec.logger.Printf("parse error: %v (line: %.100s...)", err, line)
			continue
		}

		ec.ProcessTetragonEvent(evt)
	}
}

// --- Classification helpers ---

func isPrivilegePolicy(name string) bool {
	return strings.Contains(name, "privilege") || strings.Contains(name, "priv")
}

func isPersistencePolicy(name string) bool {
	return strings.Contains(name, "persistence") || strings.Contains(name, "durability")
}

func isExecutionPolicy(name string) bool {
	return strings.Contains(name, "execution") || strings.Contains(name, "exec")
}

func isNetworkPolicy(name string) bool {
	return strings.Contains(name, "network") || strings.Contains(name, "egress")
}

func isIdentityPolicy(name string) bool {
	return strings.Contains(name, "identity") || strings.Contains(name, "ima")
}

func (ec *EventCollector) isPersistencePath(kp *ProcessKprobeEvent) bool {
	path := ec.extractPath(kp)
	for _, prefix := range ec.persistencePrefixes {
		if strings.HasPrefix(path, prefix) {
			return true
		}
	}
	return false
}

func (ec *EventCollector) isUnauthorizedEgress(kp *ProcessKprobeEvent) bool {
	// For prototype: any outbound connection not in allow-list is ΔN
	// Production: integrate with Cilium network policy
	dest := ec.extractDest(kp)
	for _, allowed := range ec.egressAllowedCIDRs {
		if strings.HasPrefix(dest, allowed) {
			return false
		}
	}
	return dest != "" // any non-empty dest outside allow-list
}

func (ec *EventCollector) extractPath(kp *ProcessKprobeEvent) string {
	for _, arg := range kp.Args {
		if arg.FileArg != nil {
			return arg.FileArg.Path
		}
	}
	return ""
}

func (ec *EventCollector) extractDest(kp *ProcessKprobeEvent) string {
	for _, arg := range kp.Args {
		if arg.SockArg != nil {
			return arg.SockArg.Daddr
		}
	}
	return ""
}

// --- Manual event injection for testing ---

// InjectDrift manually sets a drift dimension. Used by test scenarios.
func (ec *EventCollector) InjectDrift(dim signals.Dimension) {
	ec.mu.Lock()
	defer ec.mu.Unlock()

	switch dim {
	case signals.DimIdentity:
		ec.currentDrift.Identity = true
	case signals.DimPrivilege:
		ec.currentDrift.Privilege = true
	case signals.DimDurability:
		ec.currentDrift.Durability = true
	case signals.DimExecution:
		ec.currentDrift.Execution = true
	case signals.DimNetwork:
		ec.currentDrift.Network = true
	}

	ec.latestKernelNS = uint64(time.Now().UnixNano())
	ec.eventCount++
}
