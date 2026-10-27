---
description: "Task 11.324 — what Michael asked for while reviewing the guide"
model: opus
---

Implement task **11.324** from `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`. Read the whole entry; every decision
in it is Michael's. Read `CLAUDE.md`'s "Michael's standing design decisions" first (decision 3 is new).

1. A "finish setting up" sheet after creating a project: publish now, download maps now (with size);
   Later → checklist. Members get the maps half once, after acceptance.
2. *Move to Trash* / *Delete permanently…*; the bottom section becomes **Trash**. Words only.
3. An existing Tag ID: *Use the existing tag* is the default; *Create anyway* is deliberate. Every
   place a tag is created.
4. The central server's address ships filled in and changeable, from one place in the code; "whoever
   runs your server" → TriTrack support.
5. "Signal" only ever means the tag's radio signal in user-visible text; phone coverage is "cell or
   wifi coverage".

Watched red first where a test can see it. Progress lines. **Do not run `dart format`.** Close
**`Partial`**, held at Michael's phone check, **one step at a time**. Report into
`CLAUDE_DOCS/TASK_COMMS.md`, with the copy list for the content lane.
