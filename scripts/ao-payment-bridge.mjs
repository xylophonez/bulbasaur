#!/usr/bin/env node
import process from "node:process";

const defaults = {
  token: "0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc",
  node: "http://localhost:8734",
  quantity: "1",
};

function usage() {
  console.error(
    [
      "Usage:",
      "  node scripts/ao-payment-bridge.mjs --message-id <id> --slot <slot> --sender <addr> [options]",
      "",
      "Options:",
      `  --token <id>              AO token process (default ${defaults.token})`,
      "  --ledger <id>             Bulbasaur ledger process; defaults to the node config",
      `  --node <url>              Bulbasaur node URL (default ${defaults.node})`,
      `  --quantity <raw-units>    AO raw units transferred (default ${defaults.quantity})`,
      "  --recipient <addr>        local ledger account to credit; defaults to sender",
      "  --verify-only             verify without importing",
      "",
      "This helper does not talk to AO services directly. It calls the local",
      "HyperBEAM ~ao-payment@1.0 device, which verifies against the configured",
      "mainnet state endpoint and imports the credit.",
    ].join("\n"),
  );
}

function parseArgs(argv) {
  const args = { ...defaults, verifyOnly: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--verify-only") {
      args.verifyOnly = true;
    } else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else if (arg.startsWith("--")) {
      const key = arg.slice(2).replaceAll("-", "_");
      const value = argv[i + 1];
      if (!value || value.startsWith("--")) {
        throw new Error(`Missing value for ${arg}`);
      }
      args[key] = value;
      i += 1;
    } else {
      throw new Error(`Unexpected argument: ${arg}`);
    }
  }
  args.messageId = args.message_id;
  if (!args.messageId || !args.slot || !args.sender) {
    throw new Error("--message-id, --slot, and --sender are required");
  }
  if (!/^\d+$/.test(args.quantity) || BigInt(args.quantity) <= 0n) {
    throw new Error("--quantity must be a positive integer raw unit amount");
  }
  return args;
}

const args = parseArgs(process.argv);
const base = args.node.replace(/\/$/, "");
const params = new URLSearchParams({
  token: args.token,
  "message-id": args.messageId,
  slot: args.slot,
  sender: args.sender,
  quantity: args.quantity,
});
if (args.ledger) {
  params.set("ledger", args.ledger);
}
if (args.recipient) {
  params.set("recipient", args.recipient);
}

const path = args.verifyOnly ? "verify" : "ingest";
const res = await fetch(`${base}/~ao-payment@1.0/${path}?${params}`, {
  method: "POST",
});
const body = await res.text();
if (!res.ok) {
  throw new Error(`~ao-payment@1.0/${path} failed (${res.status}): ${body}`);
}
console.log(body);
