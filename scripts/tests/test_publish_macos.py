"""Offline publisher safety tests: python3 -B -m unittest discover -s scripts/tests -v."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import public_repository as repositories
import publish_macos as publisher

REPO = repositories.PUBLIC_REPO
SOURCE = "example/private-source"
MANIFEST = {"version": "1.2.3", "build": 7}
TAG = "v1.2.3-build.7"


class OfflineTestCase(unittest.TestCase):
    def setUp(self):
        # Any subprocess escaping the mocks fails before gh/git can run.
        self.patch(subprocess, "check_output", side_effect=AssertionError("Unexpected subprocess"))

    def patch(self, target, name, **kwargs):
        patcher = mock.patch.object(target, name, **kwargs)
        self.addCleanup(patcher.stop)
        return patcher.start()


class RepositoryBoundaryTests(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.run = self.patch(repositories, "run", return_value="https://github.com/" + SOURCE + ".git")
        self.visibility = {SOURCE: True, REPO: False}
        self.api = self.patch(repositories, "api", side_effect=lambda endpoint: {
            "private": self.visibility[endpoint.removeprefix("repos/")]})

    def test_private_source_and_independent_public_target_are_accepted(self):
        repositories.check_repositories(REPO)
        self.assertEqual(self.api.call_args_list, [mock.call("repos/" + SOURCE), mock.call("repos/" + REPO)])

    def test_source_and_public_repository_cannot_be_the_same(self):
        self.run.return_value = "git@github.com:" + REPO + ".git"
        with self.assertRaisesRegex(ValueError, "independent"):
            repositories.check_repositories(REPO)
        self.api.assert_not_called()

    def test_source_cannot_become_public(self):
        self.visibility[SOURCE] = False
        with self.assertRaisesRegex(ValueError, "source repository must remain private"):
            repositories.check_repositories(REPO)

    def test_distribution_cannot_be_private(self):
        self.visibility[REPO] = True
        with self.assertRaisesRegex(ValueError, "distribution repository must be public"):
            repositories.check_repositories(REPO)

    def test_reversed_repository_roles_are_rejected(self):
        self.run.return_value = "https://github.com/" + REPO
        with self.assertRaisesRegex(ValueError, "independent"):
            repositories.check_repositories(SOURCE)
        self.api.assert_not_called()


class AssetFixture(OfflineTestCase):
    def setUp(self):
        super().setUp()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        names = ("FlowQuota-1.2.3-arm64.dmg", "FlowQuota-1.2.3-x86_64.dmg",
                 "SHA256SUMS", "update-manifest.json", "release-manifest.json", "RELEASE-NOTES.md")
        self.assets = [self.bundle / name for name in names]
        for path in self.assets:
            path.write_bytes(("offline fixture: " + path.name).encode())
        (self.bundle / "update-manifest.json").write_text(json.dumps(MANIFEST))

    def remote_assets(self):
        return [{"name": path.name, "state": "uploaded", "size": path.stat().st_size,
                 "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()}
                for path in self.assets]


class AssetValidationTests(AssetFixture):
    def test_exact_complete_assets_are_accepted(self):
        self.assertEqual(publisher.verify_assets(self.remote_assets(), self.assets, True),
                         {path.name for path in self.assets})

    def test_size_hash_missing_digest_and_upload_state_are_checked(self):
        for field, value in (("size", 0), ("digest", "sha256:" + "0" * 64),
                             ("digest", None), ("state", "new")):
            with self.subTest(field=field, value=value):
                remote = self.remote_assets()
                remote[0][field] = value
                with self.assertRaisesRegex(ValueError, "size/SHA-256 mismatch"):
                    publisher.verify_assets(remote, self.assets, True)
        remote = self.remote_assets()
        del remote[0]["digest"]
        with self.assertRaises(ValueError):
            publisher.verify_assets(remote, self.assets, False)

    def test_extra_and_duplicate_assets_are_rejected_even_for_drafts(self):
        for extra in ({"name": "private-source.zip"}, self.remote_assets()[0]):
            for complete in (False, True):
                with self.subTest(extra=extra["name"], complete=complete):
                    with self.assertRaisesRegex(ValueError, "Unexpected or duplicate"):
                        publisher.verify_assets(self.remote_assets() + [extra], self.assets, complete)

    def test_missing_assets_are_allowed_only_for_incomplete_drafts(self):
        for remote in ([], self.remote_assets()[:-1]):
            with self.subTest(count=len(remote)):
                self.assertEqual(publisher.verify_assets(remote, self.assets, False),
                                 {item["name"] for item in remote})
                with self.assertRaisesRegex(ValueError, "incomplete"):
                    publisher.verify_assets(remote, self.assets, True)


class PublishSafetyTests(AssetFixture):
    def setUp(self):
        super().setUp()
        self.patch(publisher, "check_repositories")
        self.audit = self.patch(publisher, "audit_public_history")
        self.tag = self.patch(publisher, "ensure_public_tag")
        self.patch(publisher, "validate_bundle", return_value=(MANIFEST.copy(), self.assets))
        self.lookup = publisher.release_for_tag
        self.release = self.patch(publisher, "release_for_tag", return_value={"id": 42, "draft": True})
        self.api = self.patch(publisher, "api", return_value=self.remote_assets())
        self.run = self.patch(publisher, "run", return_value="")
        self.activate_real = publisher.activate_manifest
        self.activate = self.patch(publisher, "activate_manifest")
        self.read = self.patch(publisher, "read_public_file")
        self.commit = self.patch(publisher, "commit_public_files")
        self.patch(publisher, "print")

    def publish(self, activate=True):
        publisher.publish(self.bundle, REPO, activate)

    def release_commands(self):
        return [call.args for call in self.run.call_args_list if call.args[:2] == ("gh", "release")]

    def fail_command(self, operation):
        def run(*args, **kwargs):
            if args[:3] == ("gh", "release", operation):
                raise subprocess.CalledProcessError(1, args)
            return ""
        self.run.side_effect = run

    def test_draft_creation_failure_never_activates_manifest(self):
        self.release.return_value = None
        self.fail_command("create")
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.activate.assert_not_called()
        self.api.assert_not_called()
        self.assertEqual([args[2] for args in self.release_commands()], ["create"])

    def test_new_release_is_created_as_draft_before_upload(self):
        self.release.side_effect = [None, {"id": 42, "draft": True}]
        self.api.side_effect = [[], self.remote_assets()]
        self.publish()
        commands = self.release_commands()
        self.assertEqual([args[2] for args in commands], ["create", "upload", "edit"])
        self.audit.assert_called_once_with(REPO)
        self.tag.assert_called_once_with(REPO, TAG)
        self.assertIn("--draft", commands[0])
        self.assertIn("--verify-tag", commands[0])
        self.assertEqual(commands[0][commands[0].index("--title") + 1], "Flow Quota 1.2.3")
        self.assertEqual(commands[1][6:], tuple(map(str, self.assets)))
        self.activate.assert_called_once_with(self.bundle, REPO, TAG)

    def test_upload_failure_never_publishes_or_activates(self):
        self.api.return_value = []
        self.fail_command("upload")
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.activate.assert_not_called()
        self.assertEqual([args[2] for args in self.release_commands()], ["upload"])

    def test_incomplete_post_upload_verification_prevents_publication(self):
        self.api.side_effect = [[], self.remote_assets()[:-1]]
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.publish()
        self.activate.assert_not_called()
        self.assertEqual([args[2] for args in self.release_commands()], ["upload"])

    def test_failed_draft_publication_never_activates(self):
        self.fail_command("edit")
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.activate.assert_not_called()

    def test_published_release_is_verified_without_overwriting(self):
        self.release.return_value = {"id": 42, "draft": False}
        self.publish()
        self.assertEqual(self.release_commands(), [])
        self.tag.assert_not_called()
        self.activate.assert_called_once_with(self.bundle, REPO, TAG)
        self.api.assert_called_once_with("repos/" + REPO + "/releases/42/assets")

    def test_bad_published_release_is_rejected_without_repair(self):
        self.release.return_value = {"id": 42, "draft": False}
        for damage in ("missing", "digest", "extra"):
            with self.subTest(damage=damage):
                self.api.return_value = self.remote_assets()
                if damage == "missing":
                    self.api.return_value.pop()
                elif damage == "digest":
                    self.api.return_value[0]["digest"] = "sha256:" + "0" * 64
                else:
                    self.api.return_value.append({"name": "unexpected.zip"})
                with self.assertRaises(ValueError):
                    self.publish()
                self.activate.assert_not_called()
                self.assertEqual(self.release_commands(), [])

    def test_same_bundle_draft_resumes_only_missing_assets_before_activation(self):
        events = mock.Mock()
        events.attach_mock(self.api, "assets")
        events.attach_mock(self.run, "command")
        events.attach_mock(self.activate, "activate")
        self.api.side_effect = [self.remote_assets()[:2], self.remote_assets()]
        self.publish()
        self.assertEqual(self.release_commands(), [
            ("gh", "release", "upload", TAG, "--repo", REPO, *map(str, self.assets[2:])),
            ("gh", "release", "edit", TAG, "--repo", REPO, "--draft=false", "--latest")])
        steps = [call[0] for call in events.mock_calls
                 if call[0] != "command" or call.args[:2] == ("gh", "release")]
        self.assertEqual(steps, ["assets", "command", "assets", "command", "activate"])
        self.activate.assert_called_once_with(self.bundle, REPO, TAG)

    def test_complete_draft_needs_no_reupload_and_can_skip_activation(self):
        self.publish(activate=False)
        self.assertEqual([args[2] for args in self.release_commands()], ["edit"])
        self.activate.assert_not_called()

    def test_different_bundle_draft_is_not_overwritten(self):
        remote = self.remote_assets()
        remote[0]["digest"] = "sha256:" + "0" * 64
        self.api.return_value = remote
        with self.assertRaisesRegex(ValueError, "size/SHA-256 mismatch"):
            self.publish()
        self.assertEqual(self.release_commands(), [])
        self.activate.assert_not_called()

    def test_release_lookup_errors_are_not_treated_as_absent_releases(self):
        # Exercise the real lookup, including its subprocess error propagation.
        self.run.side_effect = subprocess.CalledProcessError(1, ("gh", "api"))
        with self.assertRaises(subprocess.CalledProcessError):
            self.lookup(REPO, TAG)

    def test_release_lookup_finds_tag_across_pages(self):
        expected = {"tag_name": TAG, "id": 42, "draft": True}
        self.run.return_value = json.dumps([[{"tag_name": "other"}], [expected]])
        self.assertEqual(self.lookup(REPO, TAG), expected)
        self.assertIsNone(self.lookup(REPO, "missing"))

    def activate_manifest(self, previous):
        self.release.return_value = {"id": 42, "draft": False}
        self.read.return_value = ("validated-public-head", previous)
        self.activate_real(self.bundle, REPO, TAG)

    def test_activation_rejects_rollback_and_same_version_changes(self):
        for version, build in (("1.2.4", 1), ("2.0.0", 1), ("1.2.3", 8), ("1.2.3", 7)):
            with self.subTest(version=version, build=build):
                previous = json.dumps({"version": version, "build": build}, indent=2).encode()
                error = "different public manifest" if (version, build) == ("1.2.3", 7) else "roll back"
                with self.assertRaisesRegex(ValueError, error):
                    self.activate_manifest(previous)
                self.commit.assert_not_called()

    def test_activation_commits_only_manifest_with_validated_head(self):
        content = (self.bundle / "update-manifest.json").read_bytes()
        for previous in (None, content, b'{"version":"1.2.2","build":99}',
                         b'{"version":"1.2.3","build":6}'):
            with self.subTest(previous=previous):
                self.commit.reset_mock()
                self.activate_manifest(previous)
                self.read.assert_called_with(REPO, "update-manifest.json")
                self.commit.assert_called_once_with(REPO, {"update-manifest.json": content},
                                                   "release: activate " + TAG,
                                                   expected_head="validated-public-head")

    def test_activation_propagates_concurrent_head_conflict_without_retry(self):
        self.commit.side_effect = ValueError("Public main changed during validation")
        with self.assertRaisesRegex(ValueError, "main changed"):
            self.activate_manifest(None)
        self.assertEqual(self.commit.call_count, 1)
        self.assertEqual(self.commit.call_args.kwargs["expected_head"], "validated-public-head")
        self.read.assert_called_once_with(REPO, "update-manifest.json")


if __name__ == "__main__":
    unittest.main()
