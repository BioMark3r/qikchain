const crypto = require('crypto');
const express = require('express');
const path = require('path');
const { execFile } = require('child_process');

const app = express();
const port = Number(process.env.PORT || 8787);
const readonlyProd = process.env.READONLY_PROD === '1';
const host = process.env.HOST || (readonlyProd ? '127.0.0.1' : '0.0.0.0');
const cacheMs = Math.max(0, Number(process.env.CACHE_MS || 1000));
const divergenceWarn = Math.max(0, Number(process.env.DIVERGENCE_WARN || 3));
const txRateLimitPerMinBase = Math.max(1, Number(process.env.TX_RATE_LIMIT_PER_MIN || 10));
const txRateLimitPerMin = readonlyProd ? Math.min(txRateLimitPerMinBase, 5) : txRateLimitPerMinBase;
const txMaxValueWei = parsePositiveBigInt(process.env.TX_MAX_VALUE_WEI || '1000000000000000');
const rawTxMaxBytesBase = Math.max(1, Number(process.env.RAW_TX_MAX_BYTES || 8192));
const rawTxMaxBytes = readonlyProd ? Math.min(rawTxMaxBytesBase, 4096) : rawTxMaxBytesBase;
const deployGasCap = Math.max(21000, Number(process.env.DEPLOY_GAS_CAP || 2000000));
const waitForReceipt = process.env.WAIT_FOR_RECEIPT === '1';
const repoRoot = path.resolve(__dirname, '..', '..');
const cliPath = path.join(repoRoot, 'bin', 'qikchain');
const txHelperPath = path.join(repoRoot, 'bin', 'txhelper');
const COMMAND_TIMEOUT_MS = 3000;
const TX_TIMEOUT_MS = 20000;
const SEALING_DELAY_MS = 2000;
const BURN_ADDRESS = '0x000000000000000000000000000000000000dEaD';

const authUser = process.env.AUTH_USER || '';
const authPass = process.env.AUTH_PASS || '';
const authEnabled = authUser.length > 0 && authPass.length > 0;

const txToken = process.env.TX_TOKEN || '';
const txEnabled = process.env.ENABLE_TX === '1' && txToken.length > 0;

const statusCache = {
  value: null,
  computedAt: 0,
  inFlight: null,
};

const txWindow = [];

function parsePositiveBigInt(value) {
  if (!/^\d+$/.test(String(value))) {
    return BigInt(0);
  }
  return BigInt(value);
}

