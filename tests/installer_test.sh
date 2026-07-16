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
sha256_of_text() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

wait_for_file() {
    file="$1"
    attempts=0
    while [ "$attempts" -lt 100 ]; do
        [ -e "$file" ] && return 0
        sleep 0.05
        attempts=$((attempts + 1))
    done
    fail "timed out waiting for file: $file"
}

assert_default_temps_absent() {
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-sha256.tmp"
    leftover="$(
        find "$case_dir/server" -type f \
            \( -name '.mcxboxbroadcast-head.*' \
            -o -name '.*.download.*' \
            -o -name '.mcxboxbroadcast-release-url.tmp.*' \
            -o -name '.mcxboxbroadcast-release-sha256.tmp.*' \) \
            -print -quit
    )"
    [ -z "$leftover" ] || fail "transient file was not cleaned: $leftover"
}

make_case() {
    name="$1"
    case_dir="$work_root/$name"
    mkdir -p -- "$case_dir/bin" "$case_dir/server"

    cat >"$case_dir/bin/curl" <<'MOCK'
#!/bin/ash
set -eu

if [ -n "${MOCK_SIGNAL_ON_START:-}" ]; then
    printf '%s\n' "$$" >"$MOCK_ROOT/curl-child.pid"
    terminate_starting_curl() {
        printf 'terminated\n' >"$MOCK_ROOT/curl-terminated.log"
        exit 99
    }
    trap terminate_starting_curl TERM INT
    kill -"$MOCK_SIGNAL_ON_START" "$PPID"
    : >"$MOCK_ROOT/curl-ready.log"
    sleep 2
    exit 98
fi

url=''
for argument in "$@"; do
    url="$argument"
done
output=''
arguments="$*"
while [ "$#" -gt 0 ]; do
    if [ "$1" = '--output' ]; then
        output="$2"
        break
    fi
    shift
done
[ -n "$output" ] || exit 2

case " $arguments " in
    *' -fsSI '*)
        printf '%s\n' "$arguments" >"$MOCK_ROOT/head-args.log"
        printf '%s\n' "$url" >"$MOCK_ROOT/head-url.log"
        printf '%s\n' "$output" >>"$MOCK_ROOT/head-output.log"
        if [ "${MOCK_CONCURRENT_RELEASES:-0}" = 1 ]; then
            : >"$MOCK_ROOT/${MOCK_RUN_ID}.head-ready"
            attempts=0
            while [ "$attempts" -lt 40 ]; do
                [ -e "$MOCK_ROOT/A.head-ready" ] && [ -e "$MOCK_ROOT/B.head-ready" ] && break
                sleep 0.05
                attempts=$((attempts + 1))
            done
        fi
        if [ "${MOCK_BLOCK_PHASE:-}" = head ]; then
            printf '%s\n' "$$" >"$MOCK_ROOT/curl-child.pid"
            : >"$MOCK_ROOT/curl-ready.log"
            terminate_blocked_curl() {
                printf 'terminated\n' >"$MOCK_ROOT/curl-terminated.log"
                exit 99
            }
            trap terminate_blocked_curl TERM INT
            while :; do sleep 1; done
        fi
        [ "${MOCK_HEAD_FAIL:-0}" = 1 ] && exit 22
        [ "${MOCK_HEAD_PARTIAL_FAIL:-0}" != 1 ] || {
            printf 'HTTP/2 302\r\nlocation: %s\r\n\r\n' "$MOCK_RELEASE_URL" >"$output"
            exit 22
        }
        [ "${MOCK_HEAD_NO_LOCATION:-0}" != 1 ] || {
            printf 'HTTP/2 200\r\n\r\n' >"$output"
            exit 0
        }
        printf 'HTTP/2 302\r\nlocation: %s\r\n\r\n' "$MOCK_RELEASE_URL" >"$output"
        if [ -n "${MOCK_SECOND_RELEASE_URL:-}" ]; then
            printf 'HTTP/2 302\r\nlocation: %s\r\n\r\n' "$MOCK_SECOND_RELEASE_URL" >>"$output"
        fi
        exit 0
        ;;
