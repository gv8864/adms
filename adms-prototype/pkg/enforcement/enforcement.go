package enforcement

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"
)

// LinuxEnforcer applies posture-specific enforcement using Linux primitives.
type LinuxEnforcer struct {
	logger          *log.Logger
	persistenceLoci []string
	egressAllowList []string // CIDR ranges allowed at RESTRICTED
	controllerCIDR  string   // controller/attestation channel for LOCKDOWN
	dryRun          bool     // if true, log but don't execute
}

type LinuxEnforcerConfig struct {
	PersistenceLoci []string
	EgressAllowList []string
	ControllerCIDR  string
	DryRun          bool
}

func NewLinuxEnforcer(cfg LinuxEnforcerConfig) *LinuxEnforcer {
	if len(cfg.PersistenceLoci) == 0 {
		cfg.PersistenceLoci = []string{
			"/etc/systemd/system",
			"/etc/cron.d",
			"/etc/cron.daily",
			"/etc/cron.hourly",
			"/etc/init.d",
			"/lib/modules",
			"/usr/lib/systemd/system",
		}
	}
	if cfg.ControllerCIDR == "" {
		cfg.ControllerCIDR = "127.0.0.1/32"
	}
	return &LinuxEnforcer{
		logger:          log.New(os.Stdout, "[ENFORCE] ", log.LstdFlags),
		persistenceLoci: cfg.PersistenceLoci,
		egressAllowList: cfg.EgressAllowList,
		controllerCIDR:  cfg.ControllerCIDR,
		dryRun:          cfg.DryRun,
	}
}

func (e *LinuxEnforcer) ApplyPosture(level int) error {
	switch level {
	case 0:
		return e.applyNormal()
	case 1:
		return e.applyObserve()
	case 2:
		return e.applyRestricted()
	case 3:
		return e.applyLockdown()
	default:
		return fmt.Errorf("unknown posture level: %d", level)
	}
}

// ── NORMAL: baseline, remove all ADMS restrictions ──

func (e *LinuxEnforcer) applyNormal() error {
	e.logger.Println("Applying NORMAL posture")

	// Remove filesystem immutability
	for _, path := range e.persistenceLoci {
		e.run("chattr", "-i", path)
	}

	// Restore default nftables (flush ADMS chain)
	e.run("nft", "delete", "chain", "inet", "adms", "egress")

	// Re-enable module loading
	e.run("sysctl", "-w", "kernel.modules_disabled=0")

	// Remove ADMS audit rules
	e.run("auditctl", "-D", "-k", "adms-observe")

	// Remount writable if needed
	e.run("mount", "-o", "remount,rw", "/")

	return nil
}

// ── OBSERVE: increased audit/telemetry, no blocking ──

func (e *LinuxEnforcer) applyObserve() error {
	e.logger.Println("Applying OBSERVE posture")

	// Add audit rules for high-risk syscall classes
	e.run("auditctl", "-a", "always,exit", "-F", "arch=b64",
		"-S", "ptrace", "-k", "adms-observe")
	e.run("auditctl", "-a", "always,exit", "-F", "arch=b64",
		"-S", "bpf", "-k", "adms-observe")
	e.run("auditctl", "-a", "always,exit", "-F", "arch=b64",
		"-S", "init_module", "-S", "finit_module", "-k", "adms-observe")

	return nil
}

// ── RESTRICTED: deny persistence, tighten capabilities, restrict egress ──

func (e *LinuxEnforcer) applyRestricted() error {
	e.logger.Println("Applying RESTRICTED posture")

	// 1. Make persistence loci immutable
	for _, path := range e.persistenceLoci {
		e.run("chattr", "+i", path)
	}

	// 2. Disable dynamic module loading
	e.run("sysctl", "-w", "kernel.modules_disabled=1")

	// 3. Restrict network egress to allow-list
	e.setupEgressRestriction(e.egressAllowList)

	return nil
}

// ── LOCKDOWN: quench egress, freeze processes, immutable rootfs ──

func (e *LinuxEnforcer) applyLockdown() error {
	e.logger.Println("Applying LOCKDOWN posture")

	// 1. Apply all RESTRICTED controls first
	e.applyRestricted()

	// 2. Quench egress — only allow controller/attestation channel
	e.setupEgressRestriction([]string{e.controllerCIDR})

	// 3. Remount rootfs read-only (if feasible)
	e.run("mount", "-o", "remount,ro", "/")

	// 4. Freeze non-essential processes via cgroup freezer
	// In production: use cgroup v2 freezer
	// For prototype: SIGSTOP non-essential user processes
	e.freezeNonEssential()

	return nil
}

// setupEgressRestriction creates nftables rules allowing only specified CIDRs.
func (e *LinuxEnforcer) setupEgressRestriction(allowedCIDRs []string) {
	// Create ADMS table and chain
	e.run("nft", "add", "table", "inet", "adms")
	e.run("nft", "flush", "chain", "inet", "adms", "egress")
	e.run("nft", "add", "chain", "inet", "adms", "egress",
		"{ type filter hook output priority 0 ; policy drop ; }")

	// Allow loopback
	e.run("nft", "add", "rule", "inet", "adms", "egress",
		"oifname", "lo", "accept")

	// Allow established connections
	e.run("nft", "add", "rule", "inet", "adms", "egress",
		"ct", "state", "established,related", "accept")

	// Allow DNS (UDP 53) to any — needed for resolution
	e.run("nft", "add", "rule", "inet", "adms", "egress",
		"udp", "dport", "53", "accept")

	// Allow each CIDR in allow-list
	for _, cidr := range allowedCIDRs {
		e.run("nft", "add", "rule", "inet", "adms", "egress",
			"ip", "daddr", cidr, "accept")
	}
}

func (e *LinuxEnforcer) freezeNonEssential() {
	// Read cgroup v2 freeze interface if available
	freezePath := "/sys/fs/cgroup/user.slice/cgroup.freeze"
	if _, err := os.Stat(freezePath); err == nil {
		e.logger.Println("Freezing user.slice via cgroup v2")
		if !e.dryRun {
			os.WriteFile(freezePath, []byte("1"), 0644)
		}
	} else {
		e.logger.Println("cgroup freezer not available; skipping process freeze")
	}
}

func (e *LinuxEnforcer) run(name string, args ...string) {
	cmdStr := name + " " + strings.Join(args, " ")
	if e.dryRun {
		e.logger.Printf("[DRY-RUN] %s", cmdStr)
		return
	}

	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		e.logger.Printf("[WARN] %s: %v (output: %s)", cmdStr, err, string(output))
	}
}
