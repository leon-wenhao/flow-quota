"""Publish one audited build to GitHub and Gitee; resume with the same bundle.

A failure leaves a local receipt and reports partial state. It never rolls back
another host, replaces published bytes, or calls a second platform build.
"""
import argparse
import json
from pathlib import Path
import subprocess

from gitee_api import GiteeAPI, credential
from gitee_release import GiteeRelease
from gitee_feeds import publish_feeds
from public_repository import PUBLIC_REPO, check_repositories
from publish_macos import activate_manifest, publish
from release_bundle import validate_bundle
from push_sources import git, push


def publish_dual(bundle, activate=False):
    bundle = Path(bundle).resolve()
    manifest, files = validate_bundle(bundle, PUBLIC_REPO)
    if git("status", "--porcelain"):
        raise ValueError("Commit reviewed source before dual publication")
    # Reject missing/invalid API credentials before remote mutation.
    # Actual release write scope is enforced by each host when publishing.
    gitee = GiteeAPI(credential())
    gitee.preflight()
    check_repositories(PUBLIC_REPO)
    commit = json.loads((bundle / "release-manifest.json").read_text())["sourceCommit"]
    tag = "v" + manifest["version"]
    git("merge-base", "--is-ancestor", commit, "refs/heads/main")
    local_tags = git("tag", "--list", tag)
    if local_tags:
        if git("rev-parse", tag + "^{commit}") != commit:
            raise ValueError("Local tag differs from bundle source")
    else:
        git("tag", tag, commit)
    receipt = bundle.parent / (bundle.name + "-publication.json")
    state = {"version": manifest["version"], "build": manifest["build"], "sourceCommit": commit,
             "sourceSynced": False, "githubPublished": False, "giteeVerified": False,
             "giteeFormal": False, "giteeActivated": False, "githubActivated": False}

    def save():
        temporary = receipt.with_suffix(".tmp")
        temporary.write_text(json.dumps(state, indent=2) + "\n")
        temporary.replace(receipt)

    try:
        save()
        push(tag)
        state["sourceSynced"] = True
        save()
        publish(bundle, PUBLIC_REPO, False)
        state["githubPublished"] = True
        save()
        mirror = GiteeRelease(gitee, bundle, manifest, files)
        mirror.stage()
        state["giteeVerified"] = True
        save()
        if activate:
            # Check GitHub rollback/build rules before activating either host.
            activate_manifest(bundle, PUBLIC_REPO, tag, dry_run=True)
            publish_feeds(bundle, manifest, dry_run=True)
            mirror.activate()
            state["giteeFormal"] = True
            save()
            publish_feeds(bundle, manifest)
            state["giteeActivated"] = True
            save()
            activate_manifest(bundle, PUBLIC_REPO, tag)
            state["githubActivated"] = True
            save()
    except Exception:
        save()
        print("Dual publication incomplete. State: " + str(receipt), flush=True)
        print(json.dumps(state), flush=True)
        raise
    print("Both hosts verified. " + ("Update sources activated." if activate else
          "Not activated; rerun with --activate-manifest after review."))
    print("Publication receipt: " + str(receipt))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--repo", default=PUBLIC_REPO, choices=[PUBLIC_REPO])
    parser.add_argument("--activate-manifest", action="store_true")
    args = parser.parse_args()
    try:
        publish_dual(args.bundle, args.activate_manifest)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, "Dual publication stopped: {}\n".format(error))
