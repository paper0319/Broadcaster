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
wait_for_file() {
    local file="$1"
    for _ in {1..100}; do
        [[ -e "$file" ]] && return 0
        sleep 0.05
    done
    fail "timed out waiting for file: $file"
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
    leftover="$(
        find "$CASE_DIR" -type f \
            \( -name '.mcxboxbroadcast-head.*' \
            -o -name '.*.download.*' \
            -o -name '.mcxboxbroadcast-release-url.tmp.*' \) \
            -print -quit
    )"
    [[ -z "$leftover" ]] || fail "transient file was not cleaned: $leftover"
}

make_case() {
    local name="$1"
    CASE_DIR="$work_root/$name"
    mkdir -p "$CASE_DIR/bin"

    cat >"$CASE_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_SIGNAL_ON_START:-}" ]]; then
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
echo "$*" >>"$MOCK_ROOT/curl.log"
args="$*"
output=""
while (($#)); do
    if [[ "$1" == "--output" ]]; then output="$2"; break; fi
    shift
done
[[ -n "$output" ]] || exit 2
if [[ "$args" == *"-fsSI"* ]]; then
    printf '%s\n' "$output" >>"$MOCK_ROOT/head-output.log"
    if [[ "${MOCK_CONCURRENT_RELEASES:-0}" == "1" ]]; then
        : >"$MOCK_ROOT/${MOCK_RUN_ID}.head-ready"
        for _ in {1..40}; do
            [[ -e "$MOCK_ROOT/A.head-ready" && -e "$MOCK_ROOT/B.head-ready" ]] && break
            sleep 0.05
        done
    fi
    if [[ "${MOCK_BLOCK_PHASE:-}" == head ]]; then
        printf '%s\n' "$$" >"$MOCK_ROOT/curl-child.pid"
        : >"$MOCK_ROOT/curl-ready.log"
        terminate_blocked_curl() {
            printf 'terminated\n' >"$MOCK_ROOT/curl-terminated.log"
            exit 99
        }
        trap terminate_blocked_curl TERM INT
        while :; do sleep 1; done
    fi
    [[ "${MOCK_HEAD_FAIL:-0}" == "1" ]] && exit 22
    if [[ "${MOCK_HEAD_PARTIAL_FAIL:-0}" == "1" ]]; then
        printf 'HTTP/2 302\r\nlocation: %s\r\n\r\n' "$MOCK_RELEASE_URL" >"$output"
        exit 22
    fi
    printf 'HTTP/2 302\r\nlocation: %s\r\n\r\n' "$MOCK_RELEASE_URL" >"$output"
    exit 0
fi
[[ "${MOCK_DOWNLOAD_FAIL:-0}" == "1" ]] && exit 22
printf '%s\n' "$output" >>"$MOCK_ROOT/download-output.log"
if [[ "${MOCK_BLOCK_PHASE:-}" == download ]]; then
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
printf '%s' "${MOCK_DOWNLOAD_CONTENT:-valid-new}" >"$output"
if [[ "${MOCK_CREATE_JAR_DIR:-0}" == "1" ]]; then
    mkdir -p -- "$MOCK_JAR_DEST"
fi
if [[ "${MOCK_CREATE_STATE_DIR:-0}" == "1" ]]; then
    rm -f -- .mcxboxbroadcast-release-url
    mkdir -p -- .mcxboxbroadcast-release-url
fi
MOCK

    cat >"$CASE_DIR/bin/jar" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "tf" ]] || exit 2
[[ -f "$2" ]] || exit 1
[[ "$(cat -- "$2")" == valid-* ]]
MOCK

    cat >"$CASE_DIR/bin/mv" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
