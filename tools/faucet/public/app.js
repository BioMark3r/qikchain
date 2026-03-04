const tokenKey = 'qik_faucet_token';
const healthIntervalMs = 10_000;
const statusPollMs = 2_000;
const statusPollMaxMs = 60_000;

const connectBtn = document.getElementById('connect-btn');
const walletStatus = document.getElementById('wallet-status');
const toInput = document.getElementById('to');
const tokenInput = document.getElementById('token');
const requestBtn = document.getElementById('request-btn');
const healthPanel = document.getElementById('health-panel');
const resultPanel = document.getElementById('result-panel');
const txActions = document.getElementById('tx-actions');
const copyToBtn = document.getElementById('copy-to');
const copyTxBtn = document.getElementById('copy-tx');
const checkStatusBtn = document.getElementById('check-status');

let currentTxHash = '';
let statusTimer = null;

function setResult(data) {
  resultPanel.textContent = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
}

function hideTxActions() {
  txActions.classList.add('hidden');
}

function showTxActions() {
  txActions.classList.remove('hidden');
}

async function copyText(value) {
  if (!value) return;
  try {
    await navigator.clipboard.writeText(value);
    setResult(`Copied to clipboard: ${value}`);
  } catch {
    setResult('Could not copy to clipboard in this browser context.');
  }
}

async function checkHealth() {
  try {
    const res = await fetch('/health');
    const body = await res.json();
    if (!res.ok || !body.ok) {
      healthPanel.textContent = `RPC down\n${JSON.stringify(body, null, 2)}`;
      return;
    }
    healthPanel.textContent = JSON.stringify({
      ok: body.ok,
      chainId: body.chainId,
      latestBlock: body.latestBlock,
    }, null, 2);
  } catch (err) {
    healthPanel.textContent = `RPC down\n${err.message}`;
  }
}

async function connectMetaMask() {
  if (!window.ethereum) {
    walletStatus.textContent = 'MetaMask not detected. Install MetaMask or paste an address manually.';
    return;
  }

  try {
    const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
    const account = accounts?.[0];
    if (!account) {
      walletStatus.textContent = 'No account selected in MetaMask.';
      return;
    }
    walletStatus.textContent = `Connected: ${account}`;
    toInput.value = account;
  } catch (err) {
    walletStatus.textContent = `MetaMask connection failed: ${err.message}`;
  }
}

function stopStatusPolling() {
  if (statusTimer) {
    clearTimeout(statusTimer);
    statusTimer = null;
  }
}

async function pollTxStatus(txHash, startedAt = Date.now()) {
  const elapsed = Date.now() - startedAt;
  if (elapsed > statusPollMaxMs) {
    setResult({ status: 'timeout', message: 'Still pending after 60s. You can check status again manually.' });
    return;
  }

  try {
    const res = await fetch(`/status/${txHash}`);
    const body = await res.json();

    if (!res.ok) {
      setResult(body);
      return;
    }

    if (body.status === 'pending') {
      setResult({ txHash, status: 'pending', message: 'Transaction is still pending...' });
      statusTimer = setTimeout(() => pollTxStatus(txHash, startedAt), statusPollMs);
      return;
    }

    if (body.status === 'success') {
      setResult({ txHash, status: 'success', ...body });
      return;
    }

    setResult({ txHash, status: 'failed', ...body });
  } catch (err) {
    setResult({ error: 'status_check_failed', message: err.message });
  }
}

async function requestFunds() {
  stopStatusPolling();
  hideTxActions();

  const token = tokenInput.value.trim();
  const to = toInput.value.trim();

  if (!token) {
    setResult({ error: 'missing_token', message: 'Enter X-FAUCET-TOKEN before requesting funds.' });
    return;
  }
  if (!to) {
    setResult({ error: 'missing_address', message: 'Enter a destination address.' });
    return;
  }

  localStorage.setItem(tokenKey, token);

  try {
    const res = await fetch('/faucet', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'X-FAUCET-TOKEN': token,
      },
      body: JSON.stringify({ to }),
    });

    const body = await res.json();
    if (!res.ok) {
      setResult(body);
      return;
    }

    currentTxHash = body.txHash || '';
    if (!currentTxHash) {
      setResult({ error: 'unknown', message: 'Faucet did not return a tx hash.' });
      return;
    }

    setResult({ message: 'Transaction submitted', txHash: currentTxHash, status: 'pending' });
    showTxActions();
    pollTxStatus(currentTxHash);
  } catch (err) {
    setResult({ error: 'request_failed', message: err.message });
  }
}

function boot() {
  const savedToken = localStorage.getItem(tokenKey);
  if (savedToken) {
    tokenInput.value = savedToken;
  }

  connectBtn.addEventListener('click', connectMetaMask);
  requestBtn.addEventListener('click', requestFunds);
  copyToBtn.addEventListener('click', () => copyText(toInput.value.trim()));
  copyTxBtn.addEventListener('click', () => copyText(currentTxHash));
  checkStatusBtn.addEventListener('click', () => {
    if (!currentTxHash) {
      setResult('No transaction hash available yet.');
      return;
    }
    stopStatusPolling();
    pollTxStatus(currentTxHash);
  });

  checkHealth();
  setInterval(checkHealth, healthIntervalMs);
}

boot();
