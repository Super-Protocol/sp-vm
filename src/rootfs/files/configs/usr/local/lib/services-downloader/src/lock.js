const path = require('path');
const os = require('os');
const fs = require('fs/promises');
const lockfile = require('proper-lockfile');

function buildLockName(resourceName, branchName) {
  const safe = (s) => encodeURIComponent(String(s || ''));
  return `${safe(resourceName)}__${safe(branchName)}`;
}

async function acquireResourceLock(resourceName, branchName, options = {}) {
  const baseDir = options.baseDir || path.join(os.tmpdir(), 'sp-services-downloader-locks');
  await fs.mkdir(baseDir, { recursive: true });
  const lockTarget = path.join(baseDir, buildLockName(resourceName, branchName));

  const release = await lockfile.lock(lockTarget, {
    stale: options.staleMs || 60_000,
    retries: options.retries || { retries: 120, factor: 1, minTimeout: 500 },
    realpath: false,
  });

  return release;
}

module.exports = { acquireResourceLock, buildLockName };
