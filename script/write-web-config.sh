#!/usr/bin/env bash
# Update web/src/deployments.json for one chain. No secrets.
# Usage: write-web-config.sh <chainId> <factoryAddress> [usdcAddress] [wethAddress]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${DEPLOYMENTS_PATH:-$ROOT/web/src/deployments.json}"
CHAIN_ID=${1:?chain id}
FACTORY=${2:?factory address}
USDC=${3:-}
WETH=${4:-}
if [ ! -f "$FILE" ]; then
  echo "write-web-config: $FILE not found" >&2
  exit 1
fi
tmp="$(mktemp)"
if [ -n "$USDC" ] && [ -n "$WETH" ]; then
  jq --arg c "$CHAIN_ID" --arg f "$FACTORY" --arg u "$USDC" --arg w "$WETH" \
    '.[$c] = ((.[$c] // {}) | .factory = $f | .usdc = $u | .weth = $w)' "$FILE" > "$tmp"
elif [ -n "$USDC" ]; then
  jq --arg c "$CHAIN_ID" --arg f "$FACTORY" --arg u "$USDC" \
    '.[$c] = ((.[$c] // {}) | .factory = $f | .usdc = $u)' "$FILE" > "$tmp"
else
  jq --arg c "$CHAIN_ID" --arg f "$FACTORY" \
    '.[$c] = ((.[$c] // {}) | .factory = $f)' "$FILE" > "$tmp"
fi
mv "$tmp" "$FILE"
echo "Wrote factory $FACTORY to web/src/deployments.json (chain $CHAIN_ID)"
