const express = require('express');
const path = require('path');
const { exec } = require('child_process');

const app = express();
const port = process.env.PORT || 8787;
const rpcUrl = process.env.RPC_URL || 'http://127.0.0.1:8545';
const repoRoot = path.resolve(__dirname, '..', '..');

function runQikchain(args) {
  return new Promise((resolve, reject) => {
    const command = `./bin/qikchain ${args} --rpc ${JSON.stringify(rpcUrl)}`;
    exec(command, { cwd: repoRoot, timeout: 3000 }, (error, stdout, stderr) => {
      if (error) {
        reject(new Error((stderr || error.message || '').trim() || 'qikchain command failed'));
        return;
      }
      resolve(stdout.trim());
    });
  });
}

function parseStatusOutput(stdout) {
  const parsed = {
    chainId: null,
    peerCount: null,
  };

  for (const line of stdout.split('\n')) {
    const chainMatch = line.match(/chainId:\s*(\d+)/i);
    if (chainMatch) {
      parsed.chainId = chainMatch[1];
    }

    const peerMatch = line.match(/peerCount:\s*(\d+)/i);
    if (peerMatch) {
      parsed.peerCount = Number(peerMatch[1]);
    }
  }

  return parsed;
}

function parseBlockHead(stdout) {
  const headMatch = stdout.match(/(\d+)/);
  return headMatch ? Number(headMatch[1]) : null;
}

async function readSealingHealth() {
  const firstHead = parseBlockHead(await runQikchain('block head'));

  await new Promise((resolve) => setTimeout(resolve, 2000));

  const secondHead = parseBlockHead(await runQikchain('block head'));

  return {
    blockHead: secondHead,
    sealingHealthy: Number.isInteger(firstHead) && Number.isInteger(secondHead) && secondHead > firstHead,
  };
}

app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/status', async (_req, res) => {
  try {
    const statusOutput = await runQikchain('status');
    const status = parseStatusOutput(statusOutput);
    const sealing = await readSealingHealth();

    res.json({
      rpc: rpcUrl,
      chainId: status.chainId,
      blockHead: sealing.blockHead,
      peerCount: status.peerCount,
      sealingHealthy: sealing.sealingHealthy,
    });
  } catch (err) {
    res.status(503).json({
      rpc: rpcUrl,
      chainId: null,
      blockHead: null,
      peerCount: null,
      sealingHealthy: false,
      error: err.message,
    });
  }
});

app.listen(port, () => {
  console.log(`status-ui listening on http://127.0.0.1:${port}`);
  console.log(`querying RPC_URL=${rpcUrl}`);
});
