/// Task 11.139 — looking at a screen the way somebody with larger text sees
/// it, and telling the two ways it can fail apart.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The system text sizes an iPhone can actually be set to, as multipliers of
/// the default body size (17pt).
///
/// **A ladder rather than a sweep.** A floor of "1.27" is not a fact about
/// anybody's phone — no iOS device can be set there. These are the twelve
/// stops Settings offers: the seven Dynamic Type sizes on the ordinary
/// slider, then the five Larger Accessibility Sizes that appear once
/// *Larger Accessibility Sizes* is switched on. Reporting a floor as one of
/// these says how many notches of headroom a screen has, which is the thing
/// somebody can act on.
///
/// Derived from iOS's body point sizes over the 17pt default: 14, 15, 16,
/// **17**, 19, 21, 23, then 28, 33, 40, 47, 53.
const iosTextScales = <double>[
  14 / 17, // xSmall
  15 / 17, // Small
  16 / 17, // Medium
  1.0, // Large — the default, and the only size ever rendered before 11.139
  19 / 17, // xLarge — one notch up
  21 / 17, // xxLarge
  23 / 17, // xxxLarge
  28 / 17, // AX1
  33 / 17, // AX2
  40 / 17, // AX3
  47 / 17, // AX4
  53 / 17, // AX5
];

/// The scales at or above the default — the ones a person turning text *up*
/// passes through, which is the direction this task is about.
final iosTextScalesUpward =
    iosTextScales.where((s) => s >= 1.0).toList(growable: false);

/// **The ordinary Dynamic Type slider's ceiling — task 11.257.**
///
/// This is `xxxLarge`, the last stop on Settings' plain text-size slider.
/// Everything past it (AX1-AX5) lives behind a second switch,
/// *Larger Accessibility Sizes*, which the app mentions nowhere. **This is a
/// product line, not a baseline**: it is not "the size the app happens to
/// pass at today" — it is the largest size a person reaches without opting
/// into a setting nobody has told them exists. A clip at or below this scale
/// is live for anybody who has ever moved that slider; a clip above it needs
/// a switch nobody has flipped.
final dynamicTypeSliderCeiling = iosTextScales[6];

/// One notch above the default. **If a panel's floor is this, it is not a
/// hypothetical**: it is the first thing that happens to somebody who nudges
/// the slider once.
final oneNotchUp = 19 / 17;

/// A human name for a scale, so a failure message says "xxLarge" rather than
/// "1.2352941176470589".
String textScaleName(double scale) {
  const names = [
    'xSmall', 'Small', 'Medium', 'Large (default)', 'xLarge', 'xxLarge',
    'xxxLarge', 'AX1', 'AX2', 'AX3', 'AX4', 'AX5', //
  ];
  for (var i = 0; i < iosTextScales.length; i++) {
    if ((iosTextScales[i] - scale).abs() < 0.001) {
      return '${names[i]} (${scale.toStringAsFixed(2)}x)';
    }
  }
  return '${scale.toStringAsFixed(2)}x';
}

/// A piece of text the layout did not give enough room to, **without the
/// yellow-and-black stripe that would have told somebody.**
class ClippedText {
  const ClippedText({
    required this.text,
    required this.given,
    required this.needed,
    required this.overflow,
    required this.maxLines,
    this.cutsRunningText = false,
  });

  final String text;

  /// The box the text was laid out in.
  final Size given;

  /// The box the same text needs at the same width with nothing truncated.
  final Size needed;

  /// What the widget does with the part that does not fit.
  final TextOverflow overflow;
  final int? maxLines;

  /// **Whether the reader is given any sign that a word is missing.**
  /// `ellipsis` leaves a "…" and `fade` leaves a gradient; `clip` and
  /// `visible` leave nothing at all, which is the failure nobody reports
  /// because nobody can see it.
  bool get silent =>
      overflow != TextOverflow.ellipsis && overflow != TextOverflow.fade;

