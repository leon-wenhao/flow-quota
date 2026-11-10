"""Gitee Open API v5.4.93; credentials stay in memory, never argv/logs.

GET metadata is anonymous by default. Authenticated requests do not redirect,
so a form/query token cannot be forwarded to a different host.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid

REPO = "Leon-wh/flow-quota"
BASE = "https://gitee.com/api/v5/repos/" + REPO


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Authenticated Gitee API request unexpectedly redirected")


class AnonymousRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_download_url(newurl, redirect=True)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def credential():
    token = os.environ.get("GITEE_TOKEN") or os.environ.get("GITEE_ACCESS_TOKEN")
    if not token:
        result = subprocess.run(["security", "find-generic-password", "-a", "flow-quota",
                                 "-s", "flow-quota-gitee", "-w"], capture_output=True, text=True)
        token = result.stdout.strip() if result.returncode == 0 else None
    if not token:
        raise ValueError("Gitee Release credential missing: set GITEE_TOKEN or Keychain service flow-quota-gitee")
    return token


def check_download_url(url, redirect=False):
    value = urllib.parse.urlsplit(url)
    host = value.hostname or ""
    allowed = host == "gitee.com" or (redirect and host.endswith((".gitee.com", ".giteeusercontent.com")))
    if (value.scheme != "https" or not allowed or value.username or value.password
            or value.fragment or (not redirect and value.query)):
        raise ValueError("Gitee asset requires an anonymous HTTPS URL on a supported Gitee host")


class GiteeAPI:
    def __init__(self, token):
        self.token = token
        self.authenticated = urllib.request.build_opener(NoRedirect())
        self.anonymous = urllib.request.build_opener(AnonymousRedirect())

    def _json(self, request, authenticated=False):
        try:
            opener = self.authenticated if authenticated else self.anonymous
            with opener.open(request, timeout=30) as response:
                data = response.read(1_048_577)
            if len(data) > 1_048_576:
                raise ValueError("Gitee API response exceeds size limit")
            return json.loads(data)
        except (urllib.error.URLError, OSError, ValueError) as error:
            # Do not interpolate exceptions: urllib may include access_token URLs.
            code = error.code if isinstance(error, urllib.error.HTTPError) else "transport/JSON"
            raise ValueError("Gitee API failed ({})".format(code)) from None

    def get(self, path):
        return self._json(urllib.request.Request(BASE + path))

    def write(self, path, fields, method="POST"):
        fields = dict(fields, access_token=self.token)
        data = urllib.parse.urlencode(fields).encode()
        return self._json(urllib.request.Request(BASE + path, data=data, method=method), True)

    def preflight(self):
        query = urllib.parse.urlencode({"access_token": self.token})
        self._json(urllib.request.Request("https://gitee.com/api/v5/user?" + query), True)
        repo = self.get("")
        if repo.get("private") is not False or repo.get("default_branch") != "main":
            raise ValueError("Gitee repository must be public and use main")

    def releases(self):
        result = []
        for page in range(1, 11):
            batch = self.get("/releases?per_page=100&page={}".format(page))
            result.extend(batch)
            if len(batch) < 100:
                return result
        raise ValueError("Gitee release pagination exceeds client limit")

    def assets(self, release_id):
        assets = self.get("/releases/{}/attach_files?per_page=100".format(release_id))
        if len(assets) == 100:
            raise ValueError("Gitee release exceeds attachment whitelist")
        return assets

    def upload(self, release_id, path):
        path = Path(path)
        if not re.fullmatch(r"[A-Za-z0-9._-]+", path.name):
            raise ValueError("Unsupported attachment filename")
        boundary = "flowquota" + uuid.uuid4().hex
        prefix = ('--{0}\r\nContent-Disposition: form-data; name="access_token"\r\n\r\n{1}\r\n'
                  '--{0}\r\nContent-Disposition: form-data; name="file"; filename="{2}"\r\n'
                  'Content-Type: application/octet-stream\r\n\r\n').format(boundary, self.token, path.name).encode()
        suffix = ("\r\n--" + boundary + "--\r\n").encode()

        def chunks():
            yield prefix
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    yield block
            yield suffix

        request = urllib.request.Request(BASE + "/releases/{}/attach_files".format(release_id),
            data=chunks(), headers={"Content-Type": "multipart/form-data; boundary=" + boundary,
                                   "Content-Length": str(len(prefix) + path.stat().st_size + len(suffix))})
        return self._json(request, True)

    def verify_asset(self, item, path):
        """Hash actual anonymous bytes; Gitee's attachment API has no digest field.

        This is a publication audit, not an experimental traffic test. Run real
        publication only on an allowed connection, never a hotspot experiment.
        """
        check_download_url(item["browser_download_url"])
        expected_size = path.stat().st_size
        if item.get("size") != expected_size:
            raise ValueError("Gitee attachment size mismatch: " + path.name)
        expected = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                expected.update(block)
        actual, count = hashlib.sha256(), 0
        try:
            with self.anonymous.open(item["browser_download_url"], timeout=30) as response:
                check_download_url(response.url, redirect=True)
                if path.suffix == ".dmg":
                    # Sparkle 2.10.1 saves URLResponse.suggestedFilename and
                    # SUDiskImageUnarchiver selects .dmg by filename suffix.
                    filename = response.headers.get_filename() or urllib.parse.unquote(
                        urllib.parse.urlsplit(response.url).path.rsplit("/", 1)[-1])
                    if Path(filename).suffix != ".dmg":
                        raise ValueError("Gitee download filename cannot identify a DMG")
                if response.status != 200:
                    raise ValueError("Gitee anonymous asset unavailable")
                while True:
                    block = response.read(min(1024 * 1024, expected_size - count + 1))
                    if not block:
                        break
                    count += len(block)
                    if count > expected_size:
                        raise ValueError("Gitee anonymous asset exceeds expected size")
                    actual.update(block)
        except (urllib.error.URLError, OSError):
            raise ValueError("Gitee anonymous asset download failed: " + path.name) from None
        if count != expected_size or actual.digest() != expected.digest():
            raise ValueError("Gitee anonymous asset SHA-256 mismatch: " + path.name)
