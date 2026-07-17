#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NODE_IMAGE="node:24.18.0-bookworm-slim@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d"

docker run --rm --platform linux/amd64 \
    --user "$(id -u):$(id -g)" \
    --volume "$SCRIPT_DIR:/deployment" \
    --workdir /deployment \
    "$NODE_IMAGE" \
    sh -euc '
        export HOME=/tmp
        export npm_config_cache=/tmp/npm-cache
        test "$(node --version)" = "v24.18.0"
        test "$(npm --version)" = "11.16.0"
        npm install \
            --package-lock-only \
            --ignore-scripts \
            --no-audit \
            --no-fund
        node <<"NODE"
const fs = require("node:fs");

const manifest = JSON.parse(fs.readFileSync("package.json", "utf8"));
const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));

if (lock.lockfileVersion !== 3) {
  throw new Error(`expected lockfileVersion 3, got ${lock.lockfileVersion}`);
}

for (const [name, version] of Object.entries(manifest.dependencies)) {
  if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error(`direct dependency ${name} is not pinned exactly: ${version}`);
  }
}

for (const [path, entry] of Object.entries(lock.packages)) {
  if (path === "") continue;
  if (!entry.version || !entry.resolved || !entry.integrity) {
    throw new Error(`incomplete lock entry: ${path}`);
  }
  if (!entry.resolved.startsWith("https://registry.npmjs.org/")) {
    throw new Error(`unexpected registry URL for ${path}: ${entry.resolved}`);
  }
  if (!entry.integrity.startsWith("sha512-")) {
    throw new Error(`expected SHA-512 integrity for ${path}`);
  }
}
NODE
    '

echo "Updated $SCRIPT_DIR/package-lock.json"
