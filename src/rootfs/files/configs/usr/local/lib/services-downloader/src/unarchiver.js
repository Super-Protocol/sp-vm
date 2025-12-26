const path = require('path');
const fs = require('fs/promises');
const { execFile } = require('child_process');

async function hasFiles(dir) {
  try {
    const stat = await fs.stat(dir);
    if (!stat.isDirectory()) return false;
    const entries = await fs.readdir(dir);
    return entries.length > 0;
  } catch {
    return false;
  }
}

async function ensureDir(dir) {
  await fs.mkdir(dir, { recursive: true });
}

async function findTarLike(targetDir) {
  const entries = await fs.readdir(targetDir, { withFileTypes: true });
  for (const e of entries) {
    const full = path.join(targetDir, e.name);
    if (e.isFile()) {
      const name = e.name.toLowerCase();
      if (name.endsWith('.tar.gz') || name.endsWith('.tgz') || name.endsWith('.tar')) {
        return full;
      }
    } else if (e.isDirectory()) {
      try {
        const nested = await findTarLike(full);
        if (nested) return nested;
      } catch {}
    }
  }
  return null;
}

function execTarExtract(tarFile, destDir) {
  return new Promise((resolve, reject) => {
    const lower = tarFile.toLowerCase();
    const args =
      lower.endsWith('.tar.gz') || lower.endsWith('.tgz')
        ? ['-xzf', tarFile, '-C', destDir]
        : ['-xf', tarFile, '-C', destDir];
    execFile('tar', args, (err) => {
      if (err) return reject(err);
      resolve();
    });
  });
}

async function unpackTarGz(targetDir, unpackTarTo) {
  await ensureDir(unpackTarTo);
  const destHasFiles = await hasFiles(unpackTarTo);
  if (destHasFiles) {
    console.info(`[INFO] unpack skip: destination not empty: ${unpackTarTo}`);
    return false;
  }

  const tarFile = await findTarLike(targetDir);
  if (!tarFile) {
    console.info(`[INFO] unpack skip: no archive found under ${targetDir}`);
    return false;
  }

  await execTarExtract(tarFile, unpackTarTo);
  console.info(`[INFO] unpacked ${path.basename(tarFile)} to ${unpackTarTo}`);
  return true;
}

module.exports = { unpackTarGz };
