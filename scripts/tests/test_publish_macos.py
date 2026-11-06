"""Offline publication, retry, immutable asset and latest activation tests."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import publish_macos as publisher

REPO = publisher.PUBLIC_REPO
TAG = "v1.2.3-build.7"
COMMIT = "a" * 40
MANIFEST = {"version": "1.2.3", "build": 7}


class PublisherTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.bundle = Path(temporary.name).resolve()
        self.assets = [self.bundle / name for name in (
            "FlowQuota-1.2.3-arm64.dmg", "FlowQuota-1.2.3-x86_64.dmg", "SHA256SUMS",
            "update-manifest.json", "release-manifest.json", "RELEASE-NOTES.md")]
        for path in self.assets:
            path.write_bytes(("offline fixture " + path.name).encode())
        (self.bundle / "release-manifest.json").write_text(json.dumps({"sourceCommit": COMMIT}))
        self.real_activate = publisher.activate_manifest
        self.real_lookup = publisher.release_for_tag
        self.patch(subprocess, "check_output", side_effect=AssertionError("Unexpected subprocess"))
        self.patch(subprocess, "run", side_effect=AssertionError("Unexpected subprocess"))
        self.check = self.patch(publisher, "check_repositories")
        self.run = self.patch(publisher, "run", return_value="")
        self.validate = self.patch(publisher, "validate_bundle", return_value=(MANIFEST, self.assets))
        self.tag = self.patch(publisher, "ensure_public_tag")
        self.release = self.patch(publisher, "release_for_tag", return_value={"id": 42, "draft": True})
        self.api = self.patch(publisher, "api", return_value=self.remote_assets())
        self.activate = self.patch(publisher, "activate_manifest")

    def patch(self, target, name, **kwargs):
        patcher = mock.patch.object(target, name, **kwargs)
        self.addCleanup(patcher.stop)
        return patcher.start()

    def remote_assets(self):
        return [{"name": p.name, "state": "uploaded", "size": p.stat().st_size,
                 "digest": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest()} for p in self.assets]

    def publish(self, activate=True):
        publisher.publish(self.bundle, REPO, activate)

    def commands(self):
        return [call.args for call in self.run.call_args_list if call.args[:2] == ("gh", "release")]

    def test_new_draft_uses_exact_source_tag_and_explicit_asset_list(self):
        self.release.side_effect = [None, {"id": 42, "draft": True}]
        self.api.side_effect = [[], self.remote_assets()]
        self.publish()
        self.tag.assert_called_once_with(REPO, TAG, COMMIT)
        commands = self.commands()
        self.assertEqual([c[2] for c in commands], ["create", "upload", "edit"])
        self.assertIn("--verify-tag", commands[0])
        self.assertIn("--latest=false", commands[0])
        self.assertEqual(commands[1], ("gh", "release", "upload", TAG, "--repo", REPO, *map(str, self.assets)))
        self.assertIn("--latest=false", commands[-1])
        self.activate.assert_called_once_with(self.bundle, REPO, TAG)

    def test_partial_draft_only_uploads_missing_identical_assets(self):
        self.api.side_effect = [self.remote_assets()[:2], self.remote_assets()]
        self.publish()
        self.assertEqual(self.commands()[0], ("gh", "release", "upload", TAG, "--repo", REPO,
                                             *map(str, self.assets[2:])))

    def test_different_size_hash_status_missing_digest_or_extra_asset_stops_publication(self):
        for field, value in (("size", 0), ("digest", "sha256:" + "0" * 64),
                             ("digest", None), ("state", "new"), ("name", "source.zip")):
            with self.subTest(field=field):
                self.api.return_value = self.remote_assets()
                self.api.return_value[0][field] = value
                with self.assertRaises(ValueError):
                    self.publish()
                self.assertEqual(self.commands(), [])
                self.activate.assert_not_called()
        with self.assertRaises(ValueError):
            publisher.verify_assets(self.remote_assets() * 2, self.assets, True)

    def test_published_release_is_only_verified_not_overwritten(self):
        self.release.return_value = {"id": 42, "draft": False}
        self.publish()
        self.assertEqual(self.commands(), [])
        self.activate.assert_called_once()
        self.api.return_value = self.remote_assets()[:-1]
        with self.assertRaises(ValueError):
            self.publish()

    def test_upload_and_verification_precede_publish_and_activation(self):
        events = mock.Mock()
        events.attach_mock(self.api, "assets")
        events.attach_mock(self.run, "command")
        events.attach_mock(self.activate, "activate")
        self.api.side_effect = [[], self.remote_assets()]
        self.publish()
        steps = [c[0] for c in events.mock_calls if c[0] != "command" or c.args[:2] == ("gh", "release")]
        self.assertEqual(steps, ["assets", "command", "assets", "command", "activate"])

    def test_upload_failure_cannot_activate_or_publish(self):
        self.api.return_value = []
        self.run.side_effect = lambda *args, **kw: (_ for _ in ()).throw(
            subprocess.CalledProcessError(1, args)) if args[:3] == ("gh", "release", "upload") else ""
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.activate.assert_not_called()
        self.assertNotIn("edit", [c[2] for c in self.commands()])

    def test_dirty_source_and_invalid_bundle_fail_before_creating_tag(self):
        self.run.return_value = " M source.swift"
        with self.assertRaises(ValueError):
            self.publish()
        self.tag.assert_not_called()
        self.run.return_value = ""
        self.validate.side_effect = ValueError("Invalid bundle")
        with self.assertRaises(ValueError):
            self.publish()
        self.tag.assert_not_called()

    def test_skip_activation_does_not_mark_latest(self):
        self.publish(activate=False)
        self.activate.assert_not_called()
        self.assertIn("--latest=false", self.commands()[-1])

    def test_draft_lookup_failure_is_not_absence(self):
        self.release.side_effect = [None, None]
        with self.assertRaisesRegex(ValueError, "not returned"):
            self.publish()
        self.activate.assert_not_called()
        self.run.side_effect = subprocess.CalledProcessError(1, ("gh", "api"))
        with self.assertRaises(subprocess.CalledProcessError):
            self.real_lookup(REPO, TAG)

    def test_activation_requires_published_and_matching_assets(self):
        for release in (None, {"id": 42, "draft": True}):
            self.release.return_value = release
            with self.assertRaisesRegex(ValueError, "unpublished"):
                self.real_activate(self.bundle, REPO, TAG)
        self.release.return_value = {"id": 42, "draft": False}
        self.api.return_value = self.remote_assets()[:-1]
        with self.assertRaises(ValueError):
            self.real_activate(self.bundle, REPO, TAG)
        self.assertEqual(self.commands(), [])

    def test_latest_activation_rejects_rollback_and_accepts_first_same_or_older_release(self):
        self.release.return_value = {"id": 42, "draft": False}
        for latest in (None, {"tag_name": TAG}, {"tag_name": "v1.2.2-build.99"}):
            self.run.reset_mock()
            self.api.side_effect = [self.remote_assets(), latest]
            self.real_activate(self.bundle, REPO, TAG)
            self.assertEqual(self.commands(), [("gh", "release", "edit", TAG, "--repo", REPO, "--latest")])
        for tag in ("v1.2.4-build.1", "v1.2.3-build.8", "unsupported"):
            self.run.reset_mock()
            self.api.side_effect = [self.remote_assets(), {"tag_name": tag}]
            with self.assertRaises(ValueError):
                self.real_activate(self.bundle, REPO, TAG)
            self.assertEqual(self.commands(), [])


if __name__ == "__main__":
    unittest.main()
