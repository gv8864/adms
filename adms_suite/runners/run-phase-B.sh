#!/bin/bash
# SAFETY: MIXED (contains disposable-VM tests)
# PAPER ROLE: Phase B orchestrator
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

cd "$REPO_ROOT/phase-b"

echo "============================================"
echo "ADMS Phase B: Sensor Layer and Enforcement"
echo "============================================"
echo ""

run_step() {
  local name="$1"
  echo ">>> ${name}"
  echo "---"
  bash "$name"
  echo ""
}

run_step B7-dry-run-enforcement.sh
read -r -p "Press Enter to continue to B8, or Ctrl+C to stop..." _
run_step B8-observe-enforcement.sh
read -r -p "Press Enter to continue to B9, or Ctrl+C to stop..." _
run_step B9-restricted-enforcement.sh
read -r -p "Press Enter to continue to B11, or Ctrl+C to stop..." _
run_step B11-maneuver-space-contraction.sh
read -r -p "Press Enter to continue to B10, or Ctrl+C to stop..." _
run_step B10-lockdown-enforcement.sh

echo ""
echo "============================================"
echo "Phase B Complete"
echo "============================================"
"$REPO_ROOT/scripts/collect-results.sh"