esac

printf '%s\n' "$arguments" >"$MOCK_ROOT/download-args.log"
printf '%s\n' "$url" >"$MOCK_ROOT/download-url.log"
printf '%s\n' "$output" >>"$MOCK_ROOT/download-output.log"
if [ "${MOCK_BLOCK_PHASE:-}" = download ]; then
    printf partial >"$output"
    printf '%s\n' "$$" >"$MOCK_ROOT/curl-child.pid"
    : >"$MOCK_ROOT/curl-ready.log"
    terminate_blocked_curl() {
        printf 'terminated\n' >"$MOCK_ROOT/curl-terminated.log"
        exit 99
    }
    trap terminate_blocked_curl TERM INT
    while :; do sleep 1; done
fi
[ "${MOCK_DOWNLOAD_FAIL:-0}" != 1 ] || {
    printf partial >"$output"
    exit 22
}
[ "${MOCK_DOWNLOAD_EMPTY:-0}" != 1 ] || {
    : >"$output"
    exit 0
}
printf '%s' "${MOCK_DOWNLOAD_CONTENT:-valid-new}" >"$output"
if [ "${MOCK_CREATE_JAR_DIR:-0}" = 1 ]; then
    mkdir -p -- "$MOCK_JAR_DEST"
fi
if [ "${MOCK_CREATE_STATE_DIR:-0}" = 1 ]; then
    rm -f -- .mcxboxbroadcast-release-url
    mkdir -p -- .mcxboxbroadcast-release-url
fi
MOCK

    cat >"$case_dir/bin/mv" <<'MOCK'
#!/bin/ash
set -eu

source=''
destination=''
for argument in "$@"; do
    source="$destination"
    destination="$argument"
done
printf '%s\n' "$*" >>"$MOCK_ROOT/mv.log"
if [ "$destination" = '.mcxboxbroadcast-release-url' ]; then
    printf '%s\n' "$source" >>"$MOCK_ROOT/state-temp.log"
fi
if [ "${MOCK_REPLACE_FAIL:-0}" = 1 ] && [ "$destination" = "$MOCK_JAR_DEST" ]; then
    exit 1
fi
if [ "${MOCK_STATE_MOVE_FAIL:-0}" = 1 ] &&
    [ "$destination" = '.mcxboxbroadcast-release-url' ]; then
    exit 1
fi
if [ "${MOCK_CREATE_JAR_DIR_ON_MOVE:-0}" = 1 ] &&
    [ "$destination" = "$MOCK_JAR_DEST" ]; then
    mkdir -p -- "$destination"
fi
if [ "${MOCK_CREATE_STATE_DIR_ON_MOVE:-0}" = 1 ] &&
    [ "$destination" = '.mcxboxbroadcast-release-url' ]; then
    mkdir -p -- "$destination"
fi
if [ "${MOCK_CONCURRENT_RELEASES:-0}" = 1 ]; then
    wait_for_marker() {
        marker="$1"
        attempts=0
        while [ "$attempts" -lt 40 ]; do
            [ -e "$marker" ] && return 0
            sleep 0.05
            attempts=$((attempts + 1))
        done
        return 0
    }
    if [ "$destination" = "$MOCK_JAR_DEST" ]; then
        [ "$MOCK_RUN_ID" != A ] || wait_for_marker "$MOCK_ROOT/B.jar-moved"
        /bin/mv "$@"
        : >"$MOCK_ROOT/${MOCK_RUN_ID}.jar-moved"
        exit 0
    fi
    if [ "$destination" = '.mcxboxbroadcast-release-url' ]; then
        [ "$MOCK_RUN_ID" != B ] || wait_for_marker "$MOCK_ROOT/A.state-moved"
        /bin/mv "$@"
        : >"$MOCK_ROOT/${MOCK_RUN_ID}.state-moved"
        exit 0
    fi
fi
exec /bin/mv "$@"
MOCK

    cat >"$case_dir/bin/mktemp" <<'MOCK'
