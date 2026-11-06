"""Maintain an independent public history through documented GitHub REST APIs.

Only five public paths are permitted. GitHub API authentication is delegated to
official gh; source git objects, history and credentials are never uploaded here.
"""
import argparse
import base64
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBLIC_REPO = "leon-wenhao/flow-quota-releases"
PUBLIC_FILES = ("README.md", "INSTALL.md", "DISTRIBUTION.md", "assets/logo.png")
TRACKED_FILES = set(PUBLIC_FILES) | {"update-manifest.json"}
AUTHOR = {"name": "leon-wenhao", "email": "37610667+leon-wenhao@users.noreply.github.com"}


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def api(endpoint, method="GET", payload=None):
    args = ["gh", "api", "--method", method, endpoint]
    if payload is not None:
        args += ["--input", "-"]
    result = subprocess.check_output(args, input=json.dumps(payload) if payload is not None else None, text=True)
    return json.loads(result)


def pages(endpoint):
    result = json.loads(run("gh", "api", "--paginate", "--slurp", endpoint))
    return [item for page in result for item in page]


def slug(remote):
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?", remote)
    if not match:
        raise ValueError("Expected a github.com HTTPS or SSH remote")
    return match[1]


def check_repositories(repo):
    source = slug(run("git", "remote", "get-url", "origin", cwd=ROOT))
    if repo != PUBLIC_REPO or source == repo:
        raise ValueError("Publishing must use the configured independent public repository")
    if not api("repos/" + source)["private"]:
        raise ValueError("The source repository must remain private")
    if api("repos/" + repo)["private"]:
        raise ValueError("The distribution repository must be public")


def main_head(repo):
    branches = pages("repos/" + repo + "/branches?per_page=100")
    if not branches:
        return None
    main = next((branch for branch in branches if branch["name"] == "main"), None)
    if main is None:
        raise ValueError("Distribution repository has no main branch")
    return main["commit"]["sha"]


def public_tree(repo, commit):
    tree = api("repos/{}/git/trees/{}?recursive=1".format(repo, commit))
    if tree["truncated"]:
        raise ValueError("Cannot audit truncated public tree")
    files = {}
    for item in tree["tree"]:
        if item["type"] == "tree" and item["path"] == "assets":
            continue
        if item["path"] not in TRACKED_FILES or item["type"] != "blob" or item["mode"] != "100644":
            raise ValueError("Unexpected file or mode in public history: " + item["path"])
        files[item["path"]] = item["sha"]
    return files


def audit_public_history(repo):
    # Audit all branch/tag ancestors: deleting a file in HEAD does not erase history.
    if main_head(repo) is None:
        return
    refs = api("repos/" + repo + "/git/matching-refs/")
    seen = set()
    for ref in refs:
        commits = pages("repos/{}/commits?sha={}&per_page=100".format(repo, ref["object"]["sha"]))
        for commit in commits:
            if commit["sha"] not in seen:
                public_tree(repo, commit["sha"])
                seen.add(commit["sha"])


def read_public_file(repo, name):
    head = main_head(repo)
    files = public_tree(repo, head) if head else {}
    if name not in files:
        return head, None
    blob = api("repos/{}/git/blobs/{}".format(repo, files[name]))
    if blob["encoding"] != "base64":
        raise ValueError("Unsupported public blob encoding")
    return head, base64.b64decode(blob["content"])


def commit_public_files(repo, files, message, expected_head=None):
    if repo != PUBLIC_REPO or not files or set(files) - TRACKED_FILES:
        raise ValueError("Public commit contains a path outside the explicit allowlist")
    head = main_head(repo)
    if expected_head is not None and head != expected_head:
        raise ValueError("Public main changed during validation; retry after review")
    if head is None:
        # Git Database API cannot create a tree in an entirely empty repository.
        # Contents API initializes it with only the approved public README.
        if "README.md" not in files:
            raise ValueError("Initialize public documentation before publishing a manifest")
        api("repos/" + repo + "/contents/README.md", "PUT", {
            "message": "docs: introduce Flow Quota binary distribution", "branch": "main",
            "content": base64.b64encode(files["README.md"]).decode(),
            "author": AUTHOR, "committer": AUTHOR,
        })
        head = main_head(repo)
    existing = public_tree(repo, head)
    entries = []
    for name, content in files.items():
        local_sha = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        if existing.get(name) == local_sha:
            continue
        blob = api("repos/" + repo + "/git/blobs", "POST", {
            "content": base64.b64encode(content).decode(), "encoding": "base64",
        })
        if blob["sha"] != local_sha:
            raise ValueError("GitHub blob hash differs from local public file")
        entries.append({"path": name, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    if not entries:
        return head
    commit_info = api("repos/{}/git/commits/{}".format(repo, head))
    tree = api("repos/" + repo + "/git/trees", "POST", {
        "base_tree": commit_info["tree"]["sha"], "tree": entries,
    })
    commit = api("repos/" + repo + "/git/commits", "POST", {
        "message": message, "tree": tree["sha"], "parents": [head],
        "author": AUTHOR, "committer": AUTHOR,
    })
    # No force push: a concurrent update must fail instead of being overwritten.
    api("repos/" + repo + "/git/refs/heads/main", "PATCH", {"sha": commit["sha"], "force": False})
    return commit["sha"]


def ensure_public_tag(repo, tag):
    head = main_head(repo)
    if head is None:
        raise ValueError("Initialize public documentation first")
    refs = api("repos/{}/git/matching-refs/tags/{}".format(repo, tag))
    if not any(ref["ref"] == "refs/tags/" + tag for ref in refs):
        api("repos/" + repo + "/git/refs", "POST", {"ref": "refs/tags/" + tag, "sha": head})


def sync_documents(repo):
    check_repositories(repo)
    audit_public_history(repo)
    files = {}
    for name in PUBLIC_FILES:
        source = ROOT / "distribution/public" / name
        if source.is_symlink() or not source.is_file():
            raise ValueError("Missing or symlinked public document: " + name)
        files[name] = source.read_bytes()
    commit_public_files(repo, files, "docs: update public application documentation")
    audit_public_history(repo)
    print("Public documentation synchronized through GitHub REST API")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=PUBLIC_REPO)
    args = parser.parse_args()
    sync_documents(args.repo)
