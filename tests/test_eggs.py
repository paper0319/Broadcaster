import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PELICAN = ROOT / "egg-m-c-xbox-broadcast.json"
PTERODACTYL = ROOT / "egg-m-c-xbox-broadcast-pterodactyl.json"
ICON = ROOT / "assets/mcxboxbroadcast-icon.data-uri"
UPDATER = (ROOT / "scripts/mcxboxbroadcast-updater.sh").read_bytes().decode("utf-8")
INSTALLER = (ROOT / "scripts/mcxboxbroadcast-install.sh").read_bytes().decode("utf-8")
LATEST = (
    "https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/"
    "MCXboxBroadcastStandalone.jar"
)
PELICAN_UPDATE_URL = (
    "https://raw.githubusercontent.com/paper0319/Broadcaster/"
    "refs/heads/master/egg-m-c-xbox-broadcast.json"
)
DESCRIPTION = (
    "Show a server on the friends tab in Minecraft, with safe automatic "
    "updates from the official MCXboxBroadcast releases."
)


def copy_generator_fixture(destination, include_outputs=True):
    shutil.copy2(ROOT / ".gitattributes", destination / ".gitattributes")
    shutil.copytree(ROOT / "scripts", destination / "scripts")
    shutil.copytree(ROOT / "assets", destination / "assets")
    if include_outputs:
        shutil.copy2(PELICAN, destination / PELICAN.name)
        shutil.copy2(PTERODACTYL, destination / PTERODACTYL.name)


