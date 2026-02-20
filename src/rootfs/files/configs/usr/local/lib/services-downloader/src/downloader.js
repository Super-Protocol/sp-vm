const path = require('path');
const fs = require('fs/promises');
const { download } = require('@super-protocol/sp-files-addon');

async function ensureDir(dir) {
  await fs.mkdir(dir, { recursive: true });
}

async function resourceExists(filePath) {
  try {
    const stat = await fs.stat(filePath);
    if (stat.isFile()) return true;
    if (stat.isDirectory()) {
      const entries = await fs.readdir(filePath);
      return entries.length > 0;
    }
    return false;
  } catch {
    // Path does not exist or not accessible
    return false;
  }
}

// Resource helpers and plain download only; orchestration happens in CLI

/**
 * Download resource using sp-files-addon.
 * Performs plain download; concurrency control handled by caller.
 *
 * @param {Object} params
 * @param {string} params.resourceName
 * @param {string} params.branchName
 * @param {Object} params.resource - Resource definition for sp-files-addon
 * @param {Object} [params.encryption] - Optional encryption { key, iv }
 * @param {string} params.targetDir - Local directory where the resource will be downloaded
 * @param {number} [params.threads] - Parallelism for sp-files-addon
 * @returns {Promise<{ hash: string, size: number, targetDir: string }>} download result
 */
async function downloadResource(params) {
  const { resourceName, branchName, targetDir, resource, encryption } = params;
  if (!resourceName || !branchName) throw new Error('resourceName and branchName are required');
  if (!targetDir) throw new Error('targetDir is required');
  if (!resource) {
    throw new Error('Resource is missing in parameters');
  }

  await ensureDir(targetDir);

  const result = await download(resource, targetDir, {
    encryption,
    threads: params.threads,
    retry: { maxRetries: 5, initialDelayMs: 1000 },
    progressCallback: ({ key, current, total }) => {
      const t = typeof total === 'number' ? total : 0;
      const c = typeof current === 'number' ? current : 0;
      const pct = t > 0 ? Math.floor((c / t) * 100) : 0;
      console.log(`${key} ${c}/${t} (${pct}%)`);
    },
  });

  return { hash: result.hash, size: result.size, targetDir };
}

module.exports = { downloadResource, resourceExists };