destination="${!#}"
source_index=$(($# - 1))
source="${!source_index}"
printf '%s\n' "$*" >>"$MOCK_ROOT/mv.log"
if [[ "$destination" == '.mcxboxbroadcast-release-url' ]]; then
    printf '%s\n' "$source" >>"$MOCK_ROOT/state-temp.log"
fi
if [[ "${MOCK_REPLACE_FAIL:-0}" == "1" && "$destination" == "$MOCK_JAR_DEST" ]]; then
    exit 1
fi
if [[ "${MOCK_CREATE_JAR_DIR_ON_MOVE:-0}" == "1" && "$destination" == "$MOCK_JAR_DEST" ]]; then
    mkdir -p -- "$destination"
fi
if [[ "${MOCK_CREATE_STATE_DIR_ON_MOVE:-0}" == "1" && "$destination" == '.mcxboxbroadcast-release-url' ]]; then
    mkdir -p -- "$destination"
fi
if [[ "${MOCK_CONCURRENT_RELEASES:-0}" == "1" ]]; then
    wait_for_marker() {
        local marker="$1"
        for _ in {1..40}; do
            [[ -e "$marker" ]] && return 0
            sleep 0.05
        done
        return 0
    }
    if [[ "$destination" == "$MOCK_JAR_DEST" ]]; then
        [[ "$MOCK_RUN_ID" != A ]] || wait_for_marker "$MOCK_ROOT/B.jar-moved"
        /bin/mv "$@"
        : >"$MOCK_ROOT/${MOCK_RUN_ID}.jar-moved"
        exit 0
    fi
    if [[ "$destination" == '.mcxboxbroadcast-release-url' ]]; then
        [[ "$MOCK_RUN_ID" != B ]] || wait_for_marker "$MOCK_ROOT/A.state-moved"
        /bin/mv "$@"
        : >"$MOCK_ROOT/${MOCK_RUN_ID}.state-moved"
        exit 0
    fi
fi
exec /bin/mv "$@"
MOCK

    cat >"$CASE_DIR/bin/java" <<'MOCK'
#!/usr/bin/env bash
[[ ! -e /proc/$$/fd/9 ]] || : >"$MOCK_ROOT/lock-fd-inherited.log"
printf '%s\n' "$@" >"$MOCK_ROOT/java.log"
MOCK

    cat >"$CASE_DIR/bin/flock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${MOCK_FLOCK_FAIL:-0}" != "1" ]] || exit 1
exec /usr/bin/flock "$@"
MOCK

    cat >"$CASE_DIR/bin/mktemp" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
template="${!#}"
printf '%s\n' "$template" >>"$MOCK_ROOT/mktemp.log"
if [[ -n "${MOCK_MKTEMP_FAIL_PATTERN:-}" && "$template" == *"$MOCK_MKTEMP_FAIL_PATTERN"* ]]; then
    exit 1
fi
exec /usr/bin/mktemp "$@"
MOCK

    chmod +x "$CASE_DIR/bin/"*
}

start_updater() {
    (
        cd "$CASE_DIR"
        trap - INT TERM
        exec env \
            PATH="$CASE_DIR/bin:$PATH" \
            MOCK_ROOT="$CASE_DIR" \
            MOCK_RELEASE_URL="${MOCK_RELEASE_URL:-}" \
            MOCK_HEAD_FAIL="${MOCK_HEAD_FAIL:-0}" \
            MOCK_HEAD_PARTIAL_FAIL="${MOCK_HEAD_PARTIAL_FAIL:-0}" \
            MOCK_DOWNLOAD_FAIL="${MOCK_DOWNLOAD_FAIL:-0}" \
            MOCK_DOWNLOAD_CONTENT="${MOCK_DOWNLOAD_CONTENT:-valid-new}" \
            MOCK_CONCURRENT_RELEASES="${MOCK_CONCURRENT_RELEASES:-0}" \
            MOCK_RUN_ID="${MOCK_RUN_ID:-single}" \
            MOCK_BLOCK_PHASE="${MOCK_BLOCK_PHASE:-}" \
            MOCK_SIGNAL_ON_START="${MOCK_SIGNAL_ON_START:-}" \
            MOCK_CREATE_JAR_DIR="${MOCK_CREATE_JAR_DIR:-0}" \
            MOCK_CREATE_STATE_DIR="${MOCK_CREATE_STATE_DIR:-0}" \
            MOCK_CREATE_JAR_DIR_ON_MOVE="${MOCK_CREATE_JAR_DIR_ON_MOVE:-0}" \
            MOCK_CREATE_STATE_DIR_ON_MOVE="${MOCK_CREATE_STATE_DIR_ON_MOVE:-0}" \
            MOCK_MKTEMP_FAIL_PATTERN="${MOCK_MKTEMP_FAIL_PATTERN:-}" \
            MOCK_REPLACE_FAIL="${MOCK_REPLACE_FAIL:-0}" \
            MOCK_FLOCK_FAIL="${MOCK_FLOCK_FAIL:-0}" \
            MOCK_JAR_DEST="${TEST_SERVER_JARFILE-MCXboxBroadcastStandalone.jar}" \
            AUTO_UPDATE="${AUTO_UPDATE-1}" \
            SERVER_JARFILE="${TEST_SERVER_JARFILE-MCXboxBroadcastStandalone.jar}" \
            bash "$repo_root/scripts/mcxboxbroadcast-updater.sh" \
            >"$CASE_DIR/updater.log" 2>&1
    ) &
    UPDATER_PID=$!
}

