---
title: "Joining a project"
description: "Getting onto a project someone else set up, and what an owner is asked before they let you in."
weight: 10
---

<!--
Strings read from the widgets (/w-33, 2026-10-01): server_config_screen.dart (sign-in, the
two sign-out buttons and their dialogs), project_members_screen.dart (joining, the approval
sheet), join_project_screen.dart, projects_screen.dart.
-->

Joining needs a connection, both to ask and for the answer to come back, so do
it before you lose cell or wifi coverage. Everything after that works offline.

## Sign in

Open {{< app "More" >}} → {{< app "Server Connection" >}} and enter the TriTrack
server's address if it is not already there ([TriTrack support](../../support/)
gives it). Tap {{< app "REQUEST A SIGN-IN CODE" >}} with your
email, then paste the code, or the whole link, into {{< app "Sign-in code" >}}.

_How the code reaches you depends on the server_, and the app cannot know. If
nothing arrives, ask [TriTrack support](../../support/).

If the server says it will not send to your address, check for a typo. If the
address is right, this server only sends to plain unaccented letters, digits and
ordinary punctuation; use another address or ask
[TriTrack support](../../support/).

Each phone signs in separately, with the same email.

_Signing out._ {{< app "SIGN OUT" >}} on the same screen signs this phone out;
it stops syncing and keeps everything it holds. If a phone is lost, use
{{< app "SIGN OUT EVERYWHERE" >}} from any of your devices: every device you
are signed in on stops syncing, including the one you are holding. A lost
phone keeps the data it already downloaded; that cannot be removed remotely.

## If you own the project: hand out the code

Open {{< app "Members" >}} (on the {{< app "More" >}} tab, or in the project's
row menu under {{< app "Projects" >}}). The project must be published first,
with {{< app "Publish to server" >}} in that row menu.

{{< shot "owner-members-and-code" "The Members screen, on the owner's device. Your own role first, then everyone currently on the project with theirs, then the switch that turns joining on and the code." >}}

Turn on {{< app "Let people join with a code" >}} and give your crew the code
any way you like. It does not expire and works for everyone.

- {{< app "New code" >}} replaces it, for example when somebody leaves the
  crew. Members stay; anyone still waiting has to ask again with the new code.
- {{< app "Team size limit" >}} caps the team. People waiting count toward it.

## If you are joining: ask with the code

Open {{< app "More" >}} → {{< app "Projects" >}} → {{< app "Join a project" >}}
(above the list, even when it is empty). Type the {{< app "Join code" >}},
check {{< app "Your name" >}}, and tap {{< app "Ask to join" >}}.

{{< shots >}}
{{< shot "joined-projects" "The projects list. Join a project is the row above the projects; it only appears once this device has a server address and you are signed in." >}}
{{< shot "join-code-entered" "The code typed in. Your name is filled in from your own profile and you can change it." >}}
{{< /shots >}}

The owner sees your sign-in email, which the server vouches for, and the name
you typed, labeled as what you said about yourself.

## Asking is not joining

{{< diagram "join-request" "Asking is a message to an owner, not a door that opens by itself. Your device only finds out once an owner has answered and it next checks in." >}}

{{< shot "join-waiting" "After you ask. Nothing has downloaded to this device yet, and the card under Your requests is where the answer will appear." >}}

The screen says {{< app "Waiting for approval" >}}, and the request stays under
{{< app "Your requests" >}} here and on the projects list, so you can leave.

## Approving someone

Each request is under {{< app "Waiting to join" >}} on {{< app "Members" >}},
with the address, name and date.

{{< shot "owner-pending-request" "Further down the same Members screen: who is waiting. The address is the heading because the server vouches for it; the name below it is labeled as something the person said about themselves." >}}

{{< app "Approve" >}} opens a sheet:

{{< shot "owner-approval-sheet" "The sheet an owner gets when they tap Approve. A role has to be chosen and the sentence about removal has to be ticked before the button turns on." >}}

- _The role_, starting at {{< app "Contributor — records their own" >}}; the
  others are {{< app "Viewer — read only" >}} and
  {{< app "Owner — also manages members" >}}. See
  [roles](../projects-members-and-roles/).
- _The removal sentence_, which you must tick: removing someone later stops
  their syncing but cannot delete what is already on their phone. Only let in
  people you trust with the locations they will carry away.

{{< app "Reject" >}} declines; they are told and can ask again.

## When the answer comes back

The project downloads by itself.

{{< shots >}}
{{< shot "join-downloading" "Approved, and downloading. On a big project over a poor connection this is the state you will actually sit and look at." >}}
{{< shot "join-arrived" "Done. The project is on the device and syncing, and it is in the projects list." >}}
{{< /shots >}}

The phone checks every 60 seconds while the app is open, and at once when you
bring it back to the front. A closed app checks nothing (there are no push
notifications), so open it. Pull down on the projects list to check now.

## When asking to join does not work

The card under {{< app "Your requests" >}} says what happened to your request:

- _The owner rejected it_:
  {{< app "The owner turned this down. You can ask again with the same code." >}}
- _The code changed_ while you waited: the card says so; ask for the new one.
- _Approved but nothing downloaded_: the card says whether it has partly
  arrived or not started. It finishes the next time the app is open with a
  connection; nothing needs re-asking.
- _Nothing happening_: open the app where there is cell or wifi coverage and
  pull down on the list. Most likely the owner has not looked yet.
