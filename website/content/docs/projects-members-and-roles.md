---
title: "Projects, members and roles"
description: "What a project is, who can do what on one, leaving and being removed, and the Trash: moving a project there, restoring it, and deleting it permanently."
weight: 20
---

<!--
Strings read from the widgets (/w-33, 2026-10-01): projects_screen.dart (the row menu, the
move-to-Trash and leave dialogs, the Trash section and its rows), widgets/project_deletion_dialogs.dart
(delete permanently, remove now, restore, the countdown row), project_members_screen.dart,
more_screen.dart. Re-read for /w-35 (2026-10-10) after tasks 11.324 and 11.339.
-->

Everything you record belongs to a project. A phone can hold several; the one
with the green tick under {{< app "More" >}} → {{< app "Projects" >}} is open.
Tap a name to open it. Your [Tag Library](../managing-your-tags/) belongs to the
phone, not to any project.

{{< shot "joined-projects" "The projects list on an owner's device. The tick marks the active project, Join a project sits above the list, and everything you can do to a project is behind the three-dot button at the end of its row." >}}

The three-dot button on a row holds {{< app "Publish to server" >}} (before a
project is on a server), {{< app "Members" >}},
{{< app "Edit project" >}}, {{< app "Start next season" >}},
{{< app "Leave project" >}} (once on a server) and, last,
{{< app "Move to Trash" >}}. An entry your role does not allow stays in the
menu, grayed, with the reason under it, for example
{{< app "Only a project owner can move this project to the Trash." >}}

{{< app "Members" >}} is also on the {{< app "More" >}} tab, beside
{{< app "Animals" >}}. Anyone on the project can open it; its
{{< app "Your role" >}} card says what your role allows and names the owners to
ask. Look there when something is refused.

{{< shot "more" "The More tab. Members is the row beside Animals, with Tags just below them." >}}

## The three roles

An owner sets your role when letting you in, and can change it.

| | {{< app "Viewer" >}} | {{< app "Contributor" >}} | {{< app "Owner" >}} |
| --- | --- | --- | --- |
| See the project, its tags and everybody's records | Yes | Yes | Yes |
| Receive teammates' records when the device syncs | Yes | Yes | Yes |
| Export a spreadsheet or a backup file | Yes | Yes | Yes |
| Record a bearing, a no-signal or a note | No | Yes | Yes |
| Correct a bearing you recorded yourself | No | Yes | Yes |
| Add a corrected version of a teammate's bearing | No | Yes | Yes |
| Record a truth point | No | Yes | Yes |
| Correct or delete _anybody's_ truth point | No | Yes | Yes |
| Add a tag to the project | No | Yes | Yes |
| Save a position estimate | No | Yes | Yes |
| Restore a backup file into the project | No | Yes | Yes |
| Exclude a bearing from position estimates, for everybody ({{< app "Exclude from estimates…" >}} on the Log) | No | No | Yes |
| Undo somebody else's correction | No | No | Yes |
| Rename the project, or move it to the Trash | No | No | Yes |
| Delete the project permanently, cancel that, or restore it from the Trash | No | No | Yes |
| Turn joining on, hand out the code, approve people | No | No | Yes |
| Change a role, remove somebody, put a past member back | No | No | Yes |

Three rows are worth a second look:

- _A contributor cannot remove their own bad bearing._ Record a corrected one
  over it; excluding a bearing from everybody's position estimates is an owner's
  call.
- _Any contributor may fix anybody's truth point_, unlike a bearing; see
  [truth points](../truth-points/).
- _A viewer can export everything._ Roles limit what people change, not what
  they can copy. Choose the person for what you are willing for them to hold.

## Changing a role, removing, putting back

On {{< app "Members" >}}, an owner changes a role with the dropdown on the
person's row (each choice explained, such as
{{< app "Contributor — records their own" >}}) and removes them with the icon
at the end.

{{< shot "owner-members-and-code" "The Members screen on an owner's device. Your own role is the card at the top; below it each person's role is a dropdown, and the icon at the end of their row removes them from the project." >}}

- The last owner cannot demote or remove themselves; make someone else an
  owner first.
- A removed person moves to {{< app "Past members" >}} with their dates, and
  their records stay, still under their name.
- Removing stops their syncing and server access but cannot delete what is
  already on their phone.
- A past member can be put straight back from their row: no code, no request.

_What the removed person sees_: a gray mark on the {{< app "More" >}} tab and a
gray door-out on the map, and on {{< app "Sync Status" >}}
{{< app "You're no longer on this project, so it has stopped syncing." >}}
Their copy keeps working offline. There is no message or notification.

