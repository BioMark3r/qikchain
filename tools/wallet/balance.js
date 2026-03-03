#!/usr/bin/env node
const { ethers } = require('ethers');
const { parseArgs } = require('./common');

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const rpc = args.rpc || process.env.RPC_URL || 'http://127.0.0.1:8545';
  const address = args.address;

  if (!address || !ethers.isAddress(address)) {
    throw new Error('Usage: node balance.js --rpc <url> --address <0x...>');
  }

  const provider = new ethers.JsonRpcProvider(rpc);
  const checksum = ethers.getAddress(address);
  const balanceWei = await provider.getBalance(checksum);

  console.log(`address=${checksum}`);
  console.log(`rpc=${rpc}`);
  console.log(`balanceWei=${balanceWei.toString()}`);
  console.log(`balanceEther=${ethers.formatEther(balanceWei)}`);
}

main().catch((err) => {
  console.error(`balance_error=${err.message || err}`);
  process.exit(1);
});
