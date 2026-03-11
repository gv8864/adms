package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/adms-prototype/pkg/controller"
	"github.com/adms-prototype/pkg/enforcement"
	"github.com/adms-prototype/pkg/sensors"
	"github.com/adms-prototype/pkg/signals"
)

func main() {
	// Controller parameters
	tau := flag.Duration("tau", time.Second, "controller sampling interval")
	q := flag.Int("q", 60, "quiet intervals required for rollback eligibility")
	delta := flag.Int("delta", 3, "minimum dwell intervals before de-escalation")

	// Enforcement config
	dryRun := flag.Bool("dry-run", false, "log enforcement actions without executing")
	controllerCIDR := flag.String("controller-cidr", "127.0.0.1/32", "CIDR for controller/attestation channel")

	// Authorization config
	pubkeyPath := flag.String("pubkey", "/etc/adms/operator.pub", "operator public key for A(t) verification")
	tokenDir := flag.String("token-dir", "/var/run/adms", "directory for authorization tokens")

	// Sensor config
	sensorMode := flag.String("sensor", "tetragon", "sensor mode: tetragon, inject, or manual")

	// Output
	logPath := flag.String("log", "", "path for structured log output (default: stdout)")
	metricsPath := flag.String("metrics", "/tmp/adms-metrics.json", "path for metrics export on shutdown")
	httpAddr := flag.String("http", ":8080", "HTTP API address")

	flag.Parse()

	log.Printf("ADMS Controller starting: tau=%s q=%d delta=%d sensor=%s dry-run=%v",
		*tau, *q, *delta, *sensorMode, *dryRun)
	log.Printf("Log path: %q, Metrics path: %q", *logPath, *metricsPath)

	// Initialize enforcement
	enforcer := enforcement.NewLinuxEnforcer(enforcement.LinuxEnforcerConfig{
		ControllerCIDR: *controllerCIDR,
		DryRun:         *dryRun,
	})

	// Initialize controller
	cfg := controller.Config{
		Tau:   *tau,
		Q:     *q,
		Delta: *delta,
	}

	ctrl, err := controller.New(cfg, enforcer, *logPath)
	if err != nil {
		log.Fatalf("Failed to create controller: %v", err)
	}
	defer ctrl.Close()

	// Initialize authorization
	var authorizer *signals.Authorizer
	if _, err := os.Stat(*pubkeyPath); err == nil {
		authorizer, err = signals.NewAuthorizer(*pubkeyPath, *tokenDir)
		if err != nil {
			log.Printf("WARNING: authorization disabled: %v", err)
		}
	} else {
		log.Printf("WARNING: no pubkey at %s, authorization disabled", *pubkeyPath)
	}

	// Initialize sensor collector
	collector := sensors.NewEventCollector(sensors.EventCollectorConfig{})

	// Start sensor reader based on mode
	switch *sensorMode {
	case "tetragon":
		// Read from Tetragon's JSON export on stdin
		go collector.StartTetragonReader(os.Stdin)
		log.Println("Reading Tetragon events from stdin")
		log.Println("  Pipe events: tetragon --export-stdout | adms-controller --sensor=tetragon")
	case "inject":
		log.Println("Manual injection mode — use HTTP API to inject drift events")
	case "manual":
		log.Println("Manual mode — no automatic sensor reading")
	}

	// Start HTTP API
	go startHTTPServer(*httpAddr, ctrl, collector, authorizer)

	// Main control loop
	ticker := time.NewTicker(*tau)
	defer ticker.Stop()

	// Handle shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	log.Println("Controller running. Press Ctrl+C to stop.")

	for {
		select {
		case <-ticker.C:
			// Drain sensor events for this interval
			drift, kernelNS := collector.DrainInterval()

			// Compute A(t)
			authorized := false
			if authorizer != nil {
				authorized = authorizer.IsAuthorized()
			}

			// Tick the controller
			ctrl.Tick(drift, authorized, kernelNS)

		case <-sigCh:
			log.Println("Shutting down...")

			// Export metrics
			data, err := ctrl.ExportMetrics()
			if err == nil {
				os.WriteFile(*metricsPath, data, 0644)
				log.Printf("Metrics written to %s", *metricsPath)
			}

			return
		}
	}
}

func startHTTPServer(addr string, ctrl *controller.Controller,
	collector *sensors.EventCollector, authorizer *signals.Authorizer) {

	// GET /posture — current posture
	http.HandleFunc("/posture", func(w http.ResponseWriter, r *http.Request) {
		level := ctrl.Posture()
		json.NewEncoder(w).Encode(map[string]interface{}{
			"level": level,
			"name":  controller.PostureName(level),
		})
	})

	// GET /metrics — full metrics export
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		data, err := ctrl.ExportMetrics()
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(data)
	})

	// POST /breakglass — emergency override
	http.HandleFunc("/breakglass", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			http.Error(w, "POST only", 405)
			return
		}
		var req struct {
			Reason string `json:"reason"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		if req.Reason == "" {
			req.Reason = "HTTP break-glass"
		}
		ctrl.BreakGlass(req.Reason)
		json.NewEncoder(w).Encode(map[string]string{"status": "ok", "posture": "NORMAL"})
	})

	// POST /inject — manual drift injection (for testing)
	http.HandleFunc("/inject", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			http.Error(w, "POST only", 405)
			return
		}
		var req struct {
			Dimension string `json:"dimension"` // I, P, D, E, N
		}
		json.NewDecoder(r.Body).Decode(&req)

		var dim signals.Dimension
		switch req.Dimension {
		case "I":
			dim = signals.DimIdentity
		case "P":
			dim = signals.DimPrivilege
		case "D":
			dim = signals.DimDurability
		case "E":
			dim = signals.DimExecution
		case "N":
			dim = signals.DimNetwork
		default:
			http.Error(w, fmt.Sprintf("unknown dimension: %s", req.Dimension), 400)
			return
		}

		collector.InjectDrift(dim)
		json.NewEncoder(w).Encode(map[string]string{
			"status":    "injected",
			"dimension": req.Dimension,
		})
	})

	log.Printf("HTTP API listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Printf("HTTP server error: %v", err)
	}
}
