---
title: "Privacy policy"
description: "Not yet written, except for two parts: how long the TriTrack server keeps things, and what your phone's own automatic backup does with your records."
---

_Most of this policy is not written yet._ It will say what TriTrack stores on
the device, what leaves it when a project syncs to a server, and who can read it.
Until then, treat nothing here except the two sections below as a commitment.
For an answer sooner, see [Support](../support/).

## How long the server keeps things

When a phone is signed in to the TriTrack server, its projects' records are copied
there for the team. These are the windows the server's code applies today:

- _Your project's records_ stay while the project exists. A project an owner
  moves to the Trash keeps its records on the server, hidden from every member,
  until the owner restores it or deletes it permanently.
- _A deleted project_: {{< app "Delete permanently…" >}} removes the project and
  every member's records from the server when its countdown ends, 30 days by
  default (see [deleting a project](../docs/projects-members-and-roles/#deleting-permanently)).
- _A deleted record_ (a bearing, a truth point): kept, marked as deleted, for 24
  months, so a phone that was in a drawer all winter still learns it was
  deleted. After that it can be removed for good.
- _Sign-ins_: a log of each sign-in attempt (the email, the device and the
  network address it came from) is kept for one year.
- _Syncs_: a log of each sync (which account and device, which project, how
  many records went each way) is kept for 180 days.
- _Join requests_: a request an owner has answered is kept for 30 days, so the
  phone that asked still learns the answer.

_Backups of the server._ The server software can keep a daily copy of its own
database, the last 30, on the same machine, so a deleted project is gone from
them 30 days later. A backup kept anywhere else, which would survive losing
the server itself, is planned but not in place yet.

## Your phone's own backup, and your records

_This part is written because it is the one thing you might need to act on now._

TriTrack's database is included in your phone's ordinary automatic backup, on
iPhone and Android, like any other app's files. That is deliberate: a phone
lost, drowned or stolen in the field is a likelier way to lose a season than a
broken-into cloud account, and the records at risk are the same either way
(those not yet synced to the TriTrack server). For nearly every project, the
backup is worth more than the small extra exposure, and there is nothing to do.

_What that exposure is._ Apple's documentation says the keys to an iCloud backup
are held in Apple's data centers, so Apple can read it and can be compelled to
produce it. Google does not clearly say whether an app's files get the extra
protection it offers photos and other media, so assume the same of a Google
Account backup. This is about the backup, not TriTrack: TriTrack sends your
records nowhere except that backup and the TriTrack server, once you sign in
to it.

_If your project cannot accept that_, for example a species whose location must
not leak, _each phone can turn backup off for TriTrack alone_, in the phone's
own settings, without affecting other apps. TriTrack has no setting of its own
for this, and will not: the phone's control already does it, and a second
switch invites a false sense of safety.

- _iPhone_: in Settings, under the iCloud or Apple Account backup settings, find
  the per-app list and switch TriTrack off. The wording and place change between
  iOS versions, so treat this as where to look, not exact steps.
- _Android_: Google began rolling out a per-app backup control, in the phone's
  backup settings, in June 2026. _It has not reached every phone_: it has been
  seen on a Pixel and not yet on a Samsung. If you cannot find a per-app list,
  your phone probably does not have it yet; you have not missed a step.

_What turning it off costs._ Anything recorded on that phone and not yet synced
then exists only on the phone, and is lost with it. Sync promptly, and before
time without coverage take a manual backup file off the phone, which helps
whichever way you decide here. See [sync](../docs/sync/) and
[getting your data out](../docs/getting-your-data-out/).

This page informs a decision your project makes about its own phones. For most
projects the right choice is to leave the phone's backup as it is.
