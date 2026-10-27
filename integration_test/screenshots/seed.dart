// The invented field data every screenshot is taken over.
//
// **Nothing in this file is real.** Not the people, not the animals, not the
// collars, and not the place. These images are published on a public website,
// and a published screenshot of a real collar location is a disclosure of
// where an animal is, not a picture of an app.
//
// The rules this file is written to:
//
//  * **No real study, animal or collar.** The tags, frequencies and pulse
//    rates below are made up. They are plausible VHF wildlife-telemetry
//    values so the screenshots look like the app in use, and they correspond
//    to nothing.
//  * **No location Michael works at.** The study area is in the Owyhee
//    uplands of south-eastern Oregon, chosen because it is remote public land
//    with no connection to this project, this lab, or anybody's field site.
//    It is deliberately nowhere near Flagstaff — `test/data/fixtures.dart`
//    puts its sample data there, which is fine for a test and would not be
//    fine on a web page.
//  * **No real people.** Invented names at `example.org`, which is a reserved
//    documentation domain and can never belong to anybody. `/w-05` made this
//    the sharpest rule in the file: the join screens put an **email address**
//    on screen — it is what the owner approves somebody on — so a careless
//    fixture here would publish a real person's address, not merely a name.
//
// Everything is at a fixed timestamp so that two regenerations of the same
// commit produce the same pixels; see `README.md` on why that matters.
//
// **`/w-09`: the fixture has to be at least as demanding as reality.**
// Michael overflowed a real screen the harness had already photographed and
// found clean, and the reason was this file — every invented name and note
// below used to be shorter and tidier than a field biologist's actual data,
// which is exactly the shape of value a screen never gets exercised against
// until somebody's thumb finds it. So this file now deliberately spans a
// range rather than picking one comfortable size: **most of everything below
// is still a short, ordinary example** — a two-, three-letter collar name, a
// one-line note — because the pictures still have to look like the app
// somebody actually uses, and a guide illustrated entirely with edge cases
// teaches the wrong expectations. But **at least one of each kind of thing —
// a tag name, a person's name, a project name, a note — is a realistic
// worst case, not a tidy one**, deliberately past any threshold this project
// has already measured (see `seedTagBadger` below), so a screen that only
// just fits a short label has somewhere to fail. Anybody adding a field to
// this file should ask the same question: what is its longest plausible
// value, not its most convenient one? And whoever finds a screen that can't
// hold that value files it as a finding — this fixture's job is to expose
// that, not to hide it by staying comfortable.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tritrack/data/models/actual_tag_location.dart';
import 'package:tritrack/data/models/deployment.dart';
import 'package:tritrack/data/models/estimated_position.dart';
import 'package:tritrack/data/models/individual.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/models/tag_library_entry.dart';
import 'package:tritrack/data/models/triangulation_session.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/data/sharing/tritrack_copy.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// The invented study area: Owyhee uplands, south-eastern Oregon.
///
/// Public land, no field site, no collar. Map screens are pointed here and the
/// simulator's own location is set to the same spot, so the blue dot and the
/// data agree.
const double seedLat = 42.7008;
const double seedLon = -117.3612;

/// Fixed so the images are reproducible. A screenshot harness whose output
/// changes because the clock moved cannot tell you whether the *app* changed,
/// which is the only question it exists to answer.
final DateTime seedUtc = DateTime.utc(2026, 2, 11, 17, 20, 0);
final DateTime seedLocal = DateTime(2026, 2, 11, 9, 20, 0);
const String seedOffset = '-08:00';

const String ownerUserId = 'seed-user-owner';
const String memberUserId = 'seed-user-member';

/// A third invented person, on the project as a **viewer**.
///
/// Added by `/w-05` so the members screen shows all three roles at once. Two
/// members demonstrated that there *is* a role column; three demonstrate the
/// gradient the guide has to explain — owner, contributor, viewer — without
/// the reader having to take the middle of it on trust.
const String viewerUserId = 'seed-user-viewer';
const String seedProjectId = 'seed-project-owyhee';
const String seedDeviceId = 'seed-device-A';

SyncMeta _sync({String by = ownerUserId}) => SyncMeta.initial(
      now: seedUtc,
      modifiedBy: by,
      originDeviceId: seedDeviceId,
    );

/// The person holding the phone in every screenshot.
User seedOwner() => User(
      userId: ownerUserId,
      firstName: 'Robin',
      lastName: 'Alvarez',
      email: 'robin.alvarez@example.org',
      sync: _sync(),
    );

