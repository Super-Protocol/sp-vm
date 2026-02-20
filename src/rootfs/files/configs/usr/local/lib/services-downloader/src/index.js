#!/usr/bin/env node
const fs = require('fs/promises');
const os = require('os');
const path = require('path');
const { downloadResource, resourceExists } = require('./downloader');
const { getResourceFromGatekeeper } = require('./gatekeeper-client');
const { unpackTarGz, unpackTarGzAbsolute } = require('./unarchiver');
const { acquireResourceLock } = require('./lock');

function printHelp() {
  const text = `
Services Downloader CLI

Usage:
  sp-services-downloader --resource-name <name> --branch-name <branch>
    --ssl-cert-path <path> --ssl-key-path <path>
    [--environment <env>] [--threads <n>] [--timeout <ms>]
    <--download-to <dir> | --unpack-to <dir> | --unpack-with-absolute-path>

Required arguments:
  --resource-name        Logical resource name (used for locking)
  --branch-name          Branch name (used for locking)
  --ssl-cert-path        Path to client SSL certificate (PEM)
  --ssl-key-path         Path to client SSL private key (PEM)

Optional arguments:
  --environment          Gatekeeper environment (default: mainnet)
  --threads              Parallel threads for download
  --timeout              Request timeout to Gatekeeper in ms (default: 30000)
  --download-to <dir>    Download resource into the specified directory (no unpack)
  --unpack-to <dir>      Download to temp and unpack archive contents to the specified directory
  --unpack-with-absolute-path
                         Download to temp and unpack archive entries with absolute paths directly to '/'
                         (when set, no directory is required)
  --help                 Show this help

Examples:
  sp-services-downloader --resource-name svc --branch-name main 
    --ssl-cert-path /secrets/client.crt --ssl-key-path /secrets/client.key 
    --download-to /tmp/svc

  sp-services-downloader --resource-name svc --branch-name main 
    --ssl-cert-path /secrets/client.crt --ssl-key-path /secrets/client.key 
    --unpack-to /etc/sp-swarm-services

  sp-services-downloader --resource-name svc --branch-name main 
    --ssl-cert-path /secrets/client.crt --ssl-key-path /secrets/client.key 
    --unpack-with-absolute-path`;
  process.stdout.write(text);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      args[key] = next;
      i++;
    } else {
      args[key] = true;
    }
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }
  try {
    const resourceName = args['resource-name'];
    const branchName = args['branch-name'];
    const downloadTo = args['download-to'];
    const unpackTo = args['unpack-to'];
    const sslCertPath = args['ssl-cert-path'];
    const sslKeyPath = args['ssl-key-path'];
    const environment = args.environment || 'mainnet';
    const timeout = args.timeout ? Number(args.timeout) : 30000;

    const unpackWithAbs = !!args['unpack-with-absolute-path'];
    if (!resourceName || !branchName || !sslCertPath || !sslKeyPath) {
      throw new Error('Missing required arguments. See --help');
    }
    // Mode selection: exactly one of the mode flags must be provided
    const modeCount = [!!downloadTo, !!unpackTo, unpackWithAbs].filter(Boolean).length;
    if (modeCount !== 1) {
      throw new Error(
        'Specify exactly one mode: --download-to <dir> | --unpack-to <dir> | --unpack-with-absolute-path',
      );
    }
    if (downloadTo && typeof downloadTo !== 'string') {
      throw new Error('Invalid --download-to value');
    }
    if (unpackTo && typeof unpackTo !== 'string') {
      throw new Error('Invalid --unpack-to value');
    }

    const [sslCertPem, sslKeyPem] = await Promise.all([
      fs.readFile(sslCertPath, 'utf8'),
      fs.readFile(sslKeyPath, 'utf8'),
    ]);

    console.info(`[INFO] fetching resource ${resourceName}@${branchName} env=${environment}`);
    const { resource, encryption } = await getResourceFromGatekeeper({
      resourceName,
      branchName,
      sslKeyPem,
      sslCertPem,
      environment,
      timeout,
    });

    const threads = args.threads ? Number(args.threads) : undefined;

    // Acquire per-resource lock
    const release = await acquireResourceLock(resourceName, branchName);
    console.info(`[INFO] lock acquired for ${resourceName}/${branchName}`);

    try {
      // Skip if destination already populated (download-to or unpack-to)
      if (downloadTo && (await resourceExists(downloadTo))) {
        console.info(`[INFO] skip: target already populated -> ${downloadTo}`);
        process.stdout.write(
          JSON.stringify({ ok: true, hash: 'unknown', size: 0, targetDir: downloadTo }) + '\n',
        );
        return;
      }
      if (unpackTo && (await resourceExists(unpackTo))) {
        console.info(`[INFO] skip: target already populated -> ${unpackTo}`);
        process.stdout.write(
          JSON.stringify({ ok: true, hash: 'unknown', size: 0, targetDir: unpackTo }) + '\n',
        );
        return;
      }

      let downloadDir = downloadTo || unpackTo || '/';
      let tempDir;
      try {
        if (unpackTo || unpackWithAbs) {
          const tempPrefix = path.join(os.tmpdir(), 'sp-services-downloader-');
          tempDir = await fs.mkdtemp(tempPrefix);
          console.info(`[INFO] unpack enabled: downloading archive to temp -> ${tempDir}`);
          downloadDir = tempDir;
        }

        const result = await downloadResource({
          resourceName,
          branchName,
          targetDir: downloadDir,
          resource,
          encryption,
          threads,
        });

        if (unpackWithAbs) {
          console.info(`[INFO] unpack-with-absolute-path: extracting archive entries to /`);
          await unpackTarGzAbsolute(downloadDir);
        } else if (unpackTo) {
          console.info(`[INFO] unpacking from temp to target -> ${unpackTo}`);
          await unpackTarGz(downloadDir, unpackTo);
        }

        const outTarget = unpackWithAbs ? '/' : downloadTo || unpackTo;
        process.stdout.write(
          JSON.stringify({ ok: true, hash: result.hash, size: result.size, targetDir: outTarget }) +
            '\n',
        );
      } finally {
        if (tempDir) {
          try {
            await fs.rm(tempDir, { recursive: true, force: true });
            console.info(`[INFO] cleaned temp directory -> ${tempDir}`);
          } catch (cleanupErr) {
            console.warn(`[WARN] failed to clean temp directory ${tempDir}: ${cleanupErr.message}`);
          }
        }
      }
    } finally {
      await release();
      console.info(`[INFO] lock released for ${resourceName}/${branchName}`);
    }
  } catch (e) {
    process.stderr.write(`[ERROR] ${e.message}\n`);
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main();
}