function parseRpcUrls() {
  const rawList = process.env.RPC_URLS || process.env.RPC_URL || 'http://127.0.0.1:8545';
  return rawList
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function sanitizeError(err) {
  if (readonlyProd) {
    return 'node check failed';
  }
  return err;
}

function sanitizeTxError(err) {
  if (readonlyProd) {
    return 'transaction request failed';
  }
  return err;
}

function maskRpcUrl(rpc) {
  if (!readonlyProd) {
    return rpc;
  }

  try {
    const parsed = new URL(rpc);
    return parsed.port ? `${parsed.hostname}:${parsed.port}` : parsed.hostname;
  } catch (_error) {
    return 'masked';
  }
}

function runQikchain(args) {
  return new Promise((resolve, reject) => {
    execFile(cliPath, args, { cwd: repoRoot, timeout: COMMAND_TIMEOUT_MS }, (error, stdout, stderr) => {
      if (error) {
        const errMessage = (stderr || error.message || 'qikchain command failed').trim();
        reject(new Error(errMessage));
        return;
      }
      resolve((stdout || '').trim());
    });
  });
}

function runTxHelper(args) {
  return new Promise((resolve, reject) => {
    execFile(txHelperPath, args, { cwd: repoRoot, timeout: TX_TIMEOUT_MS }, (error, stdout, stderr) => {
      if (error) {
        const errMessage = (stderr || error.message || 'tx helper failed').trim();
        reject(new Error(errMessage));
        return;
      }
      resolve((stdout || '').trim());
    });
  });
}

function parseFieldNumber(stdout, fieldName) {
  const fieldRegex = new RegExp(`${fieldName}\\s*:\\s*(-?\\d+)`, 'i');
  const match = stdout.match(fieldRegex);
  if (!match) {
    return null;
  }
  const parsed = Number(match[1]);
  return Number.isFinite(parsed) ? parsed : null;
}

function parseChainId(stdout) {
  const match = stdout.match(/chainId\s*:\s*([^\s]+)/i);
  if (!match) {
    return null;
  }
  return String(match[1]).trim();
}

function parsePeerCount(stdout) {
  return parseFieldNumber(stdout, 'peerCount');
}

function parseBlockHead(stdout) {
  const fieldValue = parseFieldNumber(stdout, 'blockHead');
  if (fieldValue !== null) {
    return fieldValue;
  }

  const firstInteger = stdout.match(/-?\d+/);
  if (!firstInteger) {
    return null;
  }
  const parsed = Number(firstInteger[0]);
  return Number.isFinite(parsed) ? parsed : null;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function checkNode(rpc) {
  const node = {
    rpc,
    up: false,
    chainId: null,
    peerCount: null,
    blockHead1: null,
    blockHead2: null,
    sealingHealthy: false,
    error: null,
  };

  try {
    const statusOutput = await runQikchain(['status', '--rpc', rpc]);
    const blockHeadOutput1 = await runQikchain(['block', 'head', '--rpc', rpc]);

    node.chainId = parseChainId(statusOutput);
    node.peerCount = parsePeerCount(statusOutput);
    node.blockHead1 = parseBlockHead(blockHeadOutput1);

    await sleep(SEALING_DELAY_MS);

    const blockHeadOutput2 = await runQikchain(['block', 'head', '--rpc', rpc]);
    node.blockHead2 = parseBlockHead(blockHeadOutput2);

    node.up = true;
    node.sealingHealthy =
      Number.isInteger(node.blockHead1) &&
      Number.isInteger(node.blockHead2) &&
      node.blockHead2 > node.blockHead1;

    return node;
  } catch (error) {
    return {
      ...node,
      up: false,
      sealingHealthy: false,
      error: sanitizeError(error.message || 'unknown error'),
    };
  }
}

function summarize(nodes) {
  const nodesTotal = nodes.length;
  const nodesUpNodes = nodes.filter((node) => node.up);
  const nodesUp = nodesUpNodes.length;
  const nodesSealing = nodes.filter((node) => node.sealingHealthy).length;

  const heads = nodesUpNodes.map((node) => node.blockHead2).filter((value) => Number.isInteger(value));
  const minBlockHead = heads.length > 0 ? Math.min(...heads) : null;
  const maxBlockHead = heads.length > 0 ? Math.max(...heads) : null;
  const headDivergence = heads.length > 0 ? maxBlockHead - minBlockHead : 0;

  const upChainIds = nodes.filter((node) => node.up && node.chainId !== null).map((node) => node.chainId);
  const uniqueChainIds = [...new Set(upChainIds)];
  const chainId = uniqueChainIds.length === 1 ? uniqueChainIds[0] : null;

  let healthy = nodesUp > 0 && nodesSealing > 0;
  let reason = 'At least one node is up and sealing.';
  if (!healthy) {
    if (nodesUp === 0) {
      reason = 'No nodes are reachable.';
    } else if (nodesSealing === 0) {
      reason = 'No node appears to be sealing.';
    }
  }

  if (nodesUp >= 2 && headDivergence > divergenceWarn) {
    healthy = false;
    reason = `${reason} head divergence detected (${headDivergence} > ${divergenceWarn}).`;
  }

  return {
    overall: { healthy, reason },
    summary: {
      nodesUp,
      nodesTotal,
      nodesSealing,
      chainId,
      minBlockHead,
      maxBlockHead,
      headDivergence,
    },
  };
}

async function computeStatus() {
  const rpcUrls = parseRpcUrls();
  const nodes = await Promise.all(rpcUrls.map((rpc) => checkNode(rpc)));
  const sanitizedNodes = nodes.map((node) => ({
    ...node,
    rpc: maskRpcUrl(node.rpc),
  }));
  const { overall, summary } = summarize(sanitizedNodes);

  return {
    timestamp: new Date().toISOString(),
    readonlyProd,
    authEnabled,
    txEnabled,
    writeMode: txEnabled ? 'enabled' : 'disabled',
    overall,
    summary,
    nodes: sanitizedNodes,
  };
}

async function getCachedStatus() {
  const now = Date.now();
  if (statusCache.value && now - statusCache.computedAt < cacheMs) {
    return statusCache.value;
  }

  if (statusCache.inFlight) {
    return statusCache.inFlight;
  }

  statusCache.inFlight = computeStatus()
    .then((result) => {
      statusCache.value = result;
      statusCache.computedAt = Date.now();
      return result;
    })
    .finally(() => {
      statusCache.inFlight = null;
    });

  return statusCache.inFlight;
}

function safeEqualStrings(a, b) {
  const aBuf = Buffer.from(a);
  const bBuf = Buffer.from(b);
  if (aBuf.length !== bBuf.length) {
    return false;
  }
  return crypto.timingSafeEqual(aBuf, bBuf);
}

function authMiddleware(req, res, next) {
  if (!authEnabled) {
    next();
    return;
  }

  const header = req.headers.authorization || '';
  const parts = header.split(' ');
  if (parts.length !== 2 || parts[0] !== 'Basic') {
    res.set('WWW-Authenticate', 'Basic realm="Qikchain Status"');
    res.status(401).json({ error: 'Unauthorized' });
    return;
  }

  let decoded = '';
  try {
    decoded = Buffer.from(parts[1], 'base64').toString('utf8');
  } catch (_error) {
    res.set('WWW-Authenticate', 'Basic realm="Qikchain Status"');
    res.status(401).json({ error: 'Unauthorized' });
    return;
  }

  const splitIndex = decoded.indexOf(':');
  const username = splitIndex === -1 ? decoded : decoded.slice(0, splitIndex);
  const password = splitIndex === -1 ? '' : decoded.slice(splitIndex + 1);
  const userOk = safeEqualStrings(username, authUser);
  const passOk = safeEqualStrings(password, authPass);

  if (!userOk || !passOk) {
    res.set('WWW-Authenticate', 'Basic realm="Qikchain Status"');
    res.status(401).json({ error: 'Unauthorized' });
    return;
  }

  next();
}

function chooseRpc(rpc) {
  const configured = parseRpcUrls();
  if (!rpc) {
    return configured[0];
  }
  if (!configured.includes(rpc)) {
    return null;
  }
  return rpc;
}

function txRateLimitOk() {
  const now = Date.now();
  while (txWindow.length > 0 && now - txWindow[0] >= 60 * 1000) {
    txWindow.shift();
  }
  if (txWindow.length >= txRateLimitPerMin) {
    return false;
  }
  txWindow.push(now);
  return true;
}

function txGateMiddleware(req, res, next) {
  if (!txEnabled) {
    res.status(403).json({ error: 'write actions disabled' });
    return;
  }

  const headerToken = String(req.headers['x-tx-token'] || '');
  if (!safeEqualStrings(headerToken, txToken)) {
    res.status(403).json({ error: 'Tx requires X-TX-TOKEN' });
    return;
  }

  if (!txRateLimitOk()) {
    res.status(429).json({ error: 'rate limit exceeded' });
    return;
  }

  next();
}

app.use(authMiddleware);
app.use(express.json({ limit: '16kb' }));
app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/status', async (_req, res) => {
  try {
    const data = await getCachedStatus();
    res.json(data);
  } catch (error) {
    res.json({
      timestamp: new Date().toISOString(),
      readonlyProd,
      authEnabled,
      txEnabled,
      writeMode: txEnabled ? 'enabled' : 'disabled',
      overall: {
        healthy: false,
        reason: 'failed to aggregate status',
      },
      summary: {
        nodesUp: 0,
        nodesTotal: parseRpcUrls().length,
        nodesSealing: 0,
        chainId: null,
        minBlockHead: null,
        maxBlockHead: null,
        headDivergence: 0,
      },
      nodes: parseRpcUrls().map((rpc) => ({
        rpc: maskRpcUrl(rpc),
        up: false,
        chainId: null,
        peerCount: null,
        blockHead1: null,
        blockHead2: null,
        sealingHealthy: false,
        error: sanitizeError(error.message || 'aggregation failed'),
      })),
    });
  }
});

