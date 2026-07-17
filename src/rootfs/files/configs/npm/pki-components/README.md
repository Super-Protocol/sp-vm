# PKI npm deployment lock

`package.json` contains the exact versions of the PKI applications installed in
the VM. `package-lock.json` is a deployment lock: it pins the complete
transitive dependency graph, tarball URLs, and SHA-512 integrity values.

The files describe one synthetic deployment project. They are not published to
npm and are not copied into the finished VM. `install_pki_components.sh` uses
them with `npm ci --omit=dev --ignore-scripts` under
`/usr/local/lib/pki-components`, removes the deployment manifests and npm's
hidden lock, and exposes the three application binaries through `/usr/bin`.

Lifecycle scripts are deliberately disabled because their downloads are not
covered by npm's lock. The installer performs the two required operations
explicitly instead:

- the `uplink-nodejs` Linux x64 N-API prebuild has a fixed release URL and
  SHA-256 in `install_pki_components.sh`;
- `sp-nvtrust-wrapper` installs wheels from the platform-specific Python lock
  embedded in its integrity-checked npm tarball. That lock requires hashes and
  permits only binary wheels. `SOURCE_DATE_EPOCH` is also supplied while
  compiling its Python cache.

## Updating a component

1. Change the exact version in `package.json`. Do not use ranges or tags.
2. From the repository root, regenerate the lock:

   ```bash
   src/rootfs/files/configs/npm/pki-components/update-lock.sh
   ```

3. Review both direct and transitive changes:

   ```bash
   git diff -- \
     src/rootfs/files/configs/npm/pki-components/package.json \
     src/rootfs/files/configs/npm/pki-components/package-lock.json
   ```

4. Build the VM. The build fails if npm cannot reproduce the locked graph or a
   downloaded tarball does not match its recorded integrity value.

The update script runs Node.js 24.18.0 and npm 11.16.0 in a pinned linux/amd64
Docker image. Do not edit `package-lock.json` manually and do not add separate
global `npm install` commands for these components.
