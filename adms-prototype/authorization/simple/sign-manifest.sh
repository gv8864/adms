#!/bin/bash
# authorization/simple/sign-manifest.sh
# Signs a deployment manifest to create an authorization token for A(t).
# Usage: bash sign-manifest.sh <manifest-path> [ttl-seconds]

set -euo pipefail

MANIFEST="${1:?Usage: sign-manifest.sh <manifest-path> [ttl-seconds]}"
TTL_SECONDS="${2:-300}"
KEY_PATH="${ADMS_KEY_PATH:-/etc/adms/operator.key}"
TOKEN_DIR="${ADMS_TOKEN_DIR:-/var/run/adms}"

mkdir -p "$TOKEN_DIR"

EXPIRY=$(($(date +%s) + TTL_SECONDS))
MANIFEST_HASH=$(sha256sum "$MANIFEST" | cut -d' ' -f1)

# Create token
cat > "$TOKEN_DIR/auth-token.json" <<EOF
{
    "manifest_hash": "$MANIFEST_HASH",
    "issued_at": $(date +%s),
    "expires_at": $EXPIRY,
    "workload_id": "$(hostname)",
    "deployment_intent": "$MANIFEST"
}
EOF

# Sign with operator key
openssl dgst -sha256 -sign "$KEY_PATH" \
    -out "$TOKEN_DIR/auth-token.sig" \
    "$TOKEN_DIR/auth-token.json"

echo "Authorization token issued:"
echo "  Manifest: $MANIFEST"
echo "  Hash:     $MANIFEST_HASH"
echo "  TTL:      ${TTL_SECONDS}s"
echo "  Expires:  $(date -d "@$EXPIRY" 2>/dev/null || date -r "$EXPIRY" 2>/dev/null || echo "$EXPIRY")"
