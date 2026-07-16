#!/bin/ash
set -u

prefix='[MCXboxBroadcast Installer]'
latest_url='https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/MCXboxBroadcastStandalone.jar'
server_dir="${SERVER_DIR:-/mnt/server}"
jar_file="${SERVER_JARFILE-MCXboxBroadcastStandalone.jar}"
state_file='.mcxboxbroadcast-release-url'
hash_file='.mcxboxbroadcast-release-sha256'

log() {
    printf '%s %s\n' "$prefix" "$*"
}

jar_path_is_safe() {
    path="$1"
    case "$path" in
        ''|/*|*\\*|*//*|*/|.*|*/.*) return 1 ;;
    esac
    jar_name="${path##*/}"
    case "$jar_name" in
        *.jar) [ "$jar_name" != '.jar' ] ;;
        *) return 1 ;;
    esac
}

if ! jar_path_is_safe "$jar_file"; then
    log "Error: unsafe Jar path: $jar_file"
    exit 2
fi

mkdir -p -- "$server_dir" || exit 1
cd -- "$server_dir" || exit 1

jar_dir="$(dirname -- "$jar_file")" || exit 1
jar_name="$(basename -- "$jar_file")" || exit 1
head_tmp=''
download_tmp=''
state_tmp=''
hash_tmp=''
temp_candidate=''
active_child=''
child_starting=0
pending_signal=0
lock_fd_open=0

cleanup() {
    [ -z "$head_tmp" ] || rm -f -- "$head_tmp"
    [ -z "$download_tmp" ] || rm -f -- "$download_tmp"
    [ -z "$state_tmp" ] || rm -f -- "$state_tmp"
    [ -z "$hash_tmp" ] || rm -f -- "$hash_tmp"
    if [ "$lock_fd_open" = 1 ]; then
        exec 9>&-
        lock_fd_open=0
    fi
}

run_tracked() {
    child_starting=1
    "$@" &
    active_child=$!
    child_starting=0
    if [ "$pending_signal" != 0 ]; then
        signal_status="$pending_signal"
        pending_signal=0
        kill -TERM "$active_child" 2>/dev/null || :
        wait "$active_child" 2>/dev/null || :
        active_child=''
        exit "$signal_status"
    fi
    wait "$active_child"
    child_status=$?
    active_child=''
    return "$child_status"
}

acquire_update_lock() {
    if ! exec 9<.; then
        return 1
    fi
    lock_fd_open=1
    if ! run_tracked flock -x 9; then
        exec 9>&-
        lock_fd_open=0
        return 1
    fi
}

handle_signal() {
    signal_status="$1"
    trap - INT TERM
    if [ "$child_starting" = 1 ]; then
        pending_signal="$signal_status"
        return
    fi
    if [ -n "$active_child" ]; then
        kill -TERM "$active_child" 2>/dev/null || :
        wait "$active_child" 2>/dev/null || :
        active_child=''
    fi
    exit "$signal_status"
}

trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

if ! mkdir -p -- "$jar_dir"; then
    log "Error: could not create the Jar directory: $jar_dir"
    exit 1
fi
if [ -d "$jar_file" ]; then
    log "Error: Jar destination is a directory: $jar_file"
    exit 1
fi

if ! acquire_update_lock; then
    log 'Error: update lock could not be acquired.'
    exit 1
fi

temp_candidate=''
if ! temp_candidate="$(mktemp './.mcxboxbroadcast-head.XXXXXX')"; then
    log 'Error: HEAD staging could not be created.'
    exit 1
fi
head_tmp="$temp_candidate"

release_url=''
if run_tracked curl -fsSI --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 30 \
    --output "$head_tmp" "$latest_url" 2>/dev/null; then
    release_url="$(
        awk 'tolower($1) == "location:" { gsub("\r", "", $2); print $2; exit }' \
            "$head_tmp"
    )"
fi
rm -f -- "$head_tmp"
head_tmp=''
download_url="${release_url:-$latest_url}"

temp_candidate=''
if ! temp_candidate="$(mktemp "./${jar_dir}/.${jar_name}.download.XXXXXX")"; then
    log 'Error: download staging could not be created.'
    exit 1
fi
download_tmp="$temp_candidate"

if [ -n "$release_url" ] && [ ! -d "$state_file" ]; then
    temp_candidate=''
    if ! temp_candidate="$(mktemp './.mcxboxbroadcast-release-url.tmp.XXXXXX')"; then
        log 'Error: release-state staging could not be created.'
        exit 1
    fi
    state_tmp="$temp_candidate"
fi
if [ -n "$release_url" ] && [ ! -d "$hash_file" ]; then
    temp_candidate=''
    if ! temp_candidate="$(mktemp './.mcxboxbroadcast-release-sha256.tmp.XXXXXX')"; then
        log 'Error: release-hash staging could not be created.'
        exit 1
    fi
    hash_tmp="$temp_candidate"
fi

log "Downloading $download_url"
if ! run_tracked curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 180 \
    --output "$download_tmp" "$download_url"; then
    log 'Error: download failed.'
    exit 1
fi
[ -s "$download_tmp" ] || {
    log 'Error: downloaded Jar is empty.'
    exit 1
}
download_hash="$(sha256sum -- "$download_tmp" | awk '{print $1}')"
if [ -d "$jar_file" ]; then
    log "Error: Jar destination became a directory: $jar_file"
    exit 1
fi
if ! mv -fT -- "$download_tmp" "$jar_file"; then
    log 'Error: Jar replacement failed.'
    exit 1
fi
download_tmp=''

if [ -n "$release_url" ]; then
    if [ -d "$hash_file" ] ||
        ! printf '%s\n' "$download_hash" >"$hash_tmp" ||
        ! mv -fT -- "$hash_tmp" "$hash_file"; then
        log 'Warning: release hash could not be saved.'
    else
        hash_tmp=''
    fi
    if [ -d "$state_file" ] ||
        ! printf '%s\n' "$release_url" >"$state_tmp" ||
        ! mv -fT -- "$state_tmp" "$state_file"; then
        log 'Warning: release state could not be saved.'
    else
        state_tmp=''
    fi
elif [ -d "$state_file" ] || [ -d "$hash_file" ]; then
    log 'Warning: release state could not be saved.'
elif ! rm -f -- "$state_file" "$hash_file"; then
    log 'Error: stale release state could not be removed.'
    exit 1
fi
log 'Installation completed.'