/// A second, invented member, so the members screen and the team log have
/// somebody other than the phone's owner on them.
User seedMember() => User(
      userId: memberUserId,
      firstName: 'Jules',
      lastName: 'Okafor',
      email: 'jules.okafor@example.org',
      sync: _sync(),
    );

/// The third member: read-only. Invented, at the reserved documentation
/// domain, like everybody else in this file.
///
/// **The realistic-worst-case name (`/w-09`).** A hyphenated double surname
/// is an ordinary thing for a real person to have, and it is meaningfully
/// longer than `seedOwner`'s and `seedMember`'s — any members list, role
/// chip or "found by" line that only fits "Dana Whitcomb" is a screen this
/// fixture would previously never have exercised.
User seedViewer() => User(
      userId: viewerUserId,
      firstName: 'Bartholomew',
      lastName: 'Okonkwo-Whitfield',
      email: 'bartholomew.okonkwo-whitfield@example.org',
      sync: _sync(),
    );

/// **The project name and notes are the realistic-worst-case example for
/// this file (`/w-09`).** There is only one project, so it is the field that
/// carries the long end of the range: a full study title the way a permit
/// or grant application actually states one, and a two-line notes field the
/// way somebody actually writes a crew instruction rather than a one-clause
/// summary.
Project seedProject() => Project(
      projectId: seedProjectId,
      projectName:
          'Owyhee Uplands Kit Fox Denning & Dispersal Survey — North Unit, '
          'Winter/Spring 2026',
      description: 'Denning survey, north unit',
      notes: 'Vulpes macrotis. Ground tracking from the rim road; rotating '
          'two-person crews cover the north unit at dawn and dusk.\n'
          'BLM grazing allotment boundary runs along the eastern edge — stay '
          'inside the permitted access corridor.',
      ownerUserId: ownerUserId,
      creationDate: DateTime.utc(2026, 1, 6, 16, 0, 0),
      bboxMinLat: seedLat - 0.06,
      bboxMinLon: seedLon - 0.08,
      bboxMaxLat: seedLat + 0.06,
      bboxMaxLon: seedLon + 0.08,
      sync: _sync(),
    );

List<ProjectMembership> seedMemberships() => [
      ProjectMembership(
        membershipId: 'seed-membership-owner',
        projectId: seedProjectId,
        userId: ownerUserId,
        joinDate: DateTime.utc(2026, 1, 6, 16, 0, 0),
        role: ProjectRole.owner,
        sync: _sync(),
      ),
      ProjectMembership(
        membershipId: 'seed-membership-member',
        projectId: seedProjectId,
        userId: memberUserId,
        joinDate: DateTime.utc(2026, 1, 19, 15, 30, 0),
        role: ProjectRole.contributor,
        sync: _sync(),
      ),
      ProjectMembership(
        membershipId: 'seed-membership-viewer',
        projectId: seedProjectId,
        userId: viewerUserId,
        joinDate: DateTime.utc(2026, 2, 2, 17, 45, 0),
        role: ProjectRole.viewer,
        sync: _sync(),
      ),
    ];

/// Three collars, invented. Frequencies sit in a VHF telemetry band and pulse
/// rates in a normal range, so the numbers read as field data rather than as
/// placeholder text — but no transmitter has ever carried them.
List<Tag> seedTags() => [
      Tag(
        tagId: 'seed-tag-sage',
        projectId: seedProjectId,
        lineageId: 'seed-tag-sage',
        frequencyMhz: 150.284,
        pulseRate: 42,
        pulsePattern: 'steady',
        tagName: 'Sage',
        status: TagStatus.active,
        notes: 'Adult female, collar 41',
        colorHex: TagColorPalette.colorForIndex(0),
        sync: _sync(),
      ),
      Tag(
        tagId: 'seed-tag-juniper',
        projectId: seedProjectId,
        lineageId: 'seed-tag-juniper',
        frequencyMhz: 150.412,
        pulseRate: 38,
        pulsePattern: 'steady',
        tagName: 'Juniper',
        status: TagStatus.active,
        notes: 'Adult male, collar 44',
        colorHex: TagColorPalette.colorForIndex(2),
        sync: _sync(),
      ),
      Tag(
        tagId: 'seed-tag-wren',
        projectId: seedProjectId,
        lineageId: 'seed-tag-wren',
        frequencyMhz: 151.106,
        pulseRate: 55,
        pulsePattern: 'steady',
        tagName: 'Wren',
        status: TagStatus.active,
        notes: 'Juvenile, collar 47',
        colorHex: TagColorPalette.colorForIndex(5),
        sync: _sync(),
      ),
      seedTagBadger(),
      seedTagLost(),
    ];

