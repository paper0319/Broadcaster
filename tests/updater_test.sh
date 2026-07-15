#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT
requested_case="${1:-all}"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_absent() { [[ ! -e "$1" ]] || fail "unexpected file: $1"; }
assert_content() {
    local expected="$1" file="$2"
    [[ "$(cat "$file")" == "$expected" ]] || fail "$file content mismatch"
}
assert_contains() {
    local expected="$1" file="$2"
    grep -Fq -- "$expected" "$file" || fail "$file missing content: $expected"
}
assert_not_contains() {
    local unexpected="$1" file="$2"
    ! grep -Fq -- "$unexpected" "$file" || fail "$file contains unexpected content: $unexpected"
}
assert_java_args() {
    local expected
    printf -v expected '%s\n' '-Xms128M' '-Xmx{{SERVER_MEMORY}}M' '-jar' "$1"
    expected="${expected%$'\n'}"
    assert_content "$expected" "$CASE_DIR/java.log"
}
assert_default_temps_absent() {
    assert_absent "$CASE_DIR/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$CASE_DIR/.mcxboxbroadcast-release-url.tmp"
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
printf '%s\n' "$output" >"$MOCK_ROOT/download-output.log"
if [[ "${MOCK_SIGNAL_PARENT:-0}" == "1" ]]; then
    printf partial >"$output"
    : >"$MOCK_ROOT/signal-sent.log"
    kill -TERM "$PPID"
    exit 0
fi
printf '%s' "${MOCK_DOWNLOAD_CONTENT:-valid-new}" >"$output"
MOCK

    cat >"$CASE_DIR/bin/jar" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "tf" ]] || exit 2
[[ -f "$2" ]] || exit 1
[[ "$(cat "$2")" == valid-* ]]
MOCK

    cat >"$CASE_DIR/bin/mv" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_REPLACE_FAIL:-0}" == "1" && "${3:-}" == *.download ]]; then
    exit 1
fi
exec /bin/mv "$@"
MOCK

    cat >"$CASE_DIR/bin/java" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$MOCK_ROOT/java.log"
MOCK

    chmod +x "$CASE_DIR/bin/"*
}

run_updater() {
    (
        cd "$CASE_DIR"
        PATH="$CASE_DIR/bin:$PATH" \
        MOCK_ROOT="$CASE_DIR" \
        SERVER_JARFILE="${TEST_SERVER_JARFILE:-MCXboxBroadcastStandalone.jar}" \
        bash "$repo_root/scripts/mcxboxbroadcast-updater.sh" \
            >"$CASE_DIR/updater.log" 2>&1
    )
}

case "$requested_case" in
    all|replacement-failure|signal-during-update|failure-cleanup|configured-path|missing-state|missing-jar) ;;
    *) fail "unknown test case: $requested_case" ;;
esac

if [[ "$requested_case" == all || "$requested_case" == replacement-failure ]]; then
    make_case replacement-failure
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    MOCK_REPLACE_FAIL=1 MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' run_updater
    assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_contains 'Warning: Jar replacement failed; keeping the existing Jar.' "$CASE_DIR/updater.log"
    assert_not_contains 'Update completed.' "$CASE_DIR/updater.log"
    assert_java_args 'MCXboxBroadcastStandalone.jar'
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == signal-during-update ]]; then
    make_case signal-during-update
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    set +e
    MOCK_SIGNAL_PARENT=1 MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' run_updater
    status=$?
    set -e
    assert_file "$CASE_DIR/signal-sent.log"
    [[ "$status" -ne 0 ]] || fail "TERM during update should exit nonzero"
    assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_absent "$CASE_DIR/java.log"
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == failure-cleanup ]]; then
    make_case failure-cleanup
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    MOCK_DOWNLOAD_CONTENT=invalid MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' run_updater
    assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_java_args 'MCXboxBroadcastStandalone.jar'
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == configured-path ]]; then
    make_case configured-path
    jar_path='server files/custom broadcast.jar'
    mkdir -p "$CASE_DIR/server files"
    printf valid-old >"$CASE_DIR/$jar_path"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    TEST_SERVER_JARFILE="$jar_path" MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' run_updater
    assert_content 'server files/.custom broadcast.jar.download' "$CASE_DIR/download-output.log"
    assert_content valid-new "$CASE_DIR/$jar_path"
    assert_content 'https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_java_args "$jar_path"
    assert_absent "$CASE_DIR/server files/.custom broadcast.jar.download"
    assert_absent "$CASE_DIR/.mcxboxbroadcast-release-url.tmp"
fi

if [[ "$requested_case" == all || "$requested_case" == missing-state ]]; then
    make_case missing-state
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' run_updater
    assert_content valid-new "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    assert_content 'https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_java_args 'MCXboxBroadcastStandalone.jar'
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == missing-jar ]]; then
    make_case missing-jar
    printf '%s\n' 'https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' >"$CASE_DIR/.mcxboxbroadcast-release-url"
    MOCK_RELEASE_URL='https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' run_updater
    assert_content valid-new "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    assert_content 'https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_java_args 'MCXboxBroadcastStandalone.jar'
    assert_default_temps_absent
fi

if [[ "$requested_case" != all ]]; then
    echo "$requested_case test passed"
    exit 0
fi

make_case disabled
printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
AUTO_UPDATE=0 run_updater
assert_absent "$CASE_DIR/curl.log"
assert_java_args 'MCXboxBroadcastStandalone.jar'
assert_default_temps_absent

make_case unchanged
printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
printf '%s\n' 'https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' >"$CASE_DIR/.mcxboxbroadcast-release-url"
MOCK_RELEASE_URL='https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' run_updater
[[ "$(wc -l <"$CASE_DIR/curl.log")" -eq 1 ]] || fail "unchanged release downloaded"
assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"
assert_java_args 'MCXboxBroadcastStandalone.jar'
assert_default_temps_absent

make_case update
printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' run_updater
assert_content valid-new "$CASE_DIR/MCXboxBroadcastStandalone.jar"
assert_content 'https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' "$CASE_DIR/.mcxboxbroadcast-release-url"
assert_java_args 'MCXboxBroadcastStandalone.jar'
assert_default_temps_absent

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
    assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_java_args 'MCXboxBroadcastStandalone.jar'
    assert_default_temps_absent
done

make_case no-jar
set +e
MOCK_HEAD_FAIL=1 MOCK_RELEASE_URL=new run_updater
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "missing jar should fail"
assert_absent "$CASE_DIR/java.log"
assert_default_temps_absent

echo "updater tests passed"
