#!/usr/bin/env node
const path = require('path');
const express = require('express');
const { ethers } = require('ethers');

const HOST = process.env.FAUCET_HOST || '0.0.0.0';
const PORT = Number(process.env.FAUCET_PORT || 8787);
const RPC_URL = process.env.FAUCET_RPC_URL || process.env.RPC_URL || 'http://127.0.0.1:8545';
const TOKEN = process.env.FAUCET_TOKEN;
const PRIVATE_KEY_RAW = process.env.FAUCET_PRIVATE_KEY;
const AMOUNT_WEI = process.env.FAUCET_AMOUNT_WEI || '100000000000000000';

if (!TOKEN) {
  console.error('FAUCET_TOKEN is required. Set it in .env.faucet or export FAUCET_TOKEN=...');
  process.exit(1);
}
if (!PRIVATE_KEY_RAW) {
  console.error('FAUCET_PRIVATE_KEY is required. Set it in .env.faucet or export FAUCET_PRIVATE_KEY=...');
  process.exit(1);
}

const PRIVATE_KEY = PRIVATE_KEY_RAW.startsWith('0x')
  ? PRIVATE_KEY_RAW
  : `0x${PRIVATE_KEY_RAW}`;

let amountWei;
try {
  amountWei = BigInt(AMOUNT_WEI);
} catch (_err) {
  console.error(`Invalid FAUCET_AMOUNT_WEI: ${AMOUNT_WEI}`);
  process.exit(1);
}
if (amountWei <= 0n) {
  console.error('FAUCET_AMOUNT_WEI must be > 0');
  process.exit(1);
}

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

const ipHits = new Map();
const toHits = new Map();
const IP_LIMIT_MS = 60 * 1000;
const TO_LIMIT_MS = 5 * 60 * 1000;

const app = express();
app.use(express.json());

const publicDir = path.join(__dirname, 'public');
app.use(express.static(publicDir));
app.get('/ui', (_req, res) => {
  res.sendFile(path.join(publicDir, 'index.html'));
});

function nowIso() {
  return new Date().toISOString();
}

function getIp(req) {
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded === 'string' && forwarded.trim()) {
    return forwarded.split(',')[0].trim();
  }
  return req.socket?.remoteAddress || req.ip || 'unknown';
}

function logRequest({ ip, to = '-', result, detail = '' }) {
  const suffix = detail ? ` (${detail})` : '';
  console.log(`[${nowIso()}] ip=${ip} to=${to} result=${result}${suffix}`);
}

function markAndCheckRateLimit(map, key, windowMs) {
  const now = Date.now();
  const previous = map.get(key);
  if (previous && now - previous < windowMs) {
    return windowMs - (now - previous);
  }
  map.set(key, now);
  return 0;
}

function renderRateLimitResponse(res, delayMs) {
  const retryAfterSec = Math.ceil(delayMs / 1000);
  return res.status(429).json({
    error: 'rate_limited',
    message: `Try again in ${retryAfterSec}s`,
    retryAfterSec,
  });
}

setInterval(() => {
  const now = Date.now();
  for (const [ip, ts] of ipHits.entries()) {
    if (now - ts >= IP_LIMIT_MS) ipHits.delete(ip);
  }
  for (const [to, ts] of toHits.entries()) {
    if (now - ts >= TO_LIMIT_MS) toHits.delete(to);
  }
}, 60 * 1000).unref();

app.get('/health', async (_req, res) => {
  try {
    const [network, latestBlock] = await Promise.all([
      provider.getNetwork(),
      provider.getBlockNumber(),
    ]);
    res.json({ ok: true, chainId: Number(network.chainId), latestBlock });
  } catch (err) {
    res.status(503).json({
      ok: false,
      error: 'rpc_unreachable',
      message: err.message,
    });
  }
});

app.post('/faucet', async (req, res) => {
  const ip = getIp(req);
  const token = req.header('X-FAUCET-TOKEN');
  const toRaw = req.body?.to;

  if (!token || token !== TOKEN) {
    logRequest({ ip, to: String(toRaw || '-'), result: 'fail', detail: 'unauthorized' });
    return res.status(401).json({
      error: 'unauthorized',
      message: 'Missing or invalid X-FAUCET-TOKEN',
    });
  }

  if (!toRaw || typeof toRaw !== 'string' || !ethers.isAddress(toRaw)) {
    logRequest({ ip, to: String(toRaw || '-'), result: 'fail', detail: 'invalid_address' });
    return res.status(400).json({
      error: 'invalid_address',
      message: 'Provide a valid destination address in `to`',
    });
  }

  const to = ethers.getAddress(toRaw);
  const ipDelay = markAndCheckRateLimit(ipHits, ip, IP_LIMIT_MS);
  if (ipDelay > 0) {
    logRequest({ ip, to, result: 'fail', detail: 'ip_rate_limited' });
    return renderRateLimitResponse(res, ipDelay);
  }

  const toDelay = markAndCheckRateLimit(toHits, to, TO_LIMIT_MS);
  if (toDelay > 0) {
    ipHits.delete(ip);
    logRequest({ ip, to, result: 'fail', detail: 'address_rate_limited' });
    return renderRateLimitResponse(res, toDelay);
  }

  try {
    const tx = await wallet.sendTransaction({ to, value: amountWei });
    logRequest({ ip, to, result: 'success', detail: tx.hash });
    return res.json({ txHash: tx.hash });
  } catch (err) {
    ipHits.delete(ip);
    toHits.delete(to);
    const msg = String(err?.message || err);
    let error = 'tx_failed';
    if (/insufficient funds/i.test(msg)) error = 'insufficient_funds';
    if (/network|ECONNREFUSED|ENOTFOUND|timeout/i.test(msg)) error = 'rpc_unreachable';
    logRequest({ ip, to, result: 'fail', detail: error });
    return res.status(500).json({ error, message: msg });
  }
});

app.get('/status/:txHash', async (req, res) => {
  const { txHash } = req.params;
  if (!txHash || !/^0x([A-Fa-f0-9]{64})$/.test(txHash)) {
    return res.status(400).json({
      error: 'invalid_tx_hash',
      message: 'Transaction hash must be a 0x-prefixed 32-byte hex value',
    });
  }

  try {
    const [receipt, latestBlock] = await Promise.all([
      provider.getTransactionReceipt(txHash),
      provider.getBlockNumber(),
    ]);
    if (!receipt) {
      return res.json({ status: 'pending' });
    }
    const confirmations = Math.max(0, latestBlock - Number(receipt.blockNumber) + 1);
    return res.json({
      status: receipt.status === 1 ? 'success' : 'failed',
      blockNumber: Number(receipt.blockNumber),
      confirmations,
    });
  } catch (err) {
    return res.status(503).json({
      error: 'rpc_unreachable',
      message: err.message,
    });
  }
});

async function startupDiagnostics() {
  try {
    const [network, balanceWei] = await Promise.all([
      provider.getNetwork(),
      provider.getBalance(wallet.address),
    ]);

    console.log(`faucet listening on http://${HOST}:${PORT}`);
    console.log(`faucet signer address: ${wallet.address}`);
    console.log(`faucet chainId: ${Number(network.chainId)}`);
    console.log(`faucet signer balance: ${ethers.formatEther(balanceWei)} ETH`);

    app.listen(PORT, HOST);
  } catch (err) {
    console.error(`Failed to reach faucet RPC at ${RPC_URL}: ${err.message}`);
    process.exit(1);
  }
}

void startupDiagnostics();