/// **A tag with a status badge** (`/w-13`, item 5, from task 11.198).
///
/// Every other seeded tag is `TagStatus.active`, so the Tag Database row's
/// status badge and the padlock beside a non-owner's read-only row had never
/// appeared in any published picture — task 11.198 fixed both icons' colour
/// by measurement, unable to look at either. Only `Tag.status` is
/// non-active — the one `tagStatusBadge` in `widgets/tag_form.dart` reads.
/// (It used to say `ProjectTagStatus.active` was kept on the link so this
/// still counted as an on-project tag; task 11.219 retired the link, and the
/// tag is on the project because its `project_id` says so.) **Deliberately not
/// `seedTagBadger`**: that tag exists to appear in every dropdown and
/// legend, and `app_context_provider.dart` filters dropdowns to
/// `TagStatus.active` tags only, so giving it a non-active status would have
/// pulled it out of every one of those pictures rather than adding a new
/// one.
Tag seedTagLost() => Tag(
      tagId: 'seed-tag-lost',
      projectId: seedProjectId,
      lineageId: 'seed-tag-lost',
      frequencyMhz: 150.750,
      pulseRate: 50,
      pulsePattern: 'steady',
      tagName: 'Ridgeline',
      status: TagStatus.lost,
      notes: 'Collar signal lost on 2026-02-01; last fix near the ridge road.',
      colorHex: TagColorPalette.colorForIndex(3),
      sync: _sync(),
    );

/// **The realistic-worst-case tag (`/w-09`).** `Sage`, `Juniper` and `Wren`
/// above are ordinary field nicknames — short, and the shape every tag name
/// used to be in this file. A collar that has been recaptured and
/// re-deployed often carries a longer working label in real field notes, so
/// this one does: a full station/status description rather than a nickname,
/// and a two-line note. It exists to be seen everywhere a tag name is shown
/// — the tag database list, the record and position dropdowns, the map
/// legend, the truth-point panel header — since none of those were ever
/// exercised against a name this long before Michael found the truth-point
/// row overflow that this task exists to answer. See `README.md`/this file's
/// header comment: the overflow itself turned out to be driven by device
/// width, not by this, but the fixture stays hostile regardless.
Tag seedTagBadger() => Tag(
      tagId: 'seed-tag-badger',
      projectId: seedProjectId,
      lineageId: 'seed-tag-badger',
      frequencyMhz: 150.900,
      pulseRate: 46,
      pulsePattern: 'steady',
      tagName: 'Badger Ridge Adult Male — Recollared 2026-02 (was Collar 12)',
      status: TagStatus.active,
      notes: 'Recaptured after previous collar\'s VHF failed; new frequency '
          'assigned.\nEar tag intact, slight limp on right hind observed at '
          'capture — monitor.',
      colorHex: TagColorPalette.colorForIndex(1),
      sync: _sync(),
    );

/// **`seedProjectTags` is gone (task 11.219).** A tag belonged to a project
/// through a `Project_Tags` link; it belongs to one directly now, so
/// [seedTags] carries `projectId` and there is no second list to keep in
/// step with it.
///
/// The device's personal tag library is seeded from the same three collars —
/// see [seedTagLibrary] — because that is what a real device looks like: a
/// tag created into a project records the collar in the person's library
/// too.
/// **The animals, and the dated links that put the collars on them** — task
/// 11.243.
///
/// Until schema v17 these did not exist in this file and did not need to:
/// `TagRepository.insert` created one animal per collar, named after the
/// collar. A tag is a piece of equipment now and creates nothing, so the
/// screenshots need the animals written down — and the result is the same
/// picture, because the names and colours are the ones the old automatic
/// backfill would have produced.
///
/// **The attached dates are the `date_put_on` values these tags carried**
/// before the column left, so the collar history in the shots is unchanged.
DateTime seedAttachedDate(String tagId) => switch (tagId) {
      'seed-tag-sage' => DateTime.utc(2026, 1, 8, 18, 0, 0),
      'seed-tag-juniper' => DateTime.utc(2026, 1, 9, 17, 40, 0),
      'seed-tag-wren' => DateTime.utc(2026, 1, 22, 19, 5, 0),
      'seed-tag-lost' => DateTime.utc(2026, 1, 15, 18, 0, 0),
      'seed-tag-badger' => DateTime.utc(2026, 2, 3, 17, 30, 0),
      // An exhaustive switch would be better and Dart cannot give one over
      // strings. A tag added to this file without a date here would silently
      // get the fallback, so the fallback is a date nobody would mistake for
      // a real one.
      _ => DateTime.utc(2026, 1, 1, 12, 0, 0),
    };

