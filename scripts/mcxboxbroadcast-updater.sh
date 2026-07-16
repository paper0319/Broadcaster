#!/usr/bin/env bash
set -u

prefix='[MCXboxBroadcast Updater]'
latest_url='https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/MCXboxBroadcastStandalone.jar'
state_file='.mcxboxbroadcast-release-url'
hash_file='.mcxboxbroadcast-release-sha256'
jar_file="${SERVER_JARFILE-MCXboxBroadcastStandalone.jar}"

log() { printf '%s %s\n' "$prefix" "$*"; }

jar_path_is_safe() {
    local path="$1" jar_name
    case "$path" in
        ''|/*|*\\*|*//*|*/|.*|*/.*) return 1 ;;
    esac
    jar_name="${path##*/}"
    [[ "$jar_name" == *.jar && "$jar_name" != '.jar' ]]
}

if ! jar_path_is_safe "$jar_file"; then
    log "Error: unsafe Jar path: $jar_file"
    exit 2
fi
if [[ -d "$jar_file" ]]; then
    log "Error: Jar destination is a directory: $jar_file"
    exit 2
fi

jar_dir="$(dirname -- "$jar_file")"
jar_name="$(basename -- "$jar_file")"
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
    [[ -z "$head_tmp" ]] || rm -f -- "$head_tmp"
    [[ -z "$download_tmp" ]] || rm -f -- "$download_tmp"
    [[ -z "$state_tmp" ]] || rm -f -- "$state_tmp"
    [[ -z "$hash_tmp" ]] || rm -f -- "$hash_tmp"
    if [[ "$lock_fd_open" == 1 ]]; then
        exec 9>&-
        lock_fd_open=0
    fi
}

run_tracked() {
    child_starting=1
    "$@" &
    active_child=$!
    child_starting=0
    if [[ "$pending_signal" != 0 ]]; then
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
    if [[ "$child_starting" == 1 ]]; then
        pending_signal="$signal_status"
        return
    fi
    if [[ -n "$active_child" ]]; then
        kill -TERM "$active_child" 2>/dev/null || :
        wait "$active_child" 2>/dev/null || :
        active_child=''
    fi
    exit "$signal_status"
}

trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

jar_is_valid() {
    [[ -f "$1" ]] && jar tf "$1" >/dev/null 2>&1
}

file_sha256() {
    sha256sum -- "$1" | awk '{print $1}'
}

auto_update_enabled() {
    case "${AUTO_UPDATE:-1}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

if auto_update_enabled; then
    if ! acquire_update_lock; then
        log 'Warning: update lock could not be acquired; keeping the existing Jar.'
    else
        log 'Checking the latest official release...'
        release_url=''
        temp_candidate=''
        if temp_candidate="$(mktemp './.mcxboxbroadcast-head.XXXXXX')"; then
            head_tmp="$temp_candidate"
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
        fi

        if [[ -z "$release_url" ]]; then
            log 'Warning: release check failed; keeping the existing Jar.'
        else
            installed_url=''
            installed_hash=''
            [[ -f "$state_file" ]] && IFS= read -r installed_url <"$state_file"
            [[ -f "$hash_file" ]] && IFS= read -r installed_hash <"$hash_file"
            current_hash=''
            if jar_is_valid "$jar_file"; then
                current_hash="$(file_sha256 "$jar_file")"
            fi

            if [[ "$installed_url" != "$release_url" ]] ||
                [[ -z "$current_hash" ]] ||
                [[ "$installed_hash" != "$current_hash" ]]; then
                temp_candidate=''
                if ! temp_candidate="$(mktemp "./${jar_dir}/.${jar_name}.download.XXXXXX")"; then
                    log 'Warning: download staging could not be created; keeping the existing Jar.'
                else
                    download_tmp="$temp_candidate"
                    temp_candidate=''
                    if [[ ! -d "$state_file" ]] &&
                        ! temp_candidate="$(mktemp './.mcxboxbroadcast-release-url.tmp.XXXXXX')"; then
                        log 'Warning: release-state staging could not be created; keeping the existing Jar.'
                    elif [[ ! -d "$hash_file" ]] &&
                        ! hash_tmp="$(mktemp './.mcxboxbroadcast-release-sha256.tmp.XXXXXX')"; then
                        log 'Warning: release-hash staging could not be created; keeping the existing Jar.'
                    else
                        [[ -d "$state_file" ]] || state_tmp="$temp_candidate"
                        log "Downloading release: $release_url"
                        if run_tracked curl --fail --silent --show-error --location \
                            --retry 3 --retry-delay 2 \
                            --connect-timeout 10 --max-time 180 \
                            --output "$download_tmp" "$release_url"; then
                            if jar_is_valid "$download_tmp"; then
                                download_hash="$(file_sha256 "$download_tmp")"
                                if [[ -d "$jar_file" ]]; then
                                    log 'Warning: Jar destination became a directory; keeping the existing Jar.'
                                elif mv -fT -- "$download_tmp" "$jar_file"; then
                                    download_tmp=''
                                    if [[ -d "$state_file" ]]; then
                                        log 'Warning: Jar updated, but release state could not be saved.'
                                    elif [[ -d "$hash_file" ]]; then
                                        log 'Warning: Jar updated, but release hash could not be saved.'
                                    elif printf '%s\n' "$download_hash" >"$hash_tmp" &&
                                        mv -fT -- "$hash_tmp" "$hash_file"; then
                                        hash_tmp=''
                                        if printf '%s\n' "$release_url" >"$state_tmp" &&
                                            mv -fT -- "$state_tmp" "$state_file"; then
                                            state_tmp=''
                                            log 'Update completed.'
                                        else
                                            log 'Warning: Jar updated, but release state could not be saved.'
                                        fi
                                    else
                                        log 'Warning: Jar updated, but release hash could not be saved.'
                                    fi
                                else
                                    log 'Warning: Jar replacement failed; keeping the existing Jar.'
                                fi
                            else
                                log 'Warning: downloaded file is not a valid Jar; keeping the existing Jar.'
                            fi
                        else
                            log 'Warning: download failed; keeping the existing Jar.'
                        fi
                    fi
                fi
            else
                log 'Already up to date.'
            fi
        fi
    fi
else
    log 'Automatic updates are disabled.'
fi

if ! jar_is_valid "$jar_file"; then
    log "Error: no valid Jar is available at $jar_file"
    exit 1
fi

cleanup
trap - EXIT INT TERM
max_memory="${SERVER_MEMORY:-0}"
case "$max_memory" in
    0) max_memory=1028 ;;
    ''|*[!0-9]*)
        log "Warning: invalid SERVER_MEMORY value '$max_memory'; using 1028 MB."
        max_memory=1028
        ;;
esac
exec java -Xms128M "-Xmx${max_memory}M" -jar "$jar_file"
