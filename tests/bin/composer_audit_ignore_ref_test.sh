#!/bin/bash

# Verifies that add_composer_audit_ignore_config() fetches
# configure_composer_audit_ignores.sh from the ref given by CI_SCRIPTS_REF,
# defaulting to `main` when the variable is unset.

set -o errexit
set -o nounset
set -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT=${ROOT_DIR}/bin/_common/composer_audit_ignore.sh
TEST_DIR=$(mktemp -d)
CURL_URLS_OUTPUT=${TEST_DIR}/curl-urls
export CURL_URLS_OUTPUT

cleanup() {
    rm -rf "$TEST_DIR"
    return 0
}
trap cleanup EXIT

# Fake `docker`: emulate `docker exec [-e VAR]... <container> bash -c <script>`
# by running the heredoc body locally. Env vars forwarded via -e are already
# inherited from this process, which is exactly the value CI_SCRIPTS_REF holds.
cat > "${TEST_DIR}/docker" <<'EOF'
#!/bin/bash
while [ "$#" -gt 0 ] && [ "$1" != "bash" ]; do
    shift
done
# now: $1=bash $2=-c $3=<script>
shift 2
# Neutralise the container-only `cd /var/www`; irrelevant to the URL under test.
exec bash -c "cd() { return 0; }; $1"
EOF
chmod +x "${TEST_DIR}/docker"

# Fake `curl`: record the requested URL and drop a no-op script at --output
# so the caller's subsequent `bash "$script"` succeeds.
cat > "${TEST_DIR}/curl" <<'EOF'
#!/bin/bash
url=""
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\n' "$url" >> "$CURL_URLS_OUTPUT"
if [ -n "$out" ]; then
    printf '#!/bin/bash\n' > "$out"
fi
EOF
chmod +x "${TEST_DIR}/curl"

run_with_ref() {
    : > "$CURL_URLS_OUTPUT"
    (
        PATH="${TEST_DIR}:${PATH}"
        if [[ "$#" -eq 1 ]]; then
            export CI_SCRIPTS_REF="$1"
        else
            unset CI_SCRIPTS_REF
        fi
        # shellcheck disable=SC1090
        source "$SCRIPT"
        add_composer_audit_ignore_config
    )
    return 0
}

assert_url_contains() {
    local needle=$1
    if ! grep -qF "$needle" "$CURL_URLS_OUTPUT"; then
        echo "Expected fetched URL to contain '${needle}', got:" >&2
        cat "$CURL_URLS_OUTPUT" >&2
        exit 1
    fi
    return 0
}

# Explicit ref is honoured.
run_with_ref "my-feature-branch"
assert_url_contains "/ci-scripts/my-feature-branch/bin/_common/configure_composer_audit_ignores.sh"

# Unset ref falls back to main.
run_with_ref
assert_url_contains "/ci-scripts/main/bin/_common/configure_composer_audit_ignores.sh"

echo "composer_audit_ignore_ref_test.sh: OK"
