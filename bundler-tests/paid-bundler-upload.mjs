#!/usr/bin/env node
/*
Standalone paid Bulbasaur bundler flow test.

The script signs a text payload as an ANS-104 data item, posts the raw item to
Bulbasaur's paid bundler route, watches the local ledger debit, waits for a
bundle txid/status in the bundler cache, and optionally probes an Arweave
gateway for the posted bundle transaction.
*/

import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import process from "node:process";

const require = createRequire(import.meta.url);

let ArweaveSigner;
let createData;
let DataItem;

function loadArbundles() {
  try {
    ({ ArweaveSigner, createData, DataItem } = require("@dha-team/arbundles"));
  } catch (err) {
    console.error("Missing dependency: @dha-team/arbundles");
    console.error("Install it with:");
    console.error("  cd bundler-tests && npm install");
    console.error("");
    console.error(err.message);
    process.exit(1);
  }
}

const defaults = {
  node: "http://localhost:8734",
  gateway: "https://arweave.net",
  text: "Hello from a paid AO bundler upload",
  bytePrice: "1162726",
  aoDecimals: "12",
  timeoutMs: "240000",
  pollMs: "2000",
  uploadPath: "/~bundler@1.0/item?codec-device=ans104@1.0",
};

function usage() {
  console.log(
    [
      "Usage:",
      "  node bundler-tests/paid-bundler-upload.mjs --wallet <jwk.json> [options]",
      "",
      "Required:",
      "  --wallet <path>             Uploader Arweave JWK with local AO ledger balance",
      "",
      "Core options:",
      `  --node <url>                Bulbasaur node endpoint (default ${defaults.node})`,
      `  --text <string>             Text payload to upload (default '${defaults.text}')`,
      "  --text-file <path>          Read text payload from a file instead of --text",
      `  --gateway <url>             Gateway to poll for visibility (default ${defaults.gateway})`,
      `  --byte-price <units>        AO base units per bundled byte for local estimate (default ${defaults.bytePrice})`,
      `  --ao-decimals <n>           AO decimals for display only (default ${defaults.aoDecimals})`,
      "",
      "Optional inspection:",
      "  --ledger-route <route>      e.g. /ledger~node-process@1.0; enables balance reads",
      "  --beneficiary <address>     Also inspect beneficiary balance if --ledger-route is set",
      "  --save-raw <path>           Save signed ANS-104 bytes",
      "  --no-gateway                Skip gateway visibility polling",
      "",
      "Polling:",
      `  --timeout-ms <ms>           Overall bundle/gateway poll timeout (default ${defaults.timeoutMs})`,
      `  --poll-ms <ms>              Poll interval (default ${defaults.pollMs})`,
      "",
      "Notes:",
      "  The node should run with BULBASAUR_BUNDLER_MAX_ITEMS=1 for immediate dispatch.",
      "  A 402 response means the wallet does not have enough local AO ledger balance.",
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
    if (arg === "--no-gateway") {
      args.noGateway = true;
      continue;
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
  args.bytePrice = args.byte_price ?? args.bytePrice;
  args.aoDecimals = args.ao_decimals ?? args.aoDecimals;
  args.timeoutMs = args.timeout_ms ?? args.timeoutMs;
  args.pollMs = args.poll_ms ?? args.pollMs;
  args.uploadPath = args.upload_path ?? args.uploadPath;
  args.textFile = args.text_file;
  args.ledgerRoute = args.ledger_route;
  args.saveRaw = args.save_raw;
  if (!args.wallet) throw new Error("--wallet is required");
  if (!/^\d+$/.test(String(args.bytePrice))) {
    throw new Error("--byte-price must be an integer AO base-unit amount");
  }
  return args;
}

function base64url(input) {
  return Buffer.from(input)
    .toString("base64")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
}

function base64urlDecode(input) {
  const padded = input + "=".repeat((4 - (input.length % 4)) % 4);
  return Buffer.from(padded.replaceAll("-", "+").replaceAll("_", "/"), "base64");
}

function walletAddress(jwk) {
  if (!jwk?.n) return "(unknown: JWK has no modulus)";
  return base64url(createHash("sha256").update(base64urlDecode(jwk.n)).digest());
}

function normalizeBaseUrl(raw) {
  return raw.replace(/\/+$/g, "");
}

function endpoint(base, path) {
  const cleanPath = path.startsWith("/") ? path : `/${path}`;
  return `${normalizeBaseUrl(base)}${cleanPath}`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function prettyAo(rawUnits, decimals) {
  const units = BigInt(rawUnits);
  const scale = 10n ** BigInt(decimals);
  const whole = units / scale;
  const fraction = units % scale;
  if (decimals === 0) return whole.toString();
  const frac = fraction.toString().padStart(decimals, "0").replace(/0+$/g, "");
  return `${whole}.${frac || "0"}`;
}

function logStep(title) {
  console.log("");
  console.log("=".repeat(78));
  console.log(title);
  console.log("=".repeat(78));
}

function logKV(key, value) {
  console.log(`${key.padEnd(24)} ${value}`);
}

async function fetchText(url, options = {}, timeoutMs = 30000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, { ...options, signal: controller.signal });
    const text = Buffer.from(await res.arrayBuffer()).toString("utf8");
    return { res, text };
  } finally {
    clearTimeout(timer);
  }
}

function tryJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function isHtml(text) {
  return /^\s*<!doctype html/i.test(String(text)) || /^\s*<html/i.test(String(text));
}

function cleanCacheText(text) {
  if (isHtml(text)) return "";
  const parsed = tryJson(text);
  const raw =
    parsed && typeof parsed === "object" && "body" in parsed
      ? String(parsed.body)
      : String(text);
  const cleaned = raw.trim().replace(/^"|"$/g, "");
  return isHtml(cleaned) ? "" : cleaned;
}

function htmlTitle(text) {
  const match = String(text).match(/<title>([^<]+)<\/title>/i);
  return match ? match[1].trim() : "";
}

function compactFailure(res, text, url) {
  const title = htmlTitle(text);
  const preview = String(text)
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 240);
  return {
    ok: false,
    status: res.status,
    title: title || undefined,
    preview,
    hint:
      "Balance inspection is optional. A 404 can mean the account has no ledger entry yet; a 500 usually means NODE_URL or LEDGER_ROUTE is stale.",
    url,
  };
}

function itemIdFromRaw(raw) {
  const parsed = new DataItem(raw);
  return typeof parsed.id === "string" ? parsed.id : base64url(parsed.id);
}

async function makeDataItem(jwk, text) {
  const signer = new ArweaveSigner(jwk);
  const nonce = base64url(randomBytes(12));
  const item = createData(Buffer.from(text, "utf8"), signer, {
    tags: [
      { name: "Content-Type", value: "text/plain; charset=utf-8" },
      { name: "App-Name", value: "Bulbasaur-Paid-Bundler-Test" },
      { name: "Unix-Time", value: String(Math.floor(Date.now() / 1000)) },
      { name: "Test-Nonce", value: nonce },
    ],
  });
  await item.sign(signer);
  const raw = Buffer.from(item.getRaw());
  const parsed = new DataItem(raw);
  const valid = await parsed.isValid();
  return {
    raw,
    id: item.id || itemIdFromRaw(raw),
    verifiedId: itemIdFromRaw(raw),
    valid,
    nonce,
  };
}

function normalizeLedgerRoute(route) {
  if (!route) return undefined;
  let clean = route.trim();
  if (!clean.startsWith("/")) clean = `/${clean}`;
  if (!clean.includes("~process@1.0") && !clean.includes("~node-process@1.0")) {
    clean = `${clean}~process@1.0`;
  }
  return clean.replace(/\/+$/g, "");
}

async function readBalance(base, ledgerRoute, address) {
  if (!ledgerRoute || !address) return undefined;
  const path = `${normalizeLedgerRoute(ledgerRoute)}/now/balance/${address}`;
  const url = endpoint(base, path);
  const { res, text } = await fetchText(url, { method: "GET" }, 30000);
  if (!res.ok) {
    return compactFailure(res, text, url);
  }
  const parsed = tryJson(text);
  const value =
    parsed && typeof parsed === "object" && "body" in parsed
      ? parsed.body
      : text.trim();
  return { ok: true, value: String(value).replace(/^"|"$/g, ""), url };
}

async function readBundlerCache(base, readPath) {
  const url = new URL(endpoint(base, "/~cache@1.0/read"));
  url.searchParams.set("read", readPath);
  url.searchParams.set("_", `${Date.now()}-${Math.random()}`);
  const { res, text } = await fetchText(
    url,
    { method: "GET", headers: { "cache-control": "no-cache, no-store" } },
    30000,
  );
  if (!res.ok) return "";
  return cleanCacheText(text);
}

function uploadResultFrom(headers, text) {
  const parsed = tryJson(text);
  const contentType = headers.get("content-type") || "";
  return {
    statusBody: parsed ?? text.slice(0, 1000),
    contentType,
    htmlTitle: contentType.includes("text/html") ? htmlTitle(text) : "",
    id: headers.get("id") || parsed?.id || parsed?.body?.id || parsed?.body?.["id"] || "",
    timestamp: headers.get("timestamp") || parsed?.timestamp || parsed?.body?.timestamp || "",
  };
}

async function postUpload(base, uploadPath, raw, timeoutMs) {
  const url = endpoint(base, uploadPath);
  const started = Date.now();
  const { res, text } = await fetchText(
    url,
    {
      method: "POST",
      headers: {
        accept: "application/json, text/plain, */*",
        "content-type": "application/octet-stream",
      },
      body: raw,
    },
    timeoutMs,
  );
  return { url, res, text, elapsedMs: Date.now() - started };
}

async function pollForBundle(base, itemId, timeoutMs, pollMs) {
  const deadline = Date.now() + timeoutMs;
  const bundlePath = `~bundler@1.0/item/${itemId}/bundle`;
  const attempts = [];
  let lastTxid = "";
  let lastStatus = "";
  while (Date.now() < deadline) {
    const txid = await readBundlerCache(base, bundlePath);
    const remainingMs = Math.max(0, deadline - Date.now());
    attempts.push({ at: new Date().toISOString(), txid, remainingMs });
    if (txid) {
      lastTxid = txid;
      const statusPath = `~bundler@1.0/tx/${txid}/status`;
      const status = (await readBundlerCache(base, statusPath)) || "posted";
      lastStatus = status;
      console.log(`Bundle tx found: ${txid}; status=${status}`);
      if (status === "complete") {
        return { txid, status, bundlePath, statusPath, attempts };
      }
      await sleep(pollMs);
      continue;
    }
    if (attempts.length === 1) {
      console.log(
        "Cache path exists only after the bundler links the item to a posted tx. " +
          "If this repeats past ~30s, check that this node can post to Arweave.",
      );
    }
    console.log(`No bundle tx yet; polling ${bundlePath} again in ${pollMs}ms`);
    await sleep(pollMs);
  }
  return {
    txid: lastTxid,
    status: lastStatus,
    bundlePath,
    statusPath: lastTxid ? `~bundler@1.0/tx/${lastTxid}/status` : "",
    attempts,
  };
}

async function pollGateway(gateway, id, label, timeoutMs, pollMs, options = {}) {
  const base = normalizeBaseUrl(gateway);
  const directUrl = `${base}/${id}`;
  const txUrl = `${base}/tx/${id}`;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (const url of [directUrl, txUrl]) {
      const { res, text } = await fetchText(url, { method: "GET" }, 30000).catch((err) => ({
        res: { ok: false, status: "fetch-error" },
        text: err.message,
      }));
      console.log(`${label} gateway probe ${url} -> ${res.status}`);
      if (options.acceptPending && res.status === 202) {
        return { ok: true, pending: true, url, preview: text.slice(0, 300) };
      }
      if (res.ok) {
        return { ok: true, url, preview: text.slice(0, 300) };
      }
    }
    await sleep(pollMs);
  }
  return { ok: false, url: directUrl };
}

