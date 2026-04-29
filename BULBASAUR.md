# Bulbasaur HyperBEAM Node

This checkout is configured to run a paid process-execution node using
`p4@1.0` as the request/response hook, `simple-pay@1.0` as the pricing device,
and a local AO-token sub-ledger as the payment ledger.

Start it with:

```sh
./scripts/start-bulbasaur.sh
```

Keep that process running. The script intentionally stays attached so the
Bulbasaur HTTP listener remains alive.

On startup it prints:

- the node URL
- the operator address
- the configured AO root token process ID
- the Bulbasaur ledger process ID

## New Components

This branch adds the following Bulbasaur-specific pieces:

- `src/dev_ao_payment.erl`: HyperBEAM device registered as `ao-payment@1.0`.
  It verifies AO root-token transfers against the configured AO mainnet state
  endpoint, requires both `Debit-Notice` and `Credit-Notice`, prevents duplicate
  imports, and then posts an operator-signed local credit into the Bulbasaur
  ledger.
- `src/hb_opts.erl`: preloads `ao-payment@1.0` so the verifier device is
  available through the normal HyperBEAM device map.
- `scripts/start-bulbasaur.erl` and `scripts/start-bulbasaur.sh`: start the
  paid node, create/load the local ledger process, wire `p4@1.0` and
  `simple-pay@1.0`, and print the runtime IDs needed for testing.
- `scripts/ao-payment-bridge.mjs`: command-line bridge that calls the local
  `~ao-payment@1.0` device. It does not talk to AO services directly; the
  HyperBEAM device performs the verification and local ledger import.
- `scripts/e2e-buy-process-execution.sh`: real end-to-end buyer flow. It sends
  a tiny AO transfer, waits for the scheduled slot, imports the verified payment
  into Bulbasaur, and spends that balance on a real process compute request.
- `scripts/spend-imported-balance.erl`: sends the signed paid compute request
  used after a payment has been imported into the local ledger.
- `src/bulbasaur_e2e.erl`, `scripts/e2e-bulbasaur.erl`, and
  `scripts/e2e-bulbasaur.sh`: local regression test for the paid-route behavior
  using a real `process@1.0` and local ledger credit.
- `scripts/bulbasaur-process.lua`: minimal Lua counter process used as the real
  process target in the E2E flow.
- `scripts/bulbasaur-token-p4-client.lua`: helper process code for exercising
  the token/P4 payment path.
- `BULBASAUR.md`: operator notes for running, paying, bridging, and testing this
  node setup.

## Architecture

```mermaid
flowchart LR
    Buyer[Buyer wallet]
    AO[AO root token process]
    State[AO mainnet state endpoint]
    Bridge[ao-payment bridge CLI]
    Device[Bulbasaur ao-payment@1.0 device]
    Ledger[Bulbasaur local ledger process]
    P4[p4@1.0 request hook]
    Pay[simple-pay@1.0 pricing device]
    Proc[Target process@1.0]

    Buyer -- "Transfer 1 AO base unit\nAction=Transfer\nRecipient=ledger\nX-HB-Recipient=buyer" --> AO
    AO -- "scheduled message +\nDebit/Credit notices" --> State
    Bridge -- "message id, slot,\nsender, recipient, quantity" --> Device
    Device -- "verify transfer and notices" --> State
    Device -- "operator-signed local credit" --> Ledger

    Buyer -- "signed /<process>~process@1.0/compute" --> P4
    P4 -- "quote/check route price" --> Pay
    Pay -- "read/debit buyer balance" --> Ledger
    P4 -- "allow funded request" --> Proc
    Proc -- "compute result" --> Buyer
```

Run the local payment E2E check with:

```sh
HB_PORT=18913 ./scripts/e2e-bulbasaur.sh
```

That test starts a node, deploys a real `process@1.0` with a local
`lua@5.3a` module, proves an unfunded signed compute gets `402`, then checks a
funded signed compute against the same deployed process and verifies the funded
client was debited by the configured route price. The test keeps the live AO
root token process ID in the ledger `token` field, but seeds the local
sub-ledger balance directly, so it verifies the paid route logic without
depending on a live AO transfer during test execution.

Defaults:

