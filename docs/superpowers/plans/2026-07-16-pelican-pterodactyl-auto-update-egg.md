# MCXboxBroadcast Cross-Panel Auto-Update Egg Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pelican PanelとPterodactyl Panel向けに、公式MCXboxBroadcast Standalone Jarを起動時に安全に自動更新する2種類のEggを提供する。

**Architecture:** 更新処理とインストール処理は読みやすいシェルファイルを正本として管理し、Python同期スクリプトで各EggのJSON文字列へ埋め込む。実行時のEggは自己完結し、GitHub Releases APIやフォーク上の外部スクリプトには依存しない。

**Tech Stack:** POSIX/Bash shell、Python 3標準ライブラリ、Pelican `PLCN_v3`、Pterodactyl `PTDL_v2`、Java 21、Docker

## Global Constraints

- Jar取得元は `https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/MCXboxBroadcastStandalone.jar` に固定する。
- GitHub Releases APIは使用しない。
- `AUTO_UPDATE`の既定値は`1`で、`0`の場合は更新確認の通信を行わない。
- ダウンロードは一時ファイルへ行い、`jar tf`成功後だけ本番Jarを置換する。
- 更新失敗時は有効な既存Jarを保持して起動する。
- `config.yml`、認証情報、セッションデータは変更しない。
- PelicanはJava 21 Pelican公式イメージ、PterodactylはJava 21 Pterodactyl公式イメージを使用する。
- ShellファイルはLF固定とする。

---

## File Structure

- Create: `.gitattributes` — ShellファイルのLFを保証する。
- Create: `scripts/mcxboxbroadcast-updater.sh` — 起動時の更新判定、検証、Jar起動を担当する正本。
- Create: `scripts/mcxboxbroadcast-install.sh` — 新規インストール時のJar取得と状態初期化を担当する正本。
- Create: `scripts/sync-eggs.py` — 2つの正本シェルを各Panel形式のEggへ埋め込む。
- Modify: `egg-m-c-xbox-broadcast.json` — Pelican用Egg。
- Create: `egg-m-c-xbox-broadcast-pterodactyl.json` — Pterodactyl用Egg。
- Create: `tests/updater_test.sh` — 更新処理の分岐テスト。
- Create: `tests/installer_test.sh` — インストール処理の分岐テスト。
- Create: `tests/test_eggs.py` — JSON構造と同期状態の静的テスト。
- Create: `tests/smoke_release.sh` — 公式Releaseの実ダウンロード検証。
- Modify: `README.md` — 2種類のEgg、インポート先、自動更新変数を説明する。

### Task 1: 起動時アップデーター

**Files:**
- Create: `.gitattributes`
- Create: `tests/updater_test.sh`
- Create: `scripts/mcxboxbroadcast-updater.sh`

**Interfaces:**
- Consumes: `AUTO_UPDATE`, `SERVER_JARFILE`, Panelが展開する`{{SERVER_MEMORY}}`
- Produces: `.mcxboxbroadcast-release-url`、更新済みJar、最終的な`exec java`

- [ ] **Step 1: Shellの改行規則と失敗する更新テストを追加する**

`.gitattributes`:

~~~gitattributes
*.sh text eol=lf
~~~

`tests/updater_test.sh`:

~~~bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_absent() { [[ ! -e "$1" ]] || fail "unexpected file: $1"; }
assert_content() {
    local expected="$1" file="$2"
    [[ "$(cat "$file")" == "$expected" ]] || fail "$file content mismatch"
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
printf '%s' "${MOCK_DOWNLOAD_CONTENT:-valid-new}" >"$output"
MOCK

    cat >"$CASE_DIR/bin/jar" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "tf" ]] || exit 2
[[ -f "$2" ]] || exit 1
[[ "$(cat "$2")" == valid-* ]]
MOCK

    cat >"$CASE_DIR/bin/java" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$MOCK_ROOT/java.log"