def embedded_runtime_urls(egg):
    startup = egg.get(
        "startup",
        egg.get("startup_commands", {}).get("Default", ""),
    )
    runtime_text = startup + "\n" + egg["scripts"]["installation"]["script"]
    return set(re.findall(r"https?://[^\s\"']+", runtime_text))


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

    def test_generated_text_is_pinned_to_lf(self):
        paths = [
            PELICAN.name,
            PTERODACTYL.name,
            "scripts/sync-eggs.py",
            "tests/test_eggs.py",
        ]
        result = subprocess.run(
            ["git", "check-attr", "eol", "--", *paths],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(
            [f"{path}: eol: lf" for path in paths],
            result.stdout.splitlines(),
        )

    def test_preserved_icon_comes_from_lf_asset(self):
        raw = ICON.read_bytes()
        self.assertTrue(raw.endswith(b"\n"))
        self.assertNotIn(b"\r\n", raw)
        payload = raw[:-1]
        self.assertNotIn(b"\n", payload)
        self.assertEqual(
            "c78ad4e241282f3fdd65af663b8186c9b1cafd007aac20d519b9c093b8927f23",
            hashlib.sha256(payload).hexdigest(),
        )
        self.assertEqual(payload.decode("ascii"), self.pelican["image"])

        result = subprocess.run(
            ["git", "check-attr", "eol", "--", ICON.relative_to(ROOT).as_posix()],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(
            "assets/mcxboxbroadcast-icon.data-uri: eol: lf",
            result.stdout.strip(),
        )

    def test_variables_use_panel_specific_rule_shapes(self):
        expected_common = [
            {
                "name": "Jar File",
                "description": "Jar filename used for download and startup.",
                "env_variable": "SERVER_JARFILE",
                "default_value": "MCXboxBroadcastStandalone.jar",
                "user_viewable": True,
                "user_editable": True,
            },
            {
                "name": "Automatic Updates",
                "description": "Check and install the latest official release on startup.",
                "env_variable": "AUTO_UPDATE",
                "default_value": "1",
                "user_viewable": True,
                "user_editable": True,
            },
        ]
        pelican_rules = [
            [
                "required",
                "string",
                "max:64",
                r"regex:/^[A-Za-z0-9][A-Za-z0-9._-]*\.jar$/",
            ],
            ["required", "boolean"],
        ]
        pterodactyl_rules = ["|".join(rules) for rules in pelican_rules]

        self.assertEqual(
            [
                {"sort": index, **common, "rules": rules}
                for index, (common, rules) in enumerate(
                    zip(expected_common, pelican_rules),
                    start=1,
                )
            ],
            self.pelican["variables"],
        )
        self.assertEqual(
            [
                {**common, "rules": rules, "field_type": "text"}
                for common, rules in zip(expected_common, pterodactyl_rules)
            ],
            self.pterodactyl["variables"],
        )

    def test_panel_jar_rule_accepts_only_safe_jar_basenames(self):
        rule = self.pelican["variables"][0]["rules"][-1]
        self.assertTrue(rule.startswith("regex:/") and rule.endswith("/"))
        pattern = rule.removeprefix("regex:/").removesuffix("/")

        for accepted in ("MCXboxBroadcastStandalone.jar", "custom-1.2.jar"):
            with self.subTest(accepted=accepted):
                self.assertIsNotNone(re.fullmatch(pattern, accepted))

        for rejected in (
            "",
            ".",
            "config.yml",
            ".mcxboxbroadcast-release-url",
            ".hidden.jar",
            "nested/custom.jar",
            r"nested\custom.jar",
        ):
            with self.subTest(rejected=rejected):
                self.assertIsNone(re.fullmatch(pattern, rejected))

    def test_panel_specific_schema_and_preserved_metadata(self):
        self.assertEqual(
            {
                "_comment",
                "meta",
                "exported_at",
                "name",
                "author",
                "uuid",
                "description",
                "image",
                "tags",
                "features",
                "docker_images",
                "file_denylist",
                "startup_commands",
                "config",
                "scripts",
                "variables",
            },
            set(self.pelican),
        )
        self.assertEqual(
            {
                "_comment",
                "meta",
                "exported_at",
                "name",
                "author",
                "description",
                "features",
                "docker_images",
                "file_denylist",
                "startup",
                "config",
                "scripts",
                "variables",
            },
            set(self.pterodactyl),
        )

        self.assertEqual(
            "DO NOT EDIT: FILE GENERATED AUTOMATICALLY BY PANEL",
            self.pelican["_comment"],
        )
        self.assertEqual("2026-04-27T10:20:18+00:00", self.pelican["exported_at"])
        self.assertEqual("MCXboxBroadcast", self.pelican["name"])
        self.assertEqual("panel@rtm516.co.uk", self.pelican["author"])
        self.assertEqual("deab1199-f8e5-4bd5-9573-d2f8c04c50a0", self.pelican["uuid"])
        self.assertEqual(["minecraft"], self.pelican["tags"])
        self.assertEqual([], self.pelican["features"])
        self.assertEqual([], self.pelican["file_denylist"])
        self.assertEqual(
            "c78ad4e241282f3fdd65af663b8186c9b1cafd007aac20d519b9c093b8927f23",
            hashlib.sha256(self.pelican["image"].encode("utf-8")).hexdigest(),
        )

        self.assertEqual(
            "DO NOT EDIT: FILE GENERATED AUTOMATICALLY BY PTERODACTYL PANEL - PTERODACTYL.IO",
            self.pterodactyl["_comment"],
        )
        self.assertEqual("2026-07-16T00:00:00+09:00", self.pterodactyl["exported_at"])
        self.assertEqual("MCXboxBroadcast", self.pterodactyl["name"])
        self.assertEqual("panel@rtm516.co.uk", self.pterodactyl["author"])
        self.assertIsNone(self.pterodactyl["features"])
        self.assertEqual([], self.pterodactyl["file_denylist"])

        expected_config = {
            "files": "{}",
            "startup": '{\r\n    "done": "Creation of Xbox LIVE session was successful!"\r\n}',
            "logs": "{}",
            "stop": "exit",
        }
        self.assertEqual(expected_config, self.pelican["config"])
        self.assertEqual(expected_config, self.pterodactyl["config"])

    def test_only_the_official_release_source_is_embedded(self):
        self.assertEqual(PELICAN_UPDATE_URL, self.pelican["meta"]["update_url"])
        self.assertIsNone(self.pterodactyl["meta"]["update_url"])
        self.assertEqual(DESCRIPTION, self.pelican["description"])
        self.assertEqual(DESCRIPTION, self.pterodactyl["description"])

        for egg in (self.pelican, self.pterodactyl):
            encoded = json.dumps(egg)
            self.assertIn(LATEST, encoded)
            self.assertNotIn("api.github.com", encoded)
            self.assertEqual({LATEST}, embedded_runtime_urls(egg))

    def test_runtime_url_scanner_includes_non_github_http_literals(self):
        rogue_urls = [
            "https://example.invalid/rogue.jar",
            "http://127.0.0.1/rogue.jar",
        ]
        for rogue_url in rogue_urls:
            with self.subTest(rogue_url=rogue_url):
                egg = json.loads(json.dumps(self.pelican))
                egg["scripts"]["installation"]["script"] += f"\n{rogue_url}\n"
                self.assertEqual(
                    {LATEST, rogue_url},
                    embedded_runtime_urls(egg),
                )

    def test_check_mode_detects_drift_without_writing(self):
        mutations = [
            (
                "pelican managed field",
                PELICAN.name,
                PELICAN_UPDATE_URL,
                PELICAN_UPDATE_URL + ".drift",
            ),
            (
                "pelican preserved metadata",
                PELICAN.name,
                "deab1199-f8e5-4bd5-9573-d2f8c04c50a0",
                "00000000-0000-0000-0000-000000000000",
            ),
            ("pterodactyl field", PTERODACTYL.name, "PTDL_v2", "PTDL_v1"),
        ]
        for case, filename, current, drift in mutations:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp:
                temp_root = Path(temp)
                copy_generator_fixture(temp_root)
                target = temp_root / filename
                target.write_text(
                    target.read_text(encoding="utf-8").replace(current, drift, 1),
                    encoding="utf-8",
                    newline="\n",
                )
                drifted_bytes = target.read_bytes()

                result = subprocess.run(
                    [sys.executable, str(temp_root / "scripts/sync-eggs.py"), "--check"],
                    cwd=temp_root,
                    text=True,
                    capture_output=True,
                )

                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertIn(f"out of date: {filename}", result.stderr)
                self.assertEqual(drifted_bytes, target.read_bytes())

    def test_check_mode_reports_missing_outputs_without_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp)
            copy_generator_fixture(temp_root, include_outputs=False)
            missing = [
                temp_root / PELICAN.name,
                temp_root / PTERODACTYL.name,
            ]

            result = subprocess.run(
                [sys.executable, str(temp_root / "scripts/sync-eggs.py"), "--check"],
                cwd=temp_root,
                text=True,
                capture_output=True,
            )

            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertEqual(
                [f"out of date: {path.name}" for path in missing],
                result.stderr.splitlines(),
            )
            self.assertNotIn("Traceback", result.stderr)
            self.assertTrue(all(not path.exists() for path in missing))

    def test_sync_recreates_missing_and_corrupt_outputs(self):
        scenarios = {
            "missing": None,
            "corrupt": b"not valid JSON\r\n",
        }
        expected = {
            PELICAN.name: PELICAN.read_bytes(),
            PTERODACTYL.name: PTERODACTYL.read_bytes(),
        }
        for scenario, corrupt_bytes in scenarios.items():
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temp:
                temp_root = Path(temp)
                copy_generator_fixture(
                    temp_root,
                    include_outputs=corrupt_bytes is not None,
                )
                if corrupt_bytes is not None:
                    for filename in expected:
                        (temp_root / filename).write_bytes(corrupt_bytes)

                result = subprocess.run(
                    [sys.executable, str(temp_root / "scripts/sync-eggs.py")],
                    cwd=temp_root,
                    text=True,
                    capture_output=True,
                )

                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual(
                    expected,
                    {filename: (temp_root / filename).read_bytes() for filename in expected},
                )

    def test_sync_is_idempotent_when_outputs_are_current(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp)
            copy_generator_fixture(temp_root)
            command = [sys.executable, str(temp_root / "scripts/sync-eggs.py")]

            first = subprocess.run(command, cwd=temp_root, text=True, capture_output=True)
            self.assertEqual(0, first.returncode, first.stdout + first.stderr)
            paths = [temp_root / PELICAN.name, temp_root / PTERODACTYL.name]
            expected_bytes = {path.name: path.read_bytes() for path in paths}
            for path in paths:
                os.utime(path, (946684800, 946684800))
            expected_mtimes = {path.name: path.stat().st_mtime_ns for path in paths}

            second = subprocess.run(command, cwd=temp_root, text=True, capture_output=True)
            self.assertEqual(0, second.returncode, second.stdout + second.stderr)
            self.assertEqual(
                expected_bytes,
                {path.name: path.read_bytes() for path in paths},
            )
            self.assertEqual(
                expected_mtimes,
                {path.name: path.stat().st_mtime_ns for path in paths},
            )

    def test_generated_files_are_current_lf_json(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/sync-eggs.py"), "--check"],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

        for path in (PELICAN, PTERODACTYL):
            raw = path.read_bytes()
            self.assertTrue(raw.endswith(b"\n"), path.name)
            self.assertNotIn(b"\r\n", raw, path.name)
            parsed = json.loads(raw.decode("utf-8"))
            rendered = (json.dumps(parsed, ensure_ascii=False, indent=4) + "\n").encode(
                "utf-8"
            )
            self.assertEqual(rendered, raw, path.name)
            self.assertEqual(parsed, json.loads(json.dumps(parsed, ensure_ascii=False)))

    def test_canonical_scripts_and_installer_images(self):
        self.assertEqual(UPDATER, self.pelican["startup_commands"]["Default"])
        self.assertEqual(UPDATER, self.pterodactyl["startup"])

        pelican_install = self.pelican["scripts"]["installation"]
        pterodactyl_install = self.pterodactyl["scripts"]["installation"]
        self.assertEqual(INSTALLER, pelican_install["script"])
        self.assertEqual(INSTALLER, pterodactyl_install["script"])
        self.assertEqual(
            "ghcr.io/pelican-eggs/installers:alpine",
            pelican_install["container"],
        )
        self.assertEqual(
            "ghcr.io/pterodactyl/installers:alpine",
            pterodactyl_install["container"],
        )
        self.assertEqual("ash", pelican_install["entrypoint"])
        self.assertEqual("ash", pterodactyl_install["entrypoint"])


if __name__ == "__main__":
    unittest.main()