run_updater() {
    start_updater
    wait "$UPDATER_PID"
}

case "$requested_case" in
    all|concurrent-release-pair|lock-failure|signal-at-child-start|unsafe-jar-names|legacy-temp-symlinks|unique-temp-names|mktemp-failure|jar-directory-collision|jar-directory-race|jar-mv-boundary-race|state-directory-collision|state-directory-race|state-mv-boundary-race|partial-head-failure|replacement-failure|signal-during-update|failure-cleanup|configured-path|option-like-path|missing-state|missing-jar) ;;
    *) fail "unknown test case: $requested_case" ;;
esac

if [[ "$requested_case" == all || "$requested_case" == concurrent-release-pair ]]; then
    make_case concurrent-release-pair
    printf valid-base >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' base >"$CASE_DIR/.mcxboxbroadcast-release-url"
    old_url='https://github.com/example/releases/download/old/MCXboxBroadcastStandalone.jar'
    new_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'

    MOCK_CONCURRENT_RELEASES=1 MOCK_RUN_ID=A \
        MOCK_RELEASE_URL="$old_url" MOCK_DOWNLOAD_CONTENT=valid-old-release \
        start_updater
    updater_a_pid=$UPDATER_PID
    MOCK_CONCURRENT_RELEASES=1 MOCK_RUN_ID=B \
        MOCK_RELEASE_URL="$new_url" MOCK_DOWNLOAD_CONTENT=valid-new-release \
        start_updater
    updater_b_pid=$UPDATER_PID
    wait "$updater_a_pid"
    wait "$updater_b_pid"

    installed_url="$(cat "$CASE_DIR/.mcxboxbroadcast-release-url")"
    case "$installed_url" in
        "$old_url") assert_content valid-old-release "$CASE_DIR/MCXboxBroadcastStandalone.jar" ;;
        "$new_url") assert_content valid-new-release "$CASE_DIR/MCXboxBroadcastStandalone.jar" ;;
        *) fail "unexpected concurrent release state: $installed_url" ;;
    esac
    assert_absent "$CASE_DIR/.mcxboxbroadcast-update.lock"
    (
        cd "$CASE_DIR"
        exec 8<.
        flock -n 8
    ) || fail 'updater transaction lock was not released'
    assert_absent "$CASE_DIR/lock-fd-inherited.log"
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == lock-failure ]]; then
    make_case lock-failure
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    MOCK_FLOCK_FAIL=1 \
        MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
        run_updater
    assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_absent "$CASE_DIR/curl.log"
    assert_contains 'Warning: update lock could not be acquired; keeping the existing Jar.' "$CASE_DIR/updater.log"
    assert_absent "$CASE_DIR/.mcxboxbroadcast-update.lock"
    assert_absent "$CASE_DIR/lock-fd-inherited.log"
    assert_java_args 'MCXboxBroadcastStandalone.jar'
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == signal-at-child-start ]]; then
    for signal_spec in 'TERM 143' 'INT 130'; do
        read -r signal_name expected_status <<<"$signal_spec"
        make_case "signal-at-child-start-${signal_name,,}"
        printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
        printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
        MOCK_SIGNAL_ON_START="$signal_name" start_updater
        script_pid="$UPDATER_PID"

        stopped=0
        for _ in {1..60}; do
            process_state="$(ps -o stat= -p "$script_pid" 2>/dev/null || :)"
            if [[ -z "$process_state" || "$process_state" == Z* ]]; then
                stopped=1
                break
            fi
            sleep 0.05
        done
        [[ "$stopped" == 1 ]] || kill -KILL "$script_pid" 2>/dev/null || :
        set +e
        wait "$script_pid"
        status=$?
        set -e
        wait_for_file "$CASE_DIR/curl-child.pid"
        child_pid="$(cat "$CASE_DIR/curl-child.pid")"
        child_still_running=0
        if kill -0 "$child_pid" 2>/dev/null; then
            child_still_running=1
            kill -KILL "$child_pid" 2>/dev/null || :
        fi

        [[ "$stopped" == 1 ]] || fail "$signal_name at child start did not stop the updater promptly"
        [[ "$status" == "$expected_status" ]] ||
            fail "$signal_name at child start exited $status instead of $expected_status"
        [[ "$child_still_running" == 0 ]] || fail "$signal_name at child start left curl running"
        assert_file "$CASE_DIR/curl-terminated.log"
        assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"
        assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
        assert_absent "$CASE_DIR/java.log"
        assert_not_contains 'Update completed.' "$CASE_DIR/updater.log"
        assert_default_temps_absent
    done
