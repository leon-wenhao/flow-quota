"""Publish signed Gitee appcasts using a separate Git branch.

The branch contains XML only, never packages, credentials or application source.
One non-force push activates both architectures. Verify raw anonymous bytes after
push; a readback failure is partial success, resumed with the same bundle.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

from gitee_api import AnonymousRedirect
from public_repository import ROOT
from push_sources import GITEE
import sparkle_feed

BRANCH = "codex/update-feeds"
REF = "refs/heads/" + BRANCH
RAW = "https://gitee.com/Leon-wh/flow-quota/raw/" + BRANCH + "/"
MAX_BYTES = 1_048_576


def git(directory, *args):
    return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *args],
                                   cwd=directory, text=True, stderr=subprocess.PIPE, timeout=60).strip()


def identity(path, architecture):
    """Validate a signed feed and its canonical Gitee package URL; no network."""
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_BYTES:
        raise ValueError("Missing/oversized Gitee signed feed")
    data = path.read_bytes()
    match = sparkle_feed.SIGNATURE.search(data)
    if not match or int(match[2]) != match.start():
        raise ValueError("Missing or malformed Gitee feed signature")
    sparkle_feed.verify_signatures([{"file": str(path), "signature": match[1].decode(),
                                    "length": int(match[2])}])
    try:
        item = ET.fromstring(data[:match.start()]).find("channel/item")
        version = item.findtext("{" + sparkle_feed.NS + "}shortVersionString")
        build = int(item.findtext("{" + sparkle_feed.NS + "}version"))
        enclosure = item.find("enclosure")
        size = int(enclosure.get("length"))
        sparkle_feed.signature_value(enclosure.get("{" + sparkle_feed.NS + "}edSignature"))
        if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
            raise ValueError("Invalid version")
        if not 0 < build <= 2**63 - 1 or not 0 < size <= 2 * 1024**3:
            raise ValueError("Invalid build/size")
        expected = ("https://gitee.com/Leon-wh/flow-quota/releases/download/v" + version +
                    "/FlowQuota-" + version + "-" + architecture + ".dmg")
        if enclosure.get("url") != expected:
            raise ValueError("Foreign or wrong-architecture package URL")
    except (ET.ParseError, TypeError, AttributeError, ValueError) as error:
        raise ValueError("Invalid Gitee feed identity/package: " + str(error)) from None
    return tuple(map(int, version.split("."))), build


def pair(directory):
    values = [identity(directory / name, arch) for arch, name in
              zip(("arm64", "x86_64"), sparkle_feed.FEEDS)]
    if values[0] != values[1]:
        raise ValueError("Gitee architecture feeds disagree on version/build")
    return values[0]


def readback(relative, expected):
    request = urllib.request.Request(RAW + relative, headers={"Cache-Control": "no-cache"})
    opener = urllib.request.build_opener(AnonymousRedirect())
    with opener.open(request, timeout=30) as response:
        actual = response.read(MAX_BYTES + 1)
        if response.status != 200 or actual != expected:
            raise ValueError("Gitee anonymous raw feed readback mismatch: " + relative)


def publish_feeds(bundle, manifest, dry_run=False):
    """Verify monotonic versions, commit feeds in isolation, push, then read back.

    Requires the corresponding source tag and hash-verified Release attachments
    (the dual publisher makes the Release formal before non-dry activation).
    Never changes the caller's index, checkout, main, tags or package bytes.
    """
    bundle = Path(bundle)
    feeds = bundle.parent / (bundle.name + "-gitee")
    new = pair(feeds)
    if new != (tuple(map(int, manifest["version"].split("."))), manifest["build"]):
        raise ValueError("Gitee feeds do not match release bundle")
    version_dir = "updates/versions/v" + manifest["version"]
    pending = {}
    for name in sparkle_feed.FEEDS:
        pending["updates/" + name] = (feeds / name).read_bytes()
        pending[version_dir + "/" + name] = (feeds / name).read_bytes()
    with tempfile.TemporaryDirectory(prefix="flow-quota-feeds-") as temporary:
        directory = Path(temporary)
        git(directory, "init", "-q")
        refs = git(directory, "ls-remote", GITEE, REF)
        before = refs.split()[0] if refs else None
        if before:
            git(directory, "fetch", "--depth=1", GITEE, REF)
            git(directory, "checkout", "--detach", "FETCH_HEAD")
            if git(directory, "rev-parse", "HEAD") != before:
                raise ValueError("Gitee feed branch changed during preflight; retry")
            old = pair(directory / "updates")
            if old != new and (old[0] >= new[0] or old[1] >= new[1]):
                raise ValueError("Refusing Gitee version/build rollback")
            if old == new and any((directory / key).is_symlink() or
                    not (directory / key).is_file() or (directory / key).read_bytes() != value
                    for key, value in pending.items()):
                raise ValueError("Immutable Gitee version differs from release bundle")
        for relative, data in pending.items():
            path = directory / relative
            if path.is_symlink() or any(parent.is_symlink() for parent in path.parents if parent != directory and directory in parent.parents):
                raise ValueError("Gitee feed path must not be a symlink")
            if relative.startswith(version_dir + "/") and path.exists() and path.read_bytes() != data:
                raise ValueError("Immutable Gitee version feed differs")
        if dry_run:
            return
        for relative, data in pending.items():
            path = directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        git(directory, "add", "--", *pending)
        if git(directory, "status", "--porcelain"):
            # Respect the publishing operator's configured Git identity.
            for key in ("user.name", "user.email"):
                git(directory, "config", key, git(ROOT, "config", "--get", key))
            git(directory, "commit", "-q", "-m", "Publish signed Gitee feeds for " + manifest["version"])
            # Ordinary fast-forward push rejects concurrent writers, without force.
            git(directory, "push", GITEE, "HEAD:" + REF)
        after = git(directory, "rev-parse", "HEAD")
        remote = git(directory, "ls-remote", GITEE, REF).split()[0]
        if remote != after:
            raise ValueError("Gitee feed branch readback differs; retry")
        for relative, data in pending.items():
            readback(relative, data)