app.get('/healthz', async (_req, res) => {
  try {
    const status = await getCachedStatus();
    const payload = {
      healthy: Boolean(status.overall && status.overall.healthy),
      reason: status.overall?.reason || 'unknown',
      nodesUp: status.summary?.nodesUp ?? 0,
      nodesTotal: status.summary?.nodesTotal ?? 0,
      nodesSealing: status.summary?.nodesSealing ?? 0,
      headDivergence: status.summary?.headDivergence ?? 0,
    };
    res.status(payload.healthy ? 200 : 503).json(payload);
  } catch (_error) {
    res.status(503).json({ healthy: false, reason: 'status unavailable', nodesUp: 0, nodesTotal: parseRpcUrls().length, nodesSealing: 0, headDivergence: 0 });
  }
});

app.post('/api/tx/burn', txGateMiddleware, async (req, res) => {
  try {
    const rpc = chooseRpc(req.body?.rpc);
    if (!rpc) {
      res.status(400).json({ error: 'invalid rpc' });
      return;
    }
    if (BigInt(1) > txMaxValueWei) {
      res.status(400).json({ error: 'value exceeds TX_MAX_VALUE_WEI' });
      return;
    }

    const args = ['--action', 'burn', '--rpc', rpc, '--to', BURN_ADDRESS, '--valueWei', '1'];
    if (waitForReceipt) {
      args.push('--waitReceipt');
    }
    const raw = await runTxHelper(args);
    const parsed = JSON.parse(raw);
    res.json({ ok: true, rpc: maskRpcUrl(rpc), to: BURN_ADDRESS, valueWei: '1', txHash: parsed.txHash, receiptStatus: parsed.receiptStatus ?? null, mined: Boolean(parsed.mined) });
  } catch (error) {
    res.status(500).json({ error: sanitizeTxError(error.message || 'burn failed') });
  }
});

