#!/bin/ash
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf -- "$work_root"' EXIT
requested_case="${1:-all}"
latest_url='https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/MCXboxBroadcastStandalone.jar'

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "missing file: $1"
}

assert_absent() {
    [ ! -e "$1" ] || fail "unexpected file: $1"
}

assert_content() {
    expected="$1"
    file="$2"
    [ "$(cat "$file")" = "$expected" ] || fail "$file content mismatch"
}

assert_not_contains() {
    unexpected="$1"
    file="$2"
    ! grep -Fq -- "$unexpected" "$file" || fail "$file contains unexpected content: $unexpected"
}

assert_contains() {
    expected="$1"
    file="$2"
    grep -Fq -- "$expected" "$file" || fail "$file missing content: $expected"
}

assert_default_temps_absent() {
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
}

make_case() {
    name="$1"
    case_dir="$work_root/$name"
    mkdir -p -- "$case_dir/bin" "$case_dir/server"

    cat >"$case_dir/bin/curl" <<'MOCK'
#!/bin/ash
set -eu

url=''
for argument in "$@"; do
    url="$argument"
done

case " $* " in
    *' -fsSI '*)
        printf '%s\n' "$*" >"$MOCK_ROOT/head-args.log"
        printf '%s\n' "$url" >"$MOCK_ROOT/head-url.log"
        [ "${MOCK_HEAD_FAIL:-0}" = 1 ] && exit 22
        [ "${MOCK_HEAD_NO_LOCATION:-0}" != 1 ] || {
            printf 'HTTP/2 200\r\n\r\n'
            exit 0
        }
        printf 'HTTP/2 302\r\nlocation: %s\r\n\r\n' "$MOCK_RELEASE_URL"
        if [ -n "${MOCK_SECOND_RELEASE_URL:-}" ]; then
            printf 'HTTP/2 302\r\nlocation: %s\r\n\r\n' "$MOCK_SECOND_RELEASE_URL"
        fi
        exit 0
        ;;
esac

printf '%s\n' "$*" >"$MOCK_ROOT/download-args.log"
printf '%s\n' "$url" >"$MOCK_ROOT/download-url.log"
output=''
while [ "$#" -gt 0 ]; do
    if [ "$1" = '--output' ]; then
        output="$2"
        break
    fi
    shift
done
[ -n "$output" ] || exit 2
printf '%s\n' "$output" >"$MOCK_ROOT/download-output.log"
[ "${MOCK_SIGNAL_PARENT:-0}" != 1 ] || {
    printf partial >"$output"
    : >"$MOCK_ROOT/signal-sent.log"
    kill -TERM "$PPID"
    exit 0
}
[ "${MOCK_DOWNLOAD_FAIL:-0}" != 1 ] || {
    printf partial >"$output"
    exit 22
}
[ "${MOCK_DOWNLOAD_EMPTY:-0}" != 1 ] || {
    : >"$output"
    exit 0
}
printf valid-new >"$output"
MOCK

    cat >"$case_dir/bin/mv" <<'MOCK'
#!/bin/ash
set -eu

destination=''
for argument in "$@"; do
    destination="$argument"
done
if [ "${MOCK_REPLACE_FAIL:-0}" = 1 ] && [ "$destination" = "$MOCK_JAR_DEST" ]; then
    exit 1
fi
if [ "${MOCK_STATE_MOVE_FAIL:-0}" = 1 ] &&
    [ "$destination" = '.mcxboxbroadcast-release-url' ]; then
    exit 1
fi
exec /bin/mv "$@"
MOCK

    chmod +x "$case_dir/bin/curl" "$case_dir/bin/mv"
}