fi

if [[ "$requested_case" == all || "$requested_case" == unsafe-jar-names ]]; then
    unsafe_names=(
        ''
        '.'
        'config.yml'
        '.mcxboxbroadcast-release-url'
        '.hidden.jar'
        'not-a-jar'
        '/tmp/evil.jar'
        '../evil.jar'
        'nested/../evil.jar'
        'nested/./evil.jar'
    )
    index=0
    for unsafe_name in "${unsafe_names[@]}"; do
        make_case "unsafe-jar-name-$index"
        printf config-data >"$CASE_DIR/config.yml"
        printf auth-data >"$CASE_DIR/auth.json"
        printf session-data >"$CASE_DIR/session.dat"
        printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
        set +e
        TEST_SERVER_JARFILE="$unsafe_name" \
            MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
            run_updater
        status=$?
        set -e
        [[ "$status" -ne 0 ]] || fail "unsafe Jar name was accepted: <$unsafe_name>"
        assert_absent "$CASE_DIR/curl.log"
        assert_absent "$CASE_DIR/java.log"
        assert_content config-data "$CASE_DIR/config.yml"
        assert_content auth-data "$CASE_DIR/auth.json"
        assert_content session-data "$CASE_DIR/session.dat"
        assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
        index=$((index + 1))
    done
fi

if [[ "$requested_case" == all || "$requested_case" == mktemp-failure ]]; then
    for failure_pattern in head download release-url.tmp; do
        make_case "mktemp-failure-$failure_pattern"
        printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
        printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
        release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
        MOCK_MKTEMP_FAIL_PATTERN="$failure_pattern" MOCK_RELEASE_URL="$release_url" run_updater
        assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"
        assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
        assert_java_args 'MCXboxBroadcastStandalone.jar'
        if [[ "$failure_pattern" == head ]]; then
            assert_absent "$CASE_DIR/curl.log"
        else
            [[ "$(wc -l <"$CASE_DIR/curl.log")" -eq 1 ]] ||
                fail "$failure_pattern mktemp failure reached the download request"
        fi
        assert_default_temps_absent
    done
fi

