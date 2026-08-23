# Building the PDF Documentation

## Prerequisites

The PDF build requires a Linux environment with the following tools:

| Dependency | Purpose |
|---|---|
| Bash | Runs the build scripts. |
| Pandoc | Combines the Markdown files and converts them to HTML. |
| WeasyPrint | Renders the intermediate HTML as an A4 PDF. |
| `rsvg-convert` | Regenerates the PDF-compatible copy of the architecture diagram when its source SVG changes. |
| DejaVu fonts | Provide the sans-serif and monospace fonts selected by `pdf.css`. |

On Debian or Ubuntu, install the dependencies with:

```bash
sudo apt update
sudo apt install bash pandoc weasyprint librsvg2-bin fonts-dejavu-core
```

The build does not require Node.js, npm, Mermaid CLI, a browser, or network
access after these packages have been installed.

Verify the installation:

```bash
pandoc --version
weasyprint --version
rsvg-convert --version
```

## Build Commands

Run the scripts from the repository root.

Build the English document:

```bash
./docs/build-en-pdf.sh
```

Output:

```text
docs/vm-attestation-documentation.pdf
```

Build the Russian document:

```bash
./docs/build-ru-pdf.sh
```

Output:

```text
docs/ru/vm-attestation-documentation.pdf
```

Each command performs a complete Markdown-to-PDF build and replaces the
corresponding output file.

## Architecture Diagram Rendering

The Markdown documents reference the vector source directly:

```text
docs/assets/architecture-overview.svg
```

WeasyPrint calculates some text metrics in this SVG differently from common
browsers. To keep the labels in their intended positions, the PDF build uses
the following pre-rendered copy:

```text
docs/assets/pdf/architecture-overview.png
```

The build script regenerates the PNG when it is absent or older than the SVG.
The Markdown files continue to reference the SVG; the substitution exists only
in the temporary HTML used to create the PDF.

## Build Process

The scripts perform the following operations:

1. Regenerate the PDF-compatible architecture image when required.
2. Combine the cover, README, and numbered chapters with Pandoc.
3. Apply `docs/pdf.css` to the generated HTML.
4. Substitute the architecture PNG in the temporary HTML.
5. Render the final A4 PDF with WeasyPrint.
6. Remove the temporary HTML file.

The scripts do not create an archive or modify the Markdown source files.

## Troubleshooting

### `rsvg-convert is required`

The architecture SVG is newer than its generated PNG, but `rsvg-convert` is
not installed. Install `librsvg2-bin` and run the build again:

```bash
sudo apt install librsvg2-bin
```

### Font layout differs between hosts

Confirm that `fonts-dejavu-core` is installed. The PDF stylesheet explicitly
uses DejaVu Sans and DejaVu Sans Mono to provide stable Latin and Cyrillic text
metrics.

### Duplicate anchor warnings

Pandoc or WeasyPrint may report that an HTML anchor is defined more than once
when different chapters contain headings with the same name. These warnings do
not stop PDF generation or affect the document contents.

### PDF appears empty after transfer

Verify the copied file directly rather than saving the binary through a text
editor. Compare its size or checksum with the file produced on the build host:

```bash
sha256sum docs/vm-attestation-documentation.pdf
sha256sum docs/ru/vm-attestation-documentation.pdf
```
