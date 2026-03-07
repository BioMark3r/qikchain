const crypto = require('crypto');
const express = require('express');
const path = require('path');
const { execFile } = require('child_process');
const { TxLab } = require('./txlab');

const app = express();
const statusUiPort = Number(process.env.STATUS_UI_PORT || process.env.PORT || 8788);
const readonlyProd = process.env.READONLY_PROD === '1';
const readonly = process.env.READONLY === '1';
const host = process.env.STATUS_UI_HOST || process.env.HOST || (readonlyProd ? '127.0.0.1' : '0.0.0.0');
const cacheMs = Math.max(0, Number(process.env.CACHE_MS || 1000));
const divergenceWarn = Math.max(0, Number(process.env.DIVERGENCE_WARN || 3));
const txRateLimitPerMinBase = Math.max(1, Number(process.env.TX_RATE_LIMIT_PER_MIN || 10));
const txRateLimitPerMin = readonlyProd ? Math.min(txRateLimitPerMinBase, 5) : txRateLimitPerMinBase;
const rawTxMaxBytesBase = Math.max(1, Number(process.env.RAW_TX_MAX_BYTES || 8192));
const rawTxMaxBytes = readonlyProd ? Math.min(rawTxMaxBytesBase, 4096) : rawTxMaxBytesBase;
const deployGasCap = Math.max(21000, Number(process.env.DEPLOY_GAS_CAP || 2000000));
const repoRoot = path.resolve(__dirname, '..', '..');
const txHelperPath = path.join(repoRoot, 'bin', 'txhelper');
const txLab = new TxLab(repoRoot);
const TX_TIMEOUT_MS = 20000;
const RPC_TIMEOUT_MS = Math.max(500, Number(process.env.RPC_TIMEOUT_MS || 2000));
const BURN_ADDRESS = process.env.BURN_ADDRESS || '0x000000000000000000000000000000000000dEaD';

const authUser = process.env.AUTH_USER || '';
const authPass = process.env.AUTH_PASS || '';
const authEnabled = authUser.length > 0 && authPass.length > 0;

const txToken = process.env.TX_TOKEN || '';
const txEnabled = txToken.length > 0;
const txFromPrivateKey = process.env.TX_FROM_PRIVATE_KEY || '';

const statusCache = {
  value: null,
  computedAt: 0,
  inFlight: null,
};

const txWindowsByIp = new Map();

function parseRpcUrls() {
  const parsedRpcUrls = String(process.env.RPC_URLS || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);

  if (parsedRpcUrls.length > 0) {
    return parsedRpcUrls;
  }

  const fallbackRpc = String(process.env.RPC_URL || '').trim();
  if (fallbackRpc) {
    return [fallbackRpc];
  }

  return [
    'http://127.0.0.1:8545',
    'http://127.0.0.1:8546',
    'http://127.0.0.1:8547',
    'http://127.0.0.1:8548',
  ];
}

