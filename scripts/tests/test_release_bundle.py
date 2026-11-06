"""Offline tests: /usr/bin/python3 -B -m unittest discover -s scripts/tests -v."""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "release_bundle.py"
SPEC = importlib.util.spec_from_file_location("release_bundle", SCRIPT)
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)
REPO = "leon-wenhao/flow-quota-releases"
VERSION = "1.2.3"
BUILD = 18
TAG = "v1.2.3-build.18"


class ReleaseBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "bundle"
        self.output.mkdir()
        self.source = self.root / "private-source.json"
        self.source_data = {
            "schemaVersion": 2, "version": VERSION, "build": BUILD,
            "minimumSystemVersion": "14.0", "sourceCommit": "deadbeef" * 5,
            "sourcePath": "/private/source/tree", "private": "DO-NOT-PUBLISH",
            "releaseNotesURL": "https://github.com/private/source/releases/latest",
        }
        self.write_json(self.source, self.source_data)
        self.names = ["FlowQuota-1.2.3-{}.dmg".format(arch) for arch in ("arm64", "x86_64")]
        for name in self.names:
            (self.output / name).write_bytes(("tiny DMG " + name).encode("ascii"))
        self.prepare()

    @staticmethod
    def write_json(path, data):
        path.write_text(json.dumps(data), encoding="utf-8")

    def prepare(self, **changes):
        args = dict(output=self.output, source_manifest=self.source, repo=REPO,
                    version=VERSION, build=BUILD)
        args.update(changes)
        return bundle.prepare_bundle(**args)

    def edit(self, name, change):
        path = self.output / name
        data = json.loads(path.read_text(encoding="utf-8"))
        change(data)
        self.write_json(path, data)

    def reject(self):
        with self.assertRaises((ValueError, OSError)):
            bundle.validate_bundle(self.output, REPO)

    def test_public_bundle_and_explicit_allowlist(self):
        manifest, paths = bundle.validate_bundle(str(self.output), REPO)
        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(manifest["build"], BUILD)
        self.assertEqual([p.name for p in paths], self.names + list(bundle.METADATA))
        self.assertEqual(len(paths), 6)
        self.assertTrue(all(p.is_file() for p in paths))
        release_url = "https://github.com/{}/releases/tag/{}".format(REPO, TAG)
        self.assertEqual(manifest["downloadURL"], release_url)
        for arch, name in zip(("arm64", "x86_64"), self.names):
            package = manifest["packages"]["macos/" + arch]
            data = (self.output / name).read_bytes()
            self.assertEqual(package, {
                "format": "dmg", "fileName": name, "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "url": "https://github.com/{}/releases/download/{}/{}".format(REPO, TAG, name),
            })
        release = json.loads((self.output / "release-manifest.json").read_text())
        self.assertEqual(set(release), {"version", "build", "releaseURL", "minimumSystemVersion",
                                        "assets", "signing", "notarized"})
        self.assertEqual(release["signing"], "ad-hoc")
        self.assertIs(release["notarized"], False)
        public = "\n".join((self.output / name).read_text() for name in bundle.METADATA)
        for secret in ("deadbeef" * 5, "/private/source/tree", "DO-NOT-PUBLISH", "private/source"):
            self.assertNotIn(secret, public)
        notes = (self.output / "RELEASE-NOTES.md").read_text()
        for text in ("功能概述", "macOS 14.0", "arm64", "x86_64", "ad-hoc", "公证",
                     "隐私与安全性", "仍要打开", "不阻断连接"):
            self.assertIn(text, notes)
        self.assertNotIn("xattr", notes)
        self.assertNotIn("spctl", notes)

    def test_version_build_and_minimum_are_strict(self):
        for version in ("1.2", "01.2.3", "v1.2.3", "1.2.3\n", "../1.2.3", 123):
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.prepare(version=version)
        for build in (0, -1, True, 18.0, "18", 2**63):
            with self.subTest(build=build), self.assertRaises(ValueError):
                self.prepare(build=build)
        for field, value in (("version", "1.2.4"), ("build", 19), ("build", True),
                             ("minimumSystemVersion", None),
                             ("minimumSystemVersion", "/private/source/tree")):
            with self.subTest(field=field, value=value):
                self.write_json(self.source, dict(self.source_data, **{field: value}))
                with self.assertRaises(ValueError):
                    self.prepare()

    def test_validate_rejects_bad_manifest_fields(self):
        cases = [("version", "../1.2.3"), ("build", True), ("build", 0),
                 ("build", "18"), ("build", 18.0), ("build", 2**63),
                 ("schemaVersion", True), ("schemaVersion", 1), ("schemaVersion", 2.0),
                 ("product", "other"), ("channel", "beta"), ("packages", []),
                 ("publishedAt", "yesterday"), ("minimumSystemVersion", "14\n")]
        for field, value in cases:
            with self.subTest(field=field, value=value):
                self.prepare()
                self.edit("update-manifest.json", lambda data: data.update({field: value}))
                self.reject()

    def test_digest_and_size(self):
        for field, value in (("size", 0), ("size", -1), ("size", True), ("size", 1.0),
                             ("size", 12345), ("sha256", "f" * 64),
                             ("sha256", "A" * 64), ("sha256", "g" * 64), ("sha256", "abc")):
            with self.subTest(field=field, value=value):
                self.prepare()
                self.edit("update-manifest.json", lambda data:
                          data["packages"]["macos/arm64"].update({field: value}))
                self.reject()
        self.prepare()
        path = self.output / self.names[0]
        path.write_bytes(b"X" * path.stat().st_size)  # Same length, different digest.
        self.reject()
        path.write_bytes(b"")
        with self.assertRaises(ValueError):
            self.prepare()

    def test_paths_urls_and_architectures(self):
        base = "https://github.com/{}/releases/download/{}/".format(REPO, TAG)
        for field, value in (("fileName", "../" + self.names[0]),
                             ("fileName", str(self.output / self.names[0])),
                             ("fileName", self.names[1]), ("format", "zip"),
                             ("url", base + "../" + self.names[0]),
                             ("url", base + self.names[1]),
                             ("url", base.replace(TAG, "v1.2.3") + self.names[0]),
                             ("url", base + self.names[0] + "?token=secret"),
                             ("url", base.replace("https:", "http:") + self.names[0])):
            with self.subTest(field=field, value=value):
                self.prepare()
                self.edit("update-manifest.json", lambda data:
                          data["packages"]["macos/arm64"].update({field: value}))
                self.reject()
        self.prepare()
        self.edit("update-manifest.json", lambda data: data["packages"].update({"macos/other": {}}))
        self.reject()
        self.prepare()
        self.edit("update-manifest.json", lambda data: data["packages"].pop("macos/x86_64"))
        self.reject()

    def test_cross_repo_and_release_urls(self):
        with self.assertRaises(ValueError):
            bundle.validate_bundle(self.output, "other/releases")
        for field in ("downloadURL", "releaseNotesURL"):
            self.prepare()
            self.edit("update-manifest.json", lambda data: data.update({field:
                      "https://github.com/private/source/releases/tag/" + TAG}))
            self.reject()
        for repo in ("../releases", "owner/repo/extra", "https://github.com/owner/repo", "a/b\n"):
            with self.subTest(repo=repo), self.assertRaises(ValueError):
                self.prepare(repo=repo)

    def test_release_manifest_consistency_and_privacy(self):
        for field, value in (("build", True), ("build", 19), ("version", "1.2.4"),
                             ("minimumSystemVersion", "15.0"), ("signing", "Developer ID"),
                             ("notarized", 0), ("notarized", True), ("assets", []),
                             ("releaseURL", "https://github.com/other/repo/releases/tag/" + TAG),
                             ("sourceCommit", "deadbeef")):
            with self.subTest(field=field):
                self.prepare()
                self.edit("release-manifest.json", lambda data: data.update({field: value}))
                self.reject()
        for field, value in (("file", "../secret.dmg"), ("size", 0), ("size", 1.0),
                             ("sha256", "0" * 64)):
            self.prepare()
            self.edit("release-manifest.json", lambda data: data["assets"][0].update({field: value}))
            self.reject()
        self.prepare()
        self.edit("update-manifest.json", lambda data: data.update({"sourcePath": "/private"}))
        self.reject()

    def test_checksums_and_notes_tampering(self):
        for name in ("SHA256SUMS", "RELEASE-NOTES.md"):
            self.prepare()
            path = self.output / name
            path.write_text(path.read_text() + "private source data\n")
            self.reject()

    def test_missing_extra_directory_and_symlink(self):
        for name in self.names + list(bundle.METADATA):
            with self.subTest(missing=name):
                path = self.output / name
                saved = path.read_bytes()
                path.unlink()
                self.reject()
                path.write_bytes(saved)
        for name in (".DS_Store", "source.zip"):
            path = self.output / name
            path.write_bytes(b"private")
            self.reject()
            with self.assertRaises(ValueError):
                self.prepare()
            path.unlink()
        extra = self.output / "directory"
        extra.mkdir()
        self.reject()
        extra.rmdir()
        for name in self.names + list(bundle.METADATA):
            path = self.output / name
            saved = path.read_bytes()
            target = self.root / "target"
            target.write_bytes(saved)
            path.unlink()
            path.symlink_to(target)
            self.reject()
            with self.assertRaises(ValueError):
                self.prepare()
            path.unlink()
            path.write_bytes(saved)
        link = self.root / "linked-output"
        link.symlink_to(self.output, target_is_directory=True)
        with self.assertRaises(ValueError):
            bundle.validate_bundle(link, REPO)

    def test_chunked_hashing_and_duplicate_json(self):
        with mock.patch.object(bundle, "CHUNK_SIZE", 3), mock.patch.object(
                Path, "read_bytes", side_effect=AssertionError("Must hash in chunks")):
            self.prepare()
        path = self.output / "update-manifest.json"
        path.write_text(path.read_text().replace('"build": 18', '"build": 18, "build": 18'))
        self.reject()

    def test_cli_prepare_validate_and_failure(self):
        common = [sys.executable, "-B", str(SCRIPT)]
        for args in (["prepare", "--source-manifest", str(self.source), "--version", VERSION,
                      "--build", str(BUILD)], ["validate"]):
            result = subprocess.run(common + args + ["--output", str(self.output), "--repo", REPO],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(TAG, result.stdout)
        result = subprocess.run(common + ["validate", "--output", str(self.output),
                                         "--repo", "other/repo"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release bundle:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
