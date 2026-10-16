#!/usr/bin/env bash

# provider-config.sh runs on every boot, because the state disk — and with it
# /sp — is wiped and re-encrypted each time. Everything here is about what
# happens when the archive it has to re-download is no longer there (SUP-343):
# the node boots blank, and the only way an operator learns why is this script's
# log, so the "gone for good" case must be distinguishable from a flaky network.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
if [[ -n "${SP_PROVIDER_CONFIG_TEST_INSTALLED_ROOT:-}" ]]; then
    under_test="$SP_PROVIDER_CONFIG_TEST_INSTALLED_ROOT/usr/local/bin/provider-config.sh"
else
    under_test="$repository_root/src/rootfs/files/configs/usr/local/bin/provider-config.sh"
fi
[[ -x "$under_test" || -r "$under_test" ]] || { echo "FAIL: not found: $under_test" >&2; exit 1; }

test_root="$(mktemp -d -t sp-provider-config.XXXXXXXX)"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

AZURE_CHASSIS_ASSET_TAG="7783-7084-3265-9085-8269-3286-77"

# A provider_config archive shaped like the real one: its root becomes /sp.
payload="$test_root/payload.tar.gz"
mkdir -p "$test_root/src/swarm"
printf 'swarm_domain: test.example\n' > "$test_root/src/swarm/config.yaml"
printf 'ssh-ed25519 AAAA test\n' > "$test_root/src/authorized_keys"
tar -czf "$payload" -C "$test_root/src" .
payload_sha256="$(sha256sum "$payload" | awk '{print $1}')"

# A curl stub standing in for both IMDS and blob storage. The userData answer is
# always valid; SP_TEST_BLOB_CODE decides what the archive download does.
make_curl_stub() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
url=""
out=""
write_out=""
head_only=0
prev=""
for arg in "$@"; do
    case "$prev" in
        -o) out="$arg" ;;
        -w|--write-out) write_out="$arg" ;;
    esac
    case "$arg" in
        -I|--head) head_only=1 ;;
        http://*|https://*) url="$arg" ;;
    esac
    prev="$arg"
done

emit_code() {
    [[ -z "$write_out" ]] || printf '%s' "${write_out//'%{http_code}'/$1}"
}

case "$url" in
    *userData*)
        printf '%s' "$SP_TEST_USER_DATA"
        exit 0
        ;;
    *azEnvironment*|*computeMetadata*)
        exit 1
        ;;
    *blob.core.windows.net*)
        if [[ "$SP_TEST_BLOB_CODE" == "200" ]]; then
            [[ "$head_only" -eq 1 || -z "$out" ]] || cp "$SP_TEST_BLOB_FILE" "$out"
            emit_code 200
            exit 0
        fi
        # curl without -f writes the error body and still exits 0.
        [[ -z "$out" ]] || : > "$out"
        emit_code "$SP_TEST_BLOB_CODE"
        exit 0
        ;;
esac
exit 1
STUB
    chmod +x "$bin_dir/curl"
}

# One run of provider-config.sh with /sp, DMI and curl all faked.
run_case() {
    local name="$1" blob_code="$2" sp_dir="$3" log_file="$4"
    local case_root="$test_root/$name"
    mkdir -p "$case_root/dmi" "$case_root/bin"
    printf '%s\n' "$AZURE_CHASSIS_ASSET_TAG" > "$case_root/dmi/chassis_asset_tag"
    printf 'Microsoft Corporation\n' > "$case_root/dmi/sys_vendor"
    make_curl_stub "$case_root/bin"
    # On a node this script runs as root; the test does not, and chown is not
    # what is under test here.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$case_root/bin/chown"
    chmod +x "$case_root/bin/chown"

    local descriptor
    descriptor="$(printf '{"provider_config":{"url":"https://acct.blob.core.windows.net/provider-config/a.tar.gz?sig=x","sha256":"%s"}}' "$payload_sha256")"

    set +e
    PATH="$case_root/bin:$PATH" \
    SP_TEST_USER_DATA="$(printf '%s' "$descriptor" | base64 -w0)" \
    SP_TEST_BLOB_CODE="$blob_code" \
    SP_TEST_BLOB_FILE="$payload" \
    SP_PROVIDER_CONFIG_SP_DIR="$sp_dir" \
    SP_PROVIDER_CONFIG_PASSWD_FILE="$case_root/passwd-s3fs" \
    SP_PROVIDER_CONFIG_DMI_DIR="$case_root/dmi" \
    SP_PROVIDER_CONFIG_STAGE_ROOT="$case_root" \
        bash "$under_test" start >"$log_file" 2>&1
    local status=$?
    set -e
    return "$status"
}

### 1. The archive is gone: the node is blank for good, and says so ############

sp_dir="$test_root/sp-404"
log="$test_root/log-404"
if run_case gone 404 "$sp_dir" "$log"; then
    fail "a 404 archive must make provider-config.sh exit non-zero"
fi
grep -q 'UNRECOVERABLE' "$log" \
    || fail "a 404 must be reported as unrecoverable, got: $(cat "$log")"
grep -q 'refresh-provider-config' "$log" \
    || fail "the unrecoverable message must name the way out (--refresh-provider-config)"
[[ -z "$(ls -A "$sp_dir" 2>/dev/null)" ]] \
    || fail "nothing may be written to ${sp_dir} when the download failed"

### 2. An expired SAS is the same dead end #####################################

log="$test_root/log-403"
if run_case expired 403 "$test_root/sp-403" "$log"; then
    fail "a 403 archive must make provider-config.sh exit non-zero"
fi
grep -q 'UNRECOVERABLE' "$log" \
    || fail "a 403 (expired SAS) must be reported as unrecoverable, got: $(cat "$log")"

### 3. A server error is transient and must NOT claim to be unrecoverable ######

log="$test_root/log-503"
if run_case transient 503 "$test_root/sp-503" "$log"; then
    fail "a 503 archive must make provider-config.sh exit non-zero"
fi
grep -q 'UNRECOVERABLE' "$log" \
    && fail "a 503 is retryable and must not be reported as unrecoverable"
grep -q '503' "$log" \
    || fail "the transient message must carry the HTTP status, got: $(cat "$log")"

### 4. The happy path still populates /sp ######################################

sp_dir="$test_root/sp-200"
log="$test_root/log-200"
run_case ok 200 "$sp_dir" "$log" \
    || fail "a reachable archive must succeed, got: $(cat "$log")"
[[ -f "$sp_dir/swarm/config.yaml" ]] \
    || fail "swarm/config.yaml must land in ${sp_dir}"
[[ -f "$sp_dir/authorized_keys" ]] \
    || fail "authorized_keys must land in ${sp_dir} (debug images need it for SSH)"
[[ "$(stat -c '%a' "$sp_dir/authorized_keys")" == "400" ]] \
    || fail "authorized_keys must be 0400 for sshd StrictModes"

### 5. A /sp that is already populated short-circuits ##########################

log="$test_root/log-idempotent"
run_case idempotent 404 "$sp_dir" "$log" \
    || fail "a populated ${sp_dir} must short-circuit even with an unreachable archive"
grep -q 'nothing to do' "$log" \
    || fail "the short-circuit must be logged, got: $(cat "$log")"

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
