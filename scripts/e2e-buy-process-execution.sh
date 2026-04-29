#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

NODE_URL="${NODE_URL:-http://localhost:18734}"
MAINNET_URL="${MAINNET_URL:-https://state.forward.computer}"
LEGACY_MU_URL="${LEGACY_MU_URL:-https://mu.ao-testnet.xyz}"
TOKEN="${TOKEN:-0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc}"
LEDGER="${LEDGER:-aqu6pW4GemwbDguS-rtCEBT_CJqsLYAWcmAULnZR-cE}"
WALLET="${WALLET:?Set WALLET=/path/to/arweave-keyfile.json}"
QUANTITY="${QUANTITY:-1}"
PAYMENT_TIMEOUT="${PAYMENT_TIMEOUT:-120}"

echo "Buying one paid process execution"
echo "Node:    $NODE_URL"
echo "MU:      $LEGACY_MU_URL"
echo "Ledger:  $LEDGER"
echo "Cost:    $QUANTITY armstrong(s)"
echo "Timeout: ${PAYMENT_TIMEOUT}s"

TRANSFER_ITEM="$(mktemp -t bulbasaur-ao-transfer.XXXXXX.ans104)"
trap 'rm -f "$TRANSFER_ITEM"' EXIT

echo "Creating signed AO transfer data item..."
TRANSFER_LOG="$(
  TOKEN="$TOKEN" LEDGER="$LEDGER" WALLET="$WALLET" QUANTITY="$QUANTITY" \
  SUBMIT=false OUT="$TRANSFER_ITEM" \
  rebar3 shell --apps hackney \
    --eval 'file:script("scripts/submit-ao-transfer-direct.erl"), init:stop().'
)"
printf '%s\n' "$TRANSFER_LOG"

MESSAGE_ID="$(printf '%s\n' "$TRANSFER_LOG" | awk '/^Message: / { print $2; exit }')"
SENDER="$(printf '%s\n' "$TRANSFER_LOG" | awk '/^Sender: / { print $2; exit }')"
if [[ -z "$MESSAGE_ID" || -z "$SENDER" || ! -s "$TRANSFER_ITEM" ]]; then
  echo "Could not create signed AO transfer data item" >&2
  exit 1
fi

echo "Submitting AO transfer to legacy MU..."
MU_RESPONSE="$(
  curl -fsS --max-time "$PAYMENT_TIMEOUT" -X POST "$LEGACY_MU_URL" \
    -H 'content-type: application/octet-stream' \
    -H 'accept: application/json' \
    --data-binary "@$TRANSFER_ITEM"
)"
echo "MU response: $MU_RESPONSE"
MU_ID="$(node -e 'try { console.log(JSON.parse(process.argv[1]).id || "") } catch (_) {}' "$MU_RESPONSE")"
if [[ -n "$MU_ID" && "$MU_ID" != "$MESSAGE_ID" ]]; then
  echo "MU returned id $MU_ID, expected $MESSAGE_ID" >&2
  exit 1
fi

echo "Waiting for AO assignment slot..."
SLOT="$(
  MAINNET_URL="$MAINNET_URL" TOKEN="$TOKEN" MESSAGE_ID="$MESSAGE_ID" node - <<'NODE'
const MAINNET_URL = process.env.MAINNET_URL;
const TOKEN = process.env.TOKEN;
const MESSAGE_ID = process.env.MESSAGE_ID;

async function currentSlot() {
  const res = await fetch(`${MAINNET_URL}/${TOKEN}~process@1.0/slot/current`);
  if (!res.ok) throw new Error(`slot/current failed: ${res.status}`);
  const text = await res.text();
  const match = text.match(/\d+/);
  if (!match) throw new Error(`could not parse current slot: ${text}`);
  return Number(match[0]);
}

function tag(tags, name) {
  return tags?.find((t) => t.name === name)?.value;
}

async function main() {
  const fromSlot = Math.max(0, (await currentSlot()) - 2);
  for (let attempt = 0; attempt < 36; attempt++) {
    const toSlot = (await currentSlot()) + 10;
    const url =
      `${MAINNET_URL}/${TOKEN}~process@1.0/schedule` +
      `?from=${fromSlot}&to=${toSlot}&accept=application/aos-2`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`schedule failed: ${res.status}`);
    const schedule = await res.json();
    for (const edge of schedule.edges || []) {
      if (edge.node?.message?.Id === MESSAGE_ID) {
        const nonce = tag(edge.node.assignment?.Tags, "Nonce");
        if (!nonce) throw new Error(`assignment missing Nonce for ${MESSAGE_ID}`);
        console.log(nonce);
        return;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 5000));
  }
  throw new Error(`message did not appear in AO schedule: ${MESSAGE_ID}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
NODE
)"

echo "AO transfer message: $MESSAGE_ID"
echo "AO assignment slot:  $SLOT"
echo "Payer address:       $SENDER"

echo "Importing verified AO payment into Bulbasaur ledger..."
for _ in $(seq 1 36); do
  if node scripts/ao-payment-bridge.mjs \
    --node "$NODE_URL" \
    --token "$TOKEN" \
    --ledger "$LEDGER" \
    --message-id "$MESSAGE_ID" \
    --slot "$SLOT" \
    --sender "$SENDER" \
    --recipient "$SENDER" \
    --quantity "$QUANTITY"; then
    break
  fi
  echo "Payment not computable yet; retrying..."
  sleep 5
done

echo "Spending imported balance on a real Bulbasaur process compute..."
HB_NODE="$NODE_URL" \
BULBASAUR_USER_WALLET="$WALLET" \
BULBASAUR_PROCESS_PRICE="$QUANTITY" \
rebar3 shell --apps hackney \
  --eval 'file:script("scripts/spend-imported-balance.erl"), init:stop().'