run_install() {
    test_server_dir="${TEST_SERVER_DIR:-$case_dir/server}"
    test_jar_file="${TEST_SERVER_JARFILE:-MCXboxBroadcastStandalone.jar}"
    env \
        PATH="$case_dir/bin:$PATH" \
        MOCK_ROOT="$case_dir" \
        MOCK_HEAD_FAIL="${MOCK_HEAD_FAIL:-0}" \
        MOCK_HEAD_NO_LOCATION="${MOCK_HEAD_NO_LOCATION:-0}" \
        MOCK_DOWNLOAD_FAIL="${MOCK_DOWNLOAD_FAIL:-0}" \
        MOCK_DOWNLOAD_EMPTY="${MOCK_DOWNLOAD_EMPTY:-0}" \
        MOCK_SIGNAL_PARENT="${MOCK_SIGNAL_PARENT:-0}" \
        MOCK_REPLACE_FAIL="${MOCK_REPLACE_FAIL:-0}" \
        MOCK_STATE_MOVE_FAIL="${MOCK_STATE_MOVE_FAIL:-0}" \
        MOCK_JAR_DEST="$test_jar_file" \
        MOCK_RELEASE_URL="${MOCK_RELEASE_URL:-}" \
        MOCK_SECOND_RELEASE_URL="${MOCK_SECOND_RELEASE_URL:-}" \
        SERVER_DIR="$test_server_dir" \
        SERVER_JARFILE="$test_jar_file" \
        ash "$repo_root/scripts/mcxboxbroadcast-install.sh" \
        >"$case_dir/install.log" 2>&1
}

case "$requested_case" in
    all|success|release-resolution|head-failure|head-failure-existing|download-failure|empty-download|signal-cleanup|existing-failures|replacement-failure|state-save-failure|configured-path|source-policy) ;;
    *) fail "unknown test case: $requested_case" ;;
esac

if [ "$requested_case" = all ] || [ "$requested_case" = success ]; then
    make_case success
    printf config-data >"$case_dir/server/config.yml"
    printf auth-data >"$case_dir/server/auth.json"
    printf session-data >"$case_dir/server/session.dat"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    MOCK_RELEASE_URL="$release_url" run_install
    assert_content valid-new "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_content "$release_url" "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_content "$latest_url" "$case_dir/head-url.log"
    assert_content "$release_url" "$case_dir/download-url.log"
    assert_content config-data "$case_dir/server/config.yml"
    assert_content auth-data "$case_dir/server/auth.json"
    assert_content session-data "$case_dir/server/session.dat"
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = release-resolution ]; then
    make_case first-location
    first_url='https://github.com/example/releases/download/first/MCXboxBroadcastStandalone.jar'
    second_url='https://objects.example.invalid/signed/MCXboxBroadcastStandalone.jar'
    MOCK_RELEASE_URL="$first_url" MOCK_SECOND_RELEASE_URL="$second_url" run_install
    assert_content "$first_url" "$case_dir/download-url.log"
    assert_content "$first_url" "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_default_temps_absent

    make_case no-location
    MOCK_HEAD_NO_LOCATION=1 run_install
    assert_content "$latest_url" "$case_dir/download-url.log"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = head-failure ]; then
    make_case head-failure
    MOCK_HEAD_FAIL=1 run_install
    assert_file "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_content valid-new "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_content "$latest_url" "$case_dir/download-url.log"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = download-failure ]; then
    make_case download-failure
    printf stale >"$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    printf stale >"$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    set +e
    MOCK_DOWNLOAD_FAIL=1 \
        MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
        run_install
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail 'download failure should fail installation'
    assert_absent "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_contains 'Error: download failed.' "$case_dir/install.log"
    assert_not_contains 'Installation completed.' "$case_dir/install.log"
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = signal-cleanup ]; then
    make_case signal-cleanup
    set +e
    MOCK_SIGNAL_PARENT=1 \
        MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
        run_install
    status=$?
    set -e
    assert_file "$case_dir/signal-sent.log"
    [ "$status" -ne 0 ] || fail 'TERM during download should fail installation'
    assert_absent "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_not_contains 'Installation completed.' "$case_dir/install.log"
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = existing-failures ]; then
    for mode in download empty head-and-download; do
        make_case "existing-$mode-failure"
        printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
        printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
        set +e
        case "$mode" in
            download)
                MOCK_DOWNLOAD_FAIL=1 \
                    MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
                    run_install
                ;;
            empty)
                MOCK_DOWNLOAD_EMPTY=1 \
                    MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
                    run_install
                ;;
            head-and-download)
                MOCK_HEAD_FAIL=1 MOCK_DOWNLOAD_FAIL=1 run_install
                ;;
        esac
        status=$?
        set -e
        [ "$status" -ne 0 ] || fail "$mode failure should fail installation"
        assert_content valid-old "$case_dir/server/MCXboxBroadcastStandalone.jar"
        assert_content old "$case_dir/server/.mcxboxbroadcast-release-url"
        assert_not_contains 'Installation completed.' "$case_dir/install.log"
        assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
        assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    done