MOCK

    chmod +x "$CASE_DIR/bin/"*
}

run_updater() {
    (
        cd "$CASE_DIR"
        PATH="$CASE_DIR/bin:$PATH" \
        MOCK_ROOT="$CASE_DIR" \
        SERVER_JARFILE="MCXboxBroadcastStandalone.jar" \
        bash "$repo_root/scripts/mcxboxbroadcast-updater.sh"
    )
}

make_case disabled
printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
AUTO_UPDATE=0 run_updater
assert_absent "$CASE_DIR/curl.log"
assert_file "$CASE_DIR/java.log"

make_case unchanged
printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
printf '%s\n' 'https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' >"$CASE_DIR/.mcxboxbroadcast-release-url"
MOCK_RELEASE_URL='https://github.com/example/releases/download/current/MCXboxBroadcastStandalone.jar' run_updater
[[ "$(wc -l <"$CASE_DIR/curl.log")" -eq 1 ]] || fail "unchanged release downloaded"
assert_content valid-old "$CASE_DIR/MCXboxBroadcastStandalone.jar"

make_case update
printf valid-old >"$CASE_DIR/MCXboxBroadcastStandalone.jar"
printf '%s\n' old >"$CASE_DIR/.mcxboxbroadcast-release-url"
MOCK_RELEASE_URL='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' run_updater
assert_content valid-new "$CASE_DIR/MCXboxBroadcastStandalone.jar"
assert_content 'https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar' "$CASE_DIR/.mcxboxbroadcast-release-url"

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
    assert_file "$CASE_DIR/java.log"
done

make_case no-jar
set +e
MOCK_HEAD_FAIL=1 MOCK_RELEASE_URL=new run_updater
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "missing jar should fail"
assert_absent "$CASE_DIR/java.log"

echo "updater tests passed"
~~~

- [ ] **Step 2: テストが対象ファイル不在で失敗することを確認する**

Run:

~~~powershell
docker run --rm -v "${PWD}:/work" -w /work ghcr.io/pterodactyl/yolks:java_21 bash tests/updater_test.sh
~~~

Expected: FAIL with `scripts/mcxboxbroadcast-updater.sh: No such file or directory`.

- [ ] **Step 3: 最小の起動時アップデーターを実装する**

`scripts/mcxboxbroadcast-updater.sh`:

~~~bash
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
~~~

- [ ] **Step 4: 更新テストが通ることを確認する**

Run: Task 1 Step 2と同じDockerコマンド。

Expected: PASS with `updater tests passed`.

- [ ] **Step 5: コミットする**

~~~powershell
git add .gitattributes scripts/mcxboxbroadcast-updater.sh tests/updater_test.sh
git commit -m "feat: add safe startup updater"
~~~

### Task 2: インストール処理

**Files:**
- Create: `tests/installer_test.sh`
- Create: `scripts/mcxboxbroadcast-install.sh`

**Interfaces:**
- Consumes: `SERVER_DIR`（テスト用、既定`/mnt/server`）、`SERVER_JARFILE`
- Produces: 初期Jarと`.mcxboxbroadcast-release-url`

- [ ] **Step 1: 失敗するインストールテストを追加する**

`tests/installer_test.sh`はTask 1のmock `curl`と同じ引数解析を使い、次の3ケースを完全に実装する。

~~~bash
#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
make_mock() {
    local dir="$1"
    mkdir -p "$dir/bin" "$dir/server"
    cat >"$dir/bin/curl" <<'MOCK'
#!/usr/bin/env ash
if echo "$*" | grep -q -- '-fsSI'; then
    [ "${MOCK_HEAD_FAIL:-0}" = 1 ] && exit 22
    printf 'HTTP/2 302\r\nlocation: %s\r\n\r\n' "$MOCK_RELEASE_URL"
    exit 0
fi
[ "${MOCK_DOWNLOAD_FAIL:-0}" = 1 ] && exit 22
while [ "$#" -gt 0 ]; do
    [ "$1" = "--output" ] && { output="$2"; break; }
    shift
done
printf valid-new >"$output"
MOCK
    chmod +x "$dir/bin/curl"
}
run_install() {
    PATH="$case_dir/bin:$PATH" SERVER_DIR="$case_dir/server" \
        SERVER_JARFILE=MCXboxBroadcastStandalone.jar \
        ash "$repo_root/scripts/mcxboxbroadcast-install.sh"
}