async function main() {
  const args = parseArgs(process.argv);
  loadArbundles();
  const node = normalizeBaseUrl(args.node);
  const timeoutMs = Number(args.timeoutMs);
  const pollMs = Number(args.pollMs);
  const aoDecimals = Number(args.aoDecimals);
  const ledgerRoute = normalizeLedgerRoute(args.ledgerRoute);

  const jwk = JSON.parse(await readFile(args.wallet, "utf8"));
  const address = walletAddress(jwk);
  const text = args.textFile ? await readFile(args.textFile, "utf8") : args.text;

  logStep("1. Configuration");
  logKV("Node", node);
  logKV("Upload path", args.uploadPath);
  logKV("Gateway", args.noGateway ? "(skipped)" : args.gateway);
  logKV("Wallet address", address);
  logKV("Text bytes", Buffer.byteLength(text, "utf8"));
  logKV("Ledger route", ledgerRoute || "(not provided; balance checks skipped)");
  logKV("Byte price", `${args.bytePrice} AO base units / bundled byte`);
  logKV("Poll timeout", `${timeoutMs}ms`);

  let beforeUploaderBalance;
  let beforeBeneficiaryBalance;
  if (ledgerRoute) {
    logStep("2. Local AO ledger balances before upload");
    beforeUploaderBalance = await readBalance(node, ledgerRoute, address);
    logKV("Uploader balance", beforeUploaderBalance?.ok ? beforeUploaderBalance.value : JSON.stringify(beforeUploaderBalance));
    if (args.beneficiary) {
      beforeBeneficiaryBalance = await readBalance(node, ledgerRoute, args.beneficiary);
      logKV("Beneficiary balance", beforeBeneficiaryBalance?.ok ? beforeBeneficiaryBalance.value : JSON.stringify(beforeBeneficiaryBalance));
    }
  }

  logStep("3. Build and verify ANS-104 data item");
  const item = await makeDataItem(jwk, text);
  const estimatedCharge = BigInt(item.raw.length) * BigInt(args.bytePrice);
  logKV("Item id", item.id);
  logKV("Verified id", item.verifiedId);
  logKV("Signature valid", String(item.valid));
  logKV("Signed bytes", item.raw.length);
  logKV("Nonce tag", item.nonce);
  logKV("Local estimate", `${estimatedCharge} base units (${prettyAo(estimatedCharge, aoDecimals)} AO)`);
  if (!item.valid) throw new Error("Signed ANS-104 item failed local signature verification");
  if (args.saveRaw) {
    await writeFile(args.saveRaw, item.raw);
    logKV("Saved raw item", args.saveRaw);
  }

  logStep("4. POST through paid Bulbasaur bundler route");
  const upload = await postUpload(node, args.uploadPath, item.raw, timeoutMs);
  const result = uploadResultFrom(upload.res.headers, upload.text);
  logKV("POST URL", upload.url);
  logKV("HTTP status", `${upload.res.status} ${upload.res.statusText}`);
  logKV("Elapsed", `${upload.elapsedMs}ms`);
  logKV("Response item id", result.id || "(none)");
  logKV("Response timestamp", result.timestamp || "(none)");
  if (result.htmlTitle) {
    logKV("Response body note", `HTML '${result.htmlTitle}' returned; using id/timestamp headers as the accepted upload proof`);
  }
  console.log("Response body preview:");
  console.log(typeof result.statusBody === "string" ? result.statusBody : JSON.stringify(result.statusBody, null, 2));
  if (!upload.res.ok) {
    if (upload.res.status === 402) {
      console.error("The node rejected the upload for insufficient local AO balance.");
    }
    throw new Error(`Paid bundler POST failed with HTTP ${upload.res.status}`);
  }
  if (result.id && result.id !== item.id) {
    console.warn(`Warning: response id ${result.id} differs from locally calculated id ${item.id}`);
  }

  if (ledgerRoute) {
    logStep("5. Local AO ledger balances immediately after POST");
    const afterPostUploader = await readBalance(node, ledgerRoute, address);
    logKV("Uploader balance", afterPostUploader?.ok ? afterPostUploader.value : JSON.stringify(afterPostUploader));
    if (beforeUploaderBalance?.ok && afterPostUploader?.ok) {
      const delta = BigInt(afterPostUploader.value) - BigInt(beforeUploaderBalance.value);
      logKV("Uploader delta", `${delta} base units`);
    }
  }

  logStep("6. Poll HyperBEAM bundler cache for bundle txid/status");
  const bundle = await pollForBundle(node, item.id, timeoutMs, pollMs);
  logKV("Cache item path", bundle.bundlePath);
  logKV("Bundle txid", bundle.txid || "(not found)");
  logKV("Bundle status", bundle.status || "(not found)");
  if (!bundle.txid) {
    throw new Error(
      "Upload was accepted, but no bundle txid appeared before timeout. " +
        "Run the node with BULBASAUR_BUNDLER_MAX_ITEMS=1 or wait for idle dispatch.",
    );
  }
  if (bundle.status !== "complete") {
    throw new Error(`Bundle tx was found, but status stayed '${bundle.status}', not 'complete', before timeout.`);
  }

  if (ledgerRoute) {
    logStep("7. Local AO ledger balances after bundle completion hook");
    const finalUploader = await readBalance(node, ledgerRoute, address);
    logKV("Uploader balance", finalUploader?.ok ? finalUploader.value : JSON.stringify(finalUploader));
    if (args.beneficiary) {
      const finalBeneficiary = await readBalance(node, ledgerRoute, args.beneficiary);
      logKV("Beneficiary balance", finalBeneficiary?.ok ? finalBeneficiary.value : JSON.stringify(finalBeneficiary));
      if (beforeBeneficiaryBalance?.ok && finalBeneficiary?.ok) {
        const delta = BigInt(finalBeneficiary.value) - BigInt(beforeBeneficiaryBalance.value);
        logKV("Beneficiary delta", `${delta} base units`);
      }
    }
  }

  if (!args.noGateway) {
    logStep("8. Poll Arweave gateway visibility");
    const bundleVisible = await pollGateway(args.gateway, bundle.txid, "Bundle tx", timeoutMs, pollMs, {
      acceptPending: true,
    });
    logKV("Bundle tx accepted", String(bundleVisible.ok));
    logKV("Bundle tx state", bundleVisible.pending ? "pending" : "available");
    logKV("Bundle tx URL", bundleVisible.url);
    if (!bundleVisible.ok) {
      throw new Error("Bundle completed locally, but the gateway did not report the bundle tx before timeout");
    }
    const itemVisible = await pollGateway(
      args.gateway,
      item.id,
      "Data item",
      Math.min(timeoutMs, 30000),
      pollMs,
    );
    logKV("Data item visible", String(itemVisible.ok));
    logKV("Data item URL", itemVisible.url);
    if (itemVisible.preview) {
      console.log("Data item preview:");
      console.log(itemVisible.preview);
    }
    if (!itemVisible.ok) {
      console.log("Data item is not gateway-indexed yet; the bundle tx above is the posted Arweave transaction.");
    }
  }

  logStep("Result");
  logKV("Paid POST", "accepted");
  logKV("Item id", item.id);
  logKV("Bundle txid", bundle.txid);
  logKV("Bundle status", bundle.status);
  logKV("Arweave item", `${normalizeBaseUrl(args.gateway)}/${item.id}`);
  logKV("Arweave bundle", `${normalizeBaseUrl(args.gateway)}/tx/${bundle.txid}`);
}

main().catch((err) => {
  console.error("");
  console.error("FAILED");
  console.error(err?.stack || String(err));
  process.exit(1);
});
