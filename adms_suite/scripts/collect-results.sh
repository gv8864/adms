#!/usr/bin/env bash
# SAFETY: HOST-SAFE
# Collects logs, metrics, and best-effort final state into one bundle.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${1:-$ADMS_RESULTS_DIR/bundle-$STAMP}"
adms_prepare_results_dir
adms_collect_results "$OUTDIR"
tar -C "$(dirname "$OUTDIR")" -czf "${OUTDIR}.tar.gz" "$(basename "$OUTDIR")"
echo "Collected results in: $OUTDIR"
echo "Archive: ${OUTDIR}.tar.gz"