List<Individual> seedIndividuals() => [
      for (final tag in seedTags())
        Individual(
          individualId: 'seed-animal-${tag.tagId}',
          projectId: seedProjectId,
          name: tag.tagName,
          colorHex: tag.colorHex,
          status: tag.status == TagStatus.active
              ? IndividualStatus.alive
              : IndividualStatus.unknown,
          lineageId: 'seed-animal-${tag.tagId}',
          sync: _sync(),
        ),
    ];

List<Deployment> seedDeployments() => [
      for (final tag in seedTags())
        Deployment(
          deploymentId: 'seed-deployment-${tag.tagId}',
          projectId: seedProjectId,
          tagId: tag.tagId,
          individualId: 'seed-animal-${tag.tagId}',
          attachedDate: seedAttachedDate(tag.tagId),
          sync: _sync(),
        ),
    ];

List<TagLibraryEntry> seedTagLibrary() => [
      for (final tag in seedTags())
        TagLibraryEntry.of(tag, tagId: 'library-${tag.tagId}'),
    ];

TriangulationSession seedSession() => TriangulationSession(
      sessionId: 'seed-session-morning',
      projectId: seedProjectId,
      tagId: 'seed-tag-sage',
      label: 'Sage — rim road, morning',
      startedAtLocal: seedLocal,
      startedAtUtc: seedUtc,
      startedAtOffset: seedOffset,
      notes: 'Three stations along the rim.',
      sync: _sync(),
    );

