#!/usr/bin/env bash

set -euo pipefail

docs_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
output="$docs_dir/vm-attestation-documentation.pdf"
html=$(mktemp "$docs_dir/.pdf-build.XXXXXX.html")
architecture_svg="$docs_dir/assets/architecture-overview.svg"
architecture_png="$docs_dir/assets/pdf/architecture-overview.png"

cleanup() {
  rm -f "$html"
}
trap cleanup EXIT

mkdir -p "$(dirname "$architecture_png")"
if [[ ! -f "$architecture_png" || "$architecture_svg" -nt "$architecture_png" ]]; then
  if ! command -v rsvg-convert >/dev/null 2>&1; then
    printf 'Error: rsvg-convert is required to update %s\n' "$architecture_png" >&2
    printf 'Install it with: sudo apt install librsvg2-bin\n' >&2
    exit 1
  fi

  rsvg-convert \
    --dpi-x 192 \
    --dpi-y 192 \
    --format png \
    --output "$architecture_png" \
    "$architecture_svg"
fi

pandoc \
  --from=gfm \
  --standalone \
  --file-scope \
  --metadata pagetitle="Virtual Machine Attestation and Trust Infrastructure" \
  --css=pdf.css \
  "$docs_dir/cover.md" \
  "$docs_dir/README.md" \
  "$docs_dir/01-architecture.md" \
  "$docs_dir/02-first-vm-bootstrap.md" \
  "$docs_dir/03-node-join.md" \
  "$docs_dir/04-vm-measurements.md" \
  "$docs_dir/05-nvidia-gpu-attestation.md" \
  "$docs_dir/06-pki.md" \
  "$docs_dir/07-reference-measurements.md" \
  --output "$html"

# WeasyPrint calculates text metrics inside this SVG differently from browsers.
# Use the pre-rendered copy in the PDF while keeping the SVG in Markdown.
sed -i \
  's#assets/architecture-overview\.svg#assets/pdf/architecture-overview.png#g' \
  "$html"

weasyprint "$html" "$output"

printf 'Created %s\n' "$output"
