"""Offline anonymous integrity, credential redaction and multipart boundaries."""
import io
from email.message import Message
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gitee_api


class GiteeBoundaryTests(unittest.TestCase):
    def test_downloads_reject_github_http_credentials_and_query_tokens(self):
        for url in ["https://github.com/package", "http://gitee.com/file", "https://u:p@gitee.com/file",
                    "https://gitee.com/file?access_token=secret"]:
            with self.assertRaises(ValueError):
                gitee_api.check_download_url(url)

    def test_errors_redact_query_token_and_credentials_missing_before_writes(self):
        api = gitee_api.GiteeAPI("private-secret")
        api.authenticated = mock.Mock()
        api.authenticated.open.side_effect = gitee_api.urllib.error.URLError("private-secret")
        with self.assertRaises(ValueError) as caught:
            api.preflight()
        self.assertNotIn("private-secret", str(caught.exception))
        with mock.patch.dict("os.environ", {}, clear=True), mock.patch("subprocess.run") as run:
            run.return_value.returncode = 1
            with self.assertRaisesRegex(ValueError, "credential missing"):
                gitee_api.credential()

    def test_anonymous_bytes_digest_not_metadata_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.dmg"
            path.write_bytes(b"correct")
            api = gitee_api.GiteeAPI("unused")
            api.anonymous = mock.Mock()
            item = {"size": 7, "browser_download_url": "https://gitee.com/file"}
            for content, valid in [(b"correct", True), (b"corrupt", False), (b"correct-extra", False), (b"short", False)]:
                response = io.BytesIO(content)
                response.status, response.url = 200, item["browser_download_url"]
                response.headers = Message()
                response.headers["Content-Disposition"] = 'attachment; filename="test.dmg"'
                api.anonymous.open.return_value = response
                if valid:
                    api.verify_asset(item, path)
                else:
                    with self.assertRaises(ValueError):
                        api.verify_asset(item, path)


    def test_anonymous_package_must_have_a_sparkle_compatible_filename(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.dmg"
            path.write_bytes(b"fixture")
            api = gitee_api.GiteeAPI("unused")
            response = io.BytesIO(b"fixture")
            response.status, response.url, response.headers = 200, "https://gitee.com/download/1", Message()
            api.anonymous = mock.Mock()
            api.anonymous.open.return_value = response
            with self.assertRaisesRegex(ValueError, "filename"):
                api.verify_asset({"size": 7, "browser_download_url": response.url}, path)


class GiteeRequestTests(unittest.TestCase):
    def test_upload_stream_length_and_field_names_without_token_in_url(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.dmg"
            path.write_bytes(b"fixture package bytes")
            api = gitee_api.GiteeAPI("fake-token")
            api._json = mock.Mock(return_value={"id": 1})
            api.upload(1, path)
            request, authenticated = api._json.call_args[0]
            body = b"".join(request.data)
            self.assertTrue(authenticated)
            self.assertNotIn("fake-token", request.full_url)
            self.assertEqual(int(request.get_header("Content-length")), len(body))
            self.assertIn(b'name="access_token"\r\n\r\nfake-token', body)
            self.assertIn(b'name="file"; filename="fixture.dmg"', body)
            self.assertIn(path.read_bytes(), body)

    def test_release_activation_uses_documented_form_fields(self):
        api = gitee_api.GiteeAPI("fake-token")
        api._json = mock.Mock(return_value={"id": 1})
        api.write("/releases/1", {"tag_name": "v0.1.12", "name": "0.1.12",
                                 "body": "release notes", "prerelease": "false"}, "PATCH")
        request, authenticated = api._json.call_args[0]
        form = urllib.parse.parse_qs(request.data.decode())
        self.assertEqual(request.method, "PATCH")
        self.assertTrue(authenticated)
        self.assertEqual(form["access_token"], ["fake-token"])
        self.assertEqual(form["prerelease"], ["false"])
        self.assertNotIn("fake-token", request.full_url)


if __name__ == "__main__":
    unittest.main()