/// Eight bearings and one omnidirectional detection: five bearings on Sage
/// from stations spread along a road, three scattered records on the other two
/// collars so the log and the map are not a single cluster, and one record on
/// Juniper that never got a bearing at all (`/w-10`, and see the comment
/// beside it — it is what makes the supersede picker's record-type label
/// photographable).
///
/// **Five, because five is what a session looks like** (`/w-11`). `/w-09`
/// seeded eight in order to stop this fixture being kinder to the app than
/// reality is, and overshot: Michael's answer on 2026-09-03 is that a tracker
/// rarely takes more than five bearings to one tag. The first three still give
/// the position estimate below a sensible geometry, and five spanning 0–29
/// minutes is still past `seedProject`'s default 15-minute window, so the
/// count *and* the time-span caution are both live on the Position screen at
/// once — the state task 11.109 found that screen unable to survive.
///
/// **The distinction this file now has to keep, and it is not the same one
/// the header states.** The header's rule is about the *size of a value*: at
/// least one tag name, person's name and note here is a realistic worst case
/// rather than a tidy one, because a screen that only just fits a short label
/// has to have somewhere to fail. This rule is about the *shape of a session*,
/// and it points the other way: **these images are the guide's claim about
/// what the app looks like in use**, so the session they are taken over has to
/// be one somebody could actually have had. A test fixture is free to exceed
/// reality — that is often exactly its job — **but it has to say that it is
/// doing so**, and a fixture that is photographed for a public page cannot,
/// because a picture carries no footnote. Anything here that deliberately
/// exceeds a real session belongs in `test/`, not in the frame.
List<Observation> seedObservations(Map<String, String> tagVersionIds) {
  Observation bearing({
    required String id,
    required String tagId,
    required String userId,
    required String? sessionId,
    required double lat,
    required double lon,
    required double magnetic,
    required double declination,
    required int minutesAfter,
    required SignalStrength strength,
    required BearingQuality quality,
    String? notes,
  }) {
    final utc = seedUtc.add(Duration(minutes: minutesAfter));
    return Observation(
      observationId: id,
      projectId: seedProjectId,
      userId: userId,
      tagId: tagId,
      sessionId: sessionId,
      tagVersionId: tagVersionIds[tagId],
      timestampLocal: seedLocal.add(Duration(minutes: minutesAfter)),
      timestampUtc: utc,
      timezoneOffset: seedOffset,
      latitude: lat,
      longitude: lon,
      positionAccuracyM: 6.0,
      positionSource: PositionSource.gpsFix,
      elevation: 1310.0,
      observationType: ObservationType.directional,
      magneticBearing: magnetic,
      trueNorthBearing: magnetic + declination,
      bearingUncertainty: 10.0,
      bearingCaptureMethod: BearingCaptureMethod.singlePoint,
      bearingMethod: BearingMethod.peak,
      magneticDeclination: declination,
      wmmModelVersion: 'WMM2025',
      antennaType: 'yagi_3el',
      signalType: SignalType.regularPulse,
      signalStrength: strength,
      bearingQuality: quality,
      notes: notes,
      sync: _sync(by: userId),
    );
  }

  const declination = 14.6;
  return [
    bearing(
      id: 'seed-obs-1',
      tagId: 'seed-tag-sage',
      userId: ownerUserId,
      sessionId: 'seed-session-morning',
      lat: seedLat - 0.0090,
      lon: seedLon - 0.0130,
      magnetic: 48.0,
      declination: declination,
      minutesAfter: 0,
      strength: SignalStrength.medium,
      quality: BearingQuality.good,
      notes: 'Clear peak, no flutter.',
    ),
    bearing(
      id: 'seed-obs-2',
      tagId: 'seed-tag-sage',
      userId: ownerUserId,
      sessionId: 'seed-session-morning',
      lat: seedLat - 0.0105,
      lon: seedLon + 0.0060,
      magnetic: 331.0,
      declination: declination,
      minutesAfter: 11,
      strength: SignalStrength.strong,
      quality: BearingQuality.good,
    ),
    bearing(
      id: 'seed-obs-3',
      tagId: 'seed-tag-sage',
      userId: memberUserId,
      sessionId: 'seed-session-morning',
      lat: seedLat + 0.0075,
      lon: seedLon + 0.0090,
      magnetic: 244.0,
      declination: declination,
      minutesAfter: 19,
      strength: SignalStrength.medium,
      quality: BearingQuality.fair,
      notes: 'Wind on the antenna.',
    ),
    bearing(
      id: 'seed-obs-sage-4',
      tagId: 'seed-tag-sage',
      userId: ownerUserId,
      sessionId: 'seed-session-morning',
      lat: seedLat - 0.0060,
      lon: seedLon - 0.0170,
      magnetic: 62.0,
      declination: declination,
      minutesAfter: 24,
      strength: SignalStrength.medium,
      quality: BearingQuality.good,
    ),
    bearing(
      id: 'seed-obs-sage-5',
      tagId: 'seed-tag-sage',
      userId: memberUserId,
      sessionId: 'seed-session-morning',
      lat: seedLat - 0.0130,
      lon: seedLon + 0.0110,
      magnetic: 312.0,
      declination: declination,
      minutesAfter: 29,
      strength: SignalStrength.strong,
      quality: BearingQuality.good,
    ),
    bearing(
      id: 'seed-obs-4',
      tagId: 'seed-tag-juniper',
      userId: ownerUserId,
      sessionId: null,
      lat: seedLat + 0.0210,
      lon: seedLon - 0.0180,
      magnetic: 152.0,
      declination: declination,
      minutesAfter: 46,
      strength: SignalStrength.weak,
      quality: BearingQuality.fair,
    ),
    bearing(
      id: 'seed-obs-5',
      tagId: 'seed-tag-juniper',
      userId: memberUserId,
      sessionId: null,
      lat: seedLat + 0.0245,
      lon: seedLon - 0.0025,
      magnetic: 209.0,
      declination: declination,
      minutesAfter: 58,
      strength: SignalStrength.medium,
      quality: BearingQuality.good,
    ),
    // **One record that is not a bearing** (`/w-10`, for task 11.199).
    //
    // A tracker who can hear a collar but cannot get a clean bearing off it
    // records it as an omnidirectional detection: the animal was audible from
    // here, and that is all the record claims. It is an ordinary thing to
    // have in a morning's work, which is what `/w-11` requires of anything in
    // this fixture — the guide is photographed over a session somebody could
    // have had.
    //
    // **It is here because of what it makes photographable.** The Log
    // screen's supersede picker labels a candidate that has no bearing by its
    // *record type*, and that label was the stored `omnidirectional` until
    // task 11.199 made it `Omni`. Every observation this fixture held was
    // directional, so the picker could only ever have shown angles, and a
    // baseline of it would have covered the one line the task changed with
    // nothing at all. See `plainWordsShotNames` in `shots.dart`.
    //
    // **It draws nothing on either map**, checked rather than assumed: every
    // ray, wedge, origin dot and legend row in `map_screen.dart` is gated on
    // `trueNorthBearing != null`, and the Position screen filters to
    // `ObservationType.directional`. The Log listing is the one picture it is
    // expected to move.
    Observation(
      observationId: 'seed-obs-juniper-omni',
      projectId: seedProjectId,
      userId: ownerUserId,
      tagId: 'seed-tag-juniper',
      sessionId: null,
      tagVersionId: tagVersionIds['seed-tag-juniper'],
      timestampLocal: seedLocal.add(const Duration(minutes: 66)),
      timestampUtc: seedUtc.add(const Duration(minutes: 66)),
      timezoneOffset: seedOffset,
      latitude: seedLat + 0.0198,
      longitude: seedLon - 0.0090,
      positionAccuracyM: 6.0,
      positionSource: PositionSource.gpsFix,
      elevation: 1296.0,
      observationType: ObservationType.omnidirectional,
      antennaType: 'omni',
      signalType: SignalType.regularPulse,
      signalStrength: SignalStrength.weak,
      notes: 'Audible on the omni, too much bounce for a bearing.',
      sync: _sync(by: ownerUserId),
    ),
    bearing(
      id: 'seed-obs-6',
      tagId: 'seed-tag-wren',
      userId: ownerUserId,
      sessionId: null,
      lat: seedLat - 0.0260,
      lon: seedLon + 0.0210,
      magnetic: 17.0,
      declination: declination,
      minutesAfter: 92,
      strength: SignalStrength.veryStrong,
      quality: BearingQuality.good,
      notes: 'Very close — likely within 200 m.',
    ),
  ];
}