if [[ "$requested_case" == all || "$requested_case" == unique-temp-names ]]; then
    make_case successive-unique-temps
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    for _ in 1 2; do
        printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
        printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
        MOCK_RELEASE_URL="$release_url" run_updater
    done
    mapfile -t successive_heads <"$CASE_DIR/head-output.log"
    mapfile -t successive_downloads <"$CASE_DIR/download-output.log"
    mapfile -t successive_states <"$CASE_DIR/state-temp.log"
    [[ "${#successive_heads[@]}" -eq 2 && "${successive_heads[0]}" != "${successive_heads[1]}" ]] ||
        fail 'successive HEAD temp names were not distinct'
    [[ "${#successive_downloads[@]}" -eq 2 && "${successive_downloads[0]}" != "${successive_downloads[1]}" ]] ||
        fail 'successive download temp names were not distinct'
    [[ "${#successive_states[@]}" -eq 2 && "${successive_states[0]}" != "${successive_states[1]}" ]] ||
        fail 'successive state temp names were not distinct'
    assert_default_temps_absent

    make_case concurrent-unique-temps
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    MOCK_RELEASE_URL="$release_url" run_updater &
    first_pid=$!
    MOCK_RELEASE_URL="$release_url" run_updater &
    second_pid=$!
    wait "$first_pid"
    wait "$second_pid"
    mapfile -t concurrent_heads <"$CASE_DIR/head-output.log"
    mapfile -t concurrent_downloads <"$CASE_DIR/download-output.log"
    mapfile -t concurrent_states <"$CASE_DIR/state-temp.log"
    [[ "${#concurrent_heads[@]}" -eq 2 && "${concurrent_heads[0]}" != "${concurrent_heads[1]}" ]] ||
        fail 'concurrent HEAD temp names were not distinct'
    [[ "${#concurrent_downloads[@]}" -eq 1 ]] ||
        fail 'serialized concurrent updater should download exactly once'
    [[ "${#concurrent_states[@]}" -eq 1 ]] ||
        fail 'serialized concurrent updater should stage state exactly once'
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == legacy-temp-symlinks ]]; then
    make_case legacy-temp-symlinks
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    printf config-data >"$CASE_DIR/config.yml"
    printf auth-data >"$CASE_DIR/auth.json"
    printf session-data >"$CASE_DIR/session.dat"
    ln -s config.yml "$CASE_DIR/.MCXboxBroadcastStandalone.jar.download"
    ln -s auth.json "$CASE_DIR/.mcxboxbroadcast-release-url.tmp"
    ln -s session.dat "$CASE_DIR/.mcxboxbroadcast-head.headers"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    MOCK_RELEASE_URL="$release_url" run_updater
    assert_content valid-new "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    assert_content "$release_url" "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_content config-data "$CASE_DIR/config.yml"
    assert_content auth-data "$CASE_DIR/auth.json"
    assert_content session-data "$CASE_DIR/session.dat"
    [[ -L "$CASE_DIR/.MCXboxBroadcastStandalone.jar.download" ]] || fail 'legacy download symlink was removed'
    [[ -L "$CASE_DIR/.mcxboxbroadcast-release-url.tmp" ]] || fail 'legacy state symlink was removed'
    [[ -L "$CASE_DIR/.mcxboxbroadcast-head.headers" ]] || fail 'legacy HEAD symlink was removed'
    assert_java_args 'MCXboxBroadcastStandalone.jar'
fi

