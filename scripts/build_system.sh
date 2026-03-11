tar xzf adms-prototype.tar.gz
cd adms-prototype

# Option 1: Quick test (no root needed)
go mod tidy
make test-unit     # runs all 15 controller tests including n=50 determinism

# Option 2: Full bare-metal install
sudo bash deploy/bare-metal/install.sh
systemctl start adms-controller
bash test/run-all.sh

# Option 3: Kubernetes
make setup-k8s

