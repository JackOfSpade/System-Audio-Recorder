#!/usr/bin/env python3
"""Merge one explicitly selected, current, fully checked same-repository PR.

This script never enumerates branches, executes PR code, or deletes a branch.
It uses only the authenticated GitHub CLI and the Python standard library.
"""
import json
import os
import subprocess


def validate(pr, base_sha, comparison, checks, required):
    if pr.get("state") != "open" or pr.get("draft"):
        raise ValueError("Select an open, non-draft pull request")
    if pr["base"]["ref"] != "main":
        raise ValueError("Only a pull request targeting main can be merged")
    if pr["head"]["repo"]["id"] != pr["base"]["repo"]["id"]:
        raise ValueError("This workflow accepts same-repository pull requests only")
    if comparison.get("merge_base_commit", {}).get("sha") != base_sha:
        raise ValueError("Update the PR with current main and rerun its checks")
    latest = {}
    for check in checks:
        if check.get("head_sha") != pr["head"]["sha"]:
            continue
        if check.get("app", {}).get("slug") != "github-actions":
            continue
        name = check["name"]
        if name not in latest or check["id"] > latest[name]["id"]:
            latest[name] = check
    failures = []
    for name in required:
        check = latest.get(name, {})
        if check.get("status") != "completed" or check.get("conclusion") != "success":
            failures.append(name)
    if failures:
        raise ValueError("Required checks missing or unsuccessful: " + ", ".join(failures))


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def api(path, paginated=False):
    args = ["api", "--method", "GET", path]
    if paginated:
        args += ["--paginate", "--slurp"]
    return json.loads(gh(*args))


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    number = os.environ["PR_NUMBER"]
    if not number.isdecimal() or int(number) < 1:
        raise ValueError("PR number must be a positive integer")
    required = json.loads(os.environ["REQUIRED_CHECKS"])
    pr = api(f"repos/{repo}/pulls/{int(number)}")
    head = pr["head"]["sha"]
    base = api(f"repos/{repo}/git/ref/heads/main")["object"]["sha"]
    comparison = api(f"repos/{repo}/compare/{base}...{head}")
    pages = api(f"repos/{repo}/commits/{head}/check-runs?filter=all&per_page=100", True)
    checks = [c for page in pages for c in page["check_runs"]]
    validate(pr, base, comparison, checks, required)
    # GitHub branch protection enforces required checks atomically at merge time.
    # match-head-commit also rejects a branch that moved after our inspection.
    # Private Free repos lack server-side protection: the explicit checks above
    # remain a guard for this workflow, but do not protect other write paths.
    gh("pr", "merge", str(int(number)), "--repo", repo, "--merge", "--match-head-commit", head)
    merged = api(f"repos/{repo}/pulls/{int(number)}")
    if not merged.get("merged"):
        raise RuntimeError("GitHub did not confirm the selected PR was merged")
    if os.environ.get("GITHUB_OUTPUT"):
        outputs = {"base_sha": base, "head_sha": head,
                   "merge_sha": merged["merge_commit_sha"]}
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            for key, value in outputs.items():
                if not isinstance(value, str) or not value.isalnum():
                    raise ValueError("Invalid commit identifier from GitHub")
                output.write(f"{key}={value}\n")
    for workflow in json.loads(os.environ["MAIN_WORKFLOWS"]):
        gh("workflow", "run", workflow, "--repo", repo, "--ref", "main")
    print(f"Merged PR #{int(number)} and dispatched main validation")


if __name__ == "__main__":
    main()
