from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PELICAN_PATH = ROOT / "egg-m-c-xbox-broadcast.json"
PTERODACTYL_PATH = ROOT / "egg-m-c-xbox-broadcast-pterodactyl.json"
ICON_PATH = ROOT / "assets/mcxboxbroadcast-icon.data-uri"
UPDATER = (ROOT / "scripts/mcxboxbroadcast-updater.sh").read_bytes().decode("utf-8")
INSTALLER = (ROOT / "scripts/mcxboxbroadcast-install.sh").read_bytes().decode("utf-8")
DESCRIPTION = (
    "Show a server on the friends tab in Minecraft, with safe automatic "
    "updates from the official MCXboxBroadcast releases."
)
STARTUP = "bash ./mcxboxbroadcast-updater.sh"
PELICAN_UPDATE_URL = (
    "https://raw.githubusercontent.com/paper0319/Broadcaster/"
    "refs/heads/master/egg-m-c-xbox-broadcast.json"
)
PELICAN_IMAGE_SHA256 = (
    "c78ad4e241282f3fdd65af663b8186c9b1cafd007aac20d519b9c093b8927f23"
)


def load_icon():
    raw = ICON_PATH.read_bytes()
    if not raw.endswith(b"\n") or b"\r" in raw:
        raise ValueError("Pelican icon asset must be a single LF-terminated line")
    payload = raw[:-1]
    if b"\n" in payload:
        raise ValueError("Pelican icon asset must be a single LF-terminated line")
    icon = payload.decode("ascii")
    if hashlib.sha256(payload).hexdigest() != PELICAN_IMAGE_SHA256:
        raise ValueError("Pelican icon asset does not match the preserved PLCN_v3 image")
    return icon


ICON = load_icon()


def installation_script():
    delimiter = "MCXBOXBROADCAST_UPDATER_EOF"
    if delimiter in UPDATER:
        raise ValueError("Updater contains the installation heredoc delimiter")
    provision_updater = f"""#!/bin/ash
set -u

server_dir="${{SERVER_DIR:-/mnt/server}}"
updater_file='mcxboxbroadcast-updater.sh'
updater_tmp=''

cleanup_updater() {{
    [ -z "$updater_tmp" ] || rm -f -- "$updater_tmp"
}}

trap cleanup_updater EXIT INT TERM

mkdir -p -- "$server_dir" || exit 1
cd -- "$server_dir" || exit 1

if ! updater_tmp="$(mktemp './.mcxboxbroadcast-updater.sh.tmp.XXXXXX')"; then
    printf '%s\\n' '[MCXboxBroadcast Installer] Error: updater staging could not be created.'
    exit 1
fi
if ! cat >"$updater_tmp" <<'{delimiter}'
{UPDATER}{delimiter}
then
    printf '%s\\n' '[MCXboxBroadcast Installer] Error: updater staging could not be written.'
    exit 1
fi
if ! chmod 755 "$updater_tmp" || ! mv -fT -- "$updater_tmp" "$updater_file"; then
    printf '%s\\n' '[MCXboxBroadcast Installer] Error: updater could not be installed.'
    exit 1
fi
updater_tmp=''
trap - EXIT INT TERM

"""
    return provision_updater + INSTALLER


INSTALLATION_SCRIPT = installation_script()


def common_config():
    return {
        "files": "{}",
        "startup": '{\r\n    "done": "Creation of Xbox LIVE session was successful!"\r\n}',
        "logs": "{}",
        "stop": "exit",
    }


def pelican_variables():
    return [
        {
            "sort": 1,
            "name": "Jar File",
            "description": "Jar filename used for download and startup.",
            "env_variable": "SERVER_JARFILE",
            "default_value": "MCXboxBroadcastStandalone.jar",
            "user_viewable": True,
            "user_editable": True,
            "rules": [
                "required",
                "string",
                "max:64",
                r"regex:/^[A-Za-z0-9][A-Za-z0-9._-]*\.jar$/",
            ],
        },
        {
            "sort": 2,
            "name": "Automatic Updates",
            "description": "Check and install the latest official release on startup.",
            "env_variable": "AUTO_UPDATE",
            "default_value": "1",
            "user_viewable": True,
            "user_editable": True,
            "rules": ["required", "boolean"],
        },
    ]


def pterodactyl_variables():
    variables = []
    for item in pelican_variables():
        converted = {key: value for key, value in item.items() if key != "sort"}
        converted["rules"] = "|".join(item["rules"])
        converted["field_type"] = "text"
        variables.append(converted)
    return variables


def build_pelican():
    return {
        "_comment": "DO NOT EDIT: FILE GENERATED AUTOMATICALLY BY PANEL",
        "meta": {"version": "PLCN_v3", "update_url": PELICAN_UPDATE_URL},
        "exported_at": "2026-04-27T10:20:18+00:00",
        "name": "MCXboxBroadcast",
        "author": "panel@rtm516.co.uk",
        "uuid": "deab1199-f8e5-4bd5-9573-d2f8c04c50a0",
        "description": DESCRIPTION,
        "image": ICON,
        "tags": ["minecraft"],
        "features": [],
        "docker_images": {"Java 21": "ghcr.io/pelican-eggs/yolks:java_21"},
        "file_denylist": [],
        "startup_commands": {"Default": STARTUP},
        "config": common_config(),
        "scripts": {
            "installation": {
                "script": INSTALLATION_SCRIPT,
                "container": "ghcr.io/pelican-eggs/installers:alpine",
                "entrypoint": "ash",
            },
        },
        "variables": pelican_variables(),
    }


def build_pterodactyl():
    return {
        "_comment": (
            "DO NOT EDIT: FILE GENERATED AUTOMATICALLY BY PTERODACTYL PANEL - "
            "PTERODACTYL.IO"
        ),
        "meta": {"version": "PTDL_v2", "update_url": None},
        "exported_at": "2026-07-16T00:00:00+09:00",
        "name": "MCXboxBroadcast",
        "author": "panel@rtm516.co.uk",
        "description": DESCRIPTION,
        "features": None,
        "docker_images": {
            "Java 21": "ghcr.io/pterodactyl/yolks:java_21",
        },
        "file_denylist": [],
        "startup": STARTUP,
        "config": common_config(),
        "scripts": {
            "installation": {
                "script": INSTALLATION_SCRIPT,
                "container": "ghcr.io/pterodactyl/installers:alpine",
                "entrypoint": "ash",
            },
        },
        "variables": pterodactyl_variables(),
    }


def render(data):
    return json.dumps(data, ensure_ascii=False, indent=4) + "\n"


def sync(path, content, check):
    encoded = content.encode("utf-8")
    if path.exists() and path.read_bytes() == encoded:
        return True
    if check:
        print(f"out of date: {path.relative_to(ROOT)}", file=sys.stderr)
        return False
    path.write_text(content, encoding="utf-8", newline="\n")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    ok = sync(PELICAN_PATH, render(build_pelican()), args.check)
    ok = sync(PTERODACTYL_PATH, render(build_pterodactyl()), args.check) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