if [[ "$requested_case" == all || "$requested_case" == state-mv-boundary-race ]]; then
    make_case state-mv-boundary-race
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    MOCK_CREATE_STATE_DIR_ON_MOVE=1 MOCK_RELEASE_URL="$release_url" run_updater
    assert_content valid-new "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    [[ -d "$CASE_DIR/.mcxboxbroadcast-release-url" ]] || fail 'mv-boundary state directory is missing'
    assert_absent "$CASE_DIR/.mcxboxbroadcast-release-url/.mcxboxbroadcast-release-url.tmp"
    assert_contains 'Warning: Jar updated, but release state could not be saved.' "$CASE_DIR/updater.log"
    assert_not_contains 'Update completed.' "$CASE_DIR/updater.log"
    assert_java_args 'MCXboxBroadcastStandalone.jar'
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == state-directory-collision ]]; then
    make_case state-directory-collision
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    mkdir -p "$CASE_DIR/.mcxboxbroadcast-release-url"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    MOCK_RELEASE_URL="$release_url" run_updater
    assert_content valid-new "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    [[ -d "$CASE_DIR/.mcxboxbroadcast-release-url" ]] || fail 'state directory was changed'
    assert_absent "$CASE_DIR/.mcxboxbroadcast-release-url/.mcxboxbroadcast-release-url.tmp"
    assert_contains 'Warning: Jar updated, but release state could not be saved.' "$CASE_DIR/updater.log"
    assert_not_contains 'Update completed.' "$CASE_DIR/updater.log"
    assert_java_args 'MCXboxBroadcastStandalone.jar'
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == state-directory-race ]]; then
    make_case state-directory-race
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    MOCK_CREATE_STATE_DIR=1 MOCK_RELEASE_URL="$release_url" run_updater
    assert_content valid-new "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    [[ -d "$CASE_DIR/.mcxboxbroadcast-release-url" ]] || fail 'racing state directory is missing'
    assert_absent "$CASE_DIR/.mcxboxbroadcast-release-url/.mcxboxbroadcast-release-url.tmp"
    assert_contains 'Warning: Jar updated, but release state could not be saved.' "$CASE_DIR/updater.log"
    assert_not_contains 'Update completed.' "$CASE_DIR/updater.log"
    assert_java_args 'MCXboxBroadcastStandalone.jar'
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == jar-mv-boundary-race ]]; then
    make_case jar-mv-boundary-race
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    set +e
    MOCK_CREATE_JAR_DIR_ON_MOVE=1 MOCK_RELEASE_URL="$release_url" run_updater
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail 'a Jar directory created at the mv boundary should stop startup'
    [[ -d "$CASE_DIR/MCXboxBroadcastStandalone.jar" ]] || fail 'mv-boundary Jar directory is missing'
    assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_absent "$CASE_DIR/MCXboxBroadcastStandalone.jar/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$CASE_DIR/java.log"
    assert_not_contains 'Update completed.' "$CASE_DIR/updater.log"
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == jar-directory-race ]]; then
    make_case jar-directory-race
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
    set +e
    MOCK_CREATE_JAR_DIR=1 MOCK_RELEASE_URL="$release_url" run_updater
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail 'a Jar destination that becomes a directory should stop startup'
    [[ -d "$CASE_DIR/MCXboxBroadcastStandalone.jar" ]] || fail 'racing Jar directory is missing'
    assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_absent "$CASE_DIR/MCXboxBroadcastStandalone.jar/.MCXboxBroadcastStandalone.jar.download"
    assert_absent "$CASE_DIR/java.log"
    assert_not_contains 'Update completed.' "$CASE_DIR/updater.log"
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == jar-directory-collision ]]; then
    make_case jar-directory-collision
    mkdir -p "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    set +e
    MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' run_updater
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail 'a Jar directory destination should stop startup'
    [[ -d "$CASE_DIR/MCXboxBroadcastStandalone.jar" ]] || fail 'Jar directory was changed'
    assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_absent "$CASE_DIR/curl.log"
    assert_absent "$CASE_DIR/java.log"
    assert_absent "$CASE_DIR/MCXboxBroadcastStandalone.jar/.MCXboxBroadcastStandalone.jar.download"
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == partial-head-failure ]]; then
    make_case partial-head-failure
    printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    untrusted_url='https://github.com/example/releases/download/untrusted/MCXboxBroadcastStandalone.jar'
    MOCK_HEAD_PARTIAL_FAIL=1 MOCK_RELEASE_URL="$untrusted_url" run_updater
    assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"
    assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
    [[ "$(wc -l <"$CASE_DIR/curl.log")" -eq 1 ]] || fail 'partial failed HEAD triggered a download'
    assert_java_args 'MCXboxBroadcastStandalone.jar'
    assert_default_temps_absent
