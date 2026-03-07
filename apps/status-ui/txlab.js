const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');

// Reuse vendored ethers from wallet tool to avoid adding new package install requirements.
const { ethers } = require('../../tools/wallet/node_modules/ethers');

const DEFAULTS = {
  enabled: process.env.TX_LAB_ENABLE === '1',
  insecureKeys: process.env.TX_LAB_INSECURE_KEYS === '1',
  host: process.env.TX_LAB_HOST || '127.0.0.1',
  port: Number(process.env.TX_LAB_PORT || 8799),
  token: process.env.TX_LAB_TOKEN || '',
  rpcUrl: process.env.TX_LAB_RPC_URL || 'http://127.0.0.1:8545',
  dbPath: process.env.TX_LAB_DB_PATH || '.data/txlab/txlab-runs.jsonl',
  accountsFile: process.env.TX_LAB_ACCOUNTS_FILE || '.data/txlab/accounts.json',
  maxConcurrency: Math.max(1, Number(process.env.TX_LAB_MAX_CONCURRENCY || 100)),
  maxTxPerRun: Math.max(1, Number(process.env.TX_LAB_MAX_TX_PER_RUN || 10000)),
};

function nowIso() { return new Date().toISOString(); }

function classifyError(errMsg) {
  const msg = String(errMsg || '').toLowerCase();
  if (msg.includes('nonce too low')) return 'nonce_too_low';
  if (msg.includes('replacement') && msg.includes('underpriced')) return 'replacement_underpriced';
  if (msg.includes('insufficient funds')) return 'insufficient_funds';
  if (msg.includes('intrinsic gas too low')) return 'intrinsic_gas_too_low';
  if (msg.includes('execution reverted') || msg.includes('revert')) return 'execution_reverted';
  if (msg.includes('invalid sender')) return 'invalid_sender';
  if (msg.includes('raw') || msg.includes('rlp')) return 'invalid_raw_tx';
  if (msg.includes('timeout')) return 'timeout';
  if (msg.includes('connection') || msg.includes('rpc') || msg.includes('dial') || msg.includes('network')) return 'rpc_network';
  return 'unknown';
}

class TxLab {
  constructor(rootDir) {
    this.rootDir = rootDir;
    this.config = { ...DEFAULTS };
    this.provider = new ethers.JsonRpcProvider(this.config.rpcUrl);
    this.accounts = new Map();
    this.scenarios = new Map();
    this.runs = new Map();
    this.activeRun = null;
    this.scenarioPath = path.resolve(rootDir, '.data/txlab/scenarios.json');
    this.runsDir = path.resolve(rootDir, '.data/txlab/runs');
    fs.mkdirSync(path.dirname(this.scenarioPath), { recursive: true });
    fs.mkdirSync(this.runsDir, { recursive: true });
    fs.mkdirSync(path.dirname(path.resolve(rootDir, this.config.dbPath)), { recursive: true });
    this._loadPersistedScenarios();
  }

  getPublicConfig() {
    return {
      enabled: this.config.enabled,
      insecureKeys: this.config.insecureKeys,
      host: this.config.host,
      port: this.config.port,
      tokenConfigured: Boolean(this.config.token),
      rpcUrl: this.config.rpcUrl,
      accountsFile: this.config.accountsFile,
      maxConcurrency: this.config.maxConcurrency,
      maxTxPerRun: this.config.maxTxPerRun,
    };
  }

  requireEnabled() { if (!this.config.enabled) { const e = new Error('tx_lab_disabled'); e.statusCode = 503; throw e; } }
  checkToken(token) { if (!this.config.token || token !== this.config.token) { const e = new Error('unauthorized'); e.statusCode = 401; throw e; } }

