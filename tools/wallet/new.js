#!/usr/bin/env node
const path = require('path');
const { Wallet } = require('ethers');
const { parseArgs, writeSecretJson } = require('./common');

function main() {
  const args = parseArgs(process.argv.slice(2));
  const wallet = Wallet.createRandom();

  console.log(`address=${wallet.address}`);
  console.log(`privateKey=${wallet.privateKey}`);

  if (args.out && typeof args.out === 'string') {
    const outPath = path.resolve(process.cwd(), args.out);
    writeSecretJson(outPath, { address: wallet.address, privateKey: wallet.privateKey });
    console.log(`saved=${outPath}`);
  }
}

try {
  main();
} catch (err) {
  console.error(err.message || err);
  process.exit(1);
}
