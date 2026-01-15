#!/bin/bash
set -euo pipefail

# Download and stage Swarm service pack into /etc/sp-swarm-services.
# - If /sp/swarm/gatekeeper-keys.yaml exists, extract TLS key/cert to
#   /etc/super/certs/gatekeeper.key and /etc/super/certs/gatekeeper.crt
# - Read BRANCH from sp-swarm-services.yaml (fallback to $BRANCH_NAME or "main")
# - Invoke Node CLI to fetch resource "sp-swarm-services" and --unpack
# - Merge content of /etc/sp-swarm-services/swarm-service-pluggins/ into /etc

YAML_PATH="${YAML_PATH:-/sp/swarm/gatekeeper-keys.yaml}" # for cert extraction
SP_SWARM_SERVICES_YAML_PATH="${SP_SWARM_SERVICES_YAML_PATH:-/sp/swarm/sp-swarm-services.yaml}"
SSL_CERT_PATH="${SSL_CERT_PATH:-/etc/super/certs/gatekeeper.crt}"
SSL_KEY_PATH="${SSL_KEY_PATH:-/etc/super/certs/gatekeeper.key}"
GK_ENV="${GATEKEEPER_ENV:-mainnet}"
TARGET_DIR="${TARGET_DIR:-/etc/sp-swarm-services}"
RESOURCE_NAME="sp-swarm-services"

log() {
	printf "[download-sp-swarm-services] %s\n" "$*" >&2;
}

# Helpers: YAML block extraction and PEM normalization
list_top_keys() {
		awk 'BEGIN{FS":"} /^[A-Za-z0-9_.-]+:[[:space:]]*/{print $1}' "$YAML_PATH" | sort -u || true
}

extract_block_from_yaml() {
		# $1: key name (e.g., key, cert)
		local keyname="$1"
		local awk_program
		read -r -d '' awk_program <<'AWK'
function ltrim(s){ sub(/^\r?/, "", s); return s }
BEGIN{ inblk=0; found=0 }
{
	sub("\r$", "", $0)
	if (inblk==0 && $0 ~ "^" KEY "[[:space:]]*:") {
		idx = index($0, ":")
		rest = substr($0, idx+1)
		gsub(/^[[:space:]]+/, "", rest)
		if (rest ~ /^\|[+-]?([[:space:]]*)?$/ || rest ~ /^$/) {
			inblk=1; found=1; next
		} else {
			inline=rest
			gsub(/[[:space:]]+$/, "", inline)
			if (inline ~ /^".*"$/ || inline ~ /^'.*'$/) { inline=substr(inline,2,length(inline)-2); gsub(/\\n/, "\n", inline) }
			print inline; exit
		}
	} else if (inblk==1) {
		if ($0 ~ /^[A-Za-z0-9_.-]+:[[:space:]]*/) { exit }
		print $0
	}
}
END { }
AWK
		awk -v KEY="$keyname" "$awk_program" "$YAML_PATH"
}

deindent_block() {
		awk '
			{ sub("\r$", "", $0); line=$0; match(line, /^[[:space:]]*/); ind=RLENGTH; if (min=="" || ind<min) min=ind; lines[NR]=line }
			END { if (min=="") min=0; for (i=1;i<=NR;i++) { if (min>0) print substr(lines[i], min+1); else print lines[i] } }
		'
}

trim_to_pem() {
		awk '
			BEGIN{begin=0}
			{ sub("\r$", "", $0); if (begin==0) { if ($0 ~ /^-----BEGIN[[:space:]]/) { begin=1; print $0 } } else { print $0 } }
		' | awk 'NF>0'
}


## TODO: temporary solution. Need to use subroot cert and key
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

	# Extract raw content for key and cert from YAML (supports block scalar and inline)
	local key_content cert_content
	key_content="$(extract_block_from_yaml key || true)"
	cert_content="$(extract_block_from_yaml cert || true)"

	if [[ -z "${key_content//[[:space:]]/}" ]]; then
		log "ERROR: key block not found in $YAML_PATH";
		log "Top-level keys: $(list_top_keys | tr '\n' ' ')";
		return 1
	fi
	if [[ -z "${cert_content//[[:space:]]/}" ]]; then
		log "ERROR: cert block not found in $YAML_PATH";
		log "Top-level keys: $(list_top_keys | tr '\n' ' ')";
		return 1
	fi

	# Normalize: deindent and trim strictly to PEM BEGIN..END
	printf "%s\n" "$key_content" | deindent_block | trim_to_pem > "$SSL_KEY_PATH"
	printf "%s\n" "$cert_content" | deindent_block | trim_to_pem > "$SSL_CERT_PATH"

	# Sanity checks
	if ! grep -q "^-----BEGIN PRIVATE KEY" "$SSL_KEY_PATH"; then
		log "ERROR: key PEM header not found after extraction"; return 1
	fi
	if ! grep -q "^-----BEGIN CERTIFICATE" "$SSL_CERT_PATH"; then
		log "ERROR: cert PEM header not found after extraction"; return 1
	fi

	# Optional openssl validation
	if command -v openssl >/dev/null 2>&1; then
		if ! openssl pkey -in "$SSL_KEY_PATH" -noout >/dev/null 2>&1; then
			log "ERROR: openssl failed to parse key: $SSL_KEY_PATH"; return 1
		fi
		if ! openssl x509 -in "$SSL_CERT_PATH" -noout >/dev/null 2>&1; then
			log "ERROR: openssl failed to parse cert: $SSL_CERT_PATH"; return 1
		fi
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

	log "Running Node services-downloader for $RESOURCE_NAME (branch=$branch)"
	if ! /usr/bin/env node /usr/local/lib/services-downloader/src/index.js \
			--resource-name "$RESOURCE_NAME" \
			--branch-name "$branch" \
			--ssl-cert-path "$SSL_CERT_PATH" \
			--ssl-key-path "$SSL_KEY_PATH" \
			--environment "$GK_ENV" \
			--unpack-with-absolute-path; then
		log "ERROR: services-downloader failed"; exit 1
	fi

	# Mark as completed to stop future retries
	mkdir -p "$TARGET_DIR"
	touch "$TARGET_DIR/.downloaded"
	log "Marked as completed: $TARGET_DIR/.downloaded"

	log "Done"
}

main "$@"
