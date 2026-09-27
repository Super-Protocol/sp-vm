#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Launch and manage a Super Protocol Swarm cluster of sp-vm confidential VMs on
Azure. Every VM is created by run_custom_conf_vm.sh; this script orders the
launches, renders each node's provider_config and waits for the cluster to
accept each node before starting the next one.

Usage:
  cluster.sh up     --spec <cluster.yaml> [options]
  cluster.sh add    --cluster <name> [--node 'key=value,...']... [options]
  cluster.sh status --cluster <name>
  cluster.sh delete --cluster <name> [--yes]

up — start a cluster from a specification (see cluster.example.yaml):
  --spec <file>             Cluster specification, at least 3 nodes, bootstrap first
  --release <tag>           Overrides `release` of the specification
  --provider-config <dir>   Overrides `provider_config` of the specification
  --wait-ui                 After the last node, wait for the cluster web UI
  --ui-timeout <seconds>    Default: 1800
  Running `up` again with the same specification continues an interrupted start.

add — add nodes to a running cluster, one after another:
  --cluster <name>
  --node 'size=...,location=...,zone=...,state_disk_size=...'
                            Fields not given come from the cluster defaults;
                            --node '' is a node made of defaults. Repeatable;
                            without --node one node of defaults is added.
  --release <tag>           Default: the cluster's release
  --provider-config <dir>   Default: the template the cluster was started with
  --spec <file>             Where to take defaults, template and release from
                            when the local cluster state is missing

Common:
  --node-timeout <seconds>  How long a node may take to boot and join; default 1800
  --skip-registry           Do not wait for mrEnclave in the trusted registry

Release builds (build-<N>-release): each node's mrEnclave must be in the trusted
registry (github.com/Super-Protocol/sp-vm, signatures/) before the next node is
started. The script prints the value and waits, without a timeout, until it
appears. Debug builds skip this.

Node names are generated: <cluster>-node-<N>-<4 random chars>. The same name is
the Azure VM name and the node name inside the Swarm; the VM lives in resource
group sp-vm-<name>, tagged with sp-cluster=<cluster>.

Local state (defaults, template path, CA bundle, rendered configs) lives in
$SP_VM_CLUSTER_STATE/<cluster>, default ~/.sp-vm/azure-clusters/<cluster>.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="${SCRIPT_DIR}/run_custom_conf_vm.sh"
CONFIG_TOOL="${SCRIPT_DIR}/cluster_config.py"
STATE_ROOT="${SP_VM_CLUSTER_STATE:-${HOME}/.sp-vm/azure-clusters}"
REGISTRY_URL="https://raw.githubusercontent.com/Super-Protocol/sp-vm/main/signatures"

GOSSIP_PORT=7946
PKI_PORT=9443
MEASURE_PORT=9180
POLL_SECONDS=20
REGISTRY_POLL_SECONDS=30

NODE_TIMEOUT=1800
UI_TIMEOUT=1800
SKIP_REGISTRY=0

CLUSTER=""
STATE_DIR=""
RELEASE=""
TEMPLATE=""
SWARM_DOMAIN_OVERRIDE=""
PKI_DOMAIN_OVERRIDE=""
RELEASE_MODE=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

trap 'echo >&2; log "Interrupted. Run the same command again to continue from here."; exit 130' INT

### Azure ######################################################################

