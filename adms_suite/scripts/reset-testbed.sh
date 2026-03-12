#!/usr/bin/env bash
# SAFETY: HOST-SAFE
# Best-effort shared reset/cleanup for nftables, cgroups, and mounts.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

adms_reset_enforcement
adms_stop_controller || true
echo "ADMS reset complete"
