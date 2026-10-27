/// **How a bearing's quality, a signal's strength, a record's type and a
/// pre-v12 record's mode are shown — one owner for the words and the colours,
/// so two screens cannot say different things about the same stored value.**
///
/// **Task 11.199 widened this file from two vocabularies to four**, and the
/// reason is the guard beside it: `test/documentation/stored_value_display_test.dart`
/// requires every enum a person reads to have exactly one file that spells it.
/// A vocabulary with no owning file is how four screens ended up printing raw
/// database tokens with nobody noticing — see that test for the count.
///
/// Michael, 2026-09-07, about the Position screen's bearing list: *"The words
/// in the positions screen on the bearing quality (good, fair, bounce?) should
/// probably be updated with colors green, yellow, red."*
///
/// He was right, and half of it already existed: the **Record** screen's
/// bearing-quality roller had been showing `✓ Good` in green, `Fair` in amber
/// and `Bounce?` in red since it was written. The **Position** screen — the one
/// where somebody decides which bearings to count — was printing
/// `o.bearingQuality?.db`, the raw database token, in one flat grey. So a
/// person picked a green *✓ Good* while recording and met a grey `good` when it
/// mattered, and a bounced bearing read `suspected_bounce`, underscore and all.
///
/// **Why the words live here and not on the enum.** `BearingQuality` is in
/// `package:tritrack_sync`, which the server also depends on; display strings
/// and a Flutter `Color` do not belong in a package whose job is the wire
/// format. **Why they live in one file at all** is the rule this project keeps
/// relearning: when one file names a string another file implements, a rename
/// moves one of them. There were two copies of these three words; there is now
/// one, and the Record screen reads it too.
///
/// ## Colour is never the only thing carrying the meaning
///
/// A coloured dot with no word was considered and rejected. There is no legend
/// on the Position panel to teach one, and **green and red are exactly the pair
/// that collapses** for the roughly one man in twelve with a red-green colour
/// vision deficiency — so a dot alone would leave those readers with nothing.
/// The word is the answer and the colour is the accelerator. Anything added
/// here follows the same rule.
library;

import 'package:flutter/widgets.dart';

import 'package:tritrack_sync/tritrack_sync.dart';

import '../theme/app_theme.dart';

/// The word a bearing quality is shown as, on every screen.
///
/// **`✓ Good` keeps its tick.** It is the value a person is looking for when
/// scanning a list of bearings to count, and the tick is what makes it findable
/// without reading — the same job the colour does, for the same reason the
/// colour cannot do it alone.
String bearingQualityLabel(BearingQuality quality) => switch (quality) {
  BearingQuality.good => '✓ Good',
  BearingQuality.fair => 'Fair',
  BearingQuality.suspectedBounce => 'Bounce?',
};

/// The colour that word is drawn in: green, amber, red.
///
/// Taken from the theme rather than named here, so the three quality colours
/// are the same three the map draws with — `animalFix` is the green a confirmed
/// fix is plotted in and `bounceRed` is the red a suspect ray is.
Color bearingQualityColor(BearingQuality quality, TriTrackColors colors) =>
    switch (quality) {
      BearingQuality.good => colors.animalFix,
      BearingQuality.fair => colors.fairAmber,
      BearingQuality.suspectedBounce => colors.bounceRed,
    };

/// A signal strength in plain words, for a row with space for them.
///
/// **Not the same list as the Record screen's roller, and that is not drift.**
/// That roller is three columns across a phone and abbreviates to fit — `Med`
/// for medium, and (task 11.194) `V. strong` for the strongest — which is a
/// fact about a 120-pixel column rather than about the value. This is the
/// unabbreviated reading, for somewhere there is room to write it out.
///
/// **Task 11.193 left the two disagreeing about the strongest one** — this
/// said *very strong* and the roller said *Extreme* — **and task 11.194
/// resolved it**: the displayed word matches the stored word everywhere,
/// abbreviated only where space demands it, because this app's data is read
/// in a CSV where the column holds `very_strong`. "Extreme" on the phone and
/// `very_strong` in the exported data was a mapping nobody wrote down.
String signalStrengthLabel(SignalStrength strength) => switch (strength) {
  SignalStrength.faint => 'faint',
  SignalStrength.weak => 'weak',
  SignalStrength.medium => 'medium',
  SignalStrength.strong => 'strong',
  SignalStrength.veryStrong => 'very strong',
};