# One line per resource group of the cluster, ordered by node index:
#   <group> <node name> <index> <role> <release>
cluster_groups() {
  az group list --tag "sp-cluster=${CLUSTER}" -o json | jq -r '
    [.[] | select(.properties.provisioningState != "Deleting")]
    | sort_by(.tags["sp-index"] | tonumber? // 0)
    | .[]
    | [.name, .tags["sp-node"], .tags["sp-index"], .tags["sp-role"], .tags["sp-release"]]
    | @tsv'
}

node_ip() {
  az vm show -d -g "sp-vm-$1" -n "$1" --query publicIps -o tsv 2>/dev/null || true
}

vm_exists() {
  az vm show -g "sp-vm-$1" -n "$1" >/dev/null 2>&1
}

# <cluster>-node-<index>-<4 random chars>, not taken by any resource group.
new_node_name() {
  local index="$1" suffix name
  while :; do
    # head exits first, so nothing in the pipeline dies of SIGPIPE.
    suffix="$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | cut -c1-4)"
    [[ ${#suffix} -eq 4 ]] || continue
    name="${CLUSTER}-node-${index}-${suffix}"
    [[ "$(az group exists -n "sp-vm-${name}")" == "false" ]] && { echo "$name"; return; }
  done
}

next_index() {
  local max
  max="$(cluster_groups | awk -F'\t' '$3 > m {m = $3} END {print m + 0}')"
  echo $((max + 1))
}

### Node probes ################################################################

fetch_ca() {
  curl -kfsS --connect-timeout 5 --max-time 15 "https://$1:${PKI_PORT}/api/v1/pki/certs/ca" 2>/dev/null
}

# Prints "<type> <mrenclave hex>" from the Measurement API.
get_measure() {
  curl -fsS --connect-timeout 5 --max-time 90 "http://$1:${MEASURE_PORT}/api/v1/getMeasure" 2>/dev/null \
    | jq -er 'select(.type and .mrenclaveHex) | "\(.type) \(.mrenclaveHex)"' 2>/dev/null
}

gossip_open() {
  timeout 3 bash -c ">/dev/tcp/$1/${GOSSIP_PORT}" 2>/dev/null
}

ca_matches() {
  local ca
  ca="$(fetch_ca "$1")" || return 1
  [[ "$ca" == "$(cat "${STATE_DIR}/ca.pem")" ]]
}

### Trusted registry ###########################################################

# Folders searched for an evidence type, in the order the PKI searches them
# (getMrEnclaveSignature in sp-nodejs-addons attestation-common).
registry_folders() {
  case "$1" in
    tdx-azure) echo "tdx-azure tdx" ;;
    sev-snp-azure) echo "sev-snp-azure sev-snp" ;;
    tdx-google) echo "tdx-google tdx" ;;
    *) echo "$1" ;;
  esac
}

# 0 — present, 1 — absent, 2 — could not tell (network or server error).
registry_has() {
  local type="$1" hex="$2" folder channel code
  for folder in $(registry_folders "$type"); do
    for channel in latest pre-release; do
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        "${REGISTRY_URL}/${folder}/${channel}/mrenclave-${hex}.json" || true)"
      case "$code" in
        200) return 0 ;;
        404) ;;
        *) return 2 ;;
      esac
    done
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${REGISTRY_URL}/mrenclave-${hex}.sign" || true)"
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *) return 2 ;;
  esac
}

wait_registry() {
  local name="$1" role="$2" ip="$3" type="$4" hex="$5" rc started last_note
  if [[ "$RELEASE_MODE" -eq 0 ]]; then
    log "${name}: debug build, the trusted registry is not checked"
    return 0
  fi
  if [[ "$SKIP_REGISTRY" -eq 1 ]]; then
    log "${name}: --skip-registry, not checking the trusted registry"
    return 0
  fi
  rc=0; registry_has "$type" "$hex" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    log "${name}: mrEnclave is in the trusted registry"
    return 0
  fi
  cat >&2 <<EOF

================================================================================
 mrEnclave of ${name} is not in the trusted registry yet.
 The cluster will not continue until it is added.

   node:       ${name} (${role}, ${ip})
   type:       ${type}
   mrEnclave:  ${hex}
   expected:   signatures/${type}/pre-release/mrenclave-${hex}.json
               in github.com/Super-Protocol/sp-vm (main)

 Checking every ${REGISTRY_POLL_SECONDS}s. raw.githubusercontent.com caches for up to
 ~5 minutes, so a new file shows up with a delay. Ctrl-C stops; running the
 same command again resumes here.
================================================================================

EOF
  started=$SECONDS; last_note=$SECONDS
  while :; do
    sleep "$REGISTRY_POLL_SECONDS"
    rc=0; registry_has "$type" "$hex" || rc=$?
    case "$rc" in
      0) log "${name}: mrEnclave appeared in the trusted registry after $(( (SECONDS - started) / 60 )) min"; return 0 ;;
      2) log "${name}: registry not reachable, retrying" ;;
    esac
    if (( SECONDS - last_note >= 300 )); then
      log "${name}: still waiting for ${type} ${hex} in the registry ($(( (SECONDS - started) / 60 )) min)"
      last_note=$SECONDS
    fi
  done
}

record_mrenclave() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$RELEASE" >>"${STATE_DIR}/mrenclave.log"
}

### Waits ######################################################################

# Sets MEASURE_TYPE and MEASURE_HEX.
wait_measure() {
  local name="$1" ip="$2" deadline="$3" out
  log "${name}: waiting for the Measurement API on ${ip}:${MEASURE_PORT}"
  while (( SECONDS < deadline )); do
    if out="$(get_measure "$ip")"; then
      MEASURE_TYPE="${out%% *}"
      MEASURE_HEX="${out#* }"
      log "${name}: ${MEASURE_TYPE} mrEnclave ${MEASURE_HEX}"
      record_mrenclave "$name" "$MEASURE_TYPE" "$MEASURE_HEX"
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
  node_failed "$name" "$ip" "the Measurement API did not answer"
}

