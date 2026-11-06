"""Validate the single public source/release repository using GitHub REST APIs."""
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBLIC_REPO = "leon-wenhao/flow-quota"


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def api(endpoint, method="GET", payload=None, allow_missing=False):
    args = ["gh", "api", "--method", method, endpoint]
    if payload is not None:
        args += ["--input", "-"]
    result = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        # Only an explicit HTTP 404 is absence; auth/network errors must stop publication.
        try:
            missing = str(json.loads(result.stdout).get("status")) == "404"
        except (ValueError, AttributeError):
            missing = False
        if allow_missing and missing:
            return None
        raise subprocess.CalledProcessError(result.returncode, args, result.stdout, result.stderr)
    return json.loads(result.stdout) if result.stdout.strip() else None


def slug(remote):
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?", remote)
    if not match:
        raise ValueError("Expected a github.com HTTPS or SSH remote")
    return match[1]


def check_repositories(repo):
    source = slug(run("git", "remote", "get-url", "origin", cwd=ROOT))
    if repo != PUBLIC_REPO or source != repo:
        raise ValueError("Source and release must use leon-wenhao/flow-quota")
    info = api("repos/" + repo)
    if info["private"] or info.get("archived") or info.get("default_branch") != "main":
        raise ValueError("The source/release repository must be public, active and use main")


def ensure_public_tag(repo, tag, source_commit):
    """Create a lightweight tag at the exact bundle source, or verify its existing target."""
    if repo != PUBLIC_REPO or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Invalid release repository/tag")
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("Invalid source commit")
    # A missing commit or a commit outside main is not an acceptable build source.
    comparison = api("repos/{}/compare/{}...main".format(repo, source_commit))
    if comparison["status"] not in ("identical", "ahead"):
        raise ValueError("Release source must be in remote main history")
    refs = api("repos/{}/git/matching-refs/tags/{}".format(repo, tag))
    existing = next((ref for ref in refs if ref["ref"] == "refs/tags/" + tag), None)
    if existing:
        target = existing["object"]
        # Annotated tags are supported, but nested/unusual targets are rejected.
        if target["type"] == "tag":
            target = api("repos/{}/git/tags/{}".format(repo, target["sha"]))["object"]
        if target["type"] != "commit" or target["sha"] != source_commit:
            raise ValueError("Existing tag points to different source; use a new version")
    else:
        api("repos/" + repo + "/git/refs", "POST",
            {"ref": "refs/tags/" + tag, "sha": source_commit})
