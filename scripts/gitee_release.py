"""Stage/verify/activate one Gitee release without rebuilding any package.

Gitee has no documented draft/latest activation controls. We upload as a
prerelease, then clear prerelease after verification. Stable signed appcasts are activated
separately in the distribution branch; Release prose is never machine state.
"""
import copy
import json
from pathlib import Path
import xml.etree.ElementTree as ET

from gitee_api import check_download_url
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
            # Sparkle 2.10.1 selects embedded feed signing by .xml suffix.
            temporary = directory / (name + ".tmp.xml")
            temporary.write_bytes(unsigned)
            sparkle_feed.sign_feed(temporary, sparkle_feed.signer())
            signed = temporary.read_bytes()
            signature_match = sparkle_feed.SIGNATURE.search(signed)
            if not signature_match or signed[:int(signature_match[2])] != unsigned:
                raise ValueError("Gitee feed signing did not produce the expected signed XML")
            sparkle_feed.verify_signatures([{
                "file": str(temporary), "signature": signature_match[1].decode(),
                "length": int(signature_match[2])}])
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
        if (self.release["tag_name"] != self.tag or
                self.release.get("target_commitish") != self.commit):
            raise ValueError("Existing Gitee release source/tag mismatch; do not overwrite")
        # Moderation may mask name/body. RELEASE-NOTES.md is an immutable,
        # hash-verified attachment; prose is not an activation or identity signal.
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

    def verify(self):
        if self.release is None or self.files is None:
            raise ValueError("Stage Gitee release before verification")
        verify_gitee_source(self.commit, self.tag)
        actual = indexed_assets(self.api.assets(self.release["id"]), self.files, True)
        for name, path in self.files.items():
            self.api.verify_asset(actual[name], path)

    def activate(self):
        """Make verified attachments formal; fixed feed activation happens later."""
        self.verify()
        if self.release["prerelease"]:
            self.api.write("/releases/" + str(self.release["id"]), {
                "tag_name": self.tag, "name": self.manifest["version"], "prerelease": "false"}, "PATCH")
        # Public readback covers PATCH success followed by a lost response.
        published = [r for r in self.api.releases() if r["tag_name"] == self.tag]
        if (len(published) != 1 or published[0]["prerelease"] or
                published[0].get("target_commitish") != self.commit):
            raise ValueError("Gitee formal release readback failed; rerun verification")
        self.release = published[0]