wait_bootstrap_pki() {
  local name="$1" ip="$2" deadline="$3" pki gossip ca last=0
  log "${name}: waiting for PKI (${PKI_PORT}) and gossip (${GOSSIP_PORT})"
  while (( SECONDS < deadline )); do
    pki=down gossip=down
    # Not `fetch_ca | grep -q`: grep quits on the first match, curl dies of
    # SIGPIPE and pipefail turns the match into a failure.
    ca="$(fetch_ca "$ip")" && [[ "$ca" == *"BEGIN CERTIFICATE"* ]] && pki=up
    gossip_open "$ip" && gossip=up
    if [[ "$pki" == up && "$gossip" == up ]]; then
      log "${name}: PKI serves the CA, gossip is open"
      return 0
    fi
    if (( SECONDS - last >= 120 )); then
      log "${name}: pki=${pki} gossip=${gossip}"
      last=$SECONDS
    fi
    sleep "$POLL_SECONDS"
  done
  node_failed "$name" "$ip" "PKI or gossip did not come up"
}

wait_joined() {
  local name="$1" ip="$2" deadline="$3" last=0
  log "${name}: waiting until it serves the cluster CA (the cluster accepted its attestation)"
  while (( SECONDS < deadline )); do
    if ca_matches "$ip"; then
      log "${name}: joined"
      return 0
    fi
    if (( SECONDS - last >= 120 )); then
      if fetch_ca "$ip" >/dev/null; then
        log "${name}: PKI answers with a different CA"
      else
        log "${name}: PKI not answering yet"
      fi
      last=$SECONDS
    fi
    sleep "$POLL_SECONDS"
  done
  node_failed "$name" "$ip" "it did not join the cluster"
}

node_failed() {
  local name="$1" ip="$2" reason="$3" measure ca
  measure="$(get_measure "$ip" || echo "no answer")"
  if ca="$(fetch_ca "$ip")"; then
    if [[ -f "${STATE_DIR}/ca.pem" && "$ca" == "$(cat "${STATE_DIR}/ca.pem")" ]]; then ca="cluster CA"; else ca="another CA"; fi
  else
    ca="no answer"
  fi
  cat >&2 <<EOF

Node ${name} failed: ${reason} within --node-timeout (${NODE_TIMEOUT}s).
  public IP:        ${ip:-none}
  Measurement API:  ${measure}
  PKI (${PKI_PORT}):       ${ca}
  gossip (${GOSSIP_PORT}):    $(gossip_open "$ip" && echo open || echo closed)
  resource group:   sp-vm-${name} (kept for inspection)
  serial console:   az serial-console connect -g sp-vm-${name} -n ${name}

Fix the cause and run the same command again to continue, or remove the node:
  ${LAUNCHER} --vm ${name} --delete
EOF
  exit 1
}

### Launch #####################################################################

# Renders the node's provider_config into the state directory; prints its
# swarm_domain. Extra arguments go to `cluster_config.py render`.
render_node() {
  local name="$1" role="$2"; shift 2
  local args=(render --template "$TEMPLATE" --out "${STATE_DIR}/nodes/${name}"
    --node-name "$name" --role "$role")
  [[ -z "$SWARM_DOMAIN_OVERRIDE" ]] || args+=(--swarm-domain "$SWARM_DOMAIN_OVERRIDE")
  [[ -z "$PKI_DOMAIN_OVERRIDE" ]] || args+=(--pki-domain "$PKI_DOMAIN_OVERRIDE")
  "$CONFIG_TOOL" "${args[@]}" "$@"
}

# launch_node <name> <index> <role> <node json>; prints the public IP.
launch_node() {
  local name="$1" index="$2" role="$3" node="$4" ip_file ip
  log "${name}: creating ($(jq -r '"\(.size), \(.location) zone \(.zone), state disk \(.state_disk_size) GB"' <<<"$node"))"
  ip_file="${STATE_DIR}/nodes/${name}.ip"
  # stdout of the launcher is only the IP (--print-ip-only); its progress on
  # stderr is shown indented.
  "$LAUNCHER" --release "$RELEASE" --vm "$name" \
    --size "$(jq -r .size <<<"$node")" \
    --location "$(jq -r .location <<<"$node")" \
    --zone "$(jq -r .zone <<<"$node")" \
    --state-disk-size "$(jq -r .state_disk_size <<<"$node")" \
    --provider-config "${STATE_DIR}/nodes/${name}" \
    --tag "sp-cluster=${CLUSTER}" --tag "sp-node=${name}" --tag "sp-index=${index}" \
    --tag "sp-role=${role}" --tag "sp-release=${RELEASE}" \
    --print-ip-only 2>&1 >"$ip_file" | sed -u 's/^/    /' >&2 \
    || die "${name}: run_custom_conf_vm.sh failed; its resource group sp-vm-${name}, if created, is kept"
  ip="$(cat "$ip_file")"
  rm -f "$ip_file"
  [[ -n "$ip" ]] || die "${name}: created without a public IP"
  log "${name}: VM up, public IP ${ip}"
  echo "$ip"
}