fi

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
    signal_specs=(
        'head TERM 143'
        'download TERM 143'
        'download INT 130'
    )
    for signal_spec in "${signal_specs[@]}"; do
        read -r block_phase signal_name expected_status <<<"$signal_spec"
        make_case "signal-$block_phase-${signal_name,,}"
        printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
        printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
        release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
        MOCK_BLOCK_PHASE="$block_phase" MOCK_RELEASE_URL="$release_url" start_updater
        script_pid="$UPDATER_PID"
        wait_for_file "$CASE_DIR/curl-ready.log"
        child_pid="$(cat "$CASE_DIR/curl-child.pid")"
        kill -0 "$child_pid" 2>/dev/null || fail 'blocked curl child was not running'
        kill -"$signal_name" "$script_pid"

        stopped=0
        for _ in {1..60}; do
            process_state="$(ps -o stat= -p "$script_pid" 2>/dev/null || :)"
            if [[ -z "$process_state" || "$process_state" == Z* ]]; then
                stopped=1
                break
            fi
            sleep 0.05
        done
        if [[ "$stopped" -ne 1 ]]; then
            kill -KILL "$script_pid" 2>/dev/null || :
        fi
        set +e
        wait "$script_pid"
        status=$?
        set -e
        child_still_running=0
        if kill -0 "$child_pid" 2>/dev/null; then
            child_still_running=1
            ps -o pid=,ppid=,stat=,args= -p "$child_pid" >&2 || :
            kill -KILL "$child_pid" 2>/dev/null || :
        fi

        [[ "$stopped" -eq 1 ]] || fail "$signal_name did not stop the updater promptly"
        [[ "$status" -eq "$expected_status" ]] ||
            fail "$signal_name exited $status instead of $expected_status"
        [[ "$child_still_running" -eq 0 ]] || fail "$signal_name left the curl child running"
        assert_file "$CASE_DIR/curl-terminated.log"
        assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"
        assert_content old "$CASE_DIR/.mcxboxbroadcast-release-url"
        assert_absent "$CASE_DIR/java.log"
        assert_not_contains 'Update completed.' "$CASE_DIR/updater.log"
        assert_default_temps_absent
    done
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
    if ! TEST_SERVER_JARFILE="$jar_path" \
        MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
        run_updater; then
        cat "$CASE_DIR/updater.log" >&2
        fail 'configured subdirectory update failed'
    fi
    download_output="$(cat "$CASE_DIR/download-output.log")"
    [[ "$download_output" == './server files/.custom broadcast.jar.download.'* ]] ||
        fail "configured download temp was not beside the Jar: $download_output"
    assert_content valid-new "$CASE_DIR/$jar_path"
    assert_content 'https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' "$CASE_DIR/.mcxboxbroadcast-release-url"
    assert_java_args "$jar_path"
    assert_default_temps_absent
fi

if [[ "$requested_case" == all || "$requested_case" == option-like-path ]]; then
    make_case option-like-path
    jar_path='-p/custom.jar'
    mkdir -p -- "$CASE_DIR/-p"
    printf valid-old >"$CASE_DIR/$jar_path"
    printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
    if ! TEST_SERVER_JARFILE="$jar_path" \
        MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' \
        run_updater; then
        cat "$CASE_DIR/updater.log" >&2
        fail 'option-like relative path update failed'
    fi
    download_output="$(cat "$CASE_DIR/download-output.log")"
    [[ "$download_output" == './-p/.custom.jar.download.'* ]] ||
        fail "option-like download temp was not safely staged beside the Jar: $download_output"
    assert_content valid-new "$CASE_DIR/$jar_path"
    assert_java_args "$jar_path"
    assert_default_temps_absent
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
assert_absent "$CASE_DIR/.mcxboxbroadcast-update.lock"
assert_java_args 'MCXboxBroadcastStandalone.jar'
assert_default_temps_absent

make_case unchanged
printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
printf '%s\n' 'https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' >"$CASE_DIR/.mcxboxbroadcast-release-url"
MOCK_RELEASE_URL='https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' run_updater
[[ "$(wc -l <"$CASE_DIR/curl.log")" -eq 1 ]] || fail "unchanged release downloaded"
assert_contains '-fsSI --retry 3 --retry-delay 2' "$CASE_DIR/curl.log"
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
