#!/usr/bin/env python3
"""Commits the staged changes in a checkout through the GitHub API.

A commit made with plain `git commit` in a workflow is unsigned. One made
through the REST git data API with the workflow's GITHUB_TOKEN (and no author
or committer given) is signed by GitHub and shows as Verified. The publish
workflow uses this to push gh-pages.

    scripts/push-signed.py <checkout> <branch> <message>

Needs GITHUB_TOKEN and GITHUB_REPOSITORY. The branch must already exist; the
checkout's HEAD must be its tip. The ref moves fast-forward only, so a
concurrent push fails rather than being lost.
"""
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")


def api(method, path, body=None):
    request = urllib.request.Request(
        f"{API}/repos/{os.environ['GITHUB_REPOSITORY']}/{path}",
        data=None if body is None else json.dumps(body).encode(),
        method=method,
        headers={
            "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"{method} {path}: {error.code} {error.read().decode()[:500]}")


def git(checkout, *args):
    return subprocess.run(
        ["git", "-C", checkout, *args], check=True, capture_output=True
    ).stdout


def main():
    checkout, branch, message = sys.argv[1:4]
    parent = git(checkout, "rev-parse", "HEAD").decode().strip()
    base_tree = git(checkout, "rev-parse", "HEAD^{tree}").decode().strip()
    changes = git(
        checkout, "diff", "--cached", "--no-renames", "--name-status", "-z", "HEAD"
    ).split(b"\0")
    entries = []
    for status, path in zip(changes[0::2], changes[1::2]):
        path = path.decode()
        if status == b"D":
            entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
            continue
        mode = git(checkout, "ls-files", "-s", "--", path).decode().split()[0]
        content = git(checkout, "show", f":{path}")
        blob = api("POST", "git/blobs", {
            "content": base64.b64encode(content).decode(),
            "encoding": "base64",
        })
        entries.append({"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]})
    if not entries:
        print("nothing new")
        return
    tree = api("POST", "git/trees", {"base_tree": base_tree, "tree": entries})
    commit = api("POST", "git/commits", {
        "message": message, "tree": tree["sha"], "parents": [parent],
    })
    api("PATCH", f"git/refs/heads/{branch}", {"sha": commit["sha"], "force": False})
    verified = commit.get("verification", {}).get("verified")
    print(f"{branch} -> {commit['sha']} ({len(entries)} files, verified: {verified})")


if __name__ == "__main__":
    main()
