"""Stage/verify/activate one Gitee release without rebuilding any package.

Gitee has no documented draft/latest activation controls. We upload as a
prerelease, then add a readiness marker and clear prerelease after verification.
The client ignores every release without this marker.
"""
import copy
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

from gitee_api import READY, check_download_url
import sparkle_feed
from push_sources import verify_gitee_source


def indexed_assets(items, expected, complete=False):
    actual = {item["name"]: item for item in items}
    if len(actual) != len(items) or set(actual) - set(expected):
        raise ValueError("Unexpected or duplicate Gitee attachment")
    if complete and set(actual) != set(expected):
        raise ValueError("Gitee attachments incomplete")
    return actual


def prepare_feeds(bundle, manifest, assets):
    """Only URLs differ; retain package signatures and independently sign feeds."""
    directory = bundle.parent / (bundle.name + "-gitee")
    directory.mkdir(exist_ok=True)
    mirrored = copy.deepcopy(manifest)
    requests, feeds = [], []
    for arch, name in zip(("arm64", "x86_64"), sparkle_feed.FEEDS):
        package = mirrored["packages"]["macos/" + arch]
        item = assets[package["fileName"]]
        check_download_url(item["browser_download_url"])
        package["url"] = item["browser_download_url"]
        original = ET.parse(bundle / name).find("channel/item/enclosure")
        signature = original.attrib["{" + sparkle_feed.NS + "}edSignature"]
        unsigned = sparkle_feed.make_xml(mirrored, arch, signature,
            sparkle_feed.description_from_notes(bundle / "RELEASE-NOTES.md"))
        path = directory / name
        if not path.exists():
            # A failed signing attempt must not leave a reusable unsigned feed.
            temporary = directory / (name + ".tmp")
            temporary.write_bytes(unsigned)
            sparkle_feed.sign_feed(temporary, sparkle_feed.signer())
            temporary.replace(path)
        data = path.read_bytes()
        match = sparkle_feed.SIGNATURE.search(data)
        if not match or data[:int(match[2])] != unsigned:
            raise ValueError("Existing Gitee feed differs from the immutable bundle")
        requests.append({"file": str(path), "signature": match[1].decode(), "length": int(match[2])})
        requests.append({"file": str(bundle / package["fileName"]), "signature": signature})
        feeds.append(path)
    sparkle_feed.verify_signatures(requests)
    return feeds


class GiteeRelease:
    def __init__(self, api, bundle, manifest, files):
        self.api, self.bundle, self.manifest = api, Path(bundle), manifest
        self.tag = "v" + manifest["version"]
        self.commit = json.loads((self.bundle / "release-manifest.json").read_text())["sourceCommit"]
        self.common = {path.name: path for path in files if path.name not in sparkle_feed.FEEDS}
        self.expected_names = set(self.common) | set(sparkle_feed.FEEDS)
        self.release = None
        self.files = None

    def stage(self):
        verify_gitee_source(self.commit, self.tag)
        releases = [release for release in self.api.releases() if release["tag_name"] == self.tag]
        if len(releases) > 1:
            raise ValueError("Duplicate Gitee releases for one tag")
        self.release = releases[0] if releases else self.api.write("/releases", {
            "tag_name": self.tag, "name": self.manifest["version"], "target_commitish": self.commit,
            "body": (self.bundle / "RELEASE-NOTES.md").read_text(), "prerelease": "true"})
        active = not self.release["prerelease"]
        expected_body = (self.bundle / "RELEASE-NOTES.md").read_text()
        if active:
            expected_body += "\n<!-- flow-quota-ready:{} -->".format(self.manifest["build"])
        if self.release["name"] != self.manifest["version"] or self.release["body"] != expected_body:
            raise ValueError("Existing Gitee release identity/notes mismatch; do not overwrite")
        actual = indexed_assets(self.api.assets(self.release["id"]), self.expected_names, active)
        for name, path in self.common.items():
            if name in actual:
                self.api.verify_asset(actual[name], path)
            elif active:
                raise ValueError("Published Gitee release is immutable")
            else:
                self.api.upload(self.release["id"], path)
        actual = indexed_assets(self.api.assets(self.release["id"]), self.expected_names)
        if not set(self.common) <= set(actual):
            raise ValueError("Gitee package/metadata upload incomplete")
        feeds = prepare_feeds(self.bundle, self.manifest, actual)
        for path in feeds:
            if path.name not in actual:
                if active:
                    raise ValueError("Published Gitee release is immutable")
                self.api.upload(self.release["id"], path)
        self.files = dict(self.common, **{path.name: path for path in feeds})
        self.verify()
        self.check_monotonic()

    def verify(self):
        if self.release is None or self.files is None:
            raise ValueError("Stage Gitee release before verification")
        verify_gitee_source(self.commit, self.tag)
        actual = indexed_assets(self.api.assets(self.release["id"]), self.files, True)
        for name, path in self.files.items():
            self.api.verify_asset(actual[name], path)

    def check_monotonic(self):
        new_version = tuple(map(int, self.manifest["version"].split(".")))
        for release in self.api.releases():
            match = READY.search(release["body"])
            if release["prerelease"] or not match:
                continue
            if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", release["tag_name"]):
                raise ValueError("Activated Gitee release has invalid tag")
            old_version = tuple(map(int, release["tag_name"][1:].split(".")))
            old_build = int(match[1])
            if release["tag_name"] == self.tag:
                if old_build != self.manifest["build"]:
                    raise ValueError("Immutable Gitee version has a different build")
            elif old_version >= new_version or old_build >= self.manifest["build"]:
                raise ValueError("Refusing Gitee version/build rollback")

    def activate(self):
        self.verify()
        self.check_monotonic()
        fields = {"tag_name": self.tag, "name": self.manifest["version"], "prerelease": "false",
                  "body": (self.bundle / "RELEASE-NOTES.md").read_text() +
                          "\n<!-- flow-quota-ready:{} -->".format(self.manifest["build"])}
        if self.release["prerelease"]:
            self.api.write("/releases/" + str(self.release["id"]), fields, "PATCH")
        # Public, no-token readback also covers "PATCH succeeded, response lost" retries.
        published = [r for r in self.api.releases() if r["tag_name"] == self.tag]
        if len(published) != 1 or any(published[0][key] != (False if key == "prerelease" else value)
                                      for key, value in fields.items()):
            raise ValueError("Gitee activation readback failed; rerun verification")
