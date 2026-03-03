const fs = require('fs');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;

    if (arg.includes('=')) {
      const [k, ...rest] = arg.slice(2).split('=');
      out[k] = rest.join('=');
      continue;
    }

    const key = arg.slice(2);
    const maybeValue = argv[i + 1];
    if (!maybeValue || maybeValue.startsWith('--')) {
      out[key] = true;
    } else {
      out[key] = maybeValue;
      i += 1;
    }
  }
  return out;
}

function normalizePk(pkRaw) {
  if (!pkRaw) {
    throw new Error('Missing private key');
  }
  return pkRaw.startsWith('0x') ? pkRaw : `0x${pkRaw}`;
}

function writeSecretJson(path, payload) {
  fs.writeFileSync(path, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 });
  fs.chmodSync(path, 0o600);
}

module.exports = {
  parseArgs,
  normalizePk,
  writeSecretJson,
};
