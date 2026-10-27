---
title: "Support"
description: "How to get help with TriTrack, what to put in a report, and the guide's pages for the commonest problems."
---

<!--
/w-35 (2026-10-10): made ready, because the app now sends people here (task 11.324):
App Info's "TriTrack support" section links to this page (app_info_screen.dart _supportUrl),
and every "tell TriTrack support (More → App Info)" sentence in the app leads to it. The
email is Michael's, from /w-38. Nothing here promises a response time; nothing in the code
or the plan sets one.
-->

The app sends you here from {{< app "More" >}} → {{< app "App Info" >}} →
{{< app "Contact TriTrack support" >}}, and whenever it says
{{< app "tell TriTrack support (More → App Info)" >}}.

## Getting in touch

For a problem with the app or the server, a question about it, or help with a
project, write to TriTrack support at
[michael.shafer@nau.edu](mailto:michael.shafer@nau.edu).

_Please include:_

- the version from {{< app "App Info" >}} (below),
- the phone model and its operating system,
- the sentence the app showed, word for word, if it showed one (Sync Status
  usually has it),
- what you were doing, what you expected, and what happened instead (a
  screenshot helps).

## Which version are you on?

Open {{< app "More" >}} → {{< app "App Info" >}}. The first line is the version
and build number; long-press it to copy it into your report.

{{< shot "app-info" "App Info. The version at the top is what a report needs; below it are the map providers and their licenses." >}}

{{< shot "app-info-support" "The bottom of App Info: the link to the guide, and Contact TriTrack support, which opens this page." >}}

_Please include it._ Several builds are in use at once, and a report that cannot
be tied to one gets read against the wrong one. The number is read from the
installed build. If the screen says it could not read the version, say how and
roughly when you installed the app instead.

## Before you write: the guide's answers

- _Sync shows amber, red or gray_: [when something goes wrong](../docs/sync/#when-something-goes-wrong)
  explains each state and what to do.
- _A record is held, or will not sync_: [some records not synced](../docs/sync/#some-records-not-synced),
  and [what a name may contain](../docs/sync/#what-a-name-may-contain).
- _Asked to join and nothing happened_: [when asking to join does not work](../docs/joining-a-project/#when-asking-to-join-does-not-work).
- _A project disappeared_: [the Trash](../docs/projects-members-and-roles/#the-trash),
  and [project deleted](../docs/sync/#project-deleted).
- _The map is blank or tiles stop arriving_: [when map tiles stop arriving](../docs/comparing-bearings-on-the-map/#when-map-tiles-stop-arriving).
- _An estimate carries a caution_: [the cautions](../docs/estimating-a-position/#the-cautions).

## This website

TriTrack is developed in the Dynamic and Active Systems Lab at Northern Arizona
University. For a problem with this website, or a map tile provider's query about
the requests the app makes, the site is published from
[github.com/dynamic-and-active-systems-lab/tritrack-site](https://github.com/dynamic-and-active-systems-lab/tritrack-site);
open an issue there. (The app gives map tile services this site's address so they
can reach a person.)
