#!/usr/bin/env node
import process from "node:process";

const defaults = {
  mainnet: "https://state.forward.computer",
  token: "0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc",
  timeoutMs: "360000",
  pollMs: "5000",
};

function usage() {
  console.error(
    [
      "Usage:",
      "  node bundler-tests/find-ao-assignment-slot.mjs --message-id <id> [options]",
      "",
      "Options:",
      `  --mainnet <url>       AO state endpoint (default ${defaults.mainnet})`,
      `  --token <id>          AO token process (default ${defaults.token})`,
      `  --timeout-ms <ms>     Poll timeout (default ${defaults.timeoutMs})`,
      `  --poll-ms <ms>        Poll interval (default ${defaults.pollMs})`,
    ].join("\n"),
  );
}

function parseArgs(argv) {
  const args = { ...defaults };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (!arg.startsWith("--")) {
      throw new Error(`Unexpected argument: ${arg}`);
    }
    const key = arg.slice(2).replaceAll("-", "_");
    const value = argv[i + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for ${arg}`);
    }
    args[key] = value;
    i += 1;
  }
  args.messageId = args.message_id;
  args.timeoutMs = args.timeout_ms ?? args.timeoutMs;
  args.pollMs = args.poll_ms ?? args.pollMs;
  if (!args.messageId) throw new Error("--message-id is required");
  return args;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeBaseUrl(raw) {
  return raw.replace(/\/+$/g, "");
}

async function currentSlot(mainnet, token) {
  const res = await fetch(`${mainnet}/${token}~process@1.0/slot/current`);
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
  const args = parseArgs(process.argv);
  const mainnet = normalizeBaseUrl(args.mainnet);
  const timeoutMs = Number(args.timeoutMs);
  const pollMs = Number(args.pollMs);
  const fromSlot = Math.max(0, (await currentSlot(mainnet, args.token)) - 5);
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const toSlot = (await currentSlot(mainnet, args.token)) + 20;
    const url =
      `${mainnet}/${args.token}~process@1.0/schedule` +
      `?from=${fromSlot}&to=${toSlot}&accept=application/aos-2`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`schedule failed: ${res.status}`);
    const schedule = await res.json();
    for (const edge of schedule.edges || []) {
      if (edge.node?.message?.Id === args.messageId) {
        const nonce = tag(edge.node.assignment?.Tags, "Nonce");
        if (!nonce) throw new Error(`assignment missing Nonce for ${args.messageId}`);
        console.log(nonce);
        return;
      }
    }
    await sleep(pollMs);
  }

  throw new Error(`message did not appear in AO schedule: ${args.messageId}`);
}

main().catch((err) => {
  console.error(err?.stack || String(err));
  process.exit(1);
});
