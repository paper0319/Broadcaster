#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_absent() { [[ ! -e "$1" ]] || fail "unexpected file: $1"; }
assert_content() {
    local expected="$1" file="$2"
    [[ "$(cat "$file")" == "$expected" ]] || fail "$file content mismatch"
}

make_case() {
    local name="$1"
    CASE_DIR="$work_root/$name"
    mkdir -p "$CASE_DIR/bin"

    cat >"$CASE_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$MOCK_ROOT/curl.log"
if [[ "$*" == *"-fsSI"* ]]; then
    [[ "${MOCK_HEAD_FAIL:-0}" == "1" ]] && exit 22
    printf 'HTTP/2 302\r\nlocation: %s\r\n\r\n' "$MOCK_RELEASE_URL"
    exit 0
fi
[[ "${MOCK_DOWNLOAD_FAIL:-0}" == "1" ]] && exit 22
output=""
while (($#)); do
    if [[ "$1" == "--output" ]]; then output="$2"; break; fi
    shift
done
[[ -n "$output" ]] || exit 2
printf '%s' "${MOCK_DOWNLOAD_CONTENT:-valid-new}" >"$output"
MOCK

    cat >"$CASE_DIR/bin/jar" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "tf" ]] || exit 2
[[ -f "$2" ]] || exit 1
[[ "$(cat "$2")" == valid-* ]]
MOCK

    cat >"$CASE_DIR/bin/java" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$MOCK_ROOT/java.log"
MOCK

    chmod +x "$CASE_DIR/bin/"*
}

run_updater() {
    (
        cd "$CASE_DIR"
        PATH="$CASE_DIR/bin:$PATH" \
        MOCK_ROOT="$CASE_DIR" \
        SERVER_JARFILE="MCXboxBroadcastStandalone.jar" \
        bash "$repo_root/scripts/mcxboxbroadcast-updater.sh"
    )
}

make_case disabled
printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
AUTO_UPDATE=0 run_updater
assert_absent "$CASE_DIR/curl.log"
assert_file "$CASE_DIR/java.log"

make_case unchanged
printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
printf '%s\n' 'https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' >"$CASE_DIR/.mcxboxbroadcast-release-url"
MOCK_RELEASE_URL='https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' run_updater
[[ "$(wc -l <"$CASE_DIR/curl.log")" -eq 1 ]] || fail "unchanged release downloaded"
assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"

make_case update
printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' run_updater
assert_content valid-new "$CASE_DIR/MCXboxBroadcastStandalone.jar"
assert_content 'https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' "$CASE_DIR/.mcxboxbroadcast-release-url"

for mode in head download invalid; do
    make_case "$mode-failure"
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    case "$mode" in
        head) MOCK_HEAD_FAIL=1 MOCK_RELEASE_URL=new run_updater ;;
        download) MOCK_DOWNLOAD_FAIL=1 MOCK_RELEASE_URL=new run_updater ;;
        invalid) MOCK_DOWNLOAD_CONTENT=invalid MOCK_RELEASE_URL=new run_updater ;;
    esac
    assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    assert_file "$CASE_DIR/java.log"
done

make_case no-jar
set +e
MOCK_HEAD_FAIL=1 MOCK_RELEASE_URL=new run_updater
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "missing jar should fail"
assert_absent "$CASE_DIR/java.log"

echo "updater tests passed"