# Addresses of the cluster nodes that serve the cluster CA, bootstrap first.
live_peers() {
  local exclude="${1:-}" group name index role release ip
  while IFS=$'\t' read -r group name index role release; do
    [[ "$name" != "$exclude" ]] || continue
    ip="$(node_ip "$name")"
    [[ -n "$ip" ]] || continue
    ca_matches "$ip" && echo "$ip"
  done < <(cluster_groups)
}

# The domain the web UI of the cluster answers on is its swarm_domain.
dns_check() {
  local domain="$1" out code ip answer
  [[ -n "$domain" ]] || return 0
  out="$(curl -sS -o /dev/null -w '%{http_code} %{remote_ip}' --max-time 10 "https://${domain}/" 2>/dev/null || true)"
  code="${out%% *}"; ip="${out#* }"
  [[ -n "$code" && "$code" != "000" ]] || return 0
  echo >&2
  echo "Domain ${domain} is up right now (${ip}, HTTP ${code})." >&2
  echo "Another cluster seems to be running on it; both would overwrite each other's DNS records." >&2
  if [[ -t 0 ]]; then
    read -r -p "Continue? [y/N] " answer
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] && return 0
  else
    log "Not asking without a terminal"
  fi
  # Nothing is created yet: leave no state behind that a later `up` would
  # mistake for a start to continue.
  [[ -n "$(cluster_groups)" ]] || rm -rf "$STATE_DIR"
  die "Aborted: stop the other cluster or set swarm_domain/pki_domain in the specification"
}

### Nodes ######################################################################

bootstrap_node() {
  local node="$1" name="$2" ip="" domain deadline
  if [[ -n "$name" && -f "${STATE_DIR}/ca.pem" ]]; then
    ip="$(node_ip "$name")"
    if [[ -n "$ip" ]] && ca_matches "$ip"; then
      log "${name}: bootstrap is already up (${ip})"
      return 0
    fi
  fi

  if [[ -z "$name" ]]; then
    name="$(new_node_name 1)"
    domain="$(render_node "$name" bootstrap)"
    echo "$domain" >"${STATE_DIR}/swarm_domain"
    dns_check "$domain"
    ip="$(launch_node "$name" 1 bootstrap "$node")"
  elif ! vm_exists "$name"; then
    log "${name}: resource group exists but the VM does not; creating it again"
    render_node "$name" bootstrap >"${STATE_DIR}/swarm_domain"
    ip="$(launch_node "$name" 1 bootstrap "$node")"
  else
    ip="$(node_ip "$name")"
    log "${name}: continuing with the existing bootstrap VM (${ip})"
  fi

  deadline=$((SECONDS + NODE_TIMEOUT))
  wait_measure "$name" "$ip" "$deadline"
  wait_registry "$name" bootstrap "$ip" "$MEASURE_TYPE" "$MEASURE_HEX"
  wait_bootstrap_pki "$name" "$ip" "$((SECONDS + NODE_TIMEOUT))"

  fetch_ca "$ip" >"${STATE_DIR}/ca.pem.new"
  "$CONFIG_TOOL" check-ca "${STATE_DIR}/ca.pem.new"
  if [[ -f "${STATE_DIR}/ca.pem" ]] && ! cmp -s "${STATE_DIR}/ca.pem" "${STATE_DIR}/ca.pem.new"; then
    die "${name} serves a new CA, not the one in ${STATE_DIR}/ca.pem (was the bootstrap recreated?). Delete the cluster and start again."
  fi
  mv "${STATE_DIR}/ca.pem.new" "${STATE_DIR}/ca.pem"
  log "${name}: cluster CA saved to ${STATE_DIR}/ca.pem"
}

