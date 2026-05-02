#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${WALLET:-}" ]]; then
  echo "WALLET is required. Set it to the uploader Arweave JWK path." >&2
  echo "Example: WALLET=/absolute/path/to/uploader.json $0" >&2
  exit 64
fi

NODE_URL="${NODE_URL:-http://localhost:8734}"
LEDGER_ROUTE="${LEDGER_ROUTE:-/ledger~node-process@1.0}"
BYTE_PRICE="${BYTE_PRICE:-1162726}"
TEXT_PAYLOAD="${TEXT_PAYLOAD:-Bulbasaur paid AO bundler upload smoke test $(date -Iseconds)-$RANDOM}"
GATEWAY="${GATEWAY:-https://arweave.net}"
TIMEOUT_MS="${TIMEOUT_MS:-240000}"
POLL_MS="${POLL_MS:-2000}"
UPLOAD_PATH="${UPLOAD_PATH:-/~bundler@1.0/item?codec-device=ans104@1.0}"

ARGS=(
  --wallet "$WALLET"
  --node "$NODE_URL"
  --upload-path "$UPLOAD_PATH"
  --ledger-route "$LEDGER_ROUTE"
  --byte-price "$BYTE_PRICE"
  --gateway "$GATEWAY"
  --timeout-ms "$TIMEOUT_MS"
  --poll-ms "$POLL_MS"
  --text "$TEXT_PAYLOAD"
)

if [[ -n "${BENEFICIARY:-}" ]]; then
  ARGS+=(--beneficiary "$BENEFICIARY")
fi

exec node "$HERE/paid-bundler-upload.mjs" "${ARGS[@]}" "$@"
