#!/usr/bin/env bash
# SAFETY: HOST-SAFE
# PAPER ROLE: result aggregation / evidence bundling
#
# Collects evaluation outputs into a single timestamped directory and tarball.
#
# Usage:
#   sudo bash combine-results.sh
#   sudo RESULTS_ROOT=/path/to/results bash combine-results.sh
#
# Expected source artifacts (best-effort; missing files are tolerated):
#   /tmp/adms-C1-M1.log
#   /tmp/adms-C2-M3.log
#   /tmp/adms-C3-M4.log
#   /tmp/adms-C4-M5.log
#   /tmp/adms-C5-parameter-sweep.log
#   /tmp/adms-B11.log
#   /tmp/adms-*.json
#   /var/log/adms/controller.log
set -euo pipefail

RESULTS_ROOT="${RESULTS_ROOT:-$PWD/results}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${RESULTS_ROOT}/${TS}"
BUNDLE_NAME="adms-results-${TS}.tar.gz"

mkdir -p "${OUT_DIR}"

log() { printf '[combine-results] %s\n' "$*"; }

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [ -e "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
    log "copied: $src -> $dst"
  else
    log "missing: $src"
  fi
}

copy_glob_if_exists() {
  local pattern="$1"
  local dst_dir="$2"
  shopt -s nullglob
  local files=( $pattern )
  shopt -u nullglob
  if [ ${#files[@]} -gt 0 ]; then
    mkdir -p "$dst_dir"
    for f in "${files[@]}"; do
      cp -f "$f" "$dst_dir/"
      log "copied: $f -> $dst_dir/"
    done
  else
    log "missing glob: $pattern"
  fi
}

log "creating output directory: ${OUT_DIR}"

# Core logs by metric / test
copy_if_exists /tmp/adms-C1-M1.log                "${OUT_DIR}/C1/log.txt"
copy_if_exists /tmp/adms-C2-M3.log                "${OUT_DIR}/C2/log.txt"
copy_if_exists /tmp/adms-C3-M4.log                "${OUT_DIR}/C3/log.txt"
copy_if_exists /tmp/adms-C4-M5.log                "${OUT_DIR}/C4/log.txt"
copy_if_exists /tmp/adms-C5-parameter-sweep.log   "${OUT_DIR}/C5/log.txt"
copy_if_exists /tmp/adms-B11.log                  "${OUT_DIR}/B11/log.txt"

# Metrics / JSON artifacts
copy_glob_if_exists /tmp/adms-C1-*.json "${OUT_DIR}/C1"
copy_glob_if_exists /tmp/adms-C2-*.json "${OUT_DIR}/C2"
copy_glob_if_exists /tmp/adms-C3-*.json "${OUT_DIR}/C3"
copy_glob_if_exists /tmp/adms-C4-*.json "${OUT_DIR}/C4"
copy_glob_if_exists /tmp/adms-C5-*.json "${OUT_DIR}/C5"
copy_glob_if_exists /tmp/adms-B11*.json "${OUT_DIR}/B11"

# Generic JSON sweep
copy_glob_if_exists /tmp/adms-*.json "${OUT_DIR}/all-json"

# Controller / platform evidence
copy_if_exists /var/log/adms/controller.log "${OUT_DIR}/platform/controller.log"

if command -v nft >/dev/null 2>&1; then
  mkdir -p "${OUT_DIR}/platform"
  nft list ruleset > "${OUT_DIR}/platform/nft-ruleset.txt" 2>/dev/null || true
fi

if command -v curl >/dev/null 2>&1; then
  mkdir -p "${OUT_DIR}/platform"
  curl -fsS --max-time 2 http://localhost:8080/posture \
    > "${OUT_DIR}/platform/posture-snapshot.json" 2>/dev/null || true
fi

# Environment manifest
cat > "${OUT_DIR}/MANIFEST.txt" <<EOF
ADMS Evaluation Bundle
Generated: $(date)
Host: $(hostname 2>/dev/null || echo unknown)
User: $(id -un 2>/dev/null || echo unknown)
Kernel: $(uname -a 2>/dev/null || echo unknown)

Included groups:
- C1: M1 transition correctness
- C2: M3 analytical contraction proxy
- C3: M4 false escalation rate
- C4: M5 rollback / liveness
- C5: parameter sensitivity
- B11: empirical maneuver-space contraction
- platform: controller log, nft ruleset, posture snapshot
EOF

# Template summary if not already present
cat > "${OUT_DIR}/RESULTS.md" <<'EOF'
# ADMS Evaluation Summary

## M1 — Transition Correctness
- Script: C1-M1-transition-correctness.sh
- Result:
- Evidence:
- Notes:

## M3 — Maneuver-Space Contraction (Analytical)
- Script: C2-M3-contraction-proxy.sh
- Result:
- Evidence:
- Notes:

## M3 — Maneuver-Space Contraction (Empirical)
- Script: B11-maneuver-space-contraction.sh
- Result:
- Evidence:
- Notes:

## M4 — False Escalation Rate
- Script: C3-M4-false-escalation.sh
- Authorized cycles:
- False escalations:
- Rate:
- Expired token test:
- Notes:

## M5 — Rollback / Liveness
- Script: C4-M5-rollback.sh
- Rollback complete:
- L_rollback:
- Stepwise rollback:
- Rollback blocked during active drift:
- Notes:

## Sensitivity / Parameter Sweep
- Script: C5-parameter-sweep.sh
- Result:
- Evidence:
- Notes:

## Overall Assessment
- Deterministic posture transitions:
- Maneuver-space contraction:
- Low false escalation under authorized drift:
- Eventual rollback / liveness:
- Sensitivity to q / delta / tau:
EOF

tar -czf "${RESULTS_ROOT}/${BUNDLE_NAME}" -C "${RESULTS_ROOT}" "${TS}"
log "bundle created: ${RESULTS_ROOT}/${BUNDLE_NAME}"
log "summary template: ${OUT_DIR}/RESULTS.md"
log "done"

