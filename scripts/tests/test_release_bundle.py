"""Offline tests: /usr/bin/python3 -B -m unittest discover -s scripts/tests -v."""

import hashlib
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET


SCRIPT = Path(__file__).resolve().parents[1] / "release_bundle.py"
SPEC = importlib.util.spec_from_file_location("release_bundle", SCRIPT)
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)
REPO = "leon-wenhao/flow-quota"
VERSION = "1.2.3"
BUILD = 18
TAG = "v1.2.3"


class ReleaseBundleTests(unittest.TestCase):
    def setUp(self):
        # Only the Keychain/signing boundary is mocked. XML, release metadata,
        # paths, checksums and whitelist validation remain real.
        signature = base64.b64encode(bytes(64)).decode()
        def signed_feed(path, tool):
            data = path.read_bytes()
            path.write_bytes(data + ("<!-- sparkle-signatures:\nedSignature: " + signature +
                "\nlength: " + str(len(data)) + "\n-->\n").encode())
        for name, options in (
            ("signer", {"return_value": "test-signer"}),
            ("sign_archive", {"return_value": signature}),
            ("sign_feed", {"side_effect": signed_feed}),
            ("verify_signatures", {"return_value": None}),
        ):
            patcher = mock.patch.object(bundle.sparkle_feed, name, **options)
            patcher.start()
            self.addCleanup(patcher.stop)
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
        args = dict(output=self.output, source_manifest=self.source, repo=REPO, source_commit="a" * 40,
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
        self.assertEqual(len(paths), 8)
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
                                        "assets", "signing", "notarized", "sourceCommit"})
        self.assertEqual(release["signing"], "ad-hoc")
        self.assertIs(release["notarized"], False)
        public = "\n".join((self.output / name).read_text() for name in bundle.METADATA)
        for secret in ("deadbeef" * 5, "/private/source/tree", "DO-NOT-PUBLISH", "private/source"):
            self.assertNotIn(secret, public)
        notes = (self.output / "RELEASE-NOTES.md").read_text()
        self.assertEqual(notes.splitlines()[0], "# 1.2.3")
        for text in ("功能概述", "更新摘要", "macOS 14.0", "arm64", "x86_64", "ad-hoc", "公证",
                     "隐私与安全性", "仍要打开", "不阻断连接"):
            self.assertIn(text, notes)
        for text in ("其他未识别（Clash）", "网络分类修正", "全部来源排行", "停止采集进度",
                     "仅支持 Clash／Mihomo", "重启后仍保留", "触发当时", "用量详情"):
            self.assertIn(text, notes)
        for obsolete in ("Clash 识别来源单列辅助明细", "上传、下载分别显示未识别／计量差额"):
            self.assertNotIn(obsolete, notes)
        self.assertNotIn("xattr", notes)
        self.assertNotIn("spctl", notes)

    def test_appcast_description_uses_concrete_release_notes(self):
        expected = (
            "本次更新", "用量图表", "全部来源排行", "Clash／Mihomo",
            "下载后自动替换并重启", "ad-hoc", "Apple 公证"
        )
        old_description = bundle.sparkle_feed.INSTALL_DESCRIPTION
        descriptions = []
        for name in bundle.sparkle_feed.FEEDS:
            data = (self.output / name).read_bytes()
            length = int(bundle.sparkle_feed.SIGNATURE.search(data)[2])
            root = ET.fromstring(data[:length])
            description_node = root.find("channel/item/description")
            description = description_node.text
            descriptions.append(description)
            for text in expected:
                self.assertIn(text, description)
            self.assertEqual(description_node.get("{" + bundle.sparkle_feed.NS + "}format"), "html")
            self.assertTrue(description.startswith("<h3>本次更新</h3><ul><li>"))
            self.assertIn("</li><li>", description)
            self.assertIn("<h3>安装与安全</h3>", description)
            self.assertNotIn("<h3>系统与安装包</h3>", description)
            self.assertNotEqual(description, old_description)
        self.assertEqual(descriptions[0], descriptions[1])

    def test_feed_architecture_version_and_signature_are_required(self):
        path = self.output / "appcast-arm64.xml"
        original = path.read_bytes()
        for bad in (original.replace(b"arm64.dmg", b"x86_64.dmg"),
                    original.replace(b"1.2.3", b"9.9.9"),
                    original.split(b"<!-- sparkle-signatures:")[0],
                    original + b"<extra/>"):
            path.write_bytes(bad)
            self.reject()
        path.write_bytes(original)
        bundle.validate_bundle(self.output, REPO)
        self.assertEqual(len(bundle.sparkle_feed.verify_signatures.call_args.args[0]), 4)

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
                             ("url", base.replace(TAG, "v1.2.3-build.18") + self.names[0]),
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
        read_bytes = Path.read_bytes
        def read_metadata(path):
            if path.suffix == ".dmg":
                raise AssertionError("Must hash DMGs in chunks")
            return read_bytes(path)
        with mock.patch.object(bundle, "CHUNK_SIZE", 3), mock.patch.object(
                Path, "read_bytes", read_metadata):
            self.prepare()
        path = self.output / "update-manifest.json"
        path.write_text(path.read_text().replace('"build": 18', '"build": 18, "build": 18'))
        self.reject()

    def test_cli_rejects_invalid_signature_and_wrong_repository(self):
        # Public validation needs no private key. Zero signatures used by unit
        # fixtures must be rejected by the real subprocess verification boundary.
        common = [sys.executable, "-B", str(SCRIPT), "validate", "--output", str(self.output)]
        for repo in (REPO, "other/repo"):
            result = subprocess.run(common + ["--repo", repo], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("release bundle:", result.stderr)
            self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
