---
title: "Your tags, and a project's tags"
description: "Your device's own list of transmitters, a project's own copy of each one, putting a tag on an animal, and pushing an edit out to your projects."
weight: 32
---

<!--
Strings read from the widgets (/w-33, 2026-10-01): tag_database_screen.dart (Tag Library:
search, headings, drag-onto-a-project dialog, import note, push dialog and result),
tags_screen.dart (More → Tags), animal_detail_screen.dart (Link a tag), quick_add_screen.dart,
widgets/tag_form.dart (the copy line and its (i)), widgets/tag_view_only_banner.dart.
/w-35 (2026-10-10): widgets/near_duplicate_tag_dialog.dart (task 11.324) and quick_add_screen.dart's
row that asks (task 11.339).
-->

A tag is one transmitter: its frequency, pulse modes and name. Which animal
wears it, and since when, is a separate dated record called a deployment, and
a bearing's animal comes from that record.

{{< diagram "tag-animal-deployment" "A tag is equipment. An individual is the animal. A deployment is the dated link between them, and it's what a bearing's animal actually comes from." >}}

{{< app "More" >}} has two lists with similar names:

- {{< app "Tag Library" >}}: every tag on this phone, on a project or not.
- {{< app "Tags" >}}: the tags on the project you have open.

## Your Tag Library

{{< shot "tags" "The Tag Library: this phone's tags, grouped under each project that uses them, with a search box for frequency or name." >}}

Tags are grouped under a heading for each project that uses them, plus
{{< app "Not on any project" >}}; tap a heading to open it. Type in
{{< app "Search by frequency or name" >}} to find one (part of a frequency
works). The + button adds a tag, and tapping a tag opens it to edit.

To put a library tag on a project, hold the handle at the left of its row and
drag it onto the project's heading, then tap {{< app "Add" >}}. The dialog
says {{< app "The project gets its own copy of the tag." >}} The project it
came from keeps its copy. You can also reorder the project headings by their
handle on the right.

The library belongs to this phone, so no project role limits it, and nothing
in it is sent to a server unless you push an edit to your projects (below).

{{< app "Bulk import CSV" >}} reads tags in from a spreadsheet, and
{{< app "Export tags CSV" >}} writes the library out. Check the file for tags
you already have before importing:
{{< app "These become new tags in your library. A row for a tag you already have makes a second, separate tag." >}}

## A project's tags

{{< app "More" >}} → {{< app "Tags" >}} lists the open project's tags. A tag
that is not active (recovered, lost, a suspected malfunction) shows that on its
row.

{{< shot "project-tags" "More → Tags: a project's own list. A tag that isn't active, here lost, carries that status on its row." >}}

{{< app "Copy from library" >}} adds a copy of a library tag to the project,
the same as dragging it in from the Tag Library.

_Who may do what._ Any contributor can copy a tag in. Changing, removing or
restoring a tag the project already has is for owners, because it changes what
the team's earlier bearings were taken against. A contributor sees
{{< app "You can copy tags into this project. Only a project owner can change one the project already has, or remove or restore it." >}}
A viewer sees {{< app "Viewers cannot change a project's tags — ask an owner to change your role." >}}
Anyone can still open a tag and read it; one you may not change opens under
{{< app "Only an owner can change this tag" >}}.

## Putting a tag on an animal

Open {{< app "More" >}} → {{< app "Animals" >}}, the animal, then
{{< app "Link a tag" >}}. Pick from {{< app "On this project" >}}, from
{{< app "From your Tag Library" >}} (copied into the project in the same step),
or {{< app "New tag…" >}}.

{{< shots >}}
{{< shot "link-tag-picker" "The picker for an animal with no tag. The one tag listed comes from the Tag Library; New tag… is below it." >}}
{{< shot "link-tag-confirm" "The confirmation. The Tag went on card shows today, with Change for another day, and the dialog says the project gets its own copy of the tag." >}}
{{< /shots >}}

The date is when the tag went on, and it decides which animal each bearing on
that tag belongs to. It starts as today; tap {{< app "Change" >}} if the tag
went on earlier. If moving the date changes the animal some bearings belong to,
the app counts them and asks before saving.

_Many animals at once._ {{< app "Quick add" >}} on the Animals screen takes the
date, species and pulse rates once under {{< app "Same for all" >}}, then one
row per animal: name and frequency. Type rows, paste them from a spreadsheet,
or import a CSV. {{< app "Review" >}} shows what each row will do (use a tag
the project has, copy one from the Tag Library, or make a new tag named by its
frequency), and nothing is saved until you confirm there.

{{< shots >}}
{{< shot "quick-add" "Quick add with three animals typed in. The date card at the top applies to every row." >}}
{{< shot "quick-add-review" "The review. Nothing is saved until Add 3 animals is tapped; the first row will use a tag from the Tag Library and the other two get new tags." >}}
{{< /shots >}}

## A Tag ID the project already has

Wherever you make a tag (More → Tags, a new tag while linking one, the Record
screen's wheel, a shared bearing), typing a Tag ID that is already on the open
project stops and asks, titled _Tag ID … is already on this project_.
{{< app "Use the existing tag" >}} is the main button, and it adds no second tag;
{{< app "Create anyway" >}} is for a genuinely different transmitter with the
same Tag ID; {{< app "Go back" >}} changes nothing. In {{< app "Quick add" >}}, a
row whose Tag ID and frequency both match a project tag simply uses it; one
whose Tag ID matches at a different frequency waits until you tap
{{< app "Choose" >}} and pick one of the two.

The check sees only what is on your phone. Two phones out of coverage can each
create the same Tag ID, and once both sync the project has two tags with it.
The app does not merge them yet, so agree before the season who adds the tags.

In the field, {{< app "＋  Add new tag" >}} on the
[Record screen's wheel](../recording-a-bearing/#pick-the-tag) makes a tag, an
animal and today's deployment in one go. Use it only for a tag that is not in
your library yet, or you will have two records of one transmitter.

## A copy is a copy

{{< diagram "tag-library-copy" "The library is one device-local list. Copying a tag into a project makes a separate row with its own history; editing one never reaches another, in either direction." >}}

_Editing the library does not change any project's copy, and editing a
project's copy changes only that project._ Each copy keeps its own history, so
two projects can describe one transmitter differently. A library tag that
projects use says so on its form, for example
{{< app "Changes here won't reach the 1 project using this tag" >}}, and a
project's copy shows {{< app "Copied in on" >}} with its date. The (i) beside
either line explains the copy.

_Pushing a fix to every copy._ After you save an edit to a library tag that
projects use, the app asks {{< app "Apply this to your projects?" >}} Accept,
answer once whether the edit corrects a mistake or records a real change, and
every copy is updated. Each copy keeps its own history. Projects where you are
not an owner are counted, not skipped silently:
{{< app "could not be changed — you are not an owner there." >}} Decline, and
nothing outside the library changes.