EstimatedPosition seedEstimate() => EstimatedPosition(
      positionId: 'seed-estimate-sage',
      projectId: seedProjectId,
      tagId: 'seed-tag-sage',
      timestampLocal: seedLocal.add(const Duration(minutes: 21)),
      timestampUtc: seedUtc.add(const Duration(minutes: 21)),
      timezoneOffset: seedOffset,
      latitude: seedLat - 0.0016,
      longitude: seedLon - 0.0021,
      semiMajorAxis: 145.0,
      semiMinorAxis: 78.0,
      rotationAngle: 51.0,
      method: EstimationMethod.lenthMle,
      observationIdsUsed: const ['seed-obs-1', 'seed-obs-2', 'seed-obs-3'],
      notes: 'Three stations, good spread.',
      sync: _sync(),
    );

/// One truth point, so the map has one. The guide does not document truth
/// points yet — `WEBSITE_PLAN.md` holds that back until task 11.92 lands — but
/// leaving the data out would make the map screenshot show a state the app no
/// longer produces for a project that has been worked.
ActualTagLocation seedTruthPoint(Map<String, String> tagVersionIds) =>
    ActualTagLocation(
      locationId: 'seed-truth-sage',
      projectId: seedProjectId,
      tagId: 'seed-tag-sage',
      timestampLocal: seedLocal.add(const Duration(minutes: 34)),
      timestampUtc: seedUtc.add(const Duration(minutes: 34)),
      timezoneOffset: seedOffset,
      latitude: seedLat - 0.0009,
      longitude: seedLon - 0.0014,
      uncertaintyRadius: 12.0,
      notes: 'Den entrance, visual.',
      foundKind: GroundTruthKind.animalAndCollar,
      tagVersionId: tagVersionIds['seed-tag-sage'],
      // Task 11.93. Left unset the screenshots would show a truth point
      // reading "not recorded" for both, which is the pre-v11 row rather than
      // the one this app writes — a seed must produce a database the app
      // itself would create.
      userId: memberUserId,
      positionSource: PositionSource.gpsFix,
      sync: _sync(),
    );