case_dir="$root/success"; make_mock "$case_dir"
release_url='https://github.com/example/releases/download/new/MCXboxBroadcastStandalone.jar'
MOCK_RELEASE_URL="$release_url" run_install
[[ "$(cat "$case_dir/server/MCXboxBroadcastStandalone.jar")" == valid-new ]] || fail "jar missing"
[[ "$(cat "$case_dir/server/.mcxboxbroadcast-release-url")" == "$release_url" ]] || fail "state missing"

case_dir="$root/head-failure"; make_mock "$case_dir"
MOCK_HEAD_FAIL=1 MOCK_RELEASE_URL=unused run_install
[[ -f "$case_dir/server/MCXboxBroadcastStandalone.jar" ]] || fail "fallback download failed"
[[ ! -e "$case_dir/server/.mcxboxbroadcast-release-url" ]] || fail "unexpected state"

case_dir="$root/download-failure"; make_mock "$case_dir"
set +e
MOCK_DOWNLOAD_FAIL=1 MOCK_RELEASE_URL=new run_install
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "download failure should fail installation"
[[ ! -e "$case_dir/server/MCXboxBroadcastStandalone.jar" ]] || fail "partial jar installed"
echo "installer tests passed"
~~~

- [ ] **Step 2: テストが対象ファイル不在で失敗することを確認する**

Run:

~~~powershell
docker run --rm -v "${PWD}:/work" -w /work ghcr.io/pterodactyl/installers:alpine ash tests/installer_test.sh
~~~

Expected: FAIL with `scripts/mcxboxbroadcast-install.sh: No such file or directory`.

- [ ] **Step 3: インストール処理を実装する**

`scripts/mcxboxbroadcast-install.sh`:

~~~sh
#!/bin/ash
set -u

prefix='[MCXboxBroadcast Installer]'
latest_url='https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/MCXboxBroadcastStandalone.jar'
server_dir="${SERVER_DIR:-/mnt/server}"
jar_file="${SERVER_JARFILE:-MCXboxBroadcastStandalone.jar}"
state_file='.mcxboxbroadcast-release-url'
download_tmp=".${jar_file}.download"

log() { printf '%s %s\n' "$prefix" "$*"; }
mkdir -p "$server_dir"
cd "$server_dir" || exit 1
rm -f "$download_tmp" "${state_file}.tmp"

release_url="$(
    curl -fsSI --connect-timeout 10 --max-time 30 "$latest_url" 2>/dev/null |
        awk 'tolower($1) == "location:" { gsub("\r", "", $2); print $2; exit }'
)"
download_url="${release_url:-$latest_url}"

log "Downloading $download_url"
if ! curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 180 \
    --output "$download_tmp" "$download_url"; then
    rm -f "$download_tmp"
    log 'Error: download failed.'
    exit 1
fi

if [ ! -s "$download_tmp" ]; then
    rm -f "$download_tmp"
    log 'Error: downloaded Jar is empty.'
    exit 1
fi

mv -f "$download_tmp" "$jar_file"
if [ -n "$release_url" ]; then
    if printf '%s\n' "$release_url" >"${state_file}.tmp"; then
        mv -f "${state_file}.tmp" "$state_file"
    else
        log 'Warning: release state could not be saved.'
    fi
fi
log 'Installation completed.'
~~~

- [ ] **Step 4: installerテストが通ることを確認する**