## Leaving a project

{{< app "Leave project" >}} in the row menu. The dialog says you stop syncing,
your records stay in the project under your name, and your copy keeps working
offline. To come back, ask with the project code or ask an owner to put you
back. If the entry is gray, the line under it says why; usually you are the
only owner.

## Deleting a project

There are two acts, and the first does not do the second.

- _{{< app "Move to Trash" >}}_ hides the project and its records on this
  phone, and you can restore it. For an owner of a project on a server, it hides
  it for every member too. _Nothing is removed from the server._
- _{{< app "Delete permanently…" >}}_ destroys it. Owners only; others see
  {{< app "Only a project owner can delete this project permanently." >}}

{{< diagram "trash-move-restore" "Move to Trash and Restore on a published project. Each box is one place the project's records live; a check means the records are kept there. An owner's move goes to the server and on to every member. A member who has left can move only their own copy, and nothing is sent." >}}

### Deleting permanently

It destroys _every member's_ records in the project on the server: bearings,
animals, tags and estimates. The dialog offers {{< app "Cancel" >}},
{{< app "Delete immediately…" >}} and {{< app "Schedule delete" >}}.
{{< app "Schedule delete" >}} is the normal choice.

{{< shot "delete-project-dialog" "The first dialog, from the three-dot menu on the project's row. It gives the number of days, says every member's records go with the project, and says members can export until then." >}}

- _Scheduling starts a countdown_ set by the server (30 days by default), so a
  phone's wrong clock cannot shorten it.
- _Why it waits:_ the owner, and every member, has time to change their mind
  and to export their records before they are gone.
- _Every member sees it_ on their {{< app "Projects" >}} row, and gets
  {{< app "Export records" >}} in the row menu until the date.
- _The owner can stop it_ with {{< app "Cancel scheduled deletion" >}}.

{{< shot "projects-countdown" "The owner's Projects list during a countdown: the row is tinted and says how many days are left, the date, and that exporting or canceling is in the three-dot menu. The date is the server's waiting period counted from the day this picture was made." >}}

{{< app "Delete immediately…" >}} skips the countdown and asks again, with
{{< app "Remove now" >}}. Records leave the server at once and its backups
within the number of days the dialog gives.
{{< app "There is no countdown and no cancel." >}} If you must tell a landowner
or permit office when the data stopped existing, give them the backup date.

Nobody's phone is emptied: each member keeps their copy, which stops syncing.
The [sync page](../sync/#project-deleted) shows what they see.

{{< diagram "trash-delete-permanently" "Delete permanently. On a published project the server waits out the countdown, then removes every member's records; each phone keeps its own copy, which stops syncing. On a project that is only on this phone, it removes the project from this phone at once." >}}

### The Trash

At the bottom of {{< app "Projects" >}}, {{< app "Trash" >}} lists every
project you moved there, with {{< app "Restore" >}} on each row. Each row's
line says where the project is:

- _On the server_: {{< app "Its records are still held on the server." >}}
  The server keeps them, hidden from everyone. The row's menu has
  {{< app "Delete permanently…" >}} (or {{< app "Cancel scheduled deletion" >}}).
- _Not sent yet_:
  {{< app "Not sent to the server yet — it goes whenever there is cell or wifi coverage." >}}
- _Only on this phone_:
  {{< app "It was never published, so it is only on this phone." >}} or, for a
  project this phone no longer syncs,
  {{< app "This phone no longer syncs it, so this is only this phone's copy." >}}
  Its menu's {{< app "Delete permanently…" >}} removes it and every record in it
  from this phone at once. There is no countdown, because nobody else holds this
  copy, and it cannot be undone: restore it and export it first if you want a
  copy.

If the server cannot answer, the section says why and lists only this phone's
rows.

{{< shot "projects-deleted-section" "The bottom of the Projects list: a project in the Trash that the server still holds, with its explanation, a Restore button, and the three-dot menu." >}}

{{< shot "projects-trash-menu" "The three-dot menu on that row: Delete permanently, with what it does under it." >}}

Members of a project you move to the Trash are told, by name, the next time
they sync, and anything they record in it still reaches the server.

### Restoring

{{< app "Restore" >}}, then {{< app "Restore project" >}}, brings it back on the
server for every member, and cancels any scheduled deletion. Members get it back
the next time they open TriTrack with cell or wifi coverage. A project already
destroyed on the server cannot be restored.