  /// **Whether the cut fell inside a sentence that had already wrapped** —
  /// task 11.332.
  ///
  /// An ellipsis says "something is missing", which is enough for a name and
  /// not enough for a sentence: the owner's deletion countdown lost
  /// "or cancel from ⋮", the words that say it can be stopped, to a "…" on
  /// the 6.1-inch phone, and the sweep passed because it failed only on
  /// [silent] cuts. **The line between the two, decided from the widgets:**
  ///
  /// - **A one-line label (allowed).** The widget says the text gets one
  ///   line — `maxLines: 1`, or `softWrap: false` — or, in a `Text` given
  ///   more lines, the hard line that was cut (the text between two `\n`,
  ///   since several screens join a sentence and a one-line description into
  ///   one `Text`) *starts on the last line shown*: it was given exactly one
  ///   line and cut at its end. A name, a frequency, a row key, a
  ///   description kept to one line under a banner: the full value is a tap
  ///   away, and cutting it is a layout choice somebody wrote down.
  /// - **Running text cut short (fails).** The cut hard line *started on an
  ///   earlier line*: it wrapped, so somebody gave it room to be read as a
  ///   sentence, and the room ran out before the sentence did. Whatever the
  ///   number of words lost, it is the end of a sentence, which is where the
  ///   instruction usually is.
  /// - **An ellipsis with no line limit (fails).** `ellipsis` with
  ///   `maxLines: null` cuts at the end of the first line, so the text gets
  ///   one line without anybody having said so. **That is what a form
  ///   field's error and helper text do by default** (`errorMaxLines` and
  ///   `helperMaxLines` are null unless set), and on 2026-10-10 the server
  ///   address field's refusal — three sentences — showed as one line ending
  ///   in "…". The three places in `lib/` that meant one line this way now
  ///   say `maxLines: 1`, so this rule reads intent from the widget rather
  ///   than guessing it from the words.
  ///
  /// Every place `lib/` truncates on purpose, and which side of this line
  /// each is on, is listed in `clipped_text_sweep_test.dart`.
  final bool cutsRunningText;

  /// What the sweep fails on: a cut with no sign at all, or a sentence that
  /// lost its end to an ellipsis.
  bool get fails => silent || cutsRunningText;

  /// How much of the text got room. 1.0 is all of it; 0.33 means two lines in
  /// three are gone. **A one-line label ellipsised at a comfortable width is
  /// ordinary design; the same label squeezed to a fifth of what it needs is
  /// not**, and this is the number that tells them apart.
  double get shown => needed.height <= 0 ? 1.0 : given.height / needed.height;

  @override
  String toString() =>
      '"${text.length > 50 ? '${text.substring(0, 47)}...' : text}" '
      '— ${(shown * 100).round()}% shown '
      '(${given.height.toStringAsFixed(0)} of '
      '${needed.height.toStringAsFixed(0)}px at '
      '${given.width.toStringAsFixed(0)}px wide, '
      '${overflow.name}${maxLines == null ? '' : ', maxLines $maxLines'}'
      '${cutsRunningText && !silent ? (maxLines == null ? ', cut to one line with no line limit set' : ', a sentence cut short') : ''})';
}