# join_node <node json> <index> <name or empty>
join_node() {
  local node="$1" index="$2" name="$3" ip="" peers=() peer_args=() peer
  if [[ -n "$name" ]]; then
    ip="$(node_ip "$name")"
    if [[ -n "$ip" ]] && ca_matches "$ip"; then
      log "${name}: already in the cluster (${ip})"
      return 0
    fi
  fi

  if [[ -z "$name" ]] || ! vm_exists "$name"; then
    mapfile -t peers < <(live_peers "$name")
    [[ ${#peers[@]} -gt 0 ]] || die "No cluster node serves the cluster CA; cannot add a node"
    for peer in "${peers[@]}"; do peer_args+=(--peer "$peer"); done
    [[ -n "$name" ]] || name="$(new_node_name "$index")"
    # `add` remembers the name before creating anything, so an interrupted add
    # finishes this node instead of starting another one.
    if [[ -n "${PENDING_FILE:-}" ]]; then
      # shellcheck disable=SC2016 # $name is a jq variable
      pending_set --arg name "$name" '.current.name = $name'
    fi
    render_node "$name" join "${peer_args[@]}" --ca "${STATE_DIR}/ca.pem" >"${STATE_DIR}/swarm_domain"
    log "${name}: joins through ${peers[*]}"
    ip="$(launch_node "$name" "$index" join "$node")"
  else
    log "${name}: continuing with the existing VM (${ip})"
  fi

  local deadline=$((SECONDS + NODE_TIMEOUT))
  wait_measure "$name" "$ip" "$deadline"
  wait_registry "$name" join "$ip" "$MEASURE_TYPE" "$MEASURE_HEX"
  wait_joined "$name" "$ip" "$((SECONDS + NODE_TIMEOUT))"
}

### UI #########################################################################

# The root page answers 200 even before the API routes exist, so the GraphQL
# endpoint the UI loads its data from is checked as well.
ui_ready() {
  local domain="$1" root api
  root="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${domain}/" || true)"
  api="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H 'content-type: application/json' --data '{"query":"{ __typename }"}' \
    "https://${domain}/graphql" || true)"
  UI_STATE="page=${root} graphql=${api}"
  [[ "$root" == 200 && "$api" == 200 ]]
}

wait_ui() {
  local domain="$1" deadline=$((SECONDS + UI_TIMEOUT)) last=0
  [[ -n "$domain" ]] || die "No swarm_domain known for this cluster; cannot wait for the UI"
  log "Waiting for the UI at https://${domain}/"
  while (( SECONDS < deadline )); do
    if ui_ready "$domain"; then
      log "UI is up: https://${domain}/"
      return 0
    fi
    if (( SECONDS - last >= 120 )); then
      log "UI not ready yet (${UI_STATE})"
      last=$SECONDS
    fi
    sleep "$POLL_SECONDS"
  done
  log "ERROR: UI did not come up within ${UI_TIMEOUT}s (${UI_STATE})"
  return 1
}

### State ######################################################################

use_cluster() {
  CLUSTER="$1"
  STATE_DIR="${STATE_ROOT}/${CLUSTER}"
}

load_settings() {
  RELEASE="$(jq -r .release "${STATE_DIR}/spec.json")"
  TEMPLATE="$(jq -r .provider_config "${STATE_DIR}/spec.json")"
  SWARM_DOMAIN_OVERRIDE="$(jq -r .swarm_domain "${STATE_DIR}/spec.json")"
  PKI_DOMAIN_OVERRIDE="$(jq -r .pki_domain "${STATE_DIR}/spec.json")"
}

set_release_mode() {
  [[ "$RELEASE" =~ ^build-[0-9]+-(debug|release)$ ]] \
    || die "Release tag must be build-<N>-debug or build-<N>-release, got '${RELEASE}'"
  RELEASE_MODE=0
  [[ "${BASH_REMATCH[1]}" == release ]] && RELEASE_MODE=1
  return 0
}

### Commands ###################################################################

cmd_up() {
  local spec="" release="" template="" wait_ui_flag=0 spec_json groups count i index node name
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --spec) spec="$2"; shift 2 ;;
      --release) release="$2"; shift 2 ;;
      --provider-config) template="$2"; shift 2 ;;
      --wait-ui) wait_ui_flag=1; shift ;;
      --ui-timeout) UI_TIMEOUT="$2"; shift 2 ;;
      --node-timeout) NODE_TIMEOUT="$2"; shift 2 ;;
      --skip-registry) SKIP_REGISTRY=1; shift ;;
      *) die "up: unknown argument $1 (see --help)" ;;
    esac
  done
  [[ -n "$spec" ]] || die "up: --spec is required"

  local tool_args=(spec "$spec")
  [[ -z "$release" ]] || tool_args+=(--release "$release")
  [[ -z "$template" ]] || tool_args+=(--provider-config "$template")
  spec_json="$("$CONFIG_TOOL" "${tool_args[@]}")"
  use_cluster "$(jq -r .name <<<"$spec_json")"

  groups="$(cluster_groups)"
  if [[ -f "${STATE_DIR}/spec.json" ]]; then
    if [[ "$(jq -S 'del(.added)' "${STATE_DIR}/spec.json")" != "$(jq -S . <<<"$spec_json")" ]]; then
      die "Cluster ${CLUSTER} was started from a different specification (${STATE_DIR}/spec.json). Use add to grow it, or delete it first."
    fi
    log "Continuing cluster ${CLUSTER} (state in ${STATE_DIR})"
  else
    [[ -z "$groups" ]] || die "Cluster ${CLUSTER} already exists in Azure but has no local state here. Use status/add --spec/delete, or pick another name."
    mkdir -p "${STATE_DIR}/nodes"
    chmod 700 "$STATE_ROOT" "$STATE_DIR" 2>/dev/null || true
    jq . <<<"$spec_json" >"${STATE_DIR}/spec.json"
  fi
  load_settings
  set_release_mode
  [[ -d "$TEMPLATE" ]] || die "provider_config template not found: ${TEMPLATE}"

  count="$(jq '.nodes | length' <<<"$spec_json")"
  log "Cluster ${CLUSTER}: ${count} nodes, ${RELEASE} ($([[ $RELEASE_MODE -eq 1 ]] && echo "release, trusted registry enforced" || echo debug))"

  for ((i = 0; i < count; i++)); do
    index=$((i + 1))
    node="$(jq -c ".nodes[$i]" <<<"$spec_json")"
    name="$(cluster_groups | awk -F'\t' -v idx="$index" '$3 == idx {print $2; exit}')"
    if [[ "$index" -eq 1 ]]; then
      bootstrap_node "$node" "$name"
    else
      [[ -f "${STATE_DIR}/ca.pem" ]] || die "No cluster CA; the bootstrap node did not finish"
      PENDING_FILE="" join_node "$node" "$index" "$name"
    fi
  done

  local ui_ok=0
  if [[ "$wait_ui_flag" -eq 1 ]]; then
    wait_ui "$(cat "${STATE_DIR}/swarm_domain" 2>/dev/null || true)" || ui_ok=1
  fi
  log "All ${count} nodes of ${CLUSTER} are in the cluster"
  status_table
  return "$ui_ok"
}

