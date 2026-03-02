const crypto = require('crypto');
const express = require('express');
const path = require('path');
const { execFile } = require('child_process');

const app = express();
const port = Number(process.env.PORT || 8787);
const readonlyProd = process.env.READONLY_PROD === '1';
const host = process.env.HOST || (readonlyProd ? '127.0.0.1' : '0.0.0.0');
const cacheMs = Math.max(0, Number(process.env.CACHE_MS || 1000));
const repoRoot = path.resolve(__dirname, '..', '..');
const cliPath = path.join(repoRoot, 'bin', 'qikchain');
const COMMAND_TIMEOUT_MS = 3000;
const SEALING_DELAY_MS = 2000;

const authUser = process.env.AUTH_USER || '';
const authPass = process.env.AUTH_PASS || '';
const authEnabled = authUser.length > 0 && authPass.length > 0;

const statusCache = {
  value: null,
  computedAt: 0,
  inFlight: null,
};

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
  const nodesUp = nodes.filter((node) => node.up).length;
  const nodesSealing = nodes.filter((node) => node.sealingHealthy).length;

  const heads = nodes.map((node) => node.blockHead2 ?? node.blockHead1).filter((value) => Number.isInteger(value));
  const maxBlockHead = heads.length > 0 ? Math.max(...heads) : null;

  const upChainIds = nodes.filter((node) => node.up && node.chainId !== null).map((node) => node.chainId);
  const uniqueChainIds = [...new Set(upChainIds)];
  const chainId = uniqueChainIds.length === 1 ? uniqueChainIds[0] : null;

  const healthy = nodesUp > 0 && nodesSealing > 0;
  let reason = 'At least one node is up and sealing.';
  if (!healthy) {
    if (nodesUp === 0) {
      reason = 'No nodes are reachable.';
    } else if (nodesSealing === 0) {
      reason = 'No node appears to be sealing.';
    }
  }

  return {
    overall: { healthy, reason },
    summary: {
      nodesUp,
      nodesTotal,
      nodesSealing,
      maxBlockHead,
      chainId,
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

function readonlyMiddleware(req, res, next) {
  if (readonlyProd && req.method !== 'GET') {
    res.status(405).json({ error: 'Method Not Allowed' });
    return;
  }
  next();
}

app.use(authMiddleware);
app.use(readonlyMiddleware);
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
      overall: {
        healthy: false,
        reason: 'failed to aggregate status',
      },
      summary: {
        nodesUp: 0,
        nodesTotal: parseRpcUrls().length,
        nodesSealing: 0,
        maxBlockHead: null,
        chainId: null,
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

app.listen(port, host, () => {
  console.log(`status-ui listening on http://${host}:${port}`);
  console.log(`RPC targets: ${parseRpcUrls().join(', ')}`);
  console.log(`readonlyProd=${readonlyProd} authEnabled=${authEnabled} cacheMs=${cacheMs}`);
});