/// Every piece of text on screen that is **silently truncated** — ellipsised,
/// faded or cut off by a `maxLines` — as opposed to overflowing loudly.
///
/// **The two failures are not the same and this project has only ever been
/// able to see one of them.** A `RenderFlex` overflow paints the
/// yellow-and-black stripe and reports a framework error, so
/// `tester.takeException()` finds it. A `Text` with `maxLines: 1` inside a
/// box that is one pixel too short simply loses its second line: nothing
/// throws, nothing is striped, and **the person reading the phone has no way
/// to know a word is missing**, so they never report it. That is the worse
/// of the two and it is the one nothing in this suite looked for.
///
/// Measured by laying the same span out again with no line limit at the width
/// it was actually given. Anything that needs more height than it got is
/// text somebody cannot read.
///
/// ## Where this instrument stops — task 11.232
///
/// Task 11.232 was asked why this did not catch the Tag details dropdown
/// clipping its own label. **It did: the finding was this instrument's, the
/// first time a test ran it over that dialog** (task 11.229, 2026-09-12).
/// What it has are two limits, and both are worth knowing before trusting a
/// verdict from it.
///
/// **1. It measures only what a test pumps.** There is no derivation behind
/// it: a screen is inspected at a text scale only when somebody wrote a test
/// that pumps that screen at that scale and calls this. On 2026-09-12 that
/// is five test files — the Main Map, the Record screen, the Position screen,
/// the app shell, and the tag dialog — against 26 `Screen` classes and the
/// dialogs and sheets besides. The dropdown was found the day the dialog
/// joined that list, and every screen not on it is unmeasured, not clean.
/// **A sweep that pumps every routable screen at every scale would close
/// this; it is a task of its own, and it should rank before it guards.**
///
/// **2. Its numbers are in the test font, which is about 1.6× Roboto's
/// width.** So a clip found here is a clip on a phone *at some scale* — not
/// necessarily the scale it was found at, and sometimes at none a phone
/// offers. The dropdown was reported clipped at the default size; in Roboto
/// it fits until AX2 and clips from AX3. Task 11.229 wrote "live on every
/// device today" off the test-font number, which is the mistake `CLAUDE.md`'s
/// widget-test-font rule exists to stop. **Read a clip from this instrument
/// as "this text can be cut off", never as "it is cut off at this size."**
List<ClippedText> clippedTexts(WidgetTester tester) {
  final found = <ClippedText>[];
  void visit(RenderObject node) {
    if (node is RenderParagraph && node.hasSize) {
      final painter = TextPainter(
        text: node.text,
        textDirection: node.textDirection,
        textAlign: node.textAlign,
        textScaler: node.textScaler,
        // The whole question: how tall is this text when nothing truncates
        // it? So no maxLines and no overflow.
        maxLines: null,
      )..layout(maxWidth: node.size.width);
      if (painter.height > node.size.height + 0.5) {
        final plain = node.text.toPlainText();
        found.add(
          ClippedText(
            text: plain,
            given: node.size,
            needed: Size(painter.width, painter.height),
            overflow: node.overflow,
            maxLines: node.maxLines,
            cutsRunningText: _cutsRunningText(node, painter, plain),
          ),
        );
      }
      painter.dispose();
    }
    node.visitChildren(visit);
  }

  visit(tester.binding.rootElement!.renderObject!);
  return found;
}

/// [ClippedText.cutsRunningText] for [node]: the widget's own line limit
/// first, then, for a `Text` allowed several lines, whether the hard line
/// (text between two `\n`) that the cut falls in had already wrapped.
///
/// [painter] is the text laid out with no line limit at the width it was
/// given. The lines whose bottoms fit in [given] are the ones shown; the cut
/// is on the last of them. Its first character is found by asking the painter
/// for the position at that line's left edge (every string in this app is
/// left-to-right). If the character before it is a `\n`, or there is none,
/// the cut hard line began on that last line and was given one line: a label.
/// Otherwise it began higher up, wrapped, and lost its end: a sentence.
///
/// **A box a pixel or two shorter than its one line** (no whole line fits)
/// is read as that first line being the one shown. That is a one-line label
/// squeezed from above and below — the Record wheel's selected tag at
/// xxxLarge, 34 px for a 35 px line, was the case on 2026-10-10 — and whether
/// it fails is [ClippedText.silent]'s question, as it was before this rule.
bool _cutsRunningText(
  RenderParagraph node,
  TextPainter painter,
  String plain,
) {
  if (node.maxLines == 1 || !node.softWrap) return false;
  if (node.maxLines == null) {
    // Cut with no line limit: only an ellipsis or a fade does that at the
    // first line (a clip or `visible` is [ClippedText.silent] already).
    return node.overflow == TextOverflow.ellipsis ||
        node.overflow == TextOverflow.fade;
  }
  return _cutHardLineHadWrapped(painter, plain, node.size);
}

