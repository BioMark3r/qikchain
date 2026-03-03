#!/usr/bin/env node
const { ethers } = require('ethers');
const { parseArgs, normalizePk } = require('./common');

async function sleep(ms) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const rpc = args.rpc || process.env.RPC_URL || 'http://127.0.0.1:8545';
  const pk = normalizePk(args.pk || '');
  const toRaw = args.to;
  const valueWeiRaw = args['value-wei'];
  const timeoutMs = Number(args.timeout || 60000);

  if (!toRaw || !ethers.isAddress(toRaw)) {
    throw new Error('Invalid --to address');
  }
  if (!valueWeiRaw || !/^\d+$/.test(String(valueWeiRaw))) {
    throw new Error('Invalid --value-wei (must be an integer in wei)');
  }

  const valueWei = BigInt(valueWeiRaw);
  const provider = new ethers.JsonRpcProvider(rpc);
  const wallet = new ethers.Wallet(pk, provider);
  const to = ethers.getAddress(toRaw);

  const tx = await wallet.sendTransaction({ to, value: valueWei });
  console.log(`from=${wallet.address}`);
  console.log(`to=${to}`);
  console.log(`valueWei=${valueWei.toString()}`);
  console.log(`txHash=${tx.hash}`);

  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const receipt = await provider.getTransactionReceipt(tx.hash);
    if (receipt) {
      console.log(`status=${receipt.status === 1 ? 'success' : 'failed'}`);
      console.log(`blockNumber=${receipt.blockNumber}`);
      return;
    }
    await sleep(2000);
  }

  throw new Error(`Timed out waiting for receipt after ${timeoutMs}ms`);
}

main().catch((err) => {
  console.error(`send_error=${err.message || err}`);
  process.exit(1);
});
