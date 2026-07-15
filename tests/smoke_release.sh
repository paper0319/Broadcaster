#!/usr/bin/env bash
set -euo pipefail

url='https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/MCXboxBroadcastStandalone.jar'
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 180 \
    --output "$tmp" "$url"
jar tf "$tmp" >/dev/null
echo "official release Jar is valid"
