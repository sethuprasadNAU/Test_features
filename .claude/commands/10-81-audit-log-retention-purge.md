---
description: "Task 10.81 — see DEVELOPMENT_PLAN.md; scheduled by task 10.72's sweep"
model: sonnet
---

Implement task **10.81** from `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`. Read that
entry in full — it carries the evidence and the acceptance criteria.

This task exists because task 10.72 swept the record for findings marked "Open"
that nobody owned. It had been described and not scheduled, which is how both
blocking findings of the sixth gate survived six weeks on paper.

Two standing rules from `TriTrack_Technical_Context.md` apply and are not
optional:

- **Fix the class, not the instance.** Name the class this finding belongs to,
  enumerate every other site it could occur at, and give a verdict per site.
  Silence about a site is not a verdict.
- **An "Open" verdict must leave with a task number**, or an accepted-risk entry
  naming who accepted it and why.

Verify by running the artifact, not by reading it. Commit before updating
`Status`.
