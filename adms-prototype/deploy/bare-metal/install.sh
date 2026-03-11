#!/bin/bash
# deploy/bare-metal/install.sh — Set up ADMS prototype on a bare-metal Linux host.
# Requirements: Ubuntu 22.04+, kernel 5.15+, root access.
# Usage: sudo bash deploy/bare-metal/install.sh

set -euo pipefail

echo "============================================"
echo "ADMS Bare-Metal Installation"
echo "============================================"

# Check kernel version
KVER=$(uname -r | cut -d. -f1-2)
echo "Kernel: $(uname -r)"
if [ "$(echo "$KVER 5.15" | awk '{print ($1 >= $2)}')" != "1" ]; then
    echo "ERROR: Kernel 5.15+ required for full eBPF support"
    exit 1
fi

# 1. Install dependencies
echo ""
echo "[1/7] Installing dependencies..."
apt-get update -qq
apt-get install -y -qq \
    linux-tools-common "linux-tools-$(uname -r)" \
    auditd nftables jq curl openssl \
    build-essential git

# 2. Install Go
echo "[2/7] Installing Go..."
if ! command -v go &> /dev/null; then
    GO_VERSION="1.22.0"
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
    export PATH=$PATH:/usr/local/go/bin
fi
echo "  Go $(go version | awk '{print $3}')"

# 3. Install Tetragon
echo "[3/7] Installing Tetragon..."
if ! command -v tetragon &> /dev/null; then
    TETRA_VERSION=$(curl -sf https://api.github.com/repos/cilium/tetragon/releases/latest | jq -r .tag_name)
    curl -sLO "https://github.com/cilium/tetragon/releases/download/${TETRA_VERSION}/tetragon-linux-amd64.tar.gz"
    tar xzf tetragon-linux-amd64.tar.gz
    install -m 755 tetragon /usr/local/bin/
    install -m 755 tetra /usr/local/bin/
    rm -f tetragon-linux-amd64.tar.gz tetragon tetra
fi
echo "  Tetragon: $(tetragon version 2>/dev/null || echo 'installed')"

# 4. Generate operator signing keys
echo "[4/7] Generating operator keys..."
mkdir -p /etc/adms /var/run/adms /var/log/adms
if [ ! -f /etc/adms/operator.key ]; then
    openssl genrsa -out /etc/adms/operator.key 4096 2>/dev/null
    openssl rsa -in /etc/adms/operator.key -pubout -out /etc/adms/operator.pub 2>/dev/null
    chmod 600 /etc/adms/operator.key
    echo "  Keys generated at /etc/adms/operator.{key,pub}"
else
    echo "  Keys already exist, skipping"
fi

# 5. Build controller
echo "[5/7] Building ADMS controller..."
cd "$(dirname "$0")/../.."
go build -o /usr/local/bin/adms-controller ./cmd/controller/
echo "  Binary: /usr/local/bin/adms-controller"

# 6. Install break-glass
echo "[6/7] Installing break-glass mechanism..."
install -m 700 breakglass/reset.sh /usr/local/sbin/adms-breakglass
echo "  Break-glass: /usr/local/sbin/adms-breakglass"

# 7. Create systemd service
echo "[7/7] Creating systemd service..."
cat > /etc/systemd/system/adms-controller.service <<EOF
[Unit]
Description=ADMS Posture Controller
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/adms-controller \\
    --tau=1s --q=60 --delta=3 \\
    --sensor=inject \\
    --http=:8080 \\
    --metrics=/var/log/adms/metrics.json \\
    --log=/var/log/adms/controller.log
Restart=always
RestartSec=5

# Resource cap (DoS resistance)
MemoryMax=256M
CPUQuota=10%

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo "  Service: adms-controller.service"
echo "  Start with: systemctl start adms-controller"

echo ""
echo "============================================"
echo "Installation complete."
echo ""
echo "Quick start:"
echo "  systemctl start adms-controller"
echo "  curl http://localhost:8080/posture"
echo ""
echo "Run tests:"
echo "  bash test/run-all.sh"
echo ""
echo "Break-glass (emergency):"
echo "  sudo adms-breakglass"
echo "============================================"