  _loadPersistedScenarios() {
    if (!fs.existsSync(this.scenarioPath)) return;
    try {
      const parsed = JSON.parse(fs.readFileSync(this.scenarioPath, 'utf8'));
      for (const sc of parsed.scenarios || []) this.scenarios.set(sc.name, sc);
    } catch (_e) {}
  }
  async _saveScenarios() { await fsp.writeFile(this.scenarioPath, JSON.stringify({ scenarios: [...this.scenarios.values()] }, null, 2)); }

  async loadAccountsFromFile(filePath) {
    this.requireEnabled();
    if (!this.config.insecureKeys) { const e = new Error('insecure_keys_disabled'); e.statusCode = 400; throw e; }
    const raw = JSON.parse(await fsp.readFile(path.resolve(this.rootDir, filePath || this.config.accountsFile), 'utf8'));
    const loaded = [];
    for (const entry of raw.accounts || []) {
      const privateKey = String(entry.privateKey || '').trim();
      if (!privateKey) continue;
      const wallet = new ethers.Wallet(privateKey);
      const derived = wallet.address;
      const address = ethers.getAddress(entry.address || derived);
      if (address !== derived) throw new Error(`account ${entry.label || address} has address/privateKey mismatch`);
      const label = String(entry.label || address);
      this.accounts.set(label, { label, address, wallet: wallet.connect(this.provider), group: entry.group || 'misc', balance: null, nonce: null, lastRefreshTs: null });
      loaded.push({ label, address, group: entry.group || 'misc' });
    }
    await this.refreshAccounts();
    return { loadedCount: loaded.length, chainId: Number(raw.chainId || 0), accounts: loaded };
  }

  async refreshAccounts() {
    this.requireEnabled();
    const out = [];
    for (const [label, account] of this.accounts.entries()) {
      const [bal, nonce] = await Promise.all([this.provider.getBalance(account.address), this.provider.getTransactionCount(account.address, 'pending')]);
      const next = { ...account, balance: bal.toString(), nonce, lastRefreshTs: nowIso() };
      this.accounts.set(label, next);
      out.push(this._publicAccount(next));
    }
    return out;
  }

  _publicAccount(a) { return { label: a.label, address: a.address, group: a.group || 'misc', balance: a.balance, nonce: a.nonce, lastRefreshTs: a.lastRefreshTs }; }
  listAccounts() { return [...this.accounts.values()].map((a) => this._publicAccount(a)); }
  setAccountGroup(label, group) { const a=this.accounts.get(label); if(!a) throw new Error('account_not_found'); a.group=group; this.accounts.set(label,a); return this._publicAccount(a); }

  listScenarios() { return [...this.scenarios.values()]; }
  async saveScenario(s) { this._validateScenario(s); this.scenarios.set(s.name, s); await this._saveScenarios(); return s; }

  _validateScenario(sc) {
    for (const key of ['name', 'mode', 'senderSelection', 'txCount', 'concurrency', 'waitMode', 'timeoutSeconds']) {
      if (sc[key] === undefined || sc[key] === null || sc[key] === '') throw new Error(`missing_${key}`);
    }
    if (!Array.isArray(sc.senderSelection) || !sc.senderSelection.length) throw new Error('missing_senderSelection');
    if (Number(sc.txCount) < 1 || Number(sc.txCount) > this.config.maxTxPerRun) throw new Error('invalid_txCount');
    if (Number(sc.concurrency) < 1 || Number(sc.concurrency) > this.config.maxConcurrency) throw new Error('invalid_concurrency');
  }

  async startRun(inputScenario) {
    this.requireEnabled();
    if (this.activeRun) throw new Error('run_already_active');
    const scenario = typeof inputScenario === 'string' ? this.scenarios.get(inputScenario) : inputScenario;
    if (!scenario) throw new Error('scenario_not_found');
    this._validateScenario(scenario);
    const run = { id:`${Date.now()}-${crypto.randomBytes(4).toString('hex')}`, startedAt:nowIso(), endedAt:null, status:'running', scenario, counters:{submitted:0,accepted:0,pending:0,mined:0,failed:0}, errorsByType:{}, latenciesMs:[], txs:[], stopRequested:false };
    this.runs.set(run.id, run); this.activeRun = run;
    this._runAsync(run).catch((err)=>{ run.status='failed'; run.stopReason=err.message; run.endedAt=nowIso(); this.activeRun=null; this._persistRun(run).catch(()=>{});});
    return this._runSummary(run);
  }

