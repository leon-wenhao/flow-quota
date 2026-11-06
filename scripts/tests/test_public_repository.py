"""Offline API safety tests; run with python3 -B -m unittest discover -s scripts/tests."""

import base64
import hashlib
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import public_repository as repository

REPO = "leon-wenhao/flow-quota-releases"
PREFIX = "repos/" + REPO
HEAD, OLD, NEW = "a" * 40, "b" * 40, "c" * 40
PUBLIC = ("README.md", "INSTALL.md", "DISTRIBUTION.md", "assets/logo.png", "update-manifest.json")


def blob_sha(content):
    return hashlib.sha1(b"blob %d\0" % len(content) + content).hexdigest()


def entry(path, mode="100644", kind="blob", sha=OLD):
    return {"path": path, "mode": mode, "type": kind, "sha": sha}


def tree(entries):
    return {"truncated": False, "tree": entries}


class OfflineCase(unittest.TestCase):
    def setUp(self):
        self.patch(subprocess, "check_output", side_effect=AssertionError("Unexpected subprocess"))
        self.head = self.patch(repository, "main_head", return_value=HEAD)
        self.api = self.patch(repository, "api", side_effect=AssertionError("Unexpected API call"))
        self.pages = self.patch(repository, "pages", side_effect=AssertionError("Unexpected pagination"))

    def patch(self, target, name, **kwargs):
        patcher = mock.patch.object(target, name, **kwargs)
        self.addCleanup(patcher.stop)
        return patcher.start()


