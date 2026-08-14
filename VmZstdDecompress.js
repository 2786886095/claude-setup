'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');
const { Transform } = require('node:stream');
const zlib = require('node:zlib');

async function main() {
  const source = process.env.CLAUDE_VM_ZST_SOURCE;
  const destination = process.env.CLAUDE_VM_ZST_DESTINATION;
  const expectedHash = (process.env.CLAUDE_VM_RUNTIME_SHA256 || '').toLowerCase();
  if (!source || !destination || (expectedHash && !/^[0-9a-f]{64}$/.test(expectedHash))) {
    throw new Error('Required source/destination is missing or SHA-256 is invalid.');
  }
  if (typeof zlib.createZstdDecompress !== 'function') {
    throw new Error(`Node ${process.version} does not provide createZstdDecompress().`);
  }

  const hash = crypto.createHash('sha256');
  const hashStream = new Transform({
    transform(chunk, encoding, callback) {
      hash.update(chunk);
      callback(null, chunk);
    },
  });

  try {
    await pipeline(
      fs.createReadStream(source),
      zlib.createZstdDecompress(),
      hashStream,
      fs.createWriteStream(destination, { flags: 'wx', mode: 0o600 }),
    );
    const actualHash = hash.digest('hex');
    if (expectedHash && actualHash !== expectedHash) {
      throw new Error(`SHA-256 mismatch: expected ${expectedHash}, got ${actualHash}`);
    }
    const handle = await fs.promises.open(destination, 'r+');
    try {
      await handle.sync();
    } finally {
      await handle.close();
    }
    process.stdout.write(JSON.stringify({ ok: true, sha256: actualHash }));
  } catch (error) {
    await fs.promises.rm(destination, { force: true }).catch(() => {});
    throw error;
  }
}

main().catch((error) => {
  process.stderr.write(`${error && error.stack ? error.stack : String(error)}\n`);
  process.exitCode = 1;
});