  async stopRun(id){ const r=this.runs.get(id); if(!r) throw new Error('run_not_found'); r.stopRequested=true; return this._runSummary(r); }

  async _runAsync(run) {
    const sc = run.scenario; const txCount=Number(sc.txCount); const conc=Math.min(Number(sc.concurrency),this.config.maxConcurrency); const waitReceipt=sc.waitMode==='wait-receipt';
    let cursor=0,inFlight=0; const tps=Number(sc.rateLimitTps||0); let sec=Date.now(),sent=0;
    const reserve = new Map(); // per-account nonce reservation for parallel sends.
    const pick=(labels,i)=>{ const label=labels[i%labels.length]; const a=this.accounts.get(label); if(!a) throw new Error(`unknown_account:${label}`); return a; };
    const nextNonce=async(account)=>{ if(!reserve.has(account.label)){ reserve.set(account.label, await this.provider.getTransactionCount(account.address,'pending')); } const n=reserve.get(account.label); reserve.set(account.label,n+1); return n; };

    const kick=async()=>{
      if (run.stopRequested || cursor >= txCount) return;
      if (tps > 0) { const now=Date.now(); if(now-sec>=1000){sec=now;sent=0;} if(sent>=tps){ await new Promise((r)=>setTimeout(r,50)); return kick(); } }
      inFlight += 1; sent += 1;
      const idx=cursor++; const subTs=Date.now(); const sender=pick(sc.senderSelection,idx); const receivers=sc.receiverSelection||[]; const receiver=receivers.length?pick(receivers,sc.randomizeReceivers?Math.floor(Math.random()*receivers.length):idx):null;
      try {
        const nonce = await nextNonce(sender);
        const res = await this._submitScenarioTx(sc, sender, receiver, nonce, waitReceipt);
        run.counters.submitted += 1; run.counters.accepted += res.accepted?1:0; run.counters.pending += res.pending?1:0; run.counters.mined += res.mined?1:0; if(!res.accepted) run.counters.failed += 1;
        if(res.errorCategory) run.errorsByType[res.errorCategory]=(run.errorsByType[res.errorCategory]||0)+1;
        run.txs.push({ txHash:res.txHash||null, sender:sender.address, receiver:receiver?receiver.address:null, nonce, submissionTs:new Date(subTs).toISOString(), receiptTs:res.receiptTs||null, status:res.mined?'mined':(res.accepted?'accepted':'failed'), errorCategory:res.errorCategory||null, error:res.error||null });
        if(res.receiptTs) run.latenciesMs.push(new Date(res.receiptTs).getTime()-subTs);
      } catch (e) {
        const cat=classifyError(e.message); run.counters.submitted += 1; run.counters.failed += 1; run.errorsByType[cat]=(run.errorsByType[cat]||0)+1;
        run.txs.push({ txHash:null, sender:sender.address, receiver:receiver?receiver.address:null, nonce:null, submissionTs:new Date(subTs).toISOString(), receiptTs:null, status:'failed', errorCategory:cat, error:String(e.message||'unknown').slice(0,220) });
      } finally { inFlight -= 1; }
    };

    while ((cursor < txCount || inFlight > 0) && !run.stopRequested) { while (inFlight < conc && cursor < txCount && !run.stopRequested) kick(); await new Promise((r)=>setTimeout(r,10)); }
    run.status = run.stopRequested ? 'stopped' : 'completed'; run.stopReason = run.stopRequested ? 'stop_requested' : null; run.endedAt = nowIso(); this.activeRun = null;
    await this._persistRun(run);
  }

