"""Push reviewed main and an optional version tag to both fixed repositories.

Explicit URLs avoid relying on clone-local multi-push configuration. Never force
push or mirror/delete refs. Each successful host is reported before the next.
"""
import argparse
import re
import subprocess
from public_repository import ROOT, PUBLIC_REPO, api

GITHUB = "https://github.com/" + PUBLIC_REPO + ".git"
GITEE = "git@gitee.com:Leon-wh/flow-quota.git"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True, timeout=60).strip()


def gitee_refs(*refs):
    output = git("ls-remote", GITEE, *refs)
    return dict(line.split()[::-1] for line in output.splitlines())


def verify_gitee_source(commit, tag):
    refs = gitee_refs("refs/heads/main", "refs/tags/" + tag, "refs/tags/" + tag + "^{}")
    target = refs.get("refs/tags/" + tag + "^{}", refs.get("refs/tags/" + tag))
    if target != commit:
        raise ValueError("Gitee tag does not point to the bundle source commit")
    # Only allow a source on local main, and require the remote's main tip to be
    # known locally before checking ancestry; no stale-ref approximation.
    remote_main = refs.get("refs/heads/main")
    if not remote_main:
        raise ValueError("Gitee main missing")
    git("merge-base", "--is-ancestor", commit, remote_main)


def push(tag=None):
    if git("status", "--porcelain"):
        raise ValueError("Commit reviewed changes before syncing source")
    commit = git("rev-parse", "refs/heads/main")
    refs = [commit + ":refs/heads/main"]
    if tag:
        if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
            raise ValueError("Invalid release tag")
        git("merge-base", "--is-ancestor", git("rev-parse", tag + "^{commit}"), commit)
        refs.append("refs/tags/" + tag + ":refs/tags/" + tag)
    completed = []
    for label, url in [("GitHub", GITHUB), ("Gitee", GITEE)]:
        try:
            git("push", "--atomic", url, *refs)
            if label == "GitHub":
                remote = api("repos/" + PUBLIC_REPO + "/git/ref/heads/main")["object"]["sha"]
            else:
                remote = gitee_refs("refs/heads/main").get("refs/heads/main")
            if remote != commit:
                raise ValueError(label + " main verification failed")
        except (subprocess.SubprocessError, ValueError) as error:
            raise ValueError("Source sync incomplete; completed={}; failed={}. Retry the same command. {}".format(
                completed, label, type(error).__name__)) from None
        completed.append(label)
        print(label + " source verified: " + commit, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag")
    args = parser.parse_args()
    try:
        push(args.tag)
    except (ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + "\n")