/// Writes the whole seed through the app's own repositories.
///
/// **Through the repositories, not raw SQL**, for the same reason the widget
/// tests do it that way: a seed written straight into the tables can produce a
/// database the app itself would never create, and then the screenshots
/// illustrate a state that cannot happen.
Future<void> seedDatabase(ProviderContainer container) async {
  final users = await container.read(userRepositoryProvider.future);
  final projects = await container.read(projectRepositoryProvider.future);
  final memberships =
      await container.read(projectMembershipRepositoryProvider.future);
  final tags = await container.read(tagRepositoryProvider.future);
  final individuals = await container.read(individualRepositoryProvider.future);
  final deployments = await container.read(deploymentRepositoryProvider.future);
  final library = await container.read(tagLibraryRepositoryProvider.future);
  final versions = await container.read(tagVersionRepositoryProvider.future);
  final sessions =
      await container.read(triangulationSessionRepositoryProvider.future);
  final observations =
      await container.read(observationRepositoryProvider.future);
  final estimates =
      await container.read(estimatedPositionRepositoryProvider.future);
  final truth =
      await container.read(actualTagLocationRepositoryProvider.future);

  await users.insert(seedOwner());
  await users.insert(seedMember());
  await users.insert(seedViewer());
  await projects.insert(seedProject());
  for (final membership in seedMemberships()) {
    // `replication` is the only authority that fits: these rows were not
    // granted by anybody on this device, they are fabricated data for a
    // picture. The door has to be named out loud, which is the point of it.
    await memberships.insert(
      membership,
      authority: const MembershipInsertAuthority.replication(
        'screenshot seed — invented data, no grant happened',
      ),
    );
  }
  // Task 11.243: the animals first — a deployment names one and the foreign
  // key wants the parent.
  for (final individual in seedIndividuals()) {
    await individuals.insert(individual);
  }
  for (final tag in seedTags()) {
    // `recordInLibrary: false` because the library is seeded explicitly
    // below with ids the harness controls — letting the repository mint
    // them would make the shots depend on a UUID.
    await tags.insert(tag, recordInLibrary: false);
  }
  for (final deployment in seedDeployments()) {
    await deployments.link(deployment);
  }
  for (final entry in seedTagLibrary()) {
    await library.insert(entry);
  }
  // `createInitialVersion` mints its own identifier, so the version ids are
  // collected here rather than hard-coded above: the records below have to
  // point at the rows that actually got written.
  final tagVersionIds = <String, String>{};
  for (final tag in seedTags()) {
    final version = await versions.createInitialVersion(
      tag,
      now: seedAttachedDate(tag.tagId),
      modifiedBy: ownerUserId,
      deviceId: seedDeviceId,
    );
    tagVersionIds[tag.tagId] = version.tagVersionId;
  }
  await sessions.insert(seedSession());
  for (final observation in seedObservations(tagVersionIds)) {
    await observations.insert(observation);
  }
  await estimates.insert(seedEstimate());
  await truth.insert(seedTruthPoint(tagVersionIds));
}

/// **A `TT1:` payload for the paste screen to parse** (`/w-10`).
///
/// Built by the app's own `buildTriTrackClipboardPayload` — the function the
/// Log screen's *Share observation…* and the map's selection card both call —
/// rather than by assembling JSON here. A payload written by the harness
/// would be the harness's idea of the format, and the picture of the preview
/// card would then illustrate a payload nothing in the app produces. This way
/// the shot is of the real round trip: what one device copies is what the
/// next one is shown.
///
/// **A colleague's record, not this device's own.** `seed-obs-5` is the
/// member's bearing on Juniper, so the card's `Observer:` line names somebody
/// other than the person holding the phone — which is the only situation in
/// which anybody ever opens this screen.
Future<String> sharedObservationPayload(ProviderContainer container) async {
  final observations =
      await container.read(observationRepositoryProvider.future);
  final tags = await container.read(tagRepositoryProvider.future);
  final users = await container.read(userRepositoryProvider.future);
  final versions = await container.read(tagVersionRepositoryProvider.future);

  final observation = await observations.findById(
    'seed-obs-5',
    projectId: seedProjectId,
  );
  if (observation == null) {
    throw StateError('seed-obs-5 is not in the seeded database, so there is '
        'nothing for the paste screen to be shown');
  }
  final tag = await tags.findById(
    observation.tagId!,
    projectId: observation.projectId,
  );
  final observer = await users.findById(observation.userId);
  if (tag == null || observer == null) {
    throw StateError('seed-obs-5 has no tag or no observer row, so the app\'s '
        'own share encoder cannot build a payload for it');
  }
  return buildTriTrackClipboardPayload(
    tagVersionRepo: versions,
    observation: observation,
    tag: tag,
    observer: observer,
  );
}
