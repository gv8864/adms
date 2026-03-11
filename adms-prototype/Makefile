.PHONY: build test test-unit test-integration clean install docker help

BINARY     := adms-controller
BUILD_DIR  := bin
GO         := go
GOFLAGS    := -trimpath
LDFLAGS    := -s -w

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

build: ## Build the controller binary
	mkdir -p $(BUILD_DIR)
	$(GO) build $(GOFLAGS) -ldflags '$(LDFLAGS)' -o $(BUILD_DIR)/$(BINARY) ./cmd/controller/
	@echo "Built: $(BUILD_DIR)/$(BINARY)"

test-unit: ## Run unit tests (no root required)
	$(GO) test -v -count=1 ./pkg/controller/...
	$(GO) test -v -count=1 ./pkg/signals/...

test-integration: build ## Run integration tests (requires running controller)
	@echo "Starting controller in background (dry-run mode)..."
	$(BUILD_DIR)/$(BINARY) --dry-run --sensor=inject --tau=1s --q=3 --delta=1 &
	@sleep 2
	@echo "Running test suite..."
	bash test/run-all.sh http://localhost:8080 || true
	@echo "Stopping controller..."
	@pkill -f $(BINARY) || true

test: test-unit ## Run all tests

clean: ## Remove build artifacts
	rm -rf $(BUILD_DIR)
	rm -f /tmp/adms-metrics.json
	rm -rf /tmp/adms-test-results

install: build ## Install to system (requires root)
	install -m 755 $(BUILD_DIR)/$(BINARY) /usr/local/bin/
	install -m 700 breakglass/reset.sh /usr/local/sbin/adms-breakglass
	mkdir -p /etc/adms /var/run/adms /var/log/adms
	@echo "Installed. Generate keys: make keys"

keys: ## Generate operator signing keys
	@mkdir -p /etc/adms
	openssl genrsa -out /etc/adms/operator.key 4096
	openssl rsa -in /etc/adms/operator.key -pubout -out /etc/adms/operator.pub
	chmod 600 /etc/adms/operator.key
	@echo "Keys: /etc/adms/operator.{key,pub}"

docker: ## Build Docker image for Kubernetes deployment
	docker build -t adms-controller:latest -f Dockerfile .

setup-bare-metal: ## Full bare-metal installation (requires root)
	sudo bash deploy/bare-metal/install.sh

setup-k8s: docker ## Deploy to Kubernetes
	kubectl apply -f deploy/kubernetes/workloads.yaml
	kubectl apply -f deploy/kubernetes/controller-deploy.yaml
	kubectl apply -f sensors/tetragon/
	@echo "Deployed. Check: kubectl get pods -n adms-test"
