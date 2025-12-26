#!/bin/bash
set -euo pipefail

# Download and stage Swarm service pack into /etc/sp-swarm-services.
# - If /sp/swarm/gatekeeper-keys.yaml exists, extract TLS key/cert to
#   /etc/super/certs/gatekeeper.key and /etc/super/certs/gatekeeper.crt
# - Read BRANCH from sp-swarm-services.yaml (fallback to $BRANCH_NAME or "main")
# - Invoke sp-services-downloader to fetch resource "sp-swarm-services" and --unpack
# - Merge content of /etc/sp-swarm-services/swarm-service-pluggins/ into /etc

YAML_PATH="${YAML_PATH:-/sp/swarm/gatekeeper-keys.yaml}" # for cert extraction
SP_SWARM_SERVICES_YAML_PATH="${SP_SWARM_SERVICES_YAML_PATH:-/sp/swarm/sp-swarm-services.yaml}"
SSL_CERT_PATH="${SSL_CERT_PATH:-/etc/super/certs/gatekeeper.crt}"
SSL_KEY_PATH="${SSL_KEY_PATH:-/etc/super/certs/gatekeeper.key}"
GK_ENV="${GATEKEEPER_ENV:-mainnet}"
TARGET_DIR="${TARGET_DIR:-/etc/sp-swarm-services}"
RESOURCE_NAME="sp-swarm-services"

log() {
	printf "[download-sp-swarm-services] %s\n" "$*";
}

ensure_gatekeeper_certs_from_yaml() {
	# If outputs already exist, skip
	if [[ -f "$SSL_KEY_PATH" && -f "$SSL_CERT_PATH" ]]; then
		log "TLS key/cert already present — skipping extraction";
		return 0
	fi

	if [[ ! -f "$YAML_PATH" ]]; then
		log "YAML not found: $YAML_PATH — skipping cert extraction";
		return 0
	fi

	install -d "$(dirname "$SSL_CERT_PATH")"
	: > "$SSL_KEY_PATH"
	: > "$SSL_CERT_PATH"

	# Extract blocks under 'key: |' and 'cert: |', mirroring Python logic from main.py
	awk -v key_out="$SSL_KEY_PATH" -v cert_out="$SSL_CERT_PATH" '
		BEGIN { mode = "" }
		/^[[:space:]]*key:[[:space:]]*\|[[:space:]]*$/  { mode="key";  next }
		/^[[:space:]]*cert:[[:space:]]*\|[[:space:]]*$/ { mode="cert"; next }
		{
			if (mode == "key")  { sub(/^\s+/, ""); print $0 >> key_out }
			else if (mode == "cert") { sub(/^\s+/, ""); print $0 >> cert_out }
		}
	' "$YAML_PATH"

	if ! grep -q "BEGIN PRIVATE KEY" "$SSL_KEY_PATH"; then
		log "ERROR: key block not found in $YAML_PATH"; return 1
	fi
	if ! grep -q "BEGIN CERTIFICATE" "$SSL_CERT_PATH"; then
		log "ERROR: cert block not found in $YAML_PATH"; return 1
	fi

	chmod 600 "$SSL_KEY_PATH" || true
	chmod 644 "$SSL_CERT_PATH" || true
	if [[ $(id -u) -eq 0 ]]; then
		chown root:root "$SSL_KEY_PATH" "$SSL_CERT_PATH" || true
	fi
	log "Wrote key to $SSL_KEY_PATH and cert to $SSL_CERT_PATH"
}

parse_branch_name() {
	local branch=""
	if [[ -f "$SP_SWARM_SERVICES_YAML_PATH" ]]; then
		# Read only 'branch' key (expected in sp-swarm-services.yaml)
		branch=$(awk '
			BEGIN{br=""}
			/^[[:space:]]*branch[[:space:]]*:/       { sub(/^[[:space:]]*branch[[:space:]]*:[[:space:]]*/, "", $0); br=$0; gsub(/[\r\n\t\f]+/, "", br); print br; exit }
		' "$SP_SWARM_SERVICES_YAML_PATH")
	fi

	# Trim quotes and whitespace
	branch="${branch//\"/}"
	branch="${branch//\'/}"
	branch="$(printf "%s" "$branch" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

	if [[ -z "$branch" ]]; then
		branch="${BRANCH_NAME:-main}"
		log "Branch not found in YAML; using: $branch"
	else
		log "Using branch from YAML: $branch"
	fi

	printf "%s" "$branch"
}

main() {
	# If sp-swarm-services YAML is missing, do nothing and exit 0
	if [[ ! -f "$SP_SWARM_SERVICES_YAML_PATH" ]]; then
		log "sp-swarm-services.yaml not found: $SP_SWARM_SERVICES_YAML_PATH — exiting"
		exit 0
	fi

	ensure_gatekeeper_certs_from_yaml || exit 1

	install -d "$TARGET_DIR"
	local branch
	branch="$(parse_branch_name)"

	log "Running services-downloader for $RESOURCE_NAME (branch=$branch)"
	if ! sp-services-downloader \
			--resource-name "$RESOURCE_NAME" \
			--branch-name "$branch" \
			--target-dir "$TARGET_DIR" \
			--ssl-cert-path "$SSL_CERT_PATH" \
			--ssl-key-path "$SSL_KEY_PATH" \
			--environment "$GK_ENV" \
			--unpack; then
		log "ERROR: services-downloader failed"; exit 1
	fi

	# Merge plugins into /etc (preserve structure, include dotfiles)
	local plugins_dir="$TARGET_DIR/swarm-service-pluggins"
	if [[ -d "$plugins_dir" ]]; then
		log "Merging swarm-service-pluggins into /etc"
		tar -C "$plugins_dir" -cf - . | tar -C /etc -xf -
	else
		log "No swarm-service-pluggins directory present; skipping merge"
	fi

	# Restart swarm one-shot services runner to pick up changes
	if command -v systemctl >/dev/null 2>&1; then
		log "Reloading systemd daemon"
		systemctl daemon-reload || true
		log "Restarting swarm-services.service"
		if ! systemctl restart swarm-services.service; then
			log "ERROR: failed to restart swarm-services.service"; exit 1
		fi
	else
		log "systemctl not available; skipping restart"
	fi

	# Mark as completed to stop future retries via timer
	mkdir -p "$TARGET_DIR"
	touch "$TARGET_DIR/.downloaded"
	log "Marked as completed: $TARGET_DIR/.downloaded"

	log "Done"
}

main "$@"
