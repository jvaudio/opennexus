# Agent guidance

## CodeRabbit review usage

CodeRabbit reviews every pull request with the account's settings (there is no `.coderabbit.yaml`), and each push to an open PR spends a review from a shared hourly allowance. These are defaults: an urgent fix, or a collaborator who needs the push now, can override them; say why in the PR.

- Push a finished, coherent change. Run the checks that cover it first (`swift test`, `scripts/lint.sh`, and the tests of any `server/` or `web/` part you touched) and batch related commits into one push rather than pushing each fix, and not while CodeRabbit is still reviewing the previous push.
- Open a PR that is still in progress as a draft and mark it ready when review would be useful.
- New pushes get an incremental review automatically. Use `@coderabbitai review` only when automatic review was paused or skipped, and `@coderabbitai full review` only when the whole PR needs a fresh pass, not repeatedly. Before merge, make sure the PR's final commit has been reviewed.
- If CodeRabbit is rate limited, say so in the PR or your hand-off and wait for the limit to clear instead of retriggering it. Its passing "Review rate limited" check is not a review: the commits it skipped still need one.
