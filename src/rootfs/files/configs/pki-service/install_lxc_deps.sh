#!/bin/bash
set -e
apt-get update

DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends skopeo umoci jq

EXPECTED_YQ_SHA256="0fb28c6680193c41b364193d0c0fc4a03177aecde51cfc04d506b1517158c2fb"
wget https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64 -O /usr/local/bin/yq-go

echo "$EXPECTED_YQ_SHA256  /usr/local/bin/yq-go" | sha256sum -c -
chmod +x /usr/local/bin/yq-go
