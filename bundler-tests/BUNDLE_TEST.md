# Bulbasaur Paid Bundler Test

This folder contains a standalone JavaScript test that signs a text payload as
an ANS-104 data item, pays the Bulbasaur bundler route in local AO ledger units,
waits for the bundle to complete, and prints the item ID, bundle txid, ledger
debit, settlement credit, and gateway probes.

## 1. Prerequisites

First, fund the **node wallet** with enough AR to post bundles to Arweave, and
make sure the **uploader keyfile** you will test with has AO. Use two different
wallets for the cleanest test:

- `NODE_WALLET`: Arweave JWK used by the Bulbasaur node. This wallet pays the
  Arweave L1 bundle transaction fee and must have AR.
- `UPLOADER_WALLET`: Arweave JWK used by the test client. This wallet signs the
  data item and should be the AO-paying user.

The upload test spends AO from Bulbasaur's local ledger. The command below
pre-funds that local ledger with `BULBASAUR_INITIAL_BALANCE_*` so the paid
bundler path can be tested immediately: signed upload, metered price, local
ledger debit, Arweave bundle post, bundle completion hook, and beneficiary
credit.

That pre-funding is a local test shortcut. It does not perform the separate
mainnet AO deposit/import step. To test the deposit/import device too, first
send AO to the node deposit address and import it with the `ao-payment@1.0`
flow documented in `BULBASAUR.md`; then start the node without the
`BULBASAUR_INITIAL_BALANCE_*` env vars and run the same upload test.

## 2. Clone And Install

```sh
git clone https://github.com/xylophonez/bulbasaur.git
cd bulbasaur
git checkout feat/bundler-optimistic-cache
rebar3 compile
cd bundler-tests
npm install
cd ..
```

## 3. Choose Paths And Addresses

Set these values in the shell where you will run the node and test:

```sh
export NODE_WALLET=/absolute/path/to/node-wallet-with-ar.json
export UPLOADER_WALLET=/absolute/path/to/uploader-wallet-with-ao.json
export UPLOADER_ADDRESS=replace-with-uploader-wallet-address
export HB_PORT=8734
```

`UPLOADER_ADDRESS` is the plain Arweave wallet address derived from
`UPLOADER_WALLET`, for example
`aYDOU6kEcE3lK7aA-gTmUKHTbLlQnZZXWpv1_i_Uq1U`. Do not include an `ar://`
prefix or any surrounding quotes in the exported value.

## 4. Start Bulbasaur

Start the node from the repository root:

```sh
HB_KEY="$NODE_WALLET" \
HB_PORT="$HB_PORT" \
BULBASAUR_BUNDLER_MAX_ITEMS=1 \
BULBASAUR_INITIAL_BALANCE_ADDRESS="$UPLOADER_ADDRESS" \
BULBASAUR_INITIAL_BALANCE=100000000000000000 \
./scripts/start-bulbasaur.sh
```

Leave that process running. Copy the printed `Operator` value; for the default
configuration it is also the bundler beneficiary and AO deposit address.

Example startup lines to look for:

```text
Bulbasaur paid-process node started at http://localhost:8734/
Operator: <node-wallet-address>
Bundler beneficiary: <node-wallet-address>
Ledger process ID: <ledger-process-id>
AO deposit address: <node-wallet-address>
Ledger route: /ledger~node-process@1.0
```

## 5. Run The E2E Upload Test

In a second terminal, from the repository root:

```sh
export NODE_URL=http://localhost:8734
export BENEFICIARY=replace-with-operator-address-printed-by-node
export TEXT_PAYLOAD="Bulbasaur paid AO upload $(date -Iseconds)-$RANDOM"

WALLET="$UPLOADER_WALLET" \
NODE_URL="$NODE_URL" \
BENEFICIARY="$BENEFICIARY" \
TEXT_PAYLOAD="$TEXT_PAYLOAD" \
./bundler-tests/run-paid-bundler-upload-verbose.sh
```

The wrapper calls:

```sh
node bundler-tests/paid-bundler-upload.mjs \
  --wallet "$UPLOADER_WALLET" \
  --node "$NODE_URL" \
  --upload-path "/~bundler@1.0/item?codec-device=ans104@1.0" \
  --ledger-route "/ledger~node-process@1.0" \
  --beneficiary "$BENEFICIARY" \
  --byte-price 1162726 \
  --gateway https://arweave.net \
  --timeout-ms 240000 \
  --poll-ms 2000 \
  --text "$TEXT_PAYLOAD"
```

## 6. Expected Output

A successful run should include:

```text
HTTP status              200 OK
Raw HTTP status          200 OK
Raw matches upload       true
Uploader delta           -<charged-ao-base-units> base units
Bundle tx found: <txid>; status=complete
Beneficiary balance      <credited-ao-base-units>
Paid POST                accepted
Optimistic raw read      matched uploaded text
Bundle status            complete
Arweave bundle           https://arweave.net/tx/<txid>
```

The script proves immediate local retrieval by calling
`/~arweave@2.9/raw=<item-id>` immediately after the paid POST and comparing the
returned bytes to the uploaded text. This should happen before the bundle txid
appears, because the bundler writes accepted uploads into the local cache. Once
the bundle reaches `complete`, Bulbasaur runs a mempool-copycat pass for that
bundle tx so pending Arweave offset reads are available before gateway indexing
catches up.