#!/bin/ash
set -eu
template=''
for argument in "$@"; do
    template="$argument"
done
printf '%s\n' "$template" >>"$MOCK_ROOT/mktemp.log"
case "$template" in
    *"${MOCK_MKTEMP_FAIL_PATTERN:-__no_match__}"*)
        [ -z "${MOCK_MKTEMP_FAIL_PATTERN:-}" ] || exit 1
        ;;
esac
exec /bin/mktemp "$@"
MOCK

    cat >"$case_dir/bin/flock" <<'MOCK'
#!/bin/ash
set -eu
[ "${MOCK_FLOCK_FAIL:-0}" != 1 ] || exit 1
exec /usr/bin/flock "$@"
MOCK

    chmod +x "$case_dir/bin/curl" "$case_dir/bin/mv" "$case_dir/bin/mktemp" "$case_dir/bin/flock"
}

invoke_install() {
    test_server_dir="${TEST_SERVER_DIR:-$case_dir/server}"
    test_jar_file="${TEST_SERVER_JARFILE-MCXboxBroadcastStandalone.jar}"
    env \
        PATH="$case_dir/bin:$PATH" \
        MOCK_ROOT="$case_dir" \
        MOCK_HEAD_FAIL="${MOCK_HEAD_FAIL:-0}" \
        MOCK_HEAD_PARTIAL_FAIL="${MOCK_HEAD_PARTIAL_FAIL:-0}" \
        MOCK_HEAD_NO_LOCATION="${MOCK_HEAD_NO_LOCATION:-0}" \
        MOCK_DOWNLOAD_FAIL="${MOCK_DOWNLOAD_FAIL:-0}" \
        MOCK_DOWNLOAD_EMPTY="${MOCK_DOWNLOAD_EMPTY:-0}" \
        MOCK_DOWNLOAD_CONTENT="${MOCK_DOWNLOAD_CONTENT:-valid-new}" \
        MOCK_CONCURRENT_RELEASES="${MOCK_CONCURRENT_RELEASES:-0}" \
        MOCK_RUN_ID="${MOCK_RUN_ID:-single}" \
        MOCK_BLOCK_PHASE="${MOCK_BLOCK_PHASE:-}" \
        MOCK_SIGNAL_ON_START="${MOCK_SIGNAL_ON_START:-}" \
        MOCK_CREATE_JAR_DIR="${MOCK_CREATE_JAR_DIR:-0}" \
        MOCK_CREATE_STATE_DIR="${MOCK_CREATE_STATE_DIR:-0}" \
        MOCK_REPLACE_FAIL="${MOCK_REPLACE_FAIL:-0}" \
        MOCK_STATE_MOVE_FAIL="${MOCK_STATE_MOVE_FAIL:-0}" \
        MOCK_CREATE_JAR_DIR_ON_MOVE="${MOCK_CREATE_JAR_DIR_ON_MOVE:-0}" \
        MOCK_CREATE_STATE_DIR_ON_MOVE="${MOCK_CREATE_STATE_DIR_ON_MOVE:-0}" \
        MOCK_MKTEMP_FAIL_PATTERN="${MOCK_MKTEMP_FAIL_PATTERN:-}" \
        MOCK_FLOCK_FAIL="${MOCK_FLOCK_FAIL:-0}" \
        MOCK_JAR_DEST="$test_jar_file" \
        MOCK_RELEASE_URL="${MOCK_RELEASE_URL:-}" \
        MOCK_SECOND_RELEASE_URL="${MOCK_SECOND_RELEASE_URL:-}" \
        SERVER_DIR="$test_server_dir" \
        SERVER_JARFILE="$test_jar_file" \
        ash "$repo_root/scripts/mcxboxbroadcast-install.sh" \
        >"$case_dir/install.log" 2>&1
}

start_install() {
    (invoke_install) &
    INSTALL_PID=$!
}

run_install() {
    start_install
    wait "$INSTALL_PID"
}