bool _cutHardLineHadWrapped(TextPainter painter, String plain, Size given) {
  final lines = painter.computeLineMetrics();
  if (lines.isEmpty) return false;
  final fit =
      lines.where((l) => l.baseline + l.descent <= given.height + 0.5).length;
  final shown = fit < 1 ? 1 : fit;
  final last = lines[shown - 1];
  final start = painter
      .getPositionForOffset(Offset(0, last.baseline - last.ascent + 1))
      .offset;
  if (start <= 0 || start > plain.length) return false;
  return plain[start - 1] != '\n';
}

/// Starts collecting the yellow-and-black stripe: every distinct layout
/// overflow reported while the returned list is alive, in the order they
/// first appeared.
///
/// **Collected rather than taken afterwards, and that is not a style
/// choice.** `tester.takeException()` returns one exception; a text scale
/// that stripes four rows of a panel at once makes the binding replace them
/// with a *"Multiple exceptions (4) were detected"* summary, which names none
/// of them — so the probe would have failed with a stack trace exactly at the
/// scales it exists to describe. Intercepting `FlutterError.onError` keeps
/// every message and every one of its widget locations.
///
/// Tile-load failures are dropped for the reason the budget tests already
/// drop them: under `flutter test` every tile fetch fails, and the noise
/// would bury the layout errors this is looking for. Everything else is
/// forwarded, so a real error in the screen under test still fails the test.
///
/// ## What an overflow *is*, decided by the act and never by the wording
///
/// **Task 11.232.** Until 2026-09-12 this handler decided "is this a layout
/// overflow?" by whether the error's text contained `overflowed by`. Then
/// task 11.229 wrote `expect(verdict.clean, isTrue, reason: '... $verdict')`,
/// and a verdict with a stripe in it renders as *"STRIPED: A RenderFlex
/// overflowed by 3.4 pixels…"*. When that `expect` failed, flutter_test
/// routed the `TestFailure` through `FlutterError.onError` — still this
/// handler, since teardown had not run — **whose text now contained the
/// magic words. It was swallowed as an overflow.** The binding then found no
/// pending exception, asserted inside its own uncaught-error path, and the
/// test's completer was never completed: **ten idle minutes to the timeout,
/// three times, and a plan entry calling the app "frozen".** The dialog had
/// laid out in 86 ms. Reproduced both ways on the same dialog at the same
/// scale — the only difference being whether the `reason` quoted the stripe.
///
/// So the classification reads what the error *is*: a `FlutterError` raised
/// by the rendering library, which is what `RenderFlex` reports through.
/// A `TestFailure` is never one of those, whatever its message says.
/// `test/support/text_scale_probe_test.dart` holds that open.
///
/// **And the timeout that made it ten minutes rather than thirty seconds:**
/// `testWidgets` passes the binding's own `defaultTestTimeout` (ten minutes)
/// to every test, and a test-level timeout overrides `flutter test
/// --timeout`. A ladder that goes past the size a screen is known clean at
/// should pass its own `timeout:` so a hang, if one ever comes back, reports
/// in a minute rather than ten.
List<String> collectLayoutOverflows() {
  final overflows = <String>[];
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception is NetworkImageLoadException) return;
    final exception = details.exception;
    final isLayoutOverflow = exception is FlutterError &&
        details.library == 'rendering library' &&
        exception.message.contains('overflowed by');
    if (isLayoutOverflow) {
      final text = details.exceptionAsString();
      final first = text.split('\n').first;
      // **Name the widget, not just the direction (task 11.147).** The
      // `context` on a layout overflow is the words "during layout" on every
      // one of them, so a failure said *"overflowed by 39 pixels on the
      // right"* and left the reader to guess which of a screenful of rows it
      // was — and this screen has a panel, a header, a map toolbar and a list
      // row that could each be the answer. The framework already knows: the
      // information collector carries the offending `RenderFlex` and the
      // widget that created it. **An instrument's last words must be a
      // finding, not a direction.**
      final lines = details.informationCollector
              ?.call()
              .map((n) => n.toStringDeep())
              .join('\n')
              .split('\n') ??
          const <String>[];
      // `creator:` is the chain of widgets that built the offending render
      // object — the only line here that names something a person can go and
      // open. `RenderFlex#5f220` names nothing.
      final creator = lines
          .firstWhere(
            (l) => l.contains('creator:'),
            orElse: () => lines.firstWhere(
              (l) => l.contains('RenderFlex#'),
              orElse: () => '',
            ),
          )
          .trim();
      final where = creator.isEmpty
          ? (details.context?.toString() ?? '')
          : (creator.length > 220 ? '${creator.substring(0, 217)}...' : creator);
      final line = where.isEmpty ? first : '$first  [$where]';
      if (!overflows.contains(line)) overflows.add(line);
      return;
    }
    original?.call(details);
  };
  addTearDown(() => FlutterError.onError = original);
  return overflows;
}

