---
description: "Task 11.237 — importing somebody else's project gives you a copy that silently cannot sync"
model: opus
---

Implement task **11.237** from `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`. Read that entry first.

**Run this before `/10-87`** — it decides which of three cases that task's consent dialog is for.

## What happens today, measured

The archive carries the project's own `project_id` **and its `Projects` row, owner included**, and
`Project_Memberships` is `ArchiveDisclosure.carried`. An import is a **merge into the same project**,
not a new project appearing, and **importing never makes you the owner.**

So a colleague who is not on the team imports your archive and gets a project in their list, owned by
you, with no membership row. The app permits this deliberately (`tag_database_screen.dart`: *"the
server is the authority and this file legitimately holds projects with no membership row"*). They can
read it. On the next sync the server refuses everything they push, and **nothing tells them.**

**Nothing is lost. The problem is the silence** — a read-only fossil that behaves like a live project.

## Michael's decision, 2026-09-13

**Allowed, as a read-only snapshot, and the app says so.** Not refused.

## 1. Classify, and derive rather than store

|  | Already on this device | Not |
|---|---|---|
| **I am a member** | **Merge** (10.87's case) | **Adopt** — live and syncing |
| **I am not** | Merge into a snapshot — still read-only | **Snapshot** — read-only, said so |

- **Derive membership from the archive's own `Project_Memberships` rows.** It is the only answer
  available offline, and offline is where this happens.
- **The file is untrusted and can lie both ways — cost each one in writing.** Claiming membership you
  lack lands on today's behaviour (server refuses), so it is the failure already being fixed.
  Denying membership you have makes a live project read-only until the next sync corrects it. **Both
  recoverable — that is the argument for deriving rather than refusing.**
- **Never store a read-only flag.** They may join tomorrow. **Re-derive every time**, so a real
  membership turns the snapshot live **with no re-import**. A cached permission is a
  hand-maintained list with a nicer name.

## 2. What a snapshot must do

- **Say what it is on the project itself**, not only in an import dialog nobody remembers a fortnight
  later. *"A copy of someone else's project. Changes here stay on this device."*
- **Do not push it.** Sync skips a project with no membership. **The refused-row pile is the symptom;
  not generating it is the fix** — assert on the push set, not on the refusal count.
- **Name the way in:** a join code grants a real membership, and the person holding a snapshot is
  exactly who needs to ask for one.
- **DECIDED by Michael, 2026-09-13: refuse the edit, and the refusal explains the way in.** Not
  *allow it and keep it local*. **His reasoning, and it is the right one: allowing an edit that can
  never leave the device is the friendlier option and the dishonest one** — it looks like
  contributing and is not. A refusal is blunter and true.
  - **The message must be short and must name the actual mechanism**, not gesture at one. The
    mechanism exists and is built: **a project owner gives out a join code** (Project Members →
    Join code), **the person enters it** (`join_project_screen.dart`, *"Have a join code?"*), and
    **the owner approves the request** — handing out a code does not by itself admit anybody
    (`project_members_screen.dart` says so). **Read those two screens and use their words**, so the
    sentence a person is given matches the buttons they will then look for.
  - **Do not build a "request to join from here" button in this task.** The person holding a
    snapshot is offline-plausible and may not have the server configured; **a message that describes
    a path is honest, a button that fails is not.** If a shortcut is worth adding later it is its own
    decision.
  - **Write the refusal once and reach it from everywhere an edit is possible** on a snapshot
    project — a refusal that exists on three screens and not the fourth is this project's oldest
    shape, and the fourth is always the one somebody finds.

## 3. The security model already records the tension

§4.19.1 notes the export screen advertises the archive as shareable *"via WhatsApp, email, or cloud
storage"* while the merge path treats it as untrusted — *"choosing a file says where the bytes came
from, not who wrote them."* **This task turns that tension into stated behaviour.**

- **Add one sentence to §4.19.1's archive row:** a non-member import is a read-only snapshot that
  does not sync, derived per read.
- **Weaken no §4.19.2 clause.** Read-only is about what leaves the device, not what the file may do
  on the way in.

## Before you report

`flutter test`. **GitHub's checks are paused** (task 11.325), so your local run, and the local nightly batch, are the evidence.

## Acceptance

- Three cases classified from the archive's own membership rows, a test each.
- A non-member import **says what it is on the project screen**.
- Sync **generates no rows** for a project with no membership — asserted on the push set.
- **Joining later turns the snapshot live with no re-import**, asserted.
- **An edit on a snapshot is refused**, with one shared message naming the join-code path in the
  words those screens use, **reachable from every editable surface** and asserted on more than one.
- §4.19.1's row updated.