- HTTP port: `8734`, override with `HB_PORT=10001`.
- Operator wallet: `bulbasaur-wallet.json`, override with `HB_KEY=/path/to/wallet.json`.
- AO root token process: `0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc`, override with `BULBASAUR_AO_TOKEN=<process-id>`.
- Process route price: `1` AO base unit, override with `BULBASAUR_PROCESS_PRICE=25`.
- Paid route template: `/.*~process@1.0/.*`.
- Generic non-process routes are free because `simple-pay-price` is set to `0`.

The important token selector is not a knob on `p4@1.0`. It is the ledger
process definition's `token` field. In this checkout, `BULBASAUR_AO_TOKEN`
feeds that field on the local `ledger~node-process@1.0` sub-ledger.

## Paying for Compute with AO

1. Start Bulbasaur and note the printed `Ledger AO funding account` value.
2. Transfer AO to the ledger process using the AO mainnet flow. Keep the
   returned message ID and assignment slot.
3. Run the local AO payment bridge. It calls Bulbasaur's `~ao-payment@1.0`
   device, which verifies the transfer against the configured AO mainnet state
   endpoint (`https://state.forward.computer`) and imports the verified credit
   into the local Bulbasaur ledger.
4. Check your Bulbasaur balance on the Bulbasaur node at
   `GET /<ledger-id>~process@1.0/now/balance/<your-wallet-address>`.
5. Deploy or target a process on Bulbasaur.
6. Send a signed compute request to `GET /<ProcessID>~process@1.0/compute`.

The root-token transfer is not sent to the Bulbasaur HTTP node. It is sent to
the AO token process itself. The bridge verifies the resulting AO
`Debit-Notice` and `Credit-Notice` before sending an operator-signed local
credit into Bulbasaur. It must not use the AO testnet CU/MU endpoints for this
mainnet AO token flow.

Transfer messages should be submitted with `returnAssignmentSlot: true` so the
slot can be passed to the HyperBEAM verifier.

Bridge import example:

```sh
node scripts/ao-payment-bridge.mjs \
  --message-id <AO transfer message ID> \
  --slot <AO assignment slot> \
  --sender <payer wallet address> \
  --node http://localhost:8734 \
  --ledger <Bulbasaur ledger process ID> \
  --quantity 1
```

`--quantity 1` is one AO base unit (`0.000000000001 AO`). To verify without
importing, add `--verify-only`.

The device verifies:

- the scheduled AO message at the supplied slot is the expected transfer
- the computed result contains the expected `Debit-Notice` and `Credit-Notice`
- the notice target is the Bulbasaur ledger process
- the sender, credited recipient, and quantity match
- the AO payment id has not already been imported by this node process

Example balance check on the Bulbasaur node:

```sh
curl http://localhost:8734/<ledger-id>~process@1.0/now/balance/YOUR_WALLET_ADDRESS
```

Example signed compute request:

```erlang
Wallet = hb:wallet(<<"my-wallet.json">>).
Req = hb_message:commit(
    #{
        <<"path">> => <<"/", ProcID/binary, "~process@1.0/compute">>,
        <<"slot">> => 0
    },
    #{ <<"priv-wallet">> => Wallet }
).
hb_http:get(<<"http://localhost:8734">>, Req, #{}).
```

For the AO deposit itself, schedule a transfer on the root AO token process with:

```text
action = "Transfer"
recipient = "<Bulbasaur ledger process ID>"
quantity = "<amount>"
X-HB-Recipient = "<local ledger account to credit>"
```

With `@permaweb/aoconnect`, that is the tag set:

```js
[
  { name: "Action", value: "Transfer" },
  { name: "Recipient", value: "<Bulbasaur ledger process ID>" },
  { name: "Quantity", value: "<amount>" },
  { name: "X-HB-Recipient", value: "<local ledger account to credit>" }
]
```

To verify your root-token balance before or after the transfer, query the AO
root token with:

```js
[
  { name: "Action", value: "Balance" },
  { name: "Recipient", value: "<your-wallet-address>" }
]
```

If the transfer succeeds, Bulbasaur should then report that balance at
`GET /ledger~node-process@1.0/now/balance/YOUR_WALLET_ADDRESS`, and each paid
compute should debit it by `BULBASAUR_PROCESS_PRICE` AO base units.
