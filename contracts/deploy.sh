#!/usr/bin/env bash
# Deploy to Base Sepolia and write the resulting addresses into ../.env.
# Usage: ./deploy.sh            (from contracts/)
set -euo pipefail

cd "$(dirname "$0")"
ENV_FILE="../.env"

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — copy .env.example and fill it in"; exit 1; }
set -a; source "$ENV_FILE"; set +a

# Contracts are immutable once deployed: tests must be green first.
forge test

mkdir -p deployments
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --broadcast \
  -vv

# Merge USDC_ADDRESS / VAULT_ADDRESS into .env, replacing any previous values.
grep -vE '^(USDC_ADDRESS|VAULT_ADDRESS)=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
cat deployments/latest.env >> "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"

echo
echo "Wrote to .env:"
cat deployments/latest.env
