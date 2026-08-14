---
name: ship
description: Authorized full-delivery mode for this repo, taking completed work through adversarial review, CI, PR, and merge. Armed ONLY by Richard, either by running /ship or by saying it in his own words ("ship it", "take it through merge", "get it landed"). Natural-language arming requires the reply to restate the armed scope before anything irreversible. Arming covers that body of work only and never carries to new work.
---

# Ship: authorized full delivery (unamentis-ios)

Richard has made the call: this change goes through review, CI, PR, and merge with you
driving. His invocation is his acceptance of the risk for THIS body of work; it expires with
it. This is the repo-specific variant of the personal `ship` skill, distilled from the
2026-08-14 delivery of PRs #5, #6, and #7, where each rule below caught a real problem.

Without an explicit arming, the repo's standing policy holds absolutely: stage only, commit
only on explicit instruction, never push.

## Non-negotiable gates

1. **Machine-readable evidence only.** A phase ends on an exit code, a test count, or a
   parsed CI conclusion, never on "looks done". A reviewer's opinion never satisfies a gate.
2. **Red CI is a critical blocker.** Diagnose immediately (download the xcresult artifact,
   `xcrun xcresulttool get test-results summary`), fix, re-push. Never merge red, never
   rationalize red. Verify checks actually REGISTERED: a check list without Unit Tests is
   not green, and a poll that treats "not yet registered" as done will lie to you.
3. **Lemon law.** Two or more confirmed defects in one file force a dedicated deep pass over
   that whole file (PR #6's download path rework came from exactly this). Defects cluster.
4. **Verify findings before fixing.** Review agents manufacture findings when asked to find
   gaps. Re-check each against the actual code; fixes for phantom bugs are real bugs.
5. **Convergence bounds.** Apply only findings affecting correctness, data integrity, or a
   stated requirement (the 500 ms turn budget counts). Quality and reuse findings get FILED
   as GitHub issues and listed in the PR body, not applied mid-ship.
6. **Report faithfully.** Failures with their output, skips named as skips, your own misses
   labeled yours (a changed assertion missed in a sibling test cost one CI round).

## Repo and machine facts that shape the run

- **The Mac Studio cannot run iOS tests or builds.** No iOS platform or simulator runtimes
  are installed; even `build-for-testing` fails. The local ceiling is `./scripts/lint.sh`
  (self-resolves DEVELOPER_DIR via `scripts/xcode-env.sh`) plus `swiftc -typecheck` against
  the iphonesimulator SDK with `-swift-version 6`. **CI is the build and test gate.** Say so
  in every PR body: which tests have never executed locally.
- **The per-edit lint hook crashes spuriously** when its swiftlint runs without
  DEVELOPER_DIR (`Trace/BPT trap: 5`). Ignore that specific noise; trust
  `./scripts/lint.sh` output instead.
- **The pre-commit hook resolves its target repo from the command text.** Commit with
  `git -C <worktree> commit ...` so it lints the worktree, not the main checkout.
- **The `models` symlink and `llama.xcframework` are machine-local.** Never stage changes
  to either; replicate CI's placeholder tree when a build probe needs it.
- Work in an isolated worktree per repo, branch named for the change, fast-forwarded onto
  current `origin/main` before committing.

## The pipeline, per wave

1. **Fresh-eyes review** of the full diff yourself: walk consumer chains end to end,
   hypothesize the likely failure modes, verify each against the code.
2. **Commit locally**, then run `/code-review` at high effort against the worktree. Eight
   finder angles run independently; adjudicate every finding (apply, file, or reject with a
   reason) before touching code.
3. **Apply the accepted set in one pass**, rerun the full local gate (lint plus typecheck of
   changed files), commit with a message that reports the work and its verification.
4. **Push, open the PR.** The body is the durable report: what it does, what review found
   and fixed, what was deferred and why, exactly what was and was not verified locally.
5. **Watch CI to completion** with a poll that requires Lint AND Unit Tests to be registered
   and non-pending. On red: artifact, diagnose, fix at the cause (including pre-existing
   breakage that blocks the gate), push, rewatch.
6. **CodeRabbit**: read its findings, verify each, fix or file. It rate-limits on busy PRs;
   when it passes without reviewing, say so in the report and substitute your own final-diff
   pass. Address a Critical finding before its CI round fails, not after.
7. **Merge** (plain merge commit, matching repo history), verify state == MERGED, confirm
   the post-merge main run goes green, then start the next wave. One wave lands fully
   before the next merges; reviews may overlap.

## After the last wave

- File deferred findings as consolidated GitHub issues (one per subsystem, not one per nit).
- Update the relevant state document in `unamentis/docs/status/` with delivery reality:
  PR numbers, merge dates, what changed between plan and landing.
- Final report: outcome first, then per-wave findings and fixes, evidence per layer, what
  remains open, and what went wrong along the way, including your own misses.
