# Mermaid diagram sources

This directory contains editable Mermaid sources for the SVG diagrams used on
the architecture pages.

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

Use the same command with `evidence-binding.mmd` for the evidence-binding
diagram.
