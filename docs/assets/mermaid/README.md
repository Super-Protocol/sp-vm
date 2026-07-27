# Mermaid diagram sources

This directory contains editable Mermaid sources for the SVG diagrams used in
the documentation.

The sources preserve the structure and meaning of the diagrams. The published
SVG files include additional manual visual styling, so rendering the Mermaid
sources does not reproduce every decorative detail.

Render a source with Mermaid CLI:

```bash
npx -p @mermaid-js/mermaid-cli mmdc \
  -i docs/assets/mermaid/architecture-overview.mmd \
  -o architecture-overview.svg \
  -b transparent
```

Use the same command with:

- `evidence-binding.mmd` for the evidence-binding diagram;
- `tdx-data-flow.mmd` for the TDX measurement data flow;
- `sev-snp-data-flow.mmd` for the SEV-SNP measurement data flow;
- `pki-hierarchy.mmd` for the PKI certificate hierarchy;
- `reference-measurement-flow.mmd` for reference measurement verification.