class CommitPublicFilesTests(OfflineCase):
    def setUp(self):
        super().setUp()
        self.remote = []
        self.api.side_effect = self.respond

    def respond(self, endpoint, method="GET", payload=None):
        if (method, endpoint) == ("GET", PREFIX + "/git/trees/" + HEAD + "?recursive=1"):
            return tree(self.remote)
        if (method, endpoint) == ("PUT", PREFIX + "/contents/README.md"):
            self.remote = [entry("README.md", sha=blob_sha(base64.b64decode(payload["content"])))]
            return {"commit": {"sha": HEAD}}
        if (method, endpoint) == ("POST", PREFIX + "/git/blobs"):
            return {"sha": blob_sha(base64.b64decode(payload["content"]))}
        if (method, endpoint) == ("GET", PREFIX + "/git/commits/" + HEAD):
            return {"tree": {"sha": "base-tree"}}
        if (method, endpoint) == ("POST", PREFIX + "/git/trees"):
            return {"sha": "new-tree"}
        if (method, endpoint) == ("POST", PREFIX + "/git/commits"):
            return {"sha": NEW}
        if (method, endpoint) == ("PATCH", PREFIX + "/git/refs/heads/main"):
            return {"object": {"sha": NEW}}
        raise AssertionError("Unexpected API request: {} {}".format(method, endpoint))

    def test_allowlisted_files_use_independent_parent_and_nonforce_patch(self):
        files = {name: ("public: " + name).encode() for name in PUBLIC}
        self.assertEqual(repository.commit_public_files(REPO, files, "docs", expected_head=HEAD), NEW)
        self.head.assert_called_once_with(REPO)
        calls = self.api.call_args_list
        blobs = [call.args[2] for call in calls if call.args[0] == PREFIX + "/git/blobs"]
        self.assertEqual([base64.b64decode(blob["content"]) for blob in blobs], list(files.values()))
        self.assertTrue(all(blob["encoding"] == "base64" for blob in blobs))
        expected_entries = [{"path": name, "mode": "100644", "type": "blob", "sha": blob_sha(data)}
                            for name, data in files.items()]
        self.assertIn(mock.call(PREFIX + "/git/trees", "POST", {
            "base_tree": "base-tree", "tree": expected_entries}), calls)
        commit = next(call.args[2] for call in calls if call.args[0] == PREFIX + "/git/commits")
        self.assertEqual(commit["parents"], [HEAD])
        self.assertEqual(commit["tree"], "new-tree")
        self.assertEqual(calls[-1], mock.call(PREFIX + "/git/refs/heads/main", "PATCH", {
            "sha": NEW, "force": False}))
        self.assertIs(calls[-1].args[2]["force"], False)

    def test_source_and_path_escape_are_rejected_before_any_api(self):
        for name in ("main.swift", "scripts/private.py", ".git/config", "AGENTS.md", "source.zip",
                     "../README.md", "/README.md", "assets/../README.md", "assets/../../private",
                     "assets/./logo.png", "README.md/../secret", "assets\\logo.png"):
            with self.subTest(path=name), self.assertRaisesRegex(ValueError, "allowlist"):
                repository.commit_public_files(REPO, {"README.md": b"ok", name: b"private"}, "docs")
        self.head.assert_not_called()
        self.api.assert_not_called()
        self.pages.assert_not_called()

    def test_empty_file_set_and_other_repository_are_rejected(self):
        for repo, files in ((REPO, {}), ("leon-wenhao/flow-quota", {"README.md": b"ok"})):
            with self.subTest(repo=repo), self.assertRaisesRegex(ValueError, "allowlist"):
                repository.commit_public_files(repo, files, "docs")
        self.api.assert_not_called()
        self.head.assert_not_called()

    def test_expected_head_mismatch_refuses_all_writes(self):
        for current in (OLD, None):
            self.head.return_value = current
            with self.subTest(head=current), self.assertRaisesRegex(ValueError, "main changed"):
                repository.commit_public_files(REPO, {"README.md": b"ok"}, "docs", expected_head=HEAD)
        self.api.assert_not_called()

    def test_blob_hash_mismatch_stops_before_tree_commit_or_patch(self):
        def bad_blob(endpoint, method="GET", payload=None):
            if endpoint == PREFIX + "/git/blobs":
                return {"sha": "0" * 40}
            return self.respond(endpoint, method, payload)

        self.api.side_effect = bad_blob
        with self.assertRaisesRegex(ValueError, "blob hash"):
            repository.commit_public_files(REPO, {"README.md": b"ok"}, "docs")
        self.assertEqual([call.args[:2] for call in self.api.call_args_list], [
            (PREFIX + "/git/trees/" + HEAD + "?recursive=1",), (PREFIX + "/git/blobs", "POST")])

    def test_unchanged_blobs_are_not_uploaded_or_committed(self):
        self.remote = [entry("README.md", sha=blob_sha(b"ok"))]
        self.assertEqual(repository.commit_public_files(REPO, {"README.md": b"ok"}, "docs"), HEAD)
        self.api.assert_called_once_with(PREFIX + "/git/trees/" + HEAD + "?recursive=1")

    def test_patch_rejection_propagates_without_force_retry(self):
        def reject_patch(endpoint, method="GET", payload=None):
            if method == "PATCH":
                raise RuntimeError("Concurrent main update")
            return self.respond(endpoint, method, payload)

        self.api.side_effect = reject_patch
        with self.assertRaisesRegex(RuntimeError, "Concurrent main"):
            repository.commit_public_files(REPO, {"README.md": b"ok"}, "docs", expected_head=HEAD)
        patches = [call for call in self.api.call_args_list if len(call.args) > 1 and call.args[1] == "PATCH"]
        self.assertEqual(len(patches), 1)
        self.assertIs(patches[0].args[2]["force"], False)

    def test_empty_repository_initializes_only_readme_before_other_public_files(self):
        self.head.side_effect = [None, HEAD]
        files = {name: ("public: " + name).encode() for name in PUBLIC}
        self.assertEqual(repository.commit_public_files(REPO, files, "docs"), NEW)
        first = self.api.call_args_list[0]
        self.assertEqual(first.args[:2], (PREFIX + "/contents/README.md", "PUT"))
        self.assertEqual(base64.b64decode(first.args[2]["content"]), files["README.md"])
        self.assertEqual(first.args[2]["branch"], "main")
        self.assertEqual(set(first.args[2]), {"message", "branch", "content", "author", "committer"})
        puts = [call for call in self.api.call_args_list if len(call.args) > 1 and call.args[1] == "PUT"]
        self.assertEqual(puts, [first])
        blobs = [call for call in self.api.call_args_list if call.args[0] == PREFIX + "/git/blobs"]
        self.assertEqual(len(blobs), 4)
        self.assertEqual(self.head.call_args_list, [mock.call(REPO), mock.call(REPO)])

    def test_readme_only_initialization_needs_no_followup_commit(self):
        self.head.side_effect = [None, HEAD]
        self.assertEqual(repository.commit_public_files(REPO, {"README.md": b"public"}, "docs"), HEAD)
        self.assertEqual(len(self.api.call_args_list), 2)
        self.assertEqual(self.api.call_args_list[-1],
                         mock.call(PREFIX + "/git/trees/" + HEAD + "?recursive=1"))

    def test_empty_repository_cannot_initialize_with_manifest_only(self):
        self.head.return_value = None
        with self.assertRaisesRegex(ValueError, "Initialize public documentation"):
            repository.commit_public_files(REPO, {"update-manifest.json": b"{}"}, "release")
        self.api.assert_not_called()