fi

if [ "$requested_case" = all ] || [ "$requested_case" = empty-download ]; then
    make_case empty-download
    set +e
    MOCK_DOWNLOAD_EMPTY=1 \
        MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
        run_install
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail 'empty download should fail installation'
    assert_absent "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = head-failure-existing ]; then
    make_case head-failure-existing
    printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
    MOCK_HEAD_FAIL=1 run_install
    assert_content valid-new "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_content "$latest_url" "$case_dir/download-url.log"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
fi

if [ "$requested_case" = all ] || [ "$requested_case" = source-policy ]; then
    make_case source-policy
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    MOCK_RELEASE_URL="$release_url" run_install
    assert_content "$latest_url" "$case_dir/head-url.log"
    assert_contains '-fsSI' "$case_dir/head-args.log"
    assert_contains '--retry 3' "$case_dir/head-args.log"
    assert_contains '--connect-timeout 10' "$case_dir/head-args.log"
    assert_contains '--max-time 30' "$case_dir/head-args.log"
    assert_contains '--fail' "$case_dir/download-args.log"
    assert_contains '--silent' "$case_dir/download-args.log"
    assert_contains '--show-error' "$case_dir/download-args.log"
    assert_contains '--location' "$case_dir/download-args.log"
    assert_contains '--retry 3' "$case_dir/download-args.log"
    assert_contains '--connect-timeout 10' "$case_dir/download-args.log"
    assert_contains '--max-time 180' "$case_dir/download-args.log"
    assert_contains "$latest_url" "$repo_root/scripts/mcxboxbroadcast-install.sh"
    assert_not_contains 'api.github.com' "$repo_root/scripts/mcxboxbroadcast-install.sh"
    if grep -Eq '(^|[[:space:]])java([[:space:]]|$)|jar[[:space:]]+tf' \
        "$repo_root/scripts/mcxboxbroadcast-install.sh"; then
        fail 'installer must not depend on Java or validate with jar tf'
    fi
fi

if [ "$requested_case" = all ] || [ "$requested_case" = replacement-failure ]; then
    make_case replacement-failure
    printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
    set +e
    MOCK_REPLACE_FAIL=1 \
        MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
        run_install
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail 'replacement failure should fail installation'
    assert_content valid-old "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_content old "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_not_contains 'Installation completed.' "$case_dir/install.log"
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
fi

if [ "$requested_case" = all ] || [ "$requested_case" = state-save-failure ]; then
    make_case state-save-failure
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    set +e
    MOCK_STATE_MOVE_FAIL=1 MOCK_RELEASE_URL="$release_url" run_install
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail 'installed Jar should remain usable when release state cannot be saved'
    assert_content valid-new "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_contains 'Warning: release state could not be saved.' "$case_dir/install.log"
    assert_contains 'Installation completed.' "$case_dir/install.log"
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = configured-path ]; then
    make_case configured-path
    server_dir="$case_dir/server files"
    jar_file='nested jars/custom broadcast.jar'
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    set +e
    TEST_SERVER_DIR="$server_dir" TEST_SERVER_JARFILE="$jar_file" \
        MOCK_RELEASE_URL="$release_url" run_install
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail 'configured subdirectory installation failed'
    assert_content 'nested jars/.custom broadcast.jar.download' "$case_dir/download-output.log"
    assert_content valid-new "$server_dir/$jar_file"
    assert_content "$release_url" "$server_dir/.mcxboxbroadcast-release-url"
    assert_absent "$server_dir/nested jars/.custom broadcast.jar.download"
    assert_absent "$server_dir/.mcxboxbroadcast-release-url.tmp"
fi

echo 'installer tests passed'