  async _submitScenarioTx(sc, sender, receiver, nonce, waitReceipt) {
    if (sc.mode === 'raw-tx') {
      const txHash = await this.provider.send('eth_sendRawTransaction', [String(sc.rawTxHex || '')]);
      return { txHash, accepted: true, pending: true, mined: false };
    }

    const txReq = { nonce };
    if (String(sc.txType || 'legacy') === 'legacy') {
      txReq.type = 0; txReq.gasPrice = await this.provider.getFeeData().then((x)=>x.gasPrice);
    } else {
      txReq.type = 2; const fee = await this.provider.getFeeData(); txReq.maxFeePerGas = fee.maxFeePerGas; txReq.maxPriorityFeePerGas = fee.maxPriorityFeePerGas;
    }

    if (sc.mode === 'native-transfer') {
      txReq.to = receiver.address; txReq.value = BigInt(String(sc.valueWei || '0')); txReq.gasLimit = BigInt(sc.gasLimit || 21000);
    } else if (sc.mode === 'contract-deploy') {
      txReq.data = String(sc.bytecode || ''); txReq.value = BigInt(String(sc.valueWei || '0')); txReq.gasLimit = BigInt(sc.gasLimit || 2000000);
    } else if (sc.mode === 'contract-call') {
      let dataHex = String(sc.data || '');
      if (!dataHex && sc.abi && sc.method) {
        dataHex = new ethers.Interface(sc.abi).encodeFunctionData(sc.method, sc.args || []);
      }
      txReq.to = String(sc.contractAddress || ''); txReq.data = dataHex; txReq.value = BigInt(String(sc.valueWei || '0')); txReq.gasLimit = BigInt(sc.gasLimit || 300000);
    } else {
      throw new Error(`unsupported_mode:${sc.mode}`);
    }

    const signed = await sender.wallet.signTransaction(txReq);
    const txHash = await this.provider.send('eth_sendRawTransaction', [signed]);
    if (!waitReceipt) return { txHash, accepted: true, pending: true, mined: false };
    const receipt = await this._waitReceipt(txHash, Number(sc.timeoutSeconds || 30));
    return { txHash, accepted: true, pending: false, mined: receipt.status === 1, receiptTs: nowIso(), errorCategory: receipt.status === 0 ? 'execution_reverted' : null, error: receipt.status === 0 ? 'execution reverted' : null };
  }

  async _waitReceipt(txHash, timeoutSeconds) {
    const start = Date.now();
    while (Date.now() - start < timeoutSeconds * 1000) {
      const r = await this.provider.getTransactionReceipt(txHash);
      if (r) return r;
      await new Promise((res)=>setTimeout(res, 250));
    }
    throw new Error('timeout waiting for receipt');
  }

  _runSummary(run){ const lat=[...run.latenciesMs].sort((a,b)=>a-b); const pct=(p)=>lat.length?lat[Math.floor((p/100)*(lat.length-1))]:null; return { id:run.id, startedAt:run.startedAt, endedAt:run.endedAt, status:run.status, stopReason:run.stopReason||null, scenario:run.scenario, counters:run.counters, errorsByType:run.errorsByType, latencyMs:{avg:lat.length?Math.round(lat.reduce((a,b)=>a+b,0)/lat.length):null,p50:pct(50),p95:pct(95),p99:pct(99)} }; }
  listRuns(){ return [...this.runs.values()].map((r)=>this._runSummary(r)); }
  getRun(id){ const r=this.runs.get(id); return r?this._runSummary(r):null; }
  getRunResults(id){ const r=this.runs.get(id); return r?{summary:this._runSummary(r),txs:r.txs}:null; }
  async _persistRun(run){ const snap=this.getRunResults(run.id); await fsp.writeFile(path.join(this.runsDir, `${run.id}.json`), JSON.stringify(snap,null,2)); await fsp.appendFile(path.resolve(this.rootDir,this.config.dbPath), `${JSON.stringify(snap.summary)}\n`); }
}

module.exports = { TxLab, classifyError, DEFAULTS };