class PublicTreeTests(OfflineCase):
    def test_regular_allowlisted_files_and_assets_directory_are_accepted(self):
        self.api.side_effect = None
        self.api.return_value = tree([entry("assets", "040000", "tree")] + [entry(name) for name in PUBLIC])
        self.assertEqual(repository.public_tree(REPO, HEAD), dict.fromkeys(PUBLIC, OLD))
        self.api.assert_called_once_with(PREFIX + "/git/trees/" + HEAD + "?recursive=1")

    def test_illegal_file_symlink_executable_submodule_and_directory_are_rejected(self):
        self.api.side_effect = None
        for item in (entry("Sources/main.swift"), entry("../README.md"), entry("/README.md"),
                     entry("assets/source.zip"), entry("README.md", "120000"),
                     entry("assets/logo.png", "120000"), entry("INSTALL.md", "100755"),
                     entry("README.md", "160000", "commit"), entry("other", "040000", "tree")):
            with self.subTest(item=item), self.assertRaisesRegex(ValueError, "Unexpected file or mode"):
                self.api.return_value = tree([item])
                repository.public_tree(REPO, HEAD)

    def test_truncated_tree_is_never_accepted(self):
        self.api.side_effect = None
        self.api.return_value = {"truncated": True, "tree": []}
        with self.assertRaisesRegex(ValueError, "truncated"):
            repository.public_tree(REPO, HEAD)


class HistoryTests(OfflineCase):
    def configure(self, refs, histories, unsafe=None):
        def respond(endpoint, method="GET", payload=None):
            if endpoint == PREFIX + "/git/matching-refs/":
                return [{"ref": name, "object": {"sha": sha}} for name, sha in refs]
            for commit in set(sha for commits in histories.values() for sha in commits):
                if endpoint == PREFIX + "/git/trees/" + commit + "?recursive=1":
                    return tree([unsafe] if commit == OLD and unsafe else [entry("README.md")])
            raise AssertionError("Unexpected history API: " + endpoint)

        self.api.side_effect = respond
        self.pages.side_effect = lambda endpoint: [{"sha": sha} for sha in histories[endpoint]]

    @staticmethod
    def commits_url(sha):
        return PREFIX + "/commits?sha=" + sha + "&per_page=100"

    def test_previous_leak_is_rejected_even_after_removal_from_head(self):
        for unsafe in (entry("Sources/private.swift"), entry("README.md", "120000")):
            with self.subTest(unsafe=unsafe):
                self.api.reset_mock()
                self.configure([("refs/heads/main", HEAD)], {self.commits_url(HEAD): [HEAD, OLD]}, unsafe)
                with self.assertRaisesRegex(ValueError, "Unexpected file or mode"):
                    repository.audit_public_history(REPO)
                self.api.assert_any_call(PREFIX + "/git/trees/" + HEAD + "?recursive=1")
                self.api.assert_any_call(PREFIX + "/git/trees/" + OLD + "?recursive=1")

    def test_leaks_reachable_only_from_another_branch_or_tag_are_rejected(self):
        for ref in ("refs/heads/old-docs", "refs/tags/v0.1.0"):
            with self.subTest(ref=ref):
                self.configure([("refs/heads/main", HEAD), (ref, OLD)], {
                    self.commits_url(HEAD): [HEAD], self.commits_url(OLD): [OLD]}, entry("private.py"))
                with self.assertRaisesRegex(ValueError, "Unexpected file or mode"):
                    repository.audit_public_history(REPO)

    def test_all_refs_are_audited_and_shared_ancestors_are_deduplicated(self):
        refs = [("refs/heads/main", HEAD), ("refs/heads/docs", NEW), ("refs/tags/v0.1.0", OLD)]
        self.configure(refs, {self.commits_url(sha): [sha, "d" * 40] for _, sha in refs})
        repository.audit_public_history(REPO)
        self.assertEqual(self.pages.call_args_list, [mock.call(self.commits_url(sha)) for _, sha in refs])
        for sha in (HEAD, NEW, OLD, "d" * 40):
            self.assertEqual(self.api.call_args_list.count(
                mock.call(PREFIX + "/git/trees/" + sha + "?recursive=1")), 1)

    def test_empty_repository_history_needs_no_api_requests(self):
        self.head.return_value = None
        repository.audit_public_history(REPO)
        self.api.assert_not_called()
        self.pages.assert_not_called()


if __name__ == "__main__":
    unittest.main()
