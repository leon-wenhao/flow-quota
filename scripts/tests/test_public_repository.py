"""Offline identity, source tag and HTTP failure tests for the single public repository."""
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import public_repository as repositories

REPO = repositories.PUBLIC_REPO
COMMIT = "a" * 40
TAG = "v1.2.3-build.7"


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.run = mock.patch.object(repositories, "run", return_value="git@github.com:" + REPO + ".git").start()
        self.api = mock.patch.object(repositories, "api", return_value={
            "private": False, "archived": False, "default_branch": "main"}).start()
        self.addCleanup(mock.patch.stopall)

    def test_same_public_source_and_release_repository_is_required(self):
        repositories.check_repositories(REPO)
        self.api.assert_called_once_with("repos/" + REPO)
        for repo in ("leon-wenhao/flow-quota-releases", "example/other"):
            with self.assertRaises(ValueError):
                repositories.check_repositories(repo)
        self.run.return_value = "https://github.com/other/repo.git"
        with self.assertRaises(ValueError):
            repositories.check_repositories(REPO)

    def test_private_archived_or_wrong_default_branch_cannot_publish(self):
        for field, value in (("private", True), ("archived", True), ("default_branch", "develop")):
            self.api.return_value = {"private": False, "archived": False, "default_branch": "main", field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                repositories.check_repositories(REPO)

    def test_tag_is_created_at_bundle_source_in_main_history(self):
        for status in ("identical", "ahead"):
            self.api.reset_mock()
            self.api.side_effect = [{"status": status}, [], {"ref": "refs/tags/" + TAG}]
            repositories.ensure_public_tag(REPO, TAG, COMMIT)
            self.api.assert_called_with("repos/" + REPO + "/git/refs", "POST",
                                        {"ref": "refs/tags/" + TAG, "sha": COMMIT})

    def test_diverged_or_unpushed_source_cannot_create_tag(self):
        for status in ("behind", "diverged"):
            self.api.reset_mock()
            self.api.side_effect = None
            self.api.return_value = {"status": status}
            with self.assertRaisesRegex(ValueError, "remote main"):
                repositories.ensure_public_tag(REPO, TAG, COMMIT)
            self.assertEqual(self.api.call_count, 1)

    def test_existing_tag_never_changes_source(self):
        for commit in (COMMIT, "b" * 40):
            self.api.reset_mock()
            self.api.side_effect = [{"status": "ahead"}, [{"ref": "refs/tags/" + TAG,
                "object": {"type": "commit", "sha": commit}}]]
            if commit == COMMIT:
                repositories.ensure_public_tag(REPO, TAG, COMMIT)
            else:
                with self.assertRaisesRegex(ValueError, "different source"):
                    repositories.ensure_public_tag(REPO, TAG, COMMIT)
            self.assertEqual(self.api.call_count, 2)

    def test_annotated_tag_is_resolved_to_source_commit(self):
        self.api.side_effect = [{"status": "identical"}, [{"ref": "refs/tags/" + TAG,
            "object": {"type": "tag", "sha": "c" * 40}}],
            {"object": {"type": "commit", "sha": COMMIT}}]
        repositories.ensure_public_tag(REPO, TAG, COMMIT)
        self.assertEqual(self.api.call_count, 3)


class APIAbsenceTests(unittest.TestCase):
    def test_only_explicit_404_can_be_treated_as_missing(self):
        for body, code, missing in [("null", 0, True), ('{"status":"404"}', 1, True),
                                    ('{"status":"403"}', 1, False), ("", 1, False)]:
            result = subprocess.CompletedProcess([], code, body, "fixture error")
            with self.subTest(body=body), mock.patch.object(subprocess, "run", return_value=result):
                if missing:
                    self.assertIsNone(repositories.api("fixture", allow_missing=True))
                else:
                    with self.assertRaises(subprocess.CalledProcessError):
                        repositories.api("fixture", allow_missing=True)

    def test_required_404_is_an_error(self):
        result = subprocess.CompletedProcess([], 1, '{"status":"404"}', "not found")
        with mock.patch.object(subprocess, "run", return_value=result):
            with self.assertRaises(subprocess.CalledProcessError):
                repositories.api("fixture")


if __name__ == "__main__":
    unittest.main()