Run: Task 2 Step 2と同じDockerコマンド。

Expected: PASS with `installer tests passed`.

- [ ] **Step 5: コミットする**

~~~powershell
git add scripts/mcxboxbroadcast-install.sh tests/installer_test.sh
git commit -m "feat: add resilient installer"
~~~

### Task 3: Egg同期生成とPanel形式

**Files:**
- Create: `tests/test_eggs.py`
- Create: `scripts/sync-eggs.py`
- Modify: `egg-m-c-xbox-broadcast.json`
- Create: `egg-m-c-xbox-broadcast-pterodactyl.json`

**Interfaces:**
- Consumes: 2つの正本Shellファイル
- Produces: Pelican `startup_commands.Default`、Pterodactyl `startup`、両Eggのinstallation script

- [ ] **Step 1: JSON構造の失敗テストを追加する**

`tests/test_eggs.py`:

~~~python
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PELICAN = ROOT / "egg-m-c-xbox-broadcast.json"
PTERODACTYL = ROOT / "egg-m-c-xbox-broadcast-pterodactyl.json"
UPDATER = (ROOT / "scripts/mcxboxbroadcast-updater.sh").read_text(encoding="utf-8")
INSTALLER = (ROOT / "scripts/mcxboxbroadcast-install.sh").read_text(encoding="utf-8")
LATEST = "https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/MCXboxBroadcastStandalone.jar"

class EggDefinitionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pelican = json.loads(PELICAN.read_text(encoding="utf-8"))
        cls.pterodactyl = json.loads(PTERODACTYL.read_text(encoding="utf-8"))

    def test_panel_versions_and_images(self):
        self.assertEqual("PLCN_v3", self.pelican["meta"]["version"])
        self.assertEqual("PTDL_v2", self.pterodactyl["meta"]["version"])
        self.assertEqual(
            {"Java 21": "ghcr.io/pelican-eggs/yolks:java_21"},
            self.pelican["docker_images"],
        )
        self.assertEqual(
            {"Java 21": "ghcr.io/pterodactyl/yolks:java_21"},
            self.pterodactyl["docker_images"],
        )

    def test_canonical_scripts_are_embedded(self):
        self.assertEqual(UPDATER, self.pelican["startup_commands"]["Default"])
        self.assertEqual(UPDATER, self.pterodactyl["startup"])
        self.assertEqual(INSTALLER, self.pelican["scripts"]["installation"]["script"])
        self.assertEqual(INSTALLER, self.pterodactyl["scripts"]["installation"]["script"])

    def test_update_variables(self):
        for egg in (self.pelican, self.pterodactyl):
            variables = {item["env_variable"]: item for item in egg["variables"]}
            self.assertEqual("MCXboxBroadcastStandalone.jar", variables["SERVER_JARFILE"]["default_value"])
            self.assertEqual("1", variables["AUTO_UPDATE"]["default_value"])

    def test_release_source_and_no_api(self):
        for egg in (self.pelican, self.pterodactyl):
            encoded = json.dumps(egg)
            self.assertIn(LATEST, encoded)
            self.assertNotIn("api.github.com", encoded)

    def test_update_urls(self):
        self.assertEqual(
            "https://raw.githubusercontent.com/paper0319/Broadcaster/refs/heads/master/egg-m-c-xbox-broadcast.json",
            self.pelican["meta"]["update_url"],
        )
        self.assertIsNone(self.pterodactyl["meta"]["update_url"])

    def test_generated_files_are_current(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/sync-eggs.py"), "--check"],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
~~~

- [ ] **Step 2: Pterodactyl Egg不在でテストが失敗することを確認する**

Run:

~~~powershell
python -m unittest tests.test_eggs -v
~~~

Expected: ERROR with `egg-m-c-xbox-broadcast-pterodactyl.json` not found.

- [ ] **Step 3: 決定的なEgg同期スクリプトを実装する**

`scripts/sync-eggs.py`は次を完全に実装する。

~~~python
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PELICAN_PATH = ROOT / "egg-m-c-xbox-broadcast.json"
PTERODACTYL_PATH = ROOT / "egg-m-c-xbox-broadcast-pterodactyl.json"
UPDATER = (ROOT / "scripts/mcxboxbroadcast-updater.sh").read_text(encoding="utf-8")
INSTALLER = (ROOT / "scripts/mcxboxbroadcast-install.sh").read_text(encoding="utf-8")
DESCRIPTION = (
    "Show a server on the friends tab in Minecraft, with safe automatic "
    "updates from the official MCXboxBroadcast releases."
)
PELICAN_UPDATE_URL = (
    "https://raw.githubusercontent.com/paper0319/Broadcaster/"
    "refs/heads/master/egg-m-c-xbox-broadcast.json"
)

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
            "rules": ["required", "string", "max:64", "regex:/^[A-Za-z0-9._-]+$/"],
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
    result = []
    for item in pelican_variables():
        converted = {key: value for key, value in item.items() if key != "sort"}
        converted["rules"] = "|".join(item["rules"])
        converted["field_type"] = "text"
        result.append(converted)
    return result

def build_pelican():
    data = json.loads(PELICAN_PATH.read_text(encoding="utf-8"))
    data["meta"]["update_url"] = PELICAN_UPDATE_URL
    data["description"] = DESCRIPTION
    data["docker_images"] = {"Java 21": "ghcr.io/pelican-eggs/yolks:java_21"}
    data["startup_commands"] = {"Default": UPDATER}
    data["scripts"]["installation"] = {
        "script": INSTALLER,
        "container": "ghcr.io/pelican-eggs/installers:alpine",
        "entrypoint": "ash",
    }
    data["variables"] = pelican_variables()
    return data

def build_pterodactyl():
    return {
        "_comment": "DO NOT EDIT: FILE GENERATED AUTOMATICALLY BY PTERODACTYL PANEL - PTERODACTYL.IO",
        "meta": {"version": "PTDL_v2", "update_url": None},
        "exported_at": "2026-07-16T00:00:00+09:00",
        "name": "MCXboxBroadcast",
        "author": "panel@rtm516.co.uk",
        "description": DESCRIPTION,
        "features": None,
        "docker_images": {"Java 21": "ghcr.io/pterodactyl/yolks:java_21"},
        "file_denylist": [],
        "startup": UPDATER,
        "config": {
            "files": "{}",
            "startup": '{\r\n    "done": "Creation of Xbox LIVE session was successful!"\r\n}',
            "logs": "{}",
            "stop": "exit",
        },
        "scripts": {
            "installation": {
                "script": INSTALLER,
                "container": "ghcr.io/pterodactyl/installers:alpine",
                "entrypoint": "ash",
            }
        },
        "variables": pterodactyl_variables(),
    }

def render(data):
    return json.dumps(data, ensure_ascii=False, indent=4) + "\n"

def sync(path, content, check):
    if check:
        if not path.exists() or path.read_text(encoding="utf-8") != content:
            print(f"out of date: {path.relative_to(ROOT)}", file=sys.stderr)
            return False
        return True
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
~~~

- [ ] **Step 4: Eggを生成し、静的テストを通す**

Run:

~~~powershell
python scripts/sync-eggs.py
python -m unittest tests.test_eggs -v
~~~

Expected: 5 tests PASS.

- [ ] **Step 5: JSON差分を確認してコミットする**

Run: `git diff --check`  
Expected: no output.

~~~powershell
git add scripts/sync-eggs.py tests/test_eggs.py egg-m-c-xbox-broadcast.json egg-m-c-xbox-broadcast-pterodactyl.json
git commit -m "feat: add Pelican and Pterodactyl auto-update eggs"
~~~

### Task 4: 実Releaseスモークテストと利用説明

**Files:**
- Create: `tests/smoke_release.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: 公式latest download URL、Java 21の`jar`コマンド
- Produces: 利用者向けのPanel別インポート案内と実ネットワーク検証

- [ ] **Step 1: 公式Releaseのスモークテストを追加する**

`tests/smoke_release.sh`:

~~~bash
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
~~~

- [ ] **Step 2: READMEのPanel節を2形式の説明へ置き換える**

`README.md`の`Pterodactyl Panel`節を次へ変更する。

~~~markdown
## Pelican and Pterodactyl Panels

This fork provides separate Egg files because Pelican and Pterodactyl use
different export formats:

- `egg-m-c-xbox-broadcast.json` — Pelican (`PLCN_v3`)
- `egg-m-c-xbox-broadcast-pterodactyl.json` — Pterodactyl (`PTDL_v2`)

Both Eggs install the official standalone Jar and, by default, check the
official GitHub Releases page on every startup. The Jar is replaced only
after the download passes validation. Set `AUTO_UPDATE` to `0` in the
Panel startup variables to disable update checks.
~~~

- [ ] **Step 3: 全ローカル・コンテナテストを実行する**

Run:

~~~powershell
python scripts/sync-eggs.py --check
python -m unittest tests.test_eggs -v
docker run --rm -v "${PWD}:/work" -w /work ghcr.io/pterodactyl/yolks:java_21 bash tests/updater_test.sh
docker run --rm -v "${PWD}:/work" -w /work ghcr.io/pterodactyl/installers:alpine ash tests/installer_test.sh
docker run --rm -v "${PWD}:/work" -w /work ghcr.io/pterodactyl/yolks:java_21 bash tests/smoke_release.sh
~~~

Expected: sync check exits 0, Python 5 tests PASS, updater and installer tests pass, smoke prints `official release Jar is valid`.

- [ ] **Step 4: Pelicanランタイムでも更新テストを実行する**

Run:

~~~powershell
docker run --rm -v "${PWD}:/work" -w /work ghcr.io/pelican-eggs/yolks:java_21 bash tests/updater_test.sh
~~~

Expected: PASS with `updater tests passed`.  
If the image cannot be pulled because the registry is unavailable, record the exact pull error; Pterodactyl runtime success remains mandatory.

- [ ] **Step 5: READMEとスモークテストをコミットする**

~~~powershell
git add README.md tests/smoke_release.sh
git commit -m "docs: explain cross-panel auto-update eggs"
~~~

### Task 5: 最終検証

**Files:**
- Verify only; no new files

**Interfaces:**
- Consumes: Tasks 1–4の全成果物
- Produces: clean worktree and evidence-backed completion report

- [ ] **Step 1: 生成物と差分品質を再確認する**

Run:

~~~powershell
python scripts/sync-eggs.py --check
python -m unittest discover -s tests -p "test_*.py" -v
git diff --check HEAD~4..HEAD
git status --short
~~~

Expected: all tests PASS, diff check has no output, status is clean.

- [ ] **Step 2: Egg内の重要値を機械的に表示する**

Run:

~~~powershell
python -c "import json; from pathlib import Path; files=['egg-m-c-xbox-broadcast.json','egg-m-c-xbox-broadcast-pterodactyl.json']; [print(f, json.loads(Path(f).read_text(encoding='utf-8'))['meta']['version']) for f in files]"
~~~

Expected:

~~~text
egg-m-c-xbox-broadcast.json PLCN_v3
egg-m-c-xbox-broadcast-pterodactyl.json PTDL_v2
~~~

- [ ] **Step 3: コミット履歴と未Push状態を報告する**

Run:

~~~powershell
git log --oneline origin/master..HEAD
git status --short --branch
~~~

Expected: design、plan、implementation commitsが表示され、ユーザーがPushを依頼するまではローカルのahead状態を維持する。