/// The word for task 11.193's "the signal itself sounded wrong" flag —
/// `Observation.signalIrregular`. **`signal_irregular` stays the column
/// name**; this is display wording only.
///
/// Michael, 2026-09-07, choosing between "Sounded irregular" and this: the
/// stronger word. It is defined once and read by every place the flag is
/// shown — the Record screen's checkbox (and, through the same `Text`, its
/// screen-reader label), the Position row's warning-triangle label, the
/// shared-observation paste screen's sentence, and (task 11.194) the Log
/// row's mark.
///
/// **"Malfunctioning" alone since 2026-09-12** (Michael, in task 11.67's
/// follow-up): the Record screen's checkbox now shares its line with the
/// *At altitude* checkbox, and "Irregular/Malfunctioning" was the width that
/// stopped the two fitting. Renamed here, so every screen changed together.
const String irregularSignalLabel = 'Malfunctioning';

/// The word for a record's type: **Bearing**, **Omni**, **Note**.
///
/// **Derived from [RecordType.label] rather than typed again**, because the
/// record-type picker is where a person meets these three words and the word
/// *Bearing* for a row stored as `directional` is a decision Michael made on
/// 2026-09-07 for that picker. A second spelling here would be the thing this
/// file exists to prevent, one screen apart.
///
/// [ObservationType] and [RecordType] are deliberately different types —
/// `RecordType` has two members that are not observations at all — so the
/// mapping is a `switch` rather than a lookup, and it is exhaustive on purpose:
/// a fourth observation type would not compile until somebody chose its word.
String observationTypeLabel(ObservationType type) => switch (type) {
  ObservationType.directional => RecordType.directional.label,
  ObservationType.omnidirectional => RecordType.omnidirectional.label,
  ObservationType.note => RecordType.note.label,
};

/// The word for the **legacy** `signal_type` column — and the name says
/// *legacy* because that is the whole content of the value.
///
/// **This does not describe a bearing this build wrote.** Since schema v12
/// (task 11.187) a bearing's mode is `Observations.pulse_mode`, a slot on the
/// tag, named by whoever entered the tag; `signal_type` is a two-valued
/// projection kept because the column is `NOT NULL` and dropping it would
/// strand every device in the field. It is lossy on a tag's third mode, which
/// projects to [SignalType.regularPulse].
///
/// **So there are exactly two honest uses**, and both are about a record whose
/// slot is unknown: a row written before v12, and a pasted replica, which drops
/// `pulse_mode` deliberately. Anywhere a slot *is* known, show the tag's own
/// mode name — never this. [pulseModeSlotOf] is the function that decides which
/// case a record is in.
///
/// **The words are [defaultPulseModeNames], read rather than retyped.** Michael,
/// 2026-09-07: records already stored as `regular_pulse` / `mortality_signal`
/// adopt the new default mode names, and the word *Regular* leaves the app. If
/// those defaults are ever renamed, these follow, which is the point.
///
/// **Prefer `TagVersionView.recordedPulseModeName` wherever a tag version is
/// in reach.** It answers the same question with everything the record knows —
/// the recorded name first, these defaults only when the slot is unknown, and
/// *"Mode 3"* rather than a guess when it is known and unnamed. This function
/// is the reduced case for a caller holding a `SignalType` and nothing else:
/// the paste screen reading a payload whose sender could not send a name. Both
/// read [defaultPulseModeNames], so neither can drift from the other.
String legacySignalTypeLabel(SignalType type) => switch (type) {
  SignalType.regularPulse => defaultPulseModeNames[0],
  SignalType.mortalitySignal => defaultPulseModeNames[1],
};
