const express = require('express');
const path = require('path');
const { execFile } = require('child_process');

const app = express();
const port = Number(process.env.PORT || 8787);
const repoRoot = path.resolve(__dirname, '..', '..');
const cliPath = path.join(repoRoot, 'bin', 'qikchain');
const COMMAND_TIMEOUT_MS = 3000;
const SEALING_DELAY_MS = 2000;
const CONCURRENCY_LIMIT = 4;

function parseRpcUrls() {
  const rawList = process.env.RPC_URLS || process.env.RPC_URL || 'http://127.0.0.1:8545';
  return rawList
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
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
  const value = parseFieldNumber(stdout, 'chainId');
  return value === null ? null : String(value);
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
  const base = {
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
    const [statusOutput, blockHeadOutput1] = await Promise.all([
      runQikchain(['status', '--rpc', rpc]),
      runQikchain(['block', 'head', '--rpc', rpc]),
    ]);

    base.chainId = parseChainId(statusOutput);
    base.peerCount = parsePeerCount(statusOutput);
    base.blockHead1 = parseBlockHead(blockHeadOutput1);

    await sleep(SEALING_DELAY_MS);

    const blockHeadOutput2 = await runQikchain(['block', 'head', '--rpc', rpc]);
    base.blockHead2 = parseBlockHead(blockHeadOutput2);

    base.up = true;
    base.sealingHealthy =
      Number.isInteger(base.blockHead1) &&
      Number.isInteger(base.blockHead2) &&
      base.blockHead2 > base.blockHead1;

    return base;
  } catch (error) {
    return {
      ...base,
      up: false,
      sealingHealthy: false,
      error: error.message || 'unknown error',
    };
  }
}

async function mapWithConcurrency(items, limit, iteratorFn) {
  const results = new Array(items.length);
  let index = 0;

  async function worker() {
    while (true) {
      const currentIndex = index;
      index += 1;
      if (currentIndex >= items.length) {
        return;
      }
      results[currentIndex] = await iteratorFn(items[currentIndex], currentIndex);
    }
  }

  const workers = Array.from({ length: Math.min(limit, items.length) }, () => worker());
  await Promise.all(workers);
  return results;
}

function summarize(nodes) {
  const nodesTotal = nodes.length;
  const nodesUp = nodes.filter((node) => node.up).length;
  const nodesSealing = nodes.filter((node) => node.sealingHealthy).length;

  const heads = nodes.map((node) => node.blockHead2 ?? node.blockHead1).filter((value) => Number.isInteger(value));
  const maxBlockHead = heads.length > 0 ? Math.max(...heads) : null;

  const peerValues = nodes.map((node) => node.peerCount).filter((value) => Number.isInteger(value));
  const totalPeers = peerValues.length === nodesTotal ? peerValues.reduce((acc, value) => acc + value, 0) : 'unknown';

  const upChainIds = nodes.filter((node) => node.up && node.chainId !== null).map((node) => node.chainId);
  const chainIdSet = new Set(upChainIds);
  const chainConsistent = chainIdSet.size <= 1;
  const chainId = chainIdSet.size === 1 ? upChainIds[0] : null;

  const healthy = nodesUp >= 1 && nodesSealing >= 1 && chainConsistent;
  let reason = 'At least one node is up and sealing, and chain ID is consistent.';
  if (!healthy) {
    if (nodesUp < 1) {
      reason = 'No nodes are reachable.';
    } else if (nodesSealing < 1) {
      reason = 'No node appears to be sealing.';
    } else if (!chainConsistent) {
      reason = 'Chain ID mismatch across reachable nodes.';
    } else {
      reason = 'Network is degraded.';
    }
  }

  return {
    overall: {
      healthy,
      reason,
    },
    summary: {
      nodesUp,
      nodesTotal,
      nodesSealing,
      totalPeers,
      maxBlockHead,
      chainId,
    },
  };
}

app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/status', async (_req, res) => {
  const rpcUrls = parseRpcUrls();

  try {
    const nodes = await mapWithConcurrency(rpcUrls, CONCURRENCY_LIMIT, checkNode);
    const { overall, summary } = summarize(nodes);

    res.json({
      timestamp: new Date().toISOString(),
      overall,
      summary,
      nodes,
    });
  } catch (error) {
    res.json({
      timestamp: new Date().toISOString(),
      overall: {
        healthy: false,
        reason: error.message || 'failed to aggregate status',
      },
      summary: {
        nodesUp: 0,
        nodesTotal: rpcUrls.length,
        nodesSealing: 0,
        totalPeers: 'unknown',
        maxBlockHead: null,
        chainId: null,
      },
      nodes: rpcUrls.map((rpc) => ({
        rpc,
        up: false,
        chainId: null,
        peerCount: null,
        blockHead1: null,
        blockHead2: null,
        sealingHealthy: false,
        error: 'aggregation failed',
      })),
    });
  }
});

app.listen(port, () => {
  console.log(`status-ui listening on http://127.0.0.1:${port}`);
  console.log(`RPC targets: ${parseRpcUrls().join(', ')}`);
});
