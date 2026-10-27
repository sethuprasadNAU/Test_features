---
description: "Task 11.50 — ask again for a record this device refused. DEFERRED: run only when the written trigger fires."
model: opus
---

**Do not run this yet.** Task 11.50 in `CLAUDE_DOCS/DEVELOPMENT_PLAN.md` is
**deferred by Michael's decision of 2026-08-29**, and the trigger is written into the
entry. Read it before doing anything.

**The gap.** The server keeps records in one numbered line and each device keeps a
bookmark saying how far it has read. When a record arrives that this device cannot
store — most often because two devices are on different builds — the device skips it
**and still moves its bookmark past it**, so nothing ever asks for that record again.
The only thing that brings it back is somebody editing it on the device where it was
written. A teammate's bearing can be on their device and on the server and
permanently not on yours.

**Why it is deferred and not open.** Task 11.44 made the refusal durable and legible:
the sync screen names the record and the reason, the notice survives a restart, and
11.44 correctly deleted the old claim that syncing again would bring it in. A visible
gap is below `SECURITY_SCOPE_AND_EXIT.md` §4's bar — B1 is silent loss *and the user
is not told* — while the fix is new machinery on the client path whose failure mode is
losing a field season. The same trade was accepted in the same shape for the
viewer-restore dialog.

**The trigger — any one, and this becomes scheduled:** a beta user reports a record
that never arrived, or that section is found non-empty on a non-development build; or
the beta team is knowingly running mixed app versions for more than a few days; or the
refusal ever becomes silent again, at which point it is B1 immediately and this stops
being deferrable.

**When it does run**, the entry states the shape so it is not re-derived under
pressure: store the refused record's position in the line at the moment it is refused;
replay from that position and never from zero; make a retry that fails again say the
same thing as the first refusal, naming which record and which rule; and read the
existing incoming-refusal store rather than building a third path, because a parallel
mechanism for the mirror-image problem is how the two halves drift apart.

Then re-read `CLAUDE.md`'s "Reporting results" section before you finish.
