#!/usr/bin/env bash
set -e

ACCESS_KEY=$(curl -s "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-access-key" -H "Metadata-Flavor: Google")
SECRET_KEY=$(curl -s "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-secret-key" -H "Metadata-Flavor: Google")
BUCKET=$(curl -s "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-bucket" -H "Metadata-Flavor: Google")
ENDPOINT=$(curl -s "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-endpoint" -H "Metadata-Flavor: Google")

if ! grep -q "metadata.google.internal" /etc/hosts; then
    echo "169.254.169.254 metadata.google.internal metadata" >> /etc/hosts
fi

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ] || [ -z "$BUCKET" ] || [ -z "$ENDPOINT" ]; then
    echo "S3 metadata attributes are missing. Not mounting /sp/"
    exit 0
fi

echo "${ACCESS_KEY}:${SECRET_KEY}" > /etc/passwd-s3fs
chmod 600 /etc/passwd-s3fs

mkdir -p /sp/

if mountpoint -q /sp/; then
    umount /sp/ || true
fi

s3fs "${BUCKET}" /sp/ \
    -o url="${ENDPOINT}" \
    -o passwd_file=/etc/passwd-s3fs \
    -o use_path_request_style \
    -o allow_other
