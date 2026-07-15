#!/usr/bin/env bash
set -u

prefix='[MCXboxBroadcast Updater]'
latest_url='https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/MCXboxBroadcastStandalone.jar'
state_file='.mcxboxbroadcast-release-url'
state_tmp="${state_file}.tmp"
jar_file="${SERVER_JARFILE:-MCXboxBroadcastStandalone.jar}"
download_tmp=".${jar_file}.download"

log() { printf '%s %s\n' "$prefix" "$*"; }
cleanup() { rm -f -- "$download_tmp" "$state_tmp"; }
trap cleanup EXIT INT TERM

jar_is_valid() {
    [[ -f "$1" ]] && jar tf "$1" >/dev/null 2>&1
}

auto_update_enabled() {
    case "${AUTO_UPDATE:-1}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

if auto_update_enabled; then
    log 'Checking the latest official release...'
    release_url="$(
        curl -fsSI --connect-timeout 10 --max-time 30 "$latest_url" 2>/dev/null |
            awk 'tolower($1) == "location:" { gsub("\r", "", $2); print $2; exit }'
    )"

    if [[ -z "$release_url" ]]; then
        log 'Warning: release check failed; keeping the existing Jar.'
    else
        installed_url=''
        [[ -f "$state_file" ]] && IFS= read -r installed_url <"$state_file"

        if [[ "$installed_url" != "$release_url" ]] || ! jar_is_valid "$jar_file"; then
            log "Downloading release: $release_url"
            if curl --fail --silent --show-error --location \
                --retry 3 --retry-delay 2 \
                --connect-timeout 10 --max-time 180 \
                --output "$download_tmp" "$release_url"; then
                if jar_is_valid "$download_tmp"; then
                    mv -f -- "$download_tmp" "$jar_file"
                    if printf '%s\n' "$release_url" >"$state_tmp" &&
                        mv -f -- "$state_tmp" "$state_file"; then
                        log 'Update completed.'
                    else
                        log 'Warning: Jar updated, but release state could not be saved.'
                    fi
                else
                    log 'Warning: downloaded file is not a valid Jar; keeping the existing Jar.'
                fi
            else
                log 'Warning: download failed; keeping the existing Jar.'
            fi
        else
            log 'Already up to date.'
        fi
    fi
else
    log 'Automatic updates are disabled.'
fi

if ! jar_is_valid "$jar_file"; then
    log "Error: no valid Jar is available at $jar_file"
    exit 1
fi

trap - EXIT INT TERM
exec java -Xms128M -Xmx{{SERVER_MEMORY}}M -jar "$jar_file"
