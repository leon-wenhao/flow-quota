"""Offline signed-feed gates and real local Git publication/retry/concurrency."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gitee_feeds
import sparkle_feed

SIGNATURE = base64.b64encode(bytes(64)).decode()


class GiteeFeedsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.remote = self.root / "remote.git"
        self.repository = self.root / "source"
        self.repository.mkdir()
        gitee_feeds.git(self.repository, "init", "-q")
        for key, value in [("user.name", "Test Publisher"), ("user.email", "test@example.invalid")]:
            gitee_feeds.git(self.repository, "config", key, value)
        subprocess.run(["git", "init", "--bare", "-q", str(self.remote)], check=True)
        for name, value in [("GITEE", str(self.remote)), ("ROOT", self.repository)]:
            patch = mock.patch.object(gitee_feeds, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(sparkle_feed, "verify_signatures")
        self.signature = patch.start()
        self.addCleanup(patch.stop)
        self.original_readback = gitee_feeds.readback
        patch = mock.patch.object(gitee_feeds, "readback", side_effect=self.readback)
        self.reader = patch.start()
        self.addCleanup(patch.stop)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        self.feeds = self.root / "bundle-gitee"
        self.feeds.mkdir()
        self.set_version("0.1.13", 34)

    def set_version(self, version, build):
        self.manifest = {"version": version, "build": build, "minimumSystemVersion": "14.0", "packages": {}}
        for arch, name in zip(("arm64", "x86_64"), sparkle_feed.FEEDS):
            self.manifest["packages"]["macos/" + arch] = {
                "url": "https://gitee.com/Leon-wh/flow-quota/releases/download/v" + version +
                       "/FlowQuota-" + version + "-" + arch + ".dmg", "size": 42}
            unsigned = sparkle_feed.make_xml(self.manifest, arch, SIGNATURE, "<p>notes</p>")
            (self.feeds / name).write_bytes(unsigned + ("<!-- sparkle-signatures:\nedSignature: " +
                SIGNATURE + "\nlength: " + str(len(unsigned)) + "\n-->\n").encode())

    def readback(self, relative, expected):
        data = subprocess.check_output(["git", "--git-dir=" + str(self.remote), "show",
                                        gitee_feeds.REF + ":" + relative])
        self.assertEqual(data, expected)

    def publish(self, **kwargs):
        gitee_feeds.publish_feeds(self.bundle, self.manifest, **kwargs)

    def tip(self):
        return gitee_feeds.git(self.repository, "ls-remote", str(self.remote), gitee_feeds.REF)

    def test_raw_readback_requires_anonymous_exact_bounded_response(self):
        # Call the real function; the ordinary Git publication tests replace it.
        with mock.patch.object(gitee_feeds.urllib.request, "build_opener") as build:
            response = build.return_value.open.return_value.__enter__.return_value
            response.status = 200
            response.read.return_value = b"signed xml"
            self.original_readback("updates/appcast-arm64.xml", b"signed xml")
            request = build.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, gitee_feeds.RAW + "updates/appcast-arm64.xml")
            self.assertNotIn("Authorization", request.headers)
            self.assertNotIn("Cookie", request.headers)
            response.read.assert_called_with(gitee_feeds.MAX_BYTES + 1)
            for status, body in [(200, b"modified"), (404, b"signed xml"),
                                 (200, b"x" * (gitee_feeds.MAX_BYTES + 1))]:
                response.status, response.read.return_value = status, body
                with self.assertRaisesRegex(ValueError, "readback mismatch"):
                    self.original_readback("updates/appcast-arm64.xml", b"signed xml")

    def test_dry_run_is_offline_for_raw_and_does_not_create_remote_branch(self):
        self.publish(dry_run=True)
        self.assertEqual(self.tip(), "")
        self.reader.assert_not_called()

    def test_both_architectures_published_once_retry_is_idempotent_and_history_preserved(self):
        source_status = gitee_feeds.git(self.repository, "status", "--porcelain")
        self.publish()
        first = self.tip()
        self.assertEqual(self.reader.call_count, 4)
        self.publish()
        self.assertEqual(self.tip(), first)
        self.set_version("0.1.14", 35)
        self.publish()
        self.assertNotEqual(self.tip(), first)
        self.assertEqual(gitee_feeds.git(self.repository, "status", "--porcelain"), source_status)
        for name in sparkle_feed.FEEDS:
            self.assertTrue(subprocess.check_output(["git", "--git-dir=" + str(self.remote),
                "show", gitee_feeds.REF + ":updates/versions/v0.1.13/" + name]))
        paths = subprocess.check_output(["git", "--git-dir=" + str(self.remote), "ls-tree", "-r",
            "--name-only", gitee_feeds.REF], text=True).splitlines()
        self.assertEqual(len(paths), 6)
        self.assertTrue(all(path.endswith(".xml") for path in paths))

    def test_version_and_build_must_both_increase_and_same_version_is_immutable(self):
        self.publish()
        first = self.tip()
        for version, build in [("0.1.12", 35), ("0.1.14", 33), ("0.1.13", 35)]:
            self.set_version(version, build)
            with self.assertRaisesRegex(ValueError, "rollback"):
                self.publish()
        self.set_version("0.1.13", 34)
        path = self.feeds / sparkle_feed.FEEDS[0]
        path.write_bytes(path.read_bytes().replace(b"notes", b"other"))
        with self.assertRaisesRegex(ValueError, "Immutable"):
            self.publish()
        self.assertEqual(self.tip(), first)

    def test_missing_architecture_bad_signature_and_wrong_host_never_publish(self):
        path = self.feeds / sparkle_feed.FEEDS[1]
        data = path.read_bytes()
        path.unlink()
        with self.assertRaisesRegex(ValueError, "Missing"):
            self.publish()
        path.write_bytes(data)
        self.signature.side_effect = ValueError("signature invalid")
        with self.assertRaisesRegex(ValueError, "signature invalid"):
            self.publish()
        self.signature.side_effect = None
        path.write_bytes(data.replace(b"gitee.com", b"evilx.com"))
        with self.assertRaisesRegex(ValueError, "package URL"):
            self.publish()
        self.assertEqual(self.tip(), "")

    def test_oversized_or_disagreeing_feeds_rejected_before_git(self):
        path = self.feeds / sparkle_feed.FEEDS[1]
        path.write_bytes(b"x" * (gitee_feeds.MAX_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "oversized"):
            self.publish()
        self.set_version("0.1.13", 34)
        path.write_bytes(path.read_bytes().replace(b">34<", b">35<"))
        with self.assertRaisesRegex(ValueError, "disagree"):
            self.publish()
        self.assertEqual(self.tip(), "")

    def test_failed_raw_readback_can_resume_without_replacing_remote_commit(self):
        self.reader.side_effect = ValueError("raw blocked")
        with self.assertRaisesRegex(ValueError, "raw blocked"):
            self.publish()
        first = self.tip()
        self.assertTrue(first)
        self.reader.side_effect = self.readback
        self.publish()
        self.assertEqual(self.tip(), first)

    def test_concurrent_writer_rejects_stale_push_without_overwriting(self):
        self.publish()
        original = gitee_feeds.git
        concurrent_tip = []
        def race(directory, *args):
            if args[0] == "push":
                other = self.root / "other"
                other.mkdir()
                original(other, "init", "-q")
                original(other, "fetch", str(self.remote), gitee_feeds.REF)
                original(other, "checkout", "--detach", "FETCH_HEAD")
                original(other, "config", "user.name", "Other Publisher")
                original(other, "config", "user.email", "other@example.invalid")
                original(other, "commit", "--allow-empty", "-m", "concurrent")
                original(other, "push", str(self.remote), "HEAD:" + gitee_feeds.REF)
                concurrent_tip.append(original(other, "rev-parse", "HEAD"))
            return original(directory, *args)
        self.set_version("0.1.14", 35)
        with mock.patch.object(gitee_feeds, "git", side_effect=race):
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish()
        self.assertTrue(self.tip().startswith(concurrent_tip[0]))


if __name__ == "__main__":
    unittest.main()
