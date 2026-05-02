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
git checkout feat/local-ledger-bundler-payments
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
Uploader delta           -<charged-ao-base-units> base units
Bundle tx found: <txid>; status=complete
Beneficiary balance      <credited-ao-base-units>
Paid POST                accepted
Bundle status            complete
Arweave bundle           https://arweave.net/tx/<txid>
```

The beneficiary balance may be `404` before the upload if the account has not
been credited in the local ledger yet. It should resolve after the bundle
completion hook credits the beneficiary.

The gateway can report the bundle transaction as `202` while it is pending
mining/indexing. The test treats that as proof that the bundle was accepted by
Arweave. The individual data item may take longer to appear at
`https://arweave.net/<item-id>` because gateway indexing of bundled data items
lags the bundle transaction.

## 7. Capture A Log

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

## 8. Common Failures

- `402`: the uploader does not have enough balance in the local Bulbasaur AO
  ledger. Import an AO deposit through `ao-payment@1.0`, or restart the local
  smoke test with `BULBASAUR_INITIAL_BALANCE_ADDRESS` set to the uploader
  address.
- No bundle txid appears: start the node with `BULBASAUR_BUNDLER_MAX_ITEMS=1`
  for immediate dispatch, or wait for idle dispatch.
- Bundle status does not reach `complete`: check that the node wallet has AR and
  can post chunks to Arweave.
- Beneficiary balance is `404` before upload: usually fine. It means the local
  ledger has no beneficiary account entry yet.
- Balance reads are `500`: `NODE_URL` or `LEDGER_ROUTE` likely points at the
  wrong node/ledger.
