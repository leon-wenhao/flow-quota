"""Offline host-specific feeds, resumable uploads and activation ordering."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gitee_release
import publish_dual
import push_sources
import sparkle_feed

SIGNATURE = base64.b64encode(bytes(64)).decode()


def sign_feed(path, tool):
    data = path.read_bytes()
    path.write_bytes(data + ("<!-- sparkle-signatures:\nedSignature: " + SIGNATURE +
                            "\nlength: " + str(len(data)) + "\n-->\n").encode())


class FakeGitee:
    def __init__(self):
        self.records, self.attachments, self.data = [], [], {}
        self.uploads, self.fail_name, self.bad_digest = [], None, False

    def releases(self):
        return copy.deepcopy(self.records)

    def write(self, path, fields, method="POST"):
        record = dict(fields, prerelease=fields["prerelease"] == "true", id=1)
        self.records = [record]
        return copy.deepcopy(record)

    def assets(self, release_id):
        return copy.deepcopy(self.attachments)

    def upload(self, release_id, path):
        if self.fail_name == path.name:
            raise ValueError("simulated upload failure")
        self.uploads.append(path.name)
        self.data[path.name] = path.read_bytes()
        self.attachments.append({"name": path.name, "size": path.stat().st_size,
            "browser_download_url": "https://gitee.com/Leon-wh/flow-quota/attach_files/" + path.name})

    def verify_asset(self, item, path):
        if self.bad_digest or hashlib.sha256(self.data[path.name]).digest() != hashlib.sha256(path.read_bytes()).digest():
            raise ValueError("SHA-256 mismatch")


class GiteeReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.bundle = Path(temporary.name) / "bundle"
        self.bundle.mkdir()
        self.manifest = {"version": "0.1.12", "build": 33, "minimumSystemVersion": "14.0", "packages": {}}
        (self.bundle / "RELEASE-NOTES.md").write_text("# 0.1.12\n\n## 更新摘要\n\n- 更新源改进\n")
        (self.bundle / "release-manifest.json").write_text(json.dumps({"sourceCommit": "a" * 40}))
        for name in ["SHA256SUMS", "update-manifest.json"]:
            (self.bundle / name).write_text("metadata")
        for arch in ["arm64", "x86_64"]:
            name = "FlowQuota-0.1.12-" + arch + ".dmg"
            (self.bundle / name).write_bytes(("package " + arch).encode())
            self.manifest["packages"]["macos/" + arch] = {"fileName": name, "size": (self.bundle / name).stat().st_size,
                "url": "https://github.com/leon-wenhao/flow-quota/releases/download/v0.1.12/" + name}
            path = self.bundle / ("appcast-" + arch + ".xml")
            path.write_bytes(sparkle_feed.make_xml(self.manifest, arch, SIGNATURE,
                sparkle_feed.description_from_notes(self.bundle / "RELEASE-NOTES.md")))
            sign_feed(path, "fake")
        for name, options in [("signer", {"return_value": "fake"}),
                              ("sign_feed", {"side_effect": sign_feed}),
                              ("verify_signatures", {"return_value": None})]:
            patcher = mock.patch.object(sparkle_feed, name, **options)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = mock.patch.object(gitee_release, "verify_gitee_source")
        self.source = patcher.start()
        self.addCleanup(patcher.stop)
        self.api = FakeGitee()

    def mirror(self):
        return gitee_release.GiteeRelease(self.api, self.bundle, self.manifest, list(self.bundle.iterdir()))

    def test_feed_urls_and_signatures_belong_to_correct_hosts_same_package_bytes(self):
        before = {p.name: p.read_bytes() for p in self.bundle.iterdir()}
        mirror = self.mirror()
        mirror.stage()
        self.assertTrue(self.api.records[0]["prerelease"])
        for name in sparkle_feed.FEEDS:
            feed = ET.fromstring(self.api.data[name])
            enclosure = feed.find("channel/item/enclosure")
            self.assertTrue(enclosure.attrib["url"].startswith("https://gitee.com/"))
            self.assertEqual(enclosure.attrib["{" + sparkle_feed.NS + "}edSignature"], SIGNATURE)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.bundle.iterdir()})
        self.assertEqual(len(self.api.attachments), 8)
        mirror.activate()
        self.assertFalse(self.api.records[0]["prerelease"])
        self.assertIn("<!-- flow-quota-ready:33 -->", self.api.records[0]["body"])
        count = len(self.api.uploads)
        self.mirror().stage()
        self.assertEqual(len(self.api.uploads), count)

    def test_interrupted_stage_resumes_missing_only_without_activating(self):
        self.api.fail_name = "appcast-x86_64.xml"
        with self.assertRaisesRegex(ValueError, "upload failure"):
            self.mirror().stage()
        self.assertTrue(self.api.records[0]["prerelease"])
        self.assertNotIn("flow-quota-ready", self.api.records[0]["body"])
        self.api.fail_name = None
        self.mirror().stage()
        self.assertEqual(len(self.api.uploads), 8)

    def test_mismatch_unexpected_assets_and_source_conflict_abort(self):
        mirror = self.mirror()
        mirror.stage()
        self.api.bad_digest = True
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            mirror.activate()
        self.assertTrue(self.api.records[0]["prerelease"])
        self.api.bad_digest = False
        self.api.attachments.append(dict(self.api.attachments[0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.mirror().stage()
        self.source.side_effect = ValueError("tag mismatch")
        with self.assertRaisesRegex(ValueError, "tag mismatch"):
            self.mirror().stage()

    def test_rollback_and_same_version_rebuild_are_rejected(self):
        mirror = self.mirror()
        mirror.stage()
        for tag, build in [("v0.1.13", 34), ("v0.1.10", 33), ("v0.1.12", 34)]:
            self.api.records = [{"id": 8, "tag_name": tag, "prerelease": False,
                "body": "<!-- flow-quota-ready:{} -->".format(build)}]
            with self.assertRaises(ValueError):
                mirror.check_monotonic()

    def test_local_feed_tampering_is_rejected(self):
        self.mirror().stage()
        feed = self.bundle.parent / "bundle-gitee/appcast-arm64.xml"
        feed.write_bytes(feed.read_bytes().replace(b"gitee.com", b"evilx.com"))
        with self.assertRaisesRegex(ValueError, "immutable"):
            self.mirror().stage()

    def test_active_release_missing_asset_is_never_repaired_in_place(self):
        mirror = self.mirror()
        mirror.stage()
        mirror.activate()
        self.api.attachments.pop()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.mirror().stage()
        self.assertEqual(len(self.api.uploads), 8)


class DualPublisherTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.bundle = Path(temporary.name) / "bundle"
        self.bundle.mkdir()
        (self.bundle / "release-manifest.json").write_text(json.dumps({"sourceCommit": "a" * 40}))
        self.events = []
        self.manifest = {"version": "0.1.12", "build": 33}
        replacements = {"validate_bundle": mock.Mock(return_value=(self.manifest, [])),
            "credential": mock.Mock(return_value="private"), "check_repositories": mock.Mock(),
            "git": mock.Mock(return_value=""), "push": mock.Mock(side_effect=lambda _: self.events.append("sources")),
            "publish": mock.Mock(side_effect=lambda *a: self.events.append("github-published")),
            "activate_manifest": mock.Mock(side_effect=lambda *a, **kw: self.events.append("github-preflight" if kw else "github-active")),
            "GiteeAPI": mock.Mock(), "GiteeRelease": mock.Mock()}
        for name, value in replacements.items():
            patcher = mock.patch.object(publish_dual, name, value)
            setattr(self, name, patcher.start())
            self.addCleanup(patcher.stop)
        self.mirror = self.GiteeRelease.return_value
        self.mirror.stage.side_effect = lambda: self.events.append("gitee-verified")
        self.mirror.activate.side_effect = lambda: self.events.append("gitee-active")

    def test_activate_only_after_both_verified_and_github_rollback_preflight(self):
        publish_dual.publish_dual(self.bundle, True)
        self.assertEqual(self.events, ["sources", "github-published", "gitee-verified", "github-preflight", "gitee-active", "github-active"])

    def test_partial_publication_receipt_and_no_activation_on_gitee_failure(self):
        self.mirror.stage.side_effect = ValueError("upload failed")
        with self.assertRaises(ValueError):
            publish_dual.publish_dual(self.bundle, True)
        self.activate_manifest.assert_not_called()
        self.mirror.activate.assert_not_called()
        state = json.loads((self.bundle.parent / "bundle-publication.json").read_text())
        self.assertTrue(state["githubPublished"])
        self.assertFalse(state["giteeVerified"])

    def test_missing_credential_fails_before_tag_push_or_publication(self):
        self.credential.side_effect = ValueError("credential missing")
        with self.assertRaises(ValueError):
            publish_dual.publish_dual(self.bundle, True)
        self.push.assert_not_called()
        self.publish.assert_not_called()
        self.assertEqual(self.git.call_count, 1)  # read-only status

    def test_staging_does_not_activate_and_rollback_failure_keeps_both_inactive(self):
        publish_dual.publish_dual(self.bundle, False)
        self.activate_manifest.assert_not_called()
        self.mirror.activate.assert_not_called()
        self.activate_manifest.side_effect = ValueError("rollback")
        with self.assertRaises(ValueError):
            publish_dual.publish_dual(self.bundle, True)
        self.mirror.activate.assert_not_called()

    def test_source_sync_failure_cannot_publish_either_release(self):
        self.push.side_effect = ValueError("partial source sync")
        with self.assertRaises(ValueError):
            publish_dual.publish_dual(self.bundle, True)
        self.publish.assert_not_called()
        self.mirror.stage.assert_not_called()


class SourceSyncTests(unittest.TestCase):
    @mock.patch.object(push_sources, "api")
    @mock.patch.object(push_sources, "git")
    def test_partial_source_push_reports_completed_host_without_force(self, git, api):
        commands = []
        def command(*args):
            commands.append(args)
            if args[:2] == ("status", "--porcelain"):
                return ""
            if args[0] == "rev-parse":
                return "a" * 40
            if args[0] == "push" and args[2] == push_sources.GITEE:
                raise ValueError("SSH unavailable")
            return ""
        git.side_effect = command
        api.return_value = {"object": {"sha": "a" * 40}}
        with self.assertRaisesRegex(ValueError, "completed=\['GitHub'\].*failed=Gitee"):
            push_sources.push()
        pushes = [args for args in commands if args[0] == "push"]
        self.assertEqual([args[2] for args in pushes], [push_sources.GITHUB, push_sources.GITEE])
        self.assertTrue(all(args[1] == "--atomic" and "--force" not in args for args in pushes))

    @mock.patch.object(push_sources, "gitee_refs")
    def test_gitee_tag_conflict_fails_before_ancestry_check(self, refs):
        refs.return_value = {"refs/heads/main": "a" * 40, "refs/tags/v0.1.12": "b" * 40}
        with mock.patch.object(push_sources, "git") as git:
            with self.assertRaisesRegex(ValueError, "tag does not point"):
                push_sources.verify_gitee_source("a" * 40, "v0.1.12")
            git.assert_not_called()

    @mock.patch.object(push_sources, "git", return_value=" M unreviewed.swift")
    def test_dirty_source_never_pushes(self, git):
        with self.assertRaisesRegex(ValueError, "Commit reviewed"):
            push_sources.push()
        git.assert_called_once_with("status", "--porcelain")


if __name__ == "__main__":
    unittest.main()
