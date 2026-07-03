#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT=${ROOT_DIR}/bin/_common/configure_composer_audit_ignores.sh
TEST_DIR=$(mktemp -d)
OUTPUT=${TEST_DIR}/composer-calls

cleanup() {
    rm -rf "$TEST_DIR"
    return 0
}
trap cleanup EXIT

cat > "${TEST_DIR}/composer" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$COMPOSER_CALLS_OUTPUT"
if [ "${COMPOSER_FAILURE:-0}" = "1" ]; then
    exit 1
fi
EOF
chmod +x "${TEST_DIR}/composer"

run_for_version() {
    local version=$1
    : > "$OUTPUT"
    COMPOSER_CALLS_OUTPUT=$OUTPUT PATH="${TEST_DIR}:${PATH}" bash "$SCRIPT" "$version"
    return 0
}

assert_line_count() {
    local expected=$1
    local actual
    actual=$(wc -l < "$OUTPUT")

    if [[ "$actual" -ne "$expected" ]]; then
        echo "Expected ${expected} Composer calls, got ${actual}" >&2
        exit 1
    fi
    return 0
}

run_for_version 7.3
assert_line_count 25
! grep -q PKSA-xwpn-zs9j-6wy5 "$OUTPUT"

run_for_version 7.4.33
assert_line_count 28
grep -q PKSA-xwpn-zs9j-6wy5 "$OUTPUT"
grep -q PKSA-8zx5-v2nz-58pb "$OUTPUT"

run_for_version 8.0
assert_line_count 25
! grep -q PKSA-xwpn-zs9j-6wy5 "$OUTPUT"

run_for_version 8.1
assert_line_count 0

if COMPOSER_CALLS_OUTPUT=$OUTPUT PATH="${TEST_DIR}:${PATH}" COMPOSER_FAILURE=1 bash "$SCRIPT" 7.3; then
    echo 'Expected a Composer failure to be propagated' >&2
    exit 1
fi
