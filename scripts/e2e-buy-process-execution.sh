#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

NODE_URL="${NODE_URL:-http://localhost:18734}"
MAINNET_URL="${MAINNET_URL:-https://state.forward.computer}"
TOKEN="${TOKEN:-0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc}"
LEDGER="${LEDGER:-aqu6pW4GemwbDguS-rtCEBT_CJqsLYAWcmAULnZR-cE}"
WALLET="${WALLET:?Set WALLET=/path/to/arweave-keyfile.json}"
QUANTITY="${QUANTITY:-1}"

echo "Buying one paid process execution"
echo "Node:    $NODE_URL"
echo "Ledger:  $LEDGER"
echo "Cost:    $QUANTITY armstrong(s)"

PAYMENT_JSON="$(
  MAINNET_URL="$MAINNET_URL" TOKEN="$TOKEN" LEDGER="$LEDGER" \
  WALLET="$WALLET" QUANTITY="$QUANTITY" node - <<'NODE' | tail -n 1
const fs = require("node:fs");
const crypto = require("node:crypto");
const { connect, createSigner } = require("@permaweb/aoconnect");

const MAINNET_URL = process.env.MAINNET_URL;
const TOKEN = process.env.TOKEN;
const LEDGER = process.env.LEDGER;
const WALLET = process.env.WALLET;
const QUANTITY = process.env.QUANTITY;

const walletBytes = fs.readFileSync(WALLET);
const wallet = JSON.parse(walletBytes);

function fromBase64Url(s) {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  return Buffer.from(s, "base64");
}

const sender = crypto
  .createHash("sha256")
  .update(fromBase64Url(wallet.n))
  .digest("base64url");

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

async function findScheduledSlot(messageId, fromSlot) {
  for (let attempt = 0; attempt < 36; attempt++) {
    const toSlot = (await currentSlot()) + 10;
    const url =
      `${MAINNET_URL}/${TOKEN}~process@1.0/schedule` +
      `?from=${fromSlot}&to=${toSlot}&accept=application/aos-2`;

    const res = await fetch(url);
    if (!res.ok) throw new Error(`schedule failed: ${res.status}`);
    const schedule = await res.json();

    for (const edge of schedule.edges || []) {
      const msg = edge.node?.message;
      const assignment = edge.node?.assignment;
      if (msg?.Id === messageId) {
        return tag(assignment?.Tags, "Nonce");
      }
    }

    await new Promise((resolve) => setTimeout(resolve, 5000));
  }
  throw new Error(`message did not appear in AO schedule: ${messageId}`);
}

const signer = createSigner(walletBytes);
const ao = connect({ MODE: "mainnet", URL: MAINNET_URL, signer });

const fromSlot = Math.max(0, (await currentSlot()) - 2);
const sent = await ao.message({
  process: TOKEN,
  signer,
  tags: [
    { name: "Action", value: "Transfer" },
    { name: "Recipient", value: LEDGER },
    { name: "Quantity", value: QUANTITY },
    { name: "X-HB-Recipient", value: sender },
  ],
});

const messageId =
  typeof sent === "string" ? sent : sent.messageId || sent.id || sent.Id;
if (!messageId) {
  throw new Error(`could not find message id in ${JSON.stringify(sent)}`);
}

const slot = await findScheduledSlot(messageId, fromSlot);
console.log(JSON.stringify({ messageId, slot, sender }));
NODE
)"

MESSAGE_ID="$(node -e 'console.log(JSON.parse(process.argv[1]).messageId)' "$PAYMENT_JSON")"
SLOT="$(node -e 'console.log(JSON.parse(process.argv[1]).slot)' "$PAYMENT_JSON")"
SENDER="$(node -e 'console.log(JSON.parse(process.argv[1]).sender)' "$PAYMENT_JSON")"

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