case "$requested_case" in
    all|concurrent-release-pair|lock-failure|signal-at-child-start|unsafe-jar-names|legacy-temp-symlinks|unique-temp-names|mktemp-failure|success|release-resolution|head-failure|partial-head-failure|head-failure-existing|download-failure|empty-download|signal-cleanup|existing-failures|replacement-failure|jar-directory-collision|jar-directory-race|jar-mv-boundary-race|state-save-failure|state-directory-collision|state-directory-race|state-directory-fallback|state-mv-boundary-race|configured-path|option-like-path|source-policy) ;;
    *) fail "unknown test case: $requested_case" ;;
esac

if [ "$requested_case" = all ] || [ "$requested_case" = concurrent-release-pair ]; then
    make_case concurrent-release-pair
    printf valid-base >"$case_dir/server/MCXboxBroadcastStandalone.jar"
    printf '%s\n' base >"$case_dir/server/.mcxboxbroadcast-release-url"
    old_url='https://github.com/example/releases/download/old/MCXboxBroadcastStandalone.jar'
    new_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'

    MOCK_CONCURRENT_RELEASES=1 MOCK_RUN_ID=A \
        MOCK_RELEASE_URL="$old_url" MOCK_DOWNLOAD_CONTENT=valid-old-release \
        start_install
    install_a_pid=$INSTALL_PID
    MOCK_CONCURRENT_RELEASES=1 MOCK_RUN_ID=B \
        MOCK_RELEASE_URL="$new_url" MOCK_DOWNLOAD_CONTENT=valid-new-release \
        start_install
    install_b_pid=$INSTALL_PID
    wait "$install_a_pid"
    wait "$install_b_pid"

    installed_url="$(cat "$case_dir/server/.mcxboxbroadcast-release-url")"
    case "$installed_url" in
        "$old_url") assert_content valid-old-release "$case_dir/server/MCXboxBroadcastStandalone.jar" ;;
        "$new_url") assert_content valid-new-release "$case_dir/server/MCXboxBroadcastStandalone.jar" ;;
        *) fail "unexpected concurrent release state: $installed_url" ;;
    esac
    (
        cd "$case_dir/server"
        exec 8<.
        flock -n 8
    ) || fail 'installer transaction lock was not released'
    assert_absent "$case_dir/server/.mcxboxbroadcast-update.lock"
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = lock-failure ]; then
    make_case lock-failure
    printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
    set +e
    MOCK_FLOCK_FAIL=1 \
        MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
        run_install
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail 'lock acquisition failure should fail installation'
    assert_content valid-old "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_content old "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_absent "$case_dir/curl.log"
    assert_contains 'Error: update lock could not be acquired.' "$case_dir/install.log"
    assert_absent "$case_dir/server/.mcxboxbroadcast-update.lock"
    assert_not_contains 'Installation completed.' "$case_dir/install.log"
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = signal-at-child-start ]; then
    signal_specs='TERM 143
INT 130'
    old_ifs="$IFS"
    IFS='
'
    for signal_spec in $signal_specs; do
        IFS="$old_ifs"
        set -- $signal_spec
        signal_name="$1"
        expected_status="$2"
        make_case "signal-at-child-start-$signal_name"
        printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
        printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
        set +e
        MOCK_SIGNAL_ON_START="$signal_name" invoke_install
        status=$?
        set -e
        wait_for_file "$case_dir/curl-child.pid"
        child_pid="$(cat "$case_dir/curl-child.pid")"
        child_still_running=0
        if kill -0 "$child_pid" 2>/dev/null; then
            child_still_running=1
            kill -KILL "$child_pid" 2>/dev/null || :
        fi

        [ "$status" = "$expected_status" ] ||
            fail "$signal_name at child start exited $status instead of $expected_status"
        [ "$child_still_running" = 0 ] || fail "$signal_name at child start left curl running"
        assert_file "$case_dir/curl-terminated.log"
        assert_content valid-old "$case_dir/server/MCXboxBroadcastStandalone.jar"
        assert_content old "$case_dir/server/.mcxboxbroadcast-release-url"
        assert_not_contains 'Installation completed.' "$case_dir/install.log"
        assert_default_temps_absent
        IFS='