The beneficiary balance may be `404` before the upload if the account has not
been credited in the local ledger yet. It should resolve after the bundle
completion hook credits the beneficiary.

The gateway can report the bundle transaction as `202` while it is pending
mining/indexing. The test treats that as proof that the bundle was accepted by
Arweave. The individual data item may take longer to appear at
`https://arweave.net/<item-id>` because gateway indexing of bundled data items
lags the bundle transaction.

The default upload path in this test is the raw ANS-104-compatible route:
`/~bundler@1.0/item?codec-device=ans104@1.0`. Bulbasaur also protects the
`/~bundler@1.0/tx` alias. Both routes are priced by `metering@1.0` and checked
by `p4@1.0` before the bundler accepts the item.

## 7. Real AO Deposit/Import Variant

The default command in step 4 uses `BULBASAUR_INITIAL_BALANCE_*` to pre-fund the
local ledger for a fast paid-upload test. To also test the real
`ao-payment@1.0` import device, start Bulbasaur without those two env vars:

```sh
HB_KEY="$NODE_WALLET" \
HB_PORT="$HB_PORT" \
BULBASAUR_BUNDLER_MAX_ITEMS=1 \
./scripts/start-bulbasaur.sh
```

Copy the printed `Ledger process ID` and `AO deposit address`, then submit a
small AO transfer from the uploader wallet to the node deposit address:

```sh
export TOKEN=0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc
export LEDGER_ID=replace-with-printed-ledger-process-id
export DEPOSIT_ADDRESS=replace-with-printed-ao-deposit-address
export QUANTITY=5000000000

HB_PORT=19110 \
TOKEN="$TOKEN" \
LEDGER="$LEDGER_ID" \
DEPOSIT_ADDRESS="$DEPOSIT_ADDRESS" \
LOCAL_RECIPIENT="$UPLOADER_ADDRESS" \
WALLET="$UPLOADER_WALLET" \
QUANTITY="$QUANTITY" \
rebar3 shell --apps hackney \
  --eval 'file:script("scripts/submit-ao-transfer-direct.erl"), init:stop().' \
  2>&1 | tee /tmp/bulbasaur-ao-transfer.log
```

The transfer output includes `Message: <message-id>`. Extract it and find its AO
assignment slot on the root token schedule:

```sh
export MESSAGE_ID="$(awk '/^Message: / { print $2; exit }' /tmp/bulbasaur-ao-transfer.log)"
export SLOT="$(
  node bundler-tests/find-ao-assignment-slot.mjs \
    --token "$TOKEN" \
    --message-id "$MESSAGE_ID"
)"
echo "$MESSAGE_ID"
echo "$SLOT"
```

Import the verified AO transfer into the local Bulbasaur ledger:

```sh
node scripts/ao-payment-bridge.mjs \
  --node "http://localhost:$HB_PORT" \
  --token "$TOKEN" \
  --ledger "$LEDGER_ID" \
  --message-id "$MESSAGE_ID" \
  --slot "$SLOT" \
  --sender "$UPLOADER_ADDRESS" \
  --recipient "$UPLOADER_ADDRESS" \
  --quantity "$QUANTITY"
```

Confirm the imported local balance:

```sh
curl "http://localhost:$HB_PORT/ledger~node-process@1.0/now/balance/$UPLOADER_ADDRESS"
```

Then run the same paid upload command from step 5. In this mode, the upload is
spending balance imported by `ao-payment@1.0`, not balance seeded by
`BULBASAUR_INITIAL_BALANCE_*`.

## 8. Capture A Log

To save the full run output:

```sh
mkdir -p bundler-tests/logs
WALLET="$UPLOADER_WALLET" \
NODE_URL=http://localhost:8734 \
BENEFICIARY="$BENEFICIARY" \
TEXT_PAYLOAD="Bulbasaur paid AO upload $(date -Iseconds)-$RANDOM" \
./bundler-tests/run-paid-bundler-upload-verbose.sh 2>&1 \
  | tee "bundler-tests/logs/paid-upload-$(date +%Y%m%d-%H%M%S).log"
```

## 9. Common Failures

- `402`: the uploader does not have enough balance in the local Bulbasaur AO
  ledger. Import an AO deposit through `ao-payment@1.0`, or restart the local
  smoke test with `BULBASAUR_INITIAL_BALANCE_ADDRESS` set to the uploader
  address. For an unfunded signed upload, this is the expected protected-route
  behavior; no bundle transaction or chunks should be posted.
- No bundle txid appears: start the node with `BULBASAUR_BUNDLER_MAX_ITEMS=1`
  for immediate dispatch, or wait for idle dispatch.
- Bundle status does not reach `complete`: check that the node wallet has AR and
  can post chunks to Arweave.
- Beneficiary balance is `404` before upload: usually fine. It means the local
  ledger has no beneficiary account entry yet.
- Balance reads are `500`: `NODE_URL` or `LEDGER_ROUTE` likely points at the
  wrong node/ledger.
