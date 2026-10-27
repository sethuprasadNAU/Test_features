---
title: "Sync"
description: "Where the app tells you how sync is going, what the frequency setting really does, and what a failure looks like."
weight: 40
---

<!--
Strings read from the widgets (/w-33, 2026-10-01): sync_status_screen.dart (headings, the
held-record section and cards, the frequency notes, the replaced-records sentence),
held_row_details.dart (card wording), sync_transport.dart (Offline too long, Project deleted,
Server doesn't offer this), sync_status_presentation.dart (colors and shapes),
identity_validation.dart (names).
-->

Everything is recorded on the phone first. Sync sends it to the server and
brings your teammates' records back, whenever there is a connection; nothing in
the field waits for it.

{{< diagram "sync-states" "Most records reach the server on the ordinary next sync. A record the server refuses stays safe on this device only; one held back for another reason clears itself once that reason does." >}}

## No server is fine

Without a server the app is complete: projects, tags, bearings, estimates, the
map and exports. There is no sync mark and nothing reaches for the network. The
rest of this page applies once a device is signed in to the TriTrack server.

{{< diagram "device-and-server" "Everything is recorded on your phone first. Most of it reaches the server once you sync, scoped to the project it belongs to and visible to your teammates from then on. Your Tag Library never does — see managing your tags." >}}

## Where to look

{{< shot "joined-sync-indicator" "The map. The sync icon is the small round button directly above the +, and here it is a green tick: this device is up to date." >}}

- _The round icon above the_ {{< app "+" >}} _on the map_. Tap it to open
  {{< app "Sync Status" >}}.
- _A dot of the same color on the_ {{< app "More" >}} _tab_, and on the
  {{< app "Sync Status" >}} row inside it.
- {{< app "Sync Status" >}} _itself_, which says in words what happened and
  what to do.

The color and shape mean:

- _Green tick_: up to date.
- _Amber triangle_: something is behind or refused, but nothing is at risk.
- _Red exclamation_: something is on this phone only, or nothing is getting
  through until somebody acts.
- _Gray_: not a verdict. Offline (crossed-out cloud), syncing (spinning arrow),
  no longer on the project (a door out), or project deleted (exclamation in a
  circle).
- _No mark at all_: no server is set up.

The shapes are there because about one man in twelve cannot tell the amber from
the red. Records waiting to sync are normal after time without coverage; the count
going down is a sync working.

## Sync now, and when it syncs by itself

{{< shot "joined-sync-status" "Sync Status. The button syncs now; the four choices under it decide when the app is allowed to sync by itself." >}}

{{< app "Sync now" >}} syncs at once, whatever the setting: tap it at the
trailhead before the drive home.

The setting decides how long after the last sync the app tries again when it
is open.
{{< app "It does not sync in the background: while the app is closed, nothing syncs at any of these settings." >}}

- {{< app "Every time I open it" >}}: most current, most battery.
- {{< app "Every 15 minutes" >}}: the default; leave it.
- {{< app "Hourly" >}}: fewer round trips.
- {{< app "Only when I ask" >}}: nothing syncs until you tap
  {{< app "Sync now" >}}, and the screen says that is why records are waiting.

The reason to choose {{< app "Only when I ask" >}} is _battery_. A project's
data is small, but in the field with no cell or wifi coverage an automatic
setting keeps trying while the app is open, and each try costs battery. Tap
{{< app "Sync now" >}} when you are back in coverage. Automatic sync uses
cellular data too; there is no wifi-only setting.

## When something goes wrong

The mark changes and {{< app "Sync Status" >}} says what happened. In every
case below, the records on your phone stay on your phone.

### Offline

{{< shot "sync-offline" "Sync Status, offline. Gray and calm on purpose: this is the ordinary condition of a phone with no cell or wifi coverage, not a fault. On the map the icon is a gray crossed-out cloud." >}}

Gray, {{< app "Offline" >}}, with the last successful sync. Not a fault: keep
recording, and the next sync takes it all.

### Some records not synced

{{< shot "sync-records-held" "Sync Status: some records not synced. Red, because the server refused something this device sent and that record is now in one place only." >}}

Red: the server refused some records. They are kept, and the screen says
{{< app "These records are safe on this device, and only here until they sync — keep it backed up. Each card says why and what to do." >}}

Under {{< app "Waiting to sync" >}}, each record has a card with
{{< app "Why it is waiting" >}}, {{< app "What you can do" >}}, when it was last
tried, and {{< app "Try again" >}}. Follow the card; it names the part of the
record the server objected to when the server said, and says plainly when it
did not. The usual fix is to retype pasted text, because
{{< app "pasted text can carry hidden characters the server will not store" >}}.
Save, then tap {{< app "Try again" >}}. The commonest case is a character in
your own name; see [below](#what-a-name-may-contain).

### Some records did not arrive

{{< shot "sync-records-missing" "Sync Status: some records did not arrive. Amber, because something the server sent is not lost: this copy of the app just cannot read it." >}}

Amber: a teammate on a newer version sent something this app cannot read
({{< app "the server sent could not be read by this app." >}}). Nothing is
lost. Update the app, and each record arrives the next time it changes.

### You're not on this project

{{< shot "sync-removed" "Sync Status: you're not on this project. Gray and calm, because this is somebody's decision, not a fault, and the icon on the map is a gray door out." >}}

Gray: {{< app "You're no longer on this project, so it has stopped syncing." >}}
You left or an owner removed you. Everything on the phone stays and works
offline. See [projects, members and roles](../projects-members-and-roles/).

### Project deleted

{{< shot "sync-project-deleted" "Sync Status for a project the server has deleted. The heading is gray with an exclamation mark in a circle, and the sentence under it says the records on this device are kept and Projects is where to export them." >}}

Gray, {{< app "Project deleted" >}}: an owner
[deleted it from the server](../projects-members-and-roles/#deleting-a-project).
{{< app "This project was deleted from the server by a project owner, so nothing from this device will reach it again." >}}
Your records stay. Keep them with {{< app "Export records" >}} on the project's
row under {{< app "Projects" >}}, or {{< app "Data Export / Backup" >}}, then
delete the project from the phone. A phone that was offline at the time finds
out on its next sync, however long it was away.

### Offline too long to sync

Red, {{< app "Offline too long to sync" >}}: a phone that has not synced a
project for over two years is refused, because syncing could bring back records
deleted meanwhile. Nothing on the phone changes; export a copy.
{{< app "There is no step in this app that fixes this — tell TriTrack support (More → App Info)." >}}
Rejoining does not help. Before a long gap, ask [support](../../support/) about
this.

### Server doesn't offer this

Red, {{< app "Server doesn't offer this" >}}: the server answered, but not to
this request. It is either older than the app, or a proxy in front of it
answered instead; the app cannot tell which.
{{< app "Tell TriTrack support (More → App Info)." >}} Nothing on the phone is
changed.

### The server's records were replaced

Not an error. A sentence starting with a date says the server was restored from
a backup or rebuilt, so the phone is syncing the project over from the
beginning: it fetches everything and sends back what the server lacks. Nothing
on the phone was deleted. Expect a long fetch and a jump in records waiting.

### Other states

- _Amber, access refused_: an owner removed you, or this phone is signed in to
  an account that was never on the project (a shared phone). The app cannot
  tell which. If you expected to be on it, ask an owner; if it is not yours,
  open one of your own projects.
- _Amber, {{< app "Signed out" >}}_: tap it and sign in again. Records keep
  collecting meanwhile.
- _Red, {{< app "Sync isn't working" >}}_: repeated failures with no specific
  cause. If it persists, contact [TriTrack support](../../support/).

## What a name may contain

Your first and last name go on every record and to your teammates' phones. A
name may contain only:

- letters and their accents, in any writing system (`Đặng Thị`, `Fernández`)
- digits (`Bill Gates 3rd`)
- hyphens and dashes, spaces (including the wide Japanese space), apostrophes
  straight or curly (`O'Brien`)
- full stops and commas (`J. R. Smith`, `Smith, Jr.`), and the middle dot
  (`ジョン・スミス`)

Anything else is refused, including at-signs, brackets, slashes and emoji, so
`Dana Reyes (PhD)` will not save. Those characters can make a name pass for an
email address on someone else's screen.

The setup screen and your profile check as you type. A character you can see
is quoted back to you: delete it. An invisible one (usually from a paste) is
named by its code point, with
{{< app "Delete the whole field and type it again" >}}.

A name refused after it was saved is held at sync, not lost; correct it on your
profile and it goes. A teammate whose name is refused is missing from your
phone until they fix it; their bearings are unaffected.

## Back up what has not synced

Unsynced records exist only on that phone. Before a week without coverage, take a
backup file off it: see [getting your data out](../getting-your-data-out/).

There are no notifications. The mark on the {{< app "More" >}} tab is the only
sign, and you see it when you open the app.
