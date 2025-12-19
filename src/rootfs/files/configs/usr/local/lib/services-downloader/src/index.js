#!/usr/bin/env node
const fs = require('fs/promises');
const { downloadResource, resourceExists } = require('./downloader');
const { getResourceFromGatekeeper } = require('./gatekeeper-client');
const { unpackTarGz } = require('./unarchiver');
const { acquireResourceLock } = require('./lock');

function printHelp() {
  const text = `
Services Downloader CLI

Usage:
  sp-services-downloader --resource-name <name> --branch-name <branch> --target-dir <dir>
    --ssl-cert-path <path> --ssl-key-path <path> [--environment <env>] [--threads <n>] [--timeout <ms>] [--unpack-tar-to <dir>]

Required arguments:
  --resource-name        Logical resource name (used for locking)
  --branch-name          Branch name (used for locking)
  --target-dir           Local directory to download into
  --ssl-cert-path        Path to client SSL certificate (PEM)
  --ssl-key-path         Path to client SSL private key (PEM)

Optional arguments:
  --environment          Gatekeeper environment (default: mainnet)
  --threads              Parallel threads for download
  --timeout              Request timeout to Gatekeeper in ms (default: 30000)
  --help                 Show this help

Examples:
  sp-services-downloader --resource-name svc --branch-name main 
    --ssl-cert-path /secrets/client.crt --ssl-key-path /secrets/client.key 
    --target-dir /tmp/svc`;
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
    const targetDir = args['target-dir'];
    const sslCertPath = args['ssl-cert-path'];
    const sslKeyPath = args['ssl-key-path'];
    const environment = args.environment || 'mainnet';
    const timeout = args.timeout ? Number(args.timeout) : 30000;

    if (!resourceName || !branchName || !targetDir || !sslCertPath || !sslKeyPath) {
      throw new Error('Missing required arguments. See --help');
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
    const unpackTarTo = args['unpack-tar-to'];

    // Acquire per-resource lock
    const release = await acquireResourceLock(resourceName, branchName);
    console.info(`[INFO] lock acquired for ${resourceName}/${branchName}`);

    try {
      // Skip if already present
      if (await resourceExists(targetDir)) {
        console.info(`[INFO] skip: target already populated -> ${targetDir}`);
        if (unpackTarTo) {
          console.info(`[INFO] unpack requested on existing target -> ${unpackTarTo}`);
          await unpackTarGz(targetDir, unpackTarTo);
        }
        process.stdout.write(
          JSON.stringify({ ok: true, hash: 'unknown', size: 0, targetDir }) + '\n',
        );
        return;
      }

      const result = await downloadResource({
        resourceName,
        branchName,
        targetDir,
        resource,
        encryption,
        threads,
      });

      if (unpackTarTo) {
        console.info(`[INFO] unpack requested -> ${unpackTarTo}`);
        await unpackTarGz(result.targetDir, unpackTarTo);
      }

      process.stdout.write(JSON.stringify({ ok: true, ...result }) + '\n');
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