'
    done
    IFS="$old_ifs"
fi

if [ "$requested_case" = all ] || [ "$requested_case" = unsafe-jar-names ]; then
    unsafe_names='<empty>
.
config.yml
.mcxboxbroadcast-release-url
.hidden.jar
not-a-jar
/tmp/evil.jar
../evil.jar
nested/../evil.jar
nested/./evil.jar'
    old_ifs="$IFS"
    IFS='
'
    index=0
    for encoded_name in $unsafe_names; do
        IFS="$old_ifs"
        unsafe_name="$encoded_name"
        [ "$encoded_name" != '<empty>' ] || unsafe_name=''
        make_case "unsafe-jar-name-$index"
        printf config-data >"$case_dir/server/config.yml"
        printf auth-data >"$case_dir/server/auth.json"
        printf session-data >"$case_dir/server/session.dat"
        printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
        set +e
        TEST_SERVER_JARFILE="$unsafe_name" \
            MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
            run_install
        status=$?
        set -e
        [ "$status" -ne 0 ] || fail "unsafe Jar name was accepted: <$unsafe_name>"
        assert_absent "$case_dir/head-url.log"
        assert_absent "$case_dir/download-url.log"
        assert_content config-data "$case_dir/server/config.yml"
        assert_content auth-data "$case_dir/server/auth.json"
        assert_content session-data "$case_dir/server/session.dat"
        assert_content old "$case_dir/server/.mcxboxbroadcast-release-url"
        index=$((index + 1))
        IFS='
'
    done
    IFS="$old_ifs"
fi

if [ "$requested_case" = all ] || [ "$requested_case" = mktemp-failure ]; then
    for failure_pattern in head download release-url.tmp; do
        make_case "mktemp-failure-$failure_pattern"
        printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
        printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
        release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
        set +e
        MOCK_MKTEMP_FAIL_PATTERN="$failure_pattern" MOCK_RELEASE_URL="$release_url" run_install
        status=$?
        set -e
        [ "$status" -ne 0 ] || fail "$failure_pattern mktemp failure should fail installation"
        assert_content valid-old "$case_dir/server/MCXboxBroadcastStandalone.jar"
        assert_content old "$case_dir/server/.mcxboxbroadcast-release-url"
        assert_not_contains 'Installation completed.' "$case_dir/install.log"
        if [ "$failure_pattern" = head ]; then
            assert_absent "$case_dir/head-url.log"
        else
            assert_file "$case_dir/head-url.log"
            assert_absent "$case_dir/download-url.log"
        fi
        assert_default_temps_absent
    done
fi

