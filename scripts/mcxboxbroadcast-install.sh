#!/bin/ash
set -u

prefix='[MCXboxBroadcast Installer]'
latest_url='https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/MCXboxBroadcastStandalone.jar'
server_dir="${SERVER_DIR:-/mnt/server}"
jar_file="${SERVER_JARFILE:-MCXboxBroadcastStandalone.jar}"
state_file='.mcxboxbroadcast-release-url'
state_tmp="${state_file}.tmp"

log() {
    printf '%s %s\n' "$prefix" "$*"
}

mkdir -p -- "$server_dir" || exit 1
cd -- "$server_dir" || exit 1

jar_dir="$(dirname -- "$jar_file")" || exit 1
jar_name="$(basename -- "$jar_file")" || exit 1
download_tmp="${jar_dir}/.${jar_name}.download"

cleanup() {
    rm -f -- "$download_tmp" "$state_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cleanup

if ! mkdir -p -- "$jar_dir"; then
    log "Error: could not create the Jar directory: $jar_dir"
    exit 1
fi
if [ -d "$jar_file" ]; then
    log "Error: Jar destination is a directory: $jar_file"
    exit 1
fi

head_output=''
release_url=''
if head_output="$(
    curl -fsSI --retry 3 --retry-delay 2 \
        --connect-timeout 10 --max-time 30 "$latest_url" 2>/dev/null
)"; then
    release_url="$(
        printf '%s\n' "$head_output" |
            awk 'tolower($1) == "location:" { gsub("\r", "", $2); print $2; exit }'
    )"
fi
download_url="${release_url:-$latest_url}"

log "Downloading $download_url"
if ! curl --fail --silent --show-error --location \
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
if [ -d "$jar_file" ]; then
    log "Error: Jar destination became a directory: $jar_file"
    exit 1
fi
if ! mv -fT -- "$download_tmp" "$jar_file"; then
    log 'Error: Jar replacement failed.'
    exit 1
fi
if [ -n "$release_url" ]; then
    if ! printf '%s\n' "$release_url" >"$state_tmp" ||
        [ -d "$state_file" ] ||
        ! mv -fT -- "$state_tmp" "$state_file"; then
        log 'Warning: release state could not be saved.'
    fi
elif [ -d "$state_file" ]; then
    log 'Warning: release state could not be saved.'
elif ! rm -f -- "$state_file"; then
    log 'Error: stale release state could not be removed.'
    exit 1
fi
log 'Installation completed.'
