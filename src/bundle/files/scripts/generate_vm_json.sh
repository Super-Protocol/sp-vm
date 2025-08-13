#!/bin/bash

set -euo pipefail;

# private
BUILD_DIR="$(pwd)/output";

# public, not required
SP_VM_IMAGE_VERSION="${SP_VM_IMAGE_VERSION:-"build-local"}"
S3_BUCKET="${S3_BUCKET:-"local"}"

# json
JSON="{\n";

if [[ ! -d "$BUILD_DIR" ]]; then
    echo "BUILD_DIR: $BUILD_DIR: not found";
    exit 1;
fi

# walking throught files in outdir
for FILE in $(find "$BUILD_DIR" -type f -exec basename {} \;); do
    case "$FILE" in
        "sp-vm-${SP_VM_IMAGE_VERSION}.img") KEY="image" ;;
        OVMF.fd) KEY="bios" ;;
        OVMF_AMD.fd) KEY="bios_amd" ;;
        *)
            echo "Don't know how to indentify file: $FILE";
            exit 1;
            ;;
    esac

    SHA256="$(sha256sum "$BUILD_DIR/$FILE" | awk '{print $1}')";
    JSON+="  \"$KEY\": {\n";
    JSON+="    \"bucket\": \"$S3_BUCKET\",\n";
    JSON+="    \"prefix\": \"$SP_VM_IMAGE_VERSION\",\n";
    JSON+="    \"filename\": \"$FILE\",\n";
    JSON+="    \"sha256\": \"$SHA256\"\n";
    JSON+="  },\n";
done

JSON="${JSON%,*}";
JSON+="\n}";
echo -e "$JSON" > "$BUILD_DIR/vm.json";