if [ "$requested_case" = all ] || [ "$requested_case" = unique-temp-names ]; then
    make_case successive-unique-temps
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    for iteration in 1 2; do
        printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
        printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
        MOCK_RELEASE_URL="$release_url" run_install
    done
    [ "$(wc -l <"$case_dir/head-output.log")" -eq 2 ] || fail 'successive HEAD temp paths were not recorded'
    [ "$(sort -u "$case_dir/head-output.log" | wc -l)" -eq 2 ] || fail 'successive HEAD temp names were not distinct'
    [ "$(wc -l <"$case_dir/download-output.log")" -eq 2 ] || fail 'successive download temp paths were not recorded'
    [ "$(sort -u "$case_dir/download-output.log" | wc -l)" -eq 2 ] || fail 'successive download temp names were not distinct'
    [ "$(wc -l <"$case_dir/state-temp.log")" -eq 2 ] || fail 'successive state temp paths were not recorded'
    [ "$(sort -u "$case_dir/state-temp.log" | wc -l)" -eq 2 ] || fail 'successive state temp names were not distinct'
    assert_default_temps_absent

    make_case concurrent-unique-temps
    printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
    MOCK_RELEASE_URL="$release_url" run_install &
    first_pid=$!
    MOCK_RELEASE_URL="$release_url" run_install &
    second_pid=$!
    wait "$first_pid"
    wait "$second_pid"
    [ "$(wc -l <"$case_dir/head-output.log")" -eq 2 ] || fail 'concurrent HEAD temp paths were not recorded'
    [ "$(sort -u "$case_dir/head-output.log" | wc -l)" -eq 2 ] || fail 'concurrent HEAD temp names were not distinct'
    [ "$(wc -l <"$case_dir/download-output.log")" -eq 2 ] || fail 'concurrent download temp paths were not recorded'
    [ "$(sort -u "$case_dir/download-output.log" | wc -l)" -eq 2 ] || fail 'concurrent download temp names were not distinct'
    [ "$(wc -l <"$case_dir/state-temp.log")" -eq 2 ] || fail 'concurrent state temp paths were not recorded'
    [ "$(sort -u "$case_dir/state-temp.log" | wc -l)" -eq 2 ] || fail 'concurrent state temp names were not distinct'
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = legacy-temp-symlinks ]; then
    make_case legacy-temp-symlinks
    printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
    printf config-data >"$case_dir/server/config.yml"
    printf auth-data >"$case_dir/server/auth.json"
    printf session-data >"$case_dir/server/session.dat"
    ln -s config.yml "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    ln -s auth.json "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    ln -s session.dat "$case_dir/server/.mcxboxbroadcast-head.headers"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    MOCK_RELEASE_URL="$release_url" run_install
    assert_content valid-new "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_content "$release_url" "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_content "$(sha256_of_text valid-new)" \
        "$case_dir/server/.mcxboxbroadcast-release-sha256"
    assert_content config-data "$case_dir/server/config.yml"
    assert_content auth-data "$case_dir/server/auth.json"
    assert_content session-data "$case_dir/server/session.dat"
    [ -L "$case_dir/server/.MCXboxBroadcastStandalone.jar.download" ] || fail 'legacy download symlink was removed'
    [ -L "$case_dir/server/.mcxboxbroadcast-release-url.tmp" ] || fail 'legacy state symlink was removed'
    [ -L "$case_dir/server/.mcxboxbroadcast-head.headers" ] || fail 'legacy HEAD symlink was removed'
fi

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

if [ "$requested_case" = all ] || [ "$requested_case" = partial-head-failure ]; then
    make_case partial-head-failure
    printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
    untrusted_url='https://github.com/example/releases/download/untrusted/MCXboxBroadcastStandalone.jar'
    MOCK_HEAD_PARTIAL_FAIL=1 MOCK_RELEASE_URL="$untrusted_url" run_install
    assert_content valid-new "$case_dir/server/MCXboxBroadcastStandalone.jar"
    assert_content "$latest_url" "$case_dir/download-url.log"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_not_contains 'api.github.com' "$repo_root/scripts/mcxboxbroadcast-install.sh"
    assert_default_temps_absent
fi

if [ "$requested_case" = all ] || [ "$requested_case" = download-failure ]; then
    make_case download-failure
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
    signal_specs='head TERM 143
download TERM 143
download INT 130'
    old_ifs="$IFS"
    IFS='
