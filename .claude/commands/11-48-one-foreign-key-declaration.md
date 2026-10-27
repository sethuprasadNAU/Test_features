---
description: "Task 11.48 — one declaration of which column points at which table. DEFERRED: run only when a third consumer needs it."
model: sonnet
---

**Do not run this yet.** Task 11.48 in `CLAUDE_DOCS/DEVELOPMENT_PLAN.md` is
deliberately deferred, and the trigger is written into it: **run it when a third
consumer needs the foreign-key graph, and not before.**

Today there are two — the server's schema and the client's new "this record is waiting
on that record" explanation, which finds the link by convention. Two consumers of a
convention is not yet a problem; three is where a convention starts being maintained
in three places.

If you have been handed this command, check whether a third consumer now exists. If it
does, implement the task. If it does not, **say so and stop** — this is the opposite of
the failure this project keeps hitting, and doing structural work before there is
enough evidence to shape it correctly is its own mistake.
