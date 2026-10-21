# CI and merging

Direct pushes to `main` are allowed. Branch protection and merge rulesets do
not require a pull request or checks before a push. CI and security workflows
still report the stable results listed below. A failed or skipped prerequisite
fails its aggregate check.

- `CI required`
- `Security required`
- `Dependency review required`

The **Merge validated PR** workflow is manual and accepts one PR number. It
checks the current main ancestry, exact PR head, GitHub Actions check origin,
and latest configured check results before merging. It checks out trusted main policy,
never PR code. It dispatches main validation after the merge and never deletes
branches itself. GitHub's existing repository auto-delete setting can separately
delete the selected PR's merged head branch. Existing branches and PRs are not
swept or automatically adopted.

The selected PR workflow is optional. Its explicit checks guard that merge
path; they do not restrict direct pushes or other writers. They cannot atomically
prevent another writer advancing main between validation and the merge. Standard
GitHub-hosted runners are used, and existing cloud/API workflows retain their
own credentials and cost controls.