function sanitizeError(err) {
  if (readonlyProd) {
    return 'unavailable';
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


function parseHexNumber(hex) {
  if (typeof hex !== 'string' || !/^0x[0-9a-fA-F]+$/.test(hex)) {
    return null;
  }

  try {
    return Number.parseInt(hex, 16);
  } catch (_error) {
    return null;
  }
}

async function rpcCall(rpc, method) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), RPC_TIMEOUT_MS);

  try {
    const response = await fetch(rpc, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: `${method}-${Date.now()}`, method, params: [] }),
      signal: controller.signal,
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    const payload = await response.json();
    if (payload.error) {
      throw new Error(payload.error.message || 'rpc error');
    }

    return payload.result;
  } catch (error) {
    if (error.name === 'AbortError') {
      throw new Error(`timeout after ${RPC_TIMEOUT_MS}ms`);
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

async function checkNode(rpc) {
  const node = {
    rpc,
    reachable: false,
    chainId: null,
    netPeerCount: null,
    ethBlockNumber: null,
    error: null,
  };

  try {
    const [blockHex, peerHex, chainHex] = await Promise.all([
      rpcCall(rpc, 'eth_blockNumber'),
      rpcCall(rpc, 'net_peerCount'),
      rpcCall(rpc, 'eth_chainId').catch(() => null),
    ]);

    node.ethBlockNumber = parseHexNumber(blockHex);
    node.netPeerCount = parseHexNumber(peerHex);
    node.chainId = chainHex;
    node.reachable = true;

    return node;
  } catch (error) {
    return {
      ...node,
      reachable: false,
      error: sanitizeError(error.message || 'unavailable'),
    };
  }
}

function summarize(nodes) {
  const nodesTotal = nodes.length;
  const nodesUpNodes = nodes.filter((node) => node.reachable);
  const nodesUp = nodesUpNodes.length;
  const nodesSealing = nodesUp;

  const heads = nodesUpNodes.map((node) => node.ethBlockNumber).filter((value) => Number.isInteger(value));
  const minBlockHead = heads.length > 0 ? Math.min(...heads) : null;
  const maxBlockHead = heads.length > 0 ? Math.max(...heads) : null;
  const headDivergence = heads.length > 0 ? maxBlockHead - minBlockHead : 0;

  const upChainIds = nodes.filter((node) => node.reachable && node.chainId !== null).map((node) => node.chainId);
  const uniqueChainIds = [...new Set(upChainIds)];
  const chainId = uniqueChainIds.length === 1 ? uniqueChainIds[0] : null;

  let healthy = nodesUp > 0;
  let reason = 'At least one node is reachable.';
  if (!healthy) {
    if (nodesUp === 0) {
      reason = 'No nodes are reachable.';
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
    divergenceWarn,
    txEnabled,
    writeMode: txEnabled ? 'enabled' : 'disabled',
    overall,
    summary,
    configuredRpcs: rpcUrls.length,
    rpcs: readonlyProd ? rpcUrls.map((rpc) => maskRpcUrl(rpc)) : rpcUrls,
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

function chooseRpc(rpcUrl) {
  const configured = parseRpcUrls();
  if (!rpcUrl) {
    return configured[0];
  }
  if (!configured.includes(rpcUrl)) {
    return null;
  }
  return rpcUrl;
}

function getTxRateWindowForIp(ip) {
  const key = ip || 'unknown';
  if (!txWindowsByIp.has(key)) {
    txWindowsByIp.set(key, []);
  }
  return txWindowsByIp.get(key);
}

function txRateLimitOk(ip) {
  const window = getTxRateWindowForIp(ip);
  const now = Date.now();
  while (window.length > 0 && now - window[0] >= 60 * 1000) {
    window.shift();
  }
  if (window.length >= txRateLimitPerMin) {
    return false;
  }
  window.push(now);
  return true;
}

function txGateMiddleware(req, res, next) {
  if (readonly) {
    res.status(403).json({ error: 'readonly' });
    return;
  }

  if (!txEnabled) {
    res.status(503).json({ error: 'tx_disabled' });
    return;
  }

  const headerToken = String(req.headers['x-tx-token'] || '');
  if (!safeEqualStrings(headerToken, txToken)) {
    res.status(401).json({ error: 'unauthorized' });
    return;
  }

  if (!txRateLimitOk(req.ip)) {
    res.status(429).json({ error: 'rate_limit' });
    return;
  }

  next();
}

function ensureFundingKey(res) {
  if (txFromPrivateKey) {
    return true;
  }
  res.status(503).json({ error: 'funding key not configured' });
  return false;
}

function txLabEnabledMiddleware(_req, res, next) {
  if (!txLab.getPublicConfig().enabled) {
    res.status(503).json({ error: 'tx_lab_disabled', message: 'Set TX_LAB_ENABLE=1 to enable tx-lab.' });
    return;
  }
  next();
}

function txLabTokenMiddleware(req, res, next) {
  try {
    txLab.checkToken(String(req.headers['x-tx-lab-token'] || ''));
    next();
  } catch (error) {
    res.status(error.statusCode || 401).json({ error: error.message || 'unauthorized' });
  }
}

app.use(authMiddleware);
app.use(express.json({ limit: '16kb', strict: true }));
app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/status', async (_req, res) => {
  try {
    const data = await getCachedStatus();
    res.json(data);
  } catch (_error) {
    res.json({
      timestamp: new Date().toISOString(),
      readonlyProd,
      authEnabled,
      divergenceWarn,
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
      configuredRpcs: parseRpcUrls().length,
      rpcs: readonlyProd ? parseRpcUrls().map((rpc) => maskRpcUrl(rpc)) : parseRpcUrls(),
      nodes: parseRpcUrls().map((rpc) => ({
        rpc: maskRpcUrl(rpc),
        reachable: false,
        chainId: null,
        netPeerCount: null,
        ethBlockNumber: null,
        error: sanitizeError('unavailable'),
      })),
    });
  }
});

app.get('/api/config', (_req, res) => {
  res.json({ readonly, txEnabled });
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

app.post('/api/tx/send-wei', txGateMiddleware, async (req, res) => {
  try {
    if (!ensureFundingKey(res)) {
      return;
    }
    const rpcUrl = chooseRpc(req.body?.rpcUrl);
    if (!rpcUrl) {
      res.status(400).json({ error: 'invalid rpcUrl' });
      return;
    }

    const raw = await runTxHelper(['--action', 'burn', '--rpc', rpcUrl, '--to', BURN_ADDRESS, '--valueWei', '1']);
    const parsed = JSON.parse(raw);
    res.json({ txHash: parsed.txHash });
  } catch (error) {
    res.status(500).json({ error: sanitizeTxError(error.message || 'send wei failed') });
  }
});

app.post('/api/tx/deploy-test-contract', txGateMiddleware, async (req, res) => {
  try {
    if (!ensureFundingKey(res)) {
      return;
    }
    const rpcUrl = chooseRpc(req.body?.rpcUrl);
    if (!rpcUrl) {
      res.status(400).json({ error: 'invalid rpcUrl' });
      return;
    }

    const raw = await runTxHelper(['--action', 'deploy', '--rpc', rpcUrl, '--deployGasCap', String(deployGasCap), '--waitReceipt']);
    const parsed = JSON.parse(raw);
    res.json({ txHash: parsed.txHash, contractAddress: parsed.contractAddress ?? null });
  } catch (error) {
    res.status(500).json({ error: sanitizeTxError(error.message || 'deploy failed') });
  }
});

app.post('/api/tx/send-raw', txGateMiddleware, async (req, res) => {
  try {
    const rpcUrl = chooseRpc(req.body?.rpcUrl);
    if (!rpcUrl) {
      res.status(400).json({ error: 'invalid rpcUrl' });
      return;
    }

    const rawTxHex = String(req.body?.rawTxHex || '').trim();
    if (!/^0x[0-9a-fA-F]+$/.test(rawTxHex)) {
      res.status(400).json({ error: 'rawTxHex must be 0x-prefixed hex' });
      return;
    }
    if (rawTxHex.length < 12) {
      res.status(400).json({ error: 'rawTxHex too short' });
      return;
    }
    if ((rawTxHex.length - 2) / 2 > rawTxMaxBytes) {
      res.status(400).json({ error: 'rawTxHex exceeds RAW_TX_MAX_BYTES' });
      return;
    }

    const raw = await runTxHelper(['--action', 'submit-raw', '--rpc', rpcUrl, '--rawTx', rawTxHex]);
    const parsed = JSON.parse(raw);
    res.json({ txHash: parsed.txHash });
  } catch (error) {
    res.status(500).json({ error: sanitizeTxError(error.message || 'submit raw failed') });
  }
});


app.get('/api/txlab/health', (_req, res) => {
  const cfg = txLab.getPublicConfig();
  res.status(cfg.enabled ? 200 : 503).json({
    ok: cfg.enabled,
    enabled: cfg.enabled,
    insecureKeys: cfg.insecureKeys,
    tokenConfigured: cfg.tokenConfigured,
    rpcUrl: cfg.rpcUrl,
    activeRun: txLab.activeRun ? txLab.activeRun.id : null,
  });
});

app.get('/api/txlab/config', (_req, res) => {
  res.json(txLab.getPublicConfig());
});

app.get('/api/txlab/accounts', txLabEnabledMiddleware, (_req, res) => {
  res.json({ accounts: txLab.listAccounts() });
});

app.post('/api/txlab/accounts/refresh', txLabEnabledMiddleware, async (_req, res) => {
  try {
    const accounts = await txLab.refreshAccounts();
    res.json({ accounts });
  } catch (error) {
    res.status(error.statusCode || 400).json({ error: error.message || 'refresh_failed' });
  }
});

app.get('/api/txlab/scenarios', txLabEnabledMiddleware, (_req, res) => {
  res.json({ scenarios: txLab.listScenarios() });
});

app.get('/api/txlab/runs', txLabEnabledMiddleware, (_req, res) => {
  res.json({ runs: txLab.listRuns() });
});

app.get('/api/txlab/runs/:id', txLabEnabledMiddleware, (req, res) => {
  const run = txLab.getRun(req.params.id);
  if (!run) {
    res.status(404).json({ error: 'run_not_found' });
    return;
  }
  res.json(run);
});

app.get('/api/txlab/runs/:id/results', txLabEnabledMiddleware, (req, res) => {
  const run = txLab.getRunResults(req.params.id);
  if (!run) {
    res.status(404).json({ error: 'run_not_found' });
    return;
  }
  res.json(run);
});

app.post('/api/txlab/accounts/load', txLabEnabledMiddleware, txLabTokenMiddleware, async (req, res) => {
  try {
    const result = await txLab.loadAccountsFromFile(req.body?.path);
    res.json(result);
  } catch (error) {
    res.status(error.statusCode || 400).json({ error: error.message || 'load_failed' });
  }
});

app.post('/api/txlab/accounts/group', txLabEnabledMiddleware, txLabTokenMiddleware, (req, res) => {
  try {
    const updated = txLab.setAccountGroup(String(req.body?.label || ''), String(req.body?.group || 'misc'));
    res.json(updated);
  } catch (error) {
    res.status(400).json({ error: error.message || 'group_failed' });
  }
});

app.post('/api/txlab/scenarios', txLabEnabledMiddleware, txLabTokenMiddleware, async (req, res) => {
  try {
    const scenario = await txLab.saveScenario(req.body || {});
    res.json(scenario);
  } catch (error) {
    res.status(400).json({ error: error.message || 'scenario_invalid' });
  }
});

app.post('/api/txlab/runs/start', txLabEnabledMiddleware, txLabTokenMiddleware, async (req, res) => {
  try {
    const run = await txLab.startRun(req.body?.scenario || req.body?.scenarioName);
    res.json(run);
  } catch (error) {
    res.status(400).json({ error: error.message || 'run_start_failed' });
  }
});

app.post('/api/txlab/runs/:id/stop', txLabEnabledMiddleware, txLabTokenMiddleware, async (req, res) => {
  try {
    const run = await txLab.stopRun(req.params.id);
    res.json(run);
  } catch (error) {
    res.status(400).json({ error: error.message || 'run_stop_failed' });
  }
});

app.use((error, _req, res, next) => {
  if (error instanceof SyntaxError && 'body' in error) {
    res.status(400).json({ error: 'invalid_json' });
    return;
  }
  next(error);
});

app.listen(statusUiPort, host, () => {
  console.log(`status-ui listening on http://${host}:${statusUiPort} (rpc_urls=${parseRpcUrls().length})`);
  console.log(`RPC targets: ${parseRpcUrls().join(', ')}`);
  console.log(`readonlyProd=${readonlyProd} readonly=${readonly} authEnabled=${authEnabled} cacheMs=${cacheMs} txEnabled=${txEnabled}`);
});