cmd_add() {
  local nodes=() release="" template="" spec="" groups defaults_file spec_json cluster_release node ref_ip
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster) use_cluster "$2"; shift 2 ;;
      --node) nodes+=("$2"); shift 2 ;;
      --release) release="$2"; shift 2 ;;
      --provider-config) template="$2"; shift 2 ;;
      --spec) spec="$2"; shift 2 ;;
      --node-timeout) NODE_TIMEOUT="$2"; shift 2 ;;
      --skip-registry) SKIP_REGISTRY=1; shift ;;
      *) die "add: unknown argument $1 (see --help)" ;;
    esac
  done
  [[ -n "$CLUSTER" ]] || die "add: --cluster is required"
  [[ ${#nodes[@]} -gt 0 ]] || nodes=("")

  groups="$(cluster_groups)"
  grep -q $'\tbootstrap\t' <<<"$groups" || die "Cluster ${CLUSTER} not found (no resource group tagged sp-cluster=${CLUSTER}, sp-role=bootstrap)"
  cluster_release="$(awk -F'\t' '$4 == "bootstrap" {print $5; exit}' <<<"$groups")"

  mkdir -p "${STATE_DIR}/nodes"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  if [[ ! -f "${STATE_DIR}/spec.json" ]]; then
    if [[ -n "$spec" ]]; then
      spec_json="$("$CONFIG_TOOL" spec "$spec")"
      [[ "$(jq -r .name <<<"$spec_json")" == "$CLUSTER" ]] || die "--spec describes cluster $(jq -r .name <<<"$spec_json"), not ${CLUSTER}"
    else
      [[ -n "$template" && -n "$release$cluster_release" ]] \
        || die "No local state for ${CLUSTER}: pass --spec <file>, or --provider-config (and --release)"
      log "WARNING: no local state and no --spec: node fields must be complete, swarm_domain/pki_domain come from the template as is"
      spec_json="$(jq -n --arg t "$(cd "$template" && pwd)" --arg r "${release:-$cluster_release}" \
        '{name: "", release: $r, provider_config: $t, defaults: {}, nodes: [], swarm_domain: "", pki_domain: ""}')"
      spec_json="$(jq --arg n "$CLUSTER" '.name = $n' <<<"$spec_json")"
    fi
    jq . <<<"$spec_json" >"${STATE_DIR}/spec.json"
  fi
  load_settings
  [[ -z "$release" ]] || RELEASE="$release"
  [[ -z "$template" ]] || TEMPLATE="$(cd "$template" && pwd)"
  [[ -d "$TEMPLATE" ]] || die "provider_config template not found: ${TEMPLATE}"
  set_release_mode
  [[ "$RELEASE" == "$cluster_release" ]] \
    || log "WARNING: the cluster runs ${cluster_release}, the new node gets ${RELEASE}"

  # The cluster CA: saved locally, or taken from the bootstrap (any node if
  # the bootstrap is gone).
  if [[ ! -f "${STATE_DIR}/ca.pem" ]]; then
    local group nname ip
    while IFS=$'\t' read -r group nname _; do
      ip="$(node_ip "$nname")"
      [[ -n "$ip" ]] && fetch_ca "$ip" >"${STATE_DIR}/ca.pem.new" && { ref_ip="$ip"; break; }
    done <<<"$groups"
    [[ -n "${ref_ip:-}" ]] || die "No node of ${CLUSTER} serves a CA"
    "$CONFIG_TOOL" check-ca "${STATE_DIR}/ca.pem.new"
    mv "${STATE_DIR}/ca.pem.new" "${STATE_DIR}/ca.pem"
    log "Cluster CA taken from ${ref_ip}"
  fi
  check_members "$groups"

  defaults_file="${STATE_DIR}/defaults.json"
  jq .defaults "${STATE_DIR}/spec.json" >"$defaults_file"

  # pending.json is the queue of this add: the node being added (`current`,
  # with its name once chosen) and those not started yet. An interrupted add
  # leaves it behind, and the next add works it off instead of starting over.
  PENDING_FILE="${STATE_DIR}/pending.json"
  if [[ -f "$PENDING_FILE" ]]; then
    log "Continuing the add that was interrupted ($(jq '(.current != null | if . then 1 else 0 end) + (.queue | length)' "$PENDING_FILE") node(s) left); --node arguments of this call are ignored"
    RELEASE="$(jq -r .release "$PENDING_FILE")"
    set_release_mode
  else
    local queue="[]"
    for node in "${nodes[@]}"; do
      queue="$(jq -c --argjson n "$("$CONFIG_TOOL" node "$defaults_file" "$node")" '. + [$n]' <<<"$queue")"
    done
    jq -n --argjson queue "$queue" --arg release "$RELEASE" \
      '{release: $release, current: null, queue: $queue}' >"$PENDING_FILE"
  fi

  while [[ "$(jq '.current != null or (.queue | length > 0)' "$PENDING_FILE")" == true ]]; do
    if [[ "$(jq '.current == null' "$PENDING_FILE")" == true ]]; then
      # shellcheck disable=SC2016 # $index is a jq variable
      pending_set --argjson index "$(next_index)" \
        '.current = {node: .queue[0], index: $index, name: ""} | .queue = .queue[1:]'
    fi
    add_one
  done
  rm -f "$PENDING_FILE"
  status_table
}

pending_set() {
  jq "$@" "$PENDING_FILE" >"${PENDING_FILE}.tmp"
  mv "${PENDING_FILE}.tmp" "$PENDING_FILE"
}

# Adds pending.current to the cluster, records it and clears it.
add_one() {
  local current
  current="$(jq -c .current "$PENDING_FILE")"
  join_node "$(jq -c .node <<<"$current")" "$(jq -r .index <<<"$current")" "$(jq -r .name <<<"$current")"
  current="$(jq -c --arg release "$RELEASE" '.current + {release: $release}' "$PENDING_FILE")"
  jq --argjson entry "$current" '.added = ((.added // []) + [$entry])' \
    "${STATE_DIR}/spec.json" >"${STATE_DIR}/spec.json.tmp"
  mv "${STATE_DIR}/spec.json.tmp" "${STATE_DIR}/spec.json"
  pending_set '.current = null'
}

# Every node that answers must serve the cluster CA; one with another CA means
# the resource groups mix two clusters.
check_members() {
  local groups="$1" group name index role release ip live=0 ca
  while IFS=$'\t' read -r group name index role release; do
    ip="$(node_ip "$name")"
    [[ -n "$ip" ]] || continue
    ca="$(fetch_ca "$ip")" || continue
    [[ "$ca" == "$(cat "${STATE_DIR}/ca.pem")" ]] \
      || die "${name} (${ip}) serves a different CA than ${STATE_DIR}/ca.pem; refusing to add nodes"
    live=$((live + 1))
  done <<<"$groups"
  [[ "$live" -gt 0 ]] || die "No node of ${CLUSTER} answers on ${PKI_PORT}"
  log "${live} node(s) of ${CLUSTER} serve the cluster CA"
}

status_table() {
  local groups group name index role release info ip size location zone measure type hex reg ca domain
  groups="$(cluster_groups)"
  [[ -n "$groups" ]] || { log "Cluster ${CLUSTER}: no resource groups"; return 0; }
  echo
  printf '%-28s %-9s %-20s %-14s %-15s %-13s %-17s %-8s %s\n' \
    NODE ROLE SIZE LOCATION IP TEE MRENCLAVE REGISTRY CA
  while IFS=$'\t' read -r group name index role release; do
    info="$(az vm show -d -g "$group" -n "$name" \
      --query '[hardwareProfile.vmSize, location, zones[0], publicIps]' -o tsv 2>/dev/null | tr '\n' '\t' || true)"
    IFS=$'\t' read -r size location zone ip <<<"$info"
    type="-" hex="-" reg="-" ca="-"
    if [[ -n "${ip:-}" ]]; then
      if measure="$(get_measure "$ip")"; then
        type="${measure%% *}"; hex="${measure#* }"
        if [[ "$release" == *-release ]]; then
          if registry_has "$type" "$hex"; then reg=yes; else reg=no; fi
        else
          reg=debug
        fi
      fi
      if [[ -f "${STATE_DIR}/ca.pem" ]]; then
        if ca_matches "$ip"; then ca=ok; elif fetch_ca "$ip" >/dev/null; then ca=other; else ca=down; fi
      elif fetch_ca "$ip" >/dev/null; then
        ca=up
      else
        ca=down
      fi
    fi
    printf '%-28s %-9s %-20s %-14s %-15s %-13s %-17s %-8s %s\n' \
      "$name" "$role" "${size:--}" "${location:--}/${zone:--}" "${ip:--}" "$type" "${hex:0:16}" "$reg" "$ca"
  done <<<"$groups"

  domain="$(cat "${STATE_DIR}/swarm_domain" 2>/dev/null || true)"
  echo
  if [[ -n "$domain" ]]; then
    if ui_ready "$domain"; then
      echo "UI: https://${domain}/ is up"
    else
      echo "UI: https://${domain}/ not ready (${UI_STATE})"
    fi
  else
    echo "UI: domain unknown (no local state for ${CLUSTER})"
  fi
}

cmd_status() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster) use_cluster "$2"; shift 2 ;;
      *) die "status: unknown argument $1 (see --help)" ;;
    esac
  done
  [[ -n "$CLUSTER" ]] || die "status: --cluster is required"
  status_table
}