/// One screen's verdict at one text scale.
class TextScaleVerdict {
  const TextScaleVerdict({required this.stripes, required this.clipped});

  /// Layout overflows — the yellow-and-black stripe, which also reports a
  /// framework error.
  final List<String> stripes;

  /// Text the layout cut off **without** the stripe or an ellipsis.
  final List<ClippedText> clipped;

  bool get clean => stripes.isEmpty && clipped.isEmpty;

  @override
  String toString() {
    if (clean) return 'clean';
    return [
      if (stripes.isNotEmpty) 'STRIPED: ${stripes.join('; ')}',
      if (clipped.isNotEmpty) 'SILENTLY CLIPPED: ${clipped.join('; ')}',
      // The instrument's last words carry its own limit (task 11.232): a
      // number measured in the test font is a number in a font ~1.6× wider
      // than the phone's, and 11.229 reported one as a device defect.
      '(measured in the test font, ~1.6× Roboto: a clip or stripe here is one '
          'a phone can reach at some size, not necessarily this one)',
    ].join('  |  ');
  }
}

/// What the frame currently on screen looks like at whatever text scale it was
/// pumped at: the stripes it reported, and the text it cut off silently.
///
/// [overflows] is the list [collectLayoutOverflows] returned before pumping.
TextScaleVerdict textScaleVerdict(
  WidgetTester tester,
  List<String> overflows,
) =>
    TextScaleVerdict(
      stripes: List.of(overflows),
      clipped: clippedTexts(tester).where((c) => c.silent).toList(),
    );

/// The failure message for a panel that is clean at a scale it was recorded as
/// failing at, or failing at one it was recorded as clean at.
///
/// **The two directions have different messages on purpose.** A panel that
/// newly fails is a regression; a panel that stops failing is somebody's fix,
/// and the recorded floor has to move up rather than be left overstating the
/// damage.
String textScaleFloorReason({
  required String panel,
  required double scale,
  required double declaredCleanThrough,
  required TextScaleVerdict verdict,
}) {
  if (scale <= declaredCleanThrough) {
    return 'The $panel is recorded as clean up to and including '
        '${textScaleName(declaredCleanThrough)}, and at '
        '${textScaleName(scale)} it is not: $verdict\n'
        'A stripe is the yellow-and-black overflow pattern, which reads as a '
        'crash to somebody who has never seen one. A silent clip is worse: '
        'the words are simply not drawn and nobody can tell. Give the box '
        'that fails a MINIMUM height instead of a fixed one, and if it is '
        'inside a panel whose height is computed, compute that height at the '
        'ambient text scale too — see position_estimation_screen.dart, which '
        'is where task 11.139 did this.';
  }
  return 'Good news that still has to be recorded: the $panel is now clean at '
      '${textScaleName(scale)}, which is above its recorded floor of '
      '${textScaleName(declaredCleanThrough)}. Raise the recorded floor in '
      'this file. A floor left where it was overstates how bad the screen is, '
      'and the next person ranking screens by it ranks them wrong.';
}