app.post('/api/tx/deploy-test', txGateMiddleware, async (req, res) => {
  try {
    const rpc = chooseRpc(req.body?.rpc);
    if (!rpc) {
      res.status(400).json({ error: 'invalid rpc' });
      return;
    }

    const args = ['--action', 'deploy', '--rpc', rpc, '--deployGasCap', String(deployGasCap)];
    if (waitForReceipt) {
      args.push('--waitReceipt');
    }
    const raw = await runTxHelper(args);
    const parsed = JSON.parse(raw);
    res.json({ ok: true, rpc: maskRpcUrl(rpc), txHash: parsed.txHash, contractAddress: parsed.contractAddress ?? null, receiptStatus: parsed.receiptStatus ?? null, mined: Boolean(parsed.mined) });
  } catch (error) {
    res.status(500).json({ error: sanitizeTxError(error.message || 'deploy failed') });
  }
});

app.post('/api/tx/submit-raw', txGateMiddleware, async (req, res) => {
  try {
    const rpc = chooseRpc(req.body?.rpc);
    if (!rpc) {
      res.status(400).json({ error: 'invalid rpc' });
      return;
    }

    const rawTx = String(req.body?.rawTx || '').trim();
    if (!/^0x[0-9a-fA-F]+$/.test(rawTx)) {
      res.status(400).json({ error: 'rawTx must be 0x-prefixed hex' });
      return;
    }
    if ((rawTx.length - 2) / 2 > rawTxMaxBytes) {
      res.status(400).json({ error: 'rawTx exceeds RAW_TX_MAX_BYTES' });
      return;
    }

    const args = ['--action', 'submit-raw', '--rpc', rpc, '--rawTx', rawTx];
    if (waitForReceipt) {
      args.push('--waitReceipt');
    }
    const raw = await runTxHelper(args);
    const parsed = JSON.parse(raw);
    res.json({ ok: true, rpc: maskRpcUrl(rpc), txHash: parsed.txHash, receiptStatus: parsed.receiptStatus ?? null, mined: Boolean(parsed.mined) });
  } catch (error) {
    res.status(500).json({ error: sanitizeTxError(error.message || 'submit raw failed') });
  }
});

app.listen(port, host, () => {
  console.log(`status-ui listening on http://${host}:${port}`);
  console.log(`RPC targets: ${parseRpcUrls().join(', ')}`);
  console.log(`readonlyProd=${readonlyProd} authEnabled=${authEnabled} cacheMs=${cacheMs} txEnabled=${txEnabled}`);
});