cmd_delete() {
  local yes=0 groups group name index role release answer pids=() failed=0 pid
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster) use_cluster "$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) die "delete: unknown argument $1 (see --help)" ;;
    esac
  done
  [[ -n "$CLUSTER" ]] || die "delete: --cluster is required"

  groups="$(cluster_groups)"
  if [[ -z "$groups" ]]; then
    log "Cluster ${CLUSTER} has no resource groups"
  else
    echo "Deleting cluster ${CLUSTER}: every resource group below with everything in it" >&2
    cut -f1,2,4 <<<"$groups" | sed 's/^/  /' >&2
    if [[ "$yes" -eq 0 ]]; then
      [[ -t 0 ]] || die "Not asking without a terminal; pass --yes"
      read -r -p "Delete? [y/N] " answer
      [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || die "Aborted"
    fi
    while IFS=$'\t' read -r group name index role release; do
      "$LAUNCHER" --vm "$name" --vm-resource-group "$group" --delete 2>&1 | sed -u "s/^/  [${name}] /" >&2 &
      pids+=($!)
    done <<<"$groups"
    for pid in "${pids[@]}"; do wait "$pid" || failed=$((failed + 1)); done
    groups="$(cluster_groups)"
    [[ -z "$groups" && "$failed" -eq 0 ]] || die "Some resource groups are still there: $(cut -f1 <<<"$groups" | tr '\n' ' ')"
    log "All resource groups of ${CLUSTER} are deleted"
  fi
  if [[ -d "$STATE_DIR" ]]; then
    rm -rf "$STATE_DIR"
    log "Local state ${STATE_DIR} removed"
  fi
}

### Main #######################################################################

[[ $# -gt 0 ]] || { usage; exit 1; }
command="$1"; shift
case "$command" in
  -h|--help|help) usage; exit 0 ;;
esac

need_cmd az
need_cmd jq
need_cmd curl
need_cmd python3
az account show >/dev/null 2>&1 || die "Not logged in to Azure (run: az login)"

case "$command" in
  up) cmd_up "$@" ;;
  add) cmd_add "$@" ;;
  status) cmd_status "$@" ;;
  delete) cmd_delete "$@" ;;
  *) die "Unknown command: ${command} (see --help)" ;;
esac
