"""Publish an audited bundle to the public source repository.

Draft retries reuse identical assets. Published releases are immutable here.
Manifest activation happens only after a complete, published release exists.
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

from public_repository import PUBLIC_REPO, ROOT, api, check_repositories, ensure_public_tag, run
from release_bundle import validate_bundle


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return "sha256:" + result.hexdigest()


def verify_assets(remote, assets, complete):
    expected = {path.name: path for path in assets}
    actual = {item["name"]: item for item in remote}
    if len(actual) != len(remote) or set(actual) - set(expected):
        raise ValueError("Unexpected or duplicate GitHub release assets")
    if complete and set(actual) != set(expected):
        raise ValueError("Release assets are incomplete")
    for name, item in actual.items():
        path = expected[name]
        if (item["state"] != "uploaded" or item["size"] != path.stat().st_size
                or item.get("digest") != digest(path)):
            raise ValueError("Release asset size/SHA-256 mismatch: " + name)
    return set(actual)


def release_for_tag(repo, tag):
    # Listing succeeds even when the tag has no Release. Authentication/network
    # errors remain errors, rather than being mistaken for an absent release.
    pages = json.loads(run("gh", "api", "--paginate", "--slurp",
                           "repos/" + repo + "/releases?per_page=100"))
    return next((item for page in pages for item in page if item["tag_name"] == tag), None)


def activate_manifest(bundle, repo, tag):
    # Check published state and assets again, including when resuming activation.
    manifest, assets = validate_bundle(bundle, repo)
    release = release_for_tag(repo, tag)
    if release is None or release["draft"]:
        raise ValueError("Cannot activate an unpublished release")
    verify_assets(api("repos/{}/releases/{}/assets".format(repo, release["id"])), assets, True)
    latest = api("repos/" + repo + "/releases/latest", allow_missing=True)
    if latest is not None:
        match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", latest["tag_name"])
        if not match:
            raise ValueError("Latest release has an unsupported tag")
        # A version has exactly one immutable tag and bundle; same-version
        # rebuilds cannot replace its assets even when the internal build increases.
        old_version = tuple(map(int, match.groups()))
        new_version = tuple(map(int, manifest["version"].split(".")))
        if old_version > new_version:
            raise ValueError("Refusing to roll back the latest release")
        if old_version < new_version:
            # Sparkle orders CFBundleVersion, independently of the marketing
            # version. A reset build would make a published update invisible.
            candidates = [item for item in latest.get("assets", [])
                          if item.get("name") == "update-manifest.json"]
            if len(candidates) != 1 or type(candidates[0].get("id")) is not int:
                raise ValueError("Latest release is missing its update manifest")
            old = json.loads(run("gh", "api", "-H", "Accept: application/octet-stream",
                "repos/{}/releases/assets/{}".format(repo, candidates[0]["id"])))
            if (not isinstance(old, dict) or old.get("version") != latest["tag_name"][1:] or type(old.get("build")) is not int
                    or old["build"] <= 0 or manifest["build"] <= old["build"]):
                raise ValueError("Sparkle requires a strictly increasing internal build")
    # Latest attachment URLs are activated only after the complete release is verified.
    run("gh", "release", "edit", tag, "--repo", repo, "--latest")


def publish(bundle, repo, activate):
    check_repositories(repo)
    if run("git", "status", "--porcelain", cwd=ROOT):
        raise ValueError("Commit reviewed source changes before publishing")
    bundle = Path(bundle).resolve()
    manifest, assets = validate_bundle(bundle, repo)
    tag = "v{}".format(manifest["version"])
    source_commit = json.loads((bundle / "release-manifest.json").read_text())["sourceCommit"]
    ensure_public_tag(repo, tag, source_commit)
    release = release_for_tag(repo, tag)
    if release is None:
        run("gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--draft", "--latest=false",
            "--title", manifest["version"],
            "--notes-file", str(bundle / "RELEASE-NOTES.md"))
        release = release_for_tag(repo, tag)
    if release is None:
        raise ValueError("Created draft was not returned by GitHub")
    remote = api("repos/{}/releases/{}/assets".format(repo, release["id"]))
    present = verify_assets(remote, assets, complete=not release["draft"])
    if release["draft"]:
        missing = [str(path) for path in assets if path.name not in present]
        if missing:
            run("gh", "release", "upload", tag, "--repo", repo, *missing)
        verify_assets(api("repos/{}/releases/{}/assets".format(repo, release["id"])), assets, True)
        run("gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--latest=false")
    # A repeated call may only verify a published release, never replace its assets.
    print("Published: https://github.com/{}/releases/tag/{}".format(repo, tag))
    if activate:
        activate_manifest(bundle, repo, tag)
        print("Activated latest Release appcasts and update-manifest.json")
    else:
        print("Manifest not activated; rerun with --activate-manifest after review")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--repo", default=PUBLIC_REPO)
    parser.add_argument("--activate-manifest", action="store_true")
    args = parser.parse_args()
    try:
        publish(args.bundle, args.repo, args.activate_manifest)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, "Publish stopped: {}\n".format(error))