'
    for signal_spec in $signal_specs; do
        IFS="$old_ifs"
        set -- $signal_spec
        block_phase="$1"
        signal_name="$2"
        expected_status="$3"
        make_case "signal-$block_phase-$signal_name"
        printf valid-old >"$case_dir/server/MCXboxBroadcastStandalone.jar"
        printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
        release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
        (
            wait_for_file "$case_dir/curl-ready.log"
            child_pid="$(cat "$case_dir/curl-child.pid")"
            script_pid="$(
                ps -o pid=,ppid= |
                    awk -v target="$child_pid" '$1 == target { print $2 }'
            )"
            [ -n "$script_pid" ] || exit 1
            printf '%s\n' "$script_pid" >"$case_dir/install-script.pid"
            kill -"$signal_name" "$script_pid"
            attempts=0
            while [ "$attempts" -lt 60 ]; do
                kill -0 "$script_pid" 2>/dev/null || exit 0
                sleep 0.05
                attempts=$((attempts + 1))
            done
            : >"$case_dir/signal-timeout.log"
            kill -KILL "$script_pid" 2>/dev/null || :
        ) &
        signaler_pid=$!
        set +e
        MOCK_BLOCK_PHASE="$block_phase" MOCK_RELEASE_URL="$release_url" invoke_install
        status=$?
        set -e
        set +e
        wait "$signaler_pid"
        signaler_status=$?
        set -e
        [ "$signaler_status" -eq 0 ] || fail "$signal_name signal helper failed"
        assert_absent "$case_dir/signal-timeout.log"
        script_pid="$(cat "$case_dir/install-script.pid")"
        child_pid="$(cat "$case_dir/curl-child.pid")"
        child_still_running=0
        if kill -0 "$child_pid" 2>/dev/null; then
            child_still_running=1
            ps -o pid=,ppid=,stat=,args= >&2 || :
            kill -KILL "$child_pid" 2>/dev/null || :
        fi

        [ "$status" -eq "$expected_status" ] ||
            fail "$signal_name exited $status instead of $expected_status"
        [ "$child_still_running" -eq 0 ] || fail "$signal_name left the curl child running"
        assert_file "$case_dir/curl-terminated.log"
        assert_content valid-old "$case_dir/server/MCXboxBroadcastStandalone.jar"
        assert_content old "$case_dir/server/.mcxboxbroadcast-release-url"
        assert_not_contains 'Installation completed.' "$case_dir/install.log"
        assert_default_temps_absent
        IFS='
'
    done
    IFS="$old_ifs"
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

if [ "$requested_case" = all ] || [ "$requested_case" = jar-directory-collision ]; then
    make_case jar-directory-collision
    mkdir -p -- "$case_dir/server/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
    set +e
    MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
        run_install
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail 'a Jar directory destination should fail installation'
    [ -d "$case_dir/server/MCXboxBroadcastStandalone.jar" ] || fail 'Jar directory was changed'
    assert_content old "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_absent "$case_dir/head-url.log"
    assert_absent "$case_dir/download-url.log"
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$case_dir/server/MCXboxBroadcastStandalone.jar/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    assert_not_contains 'Installation completed.' "$case_dir/install.log"
fi

if [ "$requested_case" = all ] || [ "$requested_case" = jar-directory-race ]; then
    make_case jar-directory-race
    printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    set +e
    MOCK_CREATE_JAR_DIR=1 MOCK_RELEASE_URL="$release_url" run_install
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail 'a Jar destination that becomes a directory should fail installation'
    [ -d "$case_dir/server/MCXboxBroadcastStandalone.jar" ] || fail 'racing Jar directory is missing'
    assert_content old "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_content "$release_url" "$case_dir/download-url.log"
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$case_dir/server/MCXboxBroadcastStandalone.jar/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    assert_not_contains 'Installation completed.' "$case_dir/install.log"
fi

if [ "$requested_case" = all ] || [ "$requested_case" = jar-mv-boundary-race ]; then
    make_case jar-mv-boundary-race
    printf '%s\n' old >"$case_dir/server/.mcxboxbroadcast-release-url"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    set +e
    MOCK_CREATE_JAR_DIR_ON_MOVE=1 MOCK_RELEASE_URL="$release_url" run_install
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail 'a Jar directory created at the mv boundary should fail installation'
    [ -d "$case_dir/server/MCXboxBroadcastStandalone.jar" ] || fail 'mv-boundary Jar directory is missing'
    assert_content old "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$case_dir/server/MCXboxBroadcastStandalone.jar/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    assert_not_contains 'Installation completed.' "$case_dir/install.log"
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

if [ "$requested_case" = all ] || [ "$requested_case" = state-directory-collision ]; then
    make_case state-directory-collision
    mkdir -p -- "$case_dir/server/.mcxboxbroadcast-release-url"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    MOCK_RELEASE_URL="$release_url" run_install
    assert_content valid-new "$case_dir/server/MCXboxBroadcastStandalone.jar"
    [ -d "$case_dir/server/.mcxboxbroadcast-release-url" ] || fail 'state directory was changed'
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url/.mcxboxbroadcast-release-url.tmp"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_contains 'Warning: release state could not be saved.' "$case_dir/install.log"
    assert_contains 'Installation completed.' "$case_dir/install.log"
