#!/bin/bash
# SAFETY: HOST-SAFE
# PAPER ROLE: Phase C orchestrator
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

cd "$REPO_ROOT/phase-c"

echo "============================================"
echo "ADMS Phase C: Full Evaluation (M1-M5)"
echo "============================================"
echo ""

run_step() {
  local name="$1"
  echo ">>> ${name}"
  echo "---"
  bash "$name"
  echo ""
}

run_step C1-M1-transition-correctness.sh
read -r -p "Press Enter to continue to C2, or Ctrl+C to stop..." _
run_step C2-M3-contraction-proxy.sh
read -r -p "Press Enter to continue to C3, or Ctrl+C to stop..." _
run_step C3-M4-false-escalation.sh
read -r -p "Press Enter to continue to C4, or Ctrl+C to stop..." _
run_step C4-M5-rollback.sh
read -r -p "Press Enter to continue to C5, or Ctrl+C to stop..." _
run_step C5-parameter-sweep.sh

echo ""
echo "============================================"
echo "Phase C Complete — All Metrics Collected"
echo "============================================"
"$REPO_ROOT/scripts/collect-results.sh"
