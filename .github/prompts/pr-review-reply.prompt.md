---
mode: agent
description: "Read and respond to pull-request review threads on intune-my-macs: fetch unresolved review comments, address each (code change or reply), re-validate with ./tools/verify.sh, and post concise replies — pausing for confirmation before pushing or resolving threads."
---

# Reply to PR review comments

You are working through **pull-request review feedback** for the `intune-my-macs`
repository. Read the open review threads, address each one, and reply — without
losing track of any comment. Use real `gh`/git/file tools; do not just describe
the steps. See [../../AGENTS.md](../../AGENTS.md) for repo conventions.

## Before you start

1. Identify the PR (ask for the number/URL if not given) and confirm the active
   `gh` account has access: `gh pr view <number>`.
2. List the review threads and comments:
   - `gh pr view <number> --json reviews,comments`
   - Unresolved line comments:
     `gh api repos/microsoft/intune-my-macs/pulls/<number>/comments`
3. Summarize each distinct piece of feedback as a checklist so nothing is missed.

## For each comment

1. **Classify** it: code change requested, question, or nit/non-actionable.
2. **If a change is requested:** make the smallest correct edit, following
   [../../docs/conventions.md](../../docs/conventions.md). Keep changes in logical
   units (one concern per commit).
3. **If it's a question:** answer it factually in a reply; only change code if the
   answer implies a fix.
4. **Re-validate:** run `./tools/verify.sh` after code changes — it must pass.
5. **Reply** to the specific thread, concisely, stating what you did:
   - `gh api repos/microsoft/intune-my-macs/pulls/<number>/comments/<comment_id>/replies -f body="…"`
   - Reference the commit that addresses it when applicable.

## Wrap up

- Re-run `./tools/verify.sh`; regenerate `INTUNE-MY-MACS-DOCUMENTATION.md` if any
  artifact changed; update `CHANGELOG.md` for material changes.
- **Pause and show a summary** (threads addressed, replies posted, commits made)
  and **confirm with the user before pushing** or resolving any thread.
- Never use `--no-verify`; never force-push; never resolve a thread you did not
  actually address.