fi

if [ "$requested_case" = all ] || [ "$requested_case" = state-directory-race ]; then
    make_case state-directory-race
    printf old >"$case_dir/server/.mcxboxbroadcast-release-url"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    MOCK_CREATE_STATE_DIR=1 MOCK_RELEASE_URL="$release_url" run_install
    assert_content valid-new "$case_dir/server/MCXboxBroadcastStandalone.jar"
    [ -d "$case_dir/server/.mcxboxbroadcast-release-url" ] || fail 'racing state directory is missing'
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url/.mcxboxbroadcast-release-url.tmp"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_contains 'Warning: release state could not be saved.' "$case_dir/install.log"
    assert_contains 'Installation completed.' "$case_dir/install.log"
fi

if [ "$requested_case" = all ] || [ "$requested_case" = state-directory-fallback ]; then
    make_case state-directory-fallback
    mkdir -p -- "$case_dir/server/.mcxboxbroadcast-release-url"
    set +e
    MOCK_HEAD_FAIL=1 run_install
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail 'official fallback should tolerate a state directory collision'
    assert_content valid-new "$case_dir/server/MCXboxBroadcastStandalone.jar"
    [ -d "$case_dir/server/.mcxboxbroadcast-release-url" ] || fail 'state directory was changed'
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url/.mcxboxbroadcast-release-url.tmp"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_contains 'Warning: release state could not be saved.' "$case_dir/install.log"
    assert_contains 'Installation completed.' "$case_dir/install.log"
fi

if [ "$requested_case" = all ] || [ "$requested_case" = state-mv-boundary-race ]; then
    make_case state-mv-boundary-race
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    set +e
    MOCK_CREATE_STATE_DIR_ON_MOVE=1 MOCK_RELEASE_URL="$release_url" run_install
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail 'state mv-boundary collision should keep the installed Jar usable'
    assert_content valid-new "$case_dir/server/MCXboxBroadcastStandalone.jar"
    [ -d "$case_dir/server/.mcxboxbroadcast-release-url" ] || fail 'mv-boundary state directory is missing'
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url/.mcxboxbroadcast-release-url.tmp"
    assert_absent "$case_dir/server/.mcxboxbroadcast-release-url.tmp"
    assert_absent "$case_dir/server/.MCXboxBroadcastStandalone.jar.download"
    assert_contains 'Warning: release state could not be saved.' "$case_dir/install.log"
    assert_contains 'Installation completed.' "$case_dir/install.log"
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
    download_output="$(cat "$case_dir/download-output.log")"
    case "$download_output" in
        './nested jars/.custom broadcast.jar.download.'*) ;;
        *) fail "configured download temp was not beside the Jar: $download_output" ;;
    esac
    assert_content valid-new "$server_dir/$jar_file"
    assert_content "$release_url" "$server_dir/.mcxboxbroadcast-release-url"
    assert_absent "$server_dir/nested jars/.custom broadcast.jar.download"
    assert_absent "$server_dir/.mcxboxbroadcast-release-url.tmp"
fi

if [ "$requested_case" = all ] || [ "$requested_case" = option-like-path ]; then
    make_case option-like-path
    jar_file='-p/custom.jar'
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    set +e
    TEST_SERVER_JARFILE="$jar_file" MOCK_RELEASE_URL="$release_url" run_install
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail 'option-like relative path installation failed'
    download_output="$(cat "$case_dir/download-output.log")"
    case "$download_output" in
        './-p/.custom.jar.download.'*) ;;
        *) fail "option-like download temp was not safely staged beside the Jar: $download_output" ;;
    esac
    assert_content valid-new "$case_dir/server/$jar_file"
    assert_content "$release_url" "$case_dir/server/.mcxboxbroadcast-release-url"
    assert_default_temps_absent
fi

echo 'installer tests passed'
