// The part a person cannot skip.
//
// A regenerated screenshot that silently overwrites its predecessor is not a
// check — it is the same defect one level over from a copy-drift check that
// nobody reads. So this tool never writes over a committed image on its own.
// It compares, it names every screen that moved, it writes a diff picture, and
// then it stops. `--accept` is the acknowledgement, and it is a separate
// command somebody has to type after looking.
//
// Exit codes are the contract, the same shape as `website/tools/`:
//
//   0  every screen matched, or `--accept` wrote the new ones
//   1  something changed, is new, or has disappeared, and nobody has said yes
//   2  the review could not run at all — **not a pass**
//
// Usage:
//   dart run integration_test/screenshots/review.dart <staging-dir> <profile>
//   dart run integration_test/screenshots/review.dart <staging-dir> <profile> --accept

import 'dart:io';
import 'dart:typed_data';

import 'png.dart';
import 'shots.dart';

/// Where the committed images live. Inside `website/` because that is what
/// serves them; there is exactly one copy of each image in the repository, so
/// there is nothing for a second copy to drift from.
const String committedRoot = 'website/static/screens';

/// **The tolerance, and what it costs.**
///
/// A pixel counts as moved when any of its three channels differs by more than
/// [channelTolerance]; a screen counts as changed when more than
/// [areaTolerance] of its pixels have moved.
///
/// Measured, not chosen. Two consecutive runs of the same commit on the same
/// machine left twelve of fourteen screens **pixel-identical**; the worst was
/// the pre-trip checklist at 0.0512%, because it prints how many map tiles are
/// cached and that depends on what the run happened to fetch. 0.12% sits about
/// twice above that.
///
/// **What it costs, and this is the real limit.** A word of body text at this
/// scale is roughly 150 x 40 pixels — about 0.16% of the screen. So a single
/// changed word is only just above the threshold, and a shorter one in a
/// smaller type size can slip under it. See `README.md`; the copy-drift check
/// in `website/tools/` is what covers that case, and neither is a guarantee on
/// its own.
const int channelTolerance = 12;
const double areaTolerance = 0.0012;

void main(List<String> args) {
  // `main` returning an int does NOT set a Dart process's exit code — the
  // first run of this tool exited 0 while printing that it had reviewed
  // nothing, which is precisely the "cannot tell success from its own
  // failure" shape the exit codes exist to prevent.
  //
  // **A file that goes away underneath this review is exit 2, and that is the
  // whole reason this `try` exists** (`/w-06`). On 2026-08-31 a second
  // regeneration emptied `build/screenshots/iphone-6.9` while this one was
  // between the driver writing its images and the review reading them. The
  // read threw `PathNotFoundException`, nothing caught it, the process exited
  // **255**, and `regenerate.sh` treated any non-2 exit as "a screen changed
  // and nobody has said yes."
  //
  // **So a run that could not read its own output reported as ordinary
  // drift** — which is worse than a crash, because a crash gets investigated
  // and drift gets accepted. Exit 2 already means *could not run, and this is
  // not a pass*; a review that cannot reach its own files has compared
  // nothing, so it belongs in the same code as an empty output directory.
  //
  // Caught here rather than around each read on purpose: the class is "the
  // filesystem refused", not "this one `readAsBytesSync`", and a later reader
  // or writer added to `_run` must not have to remember to wrap itself.
  try {
    exitCode = _run(args);
  } on PathNotFoundException catch (e) {
    stderr.writeln('${e.path} went away underneath this review: it was there '
        'when the run listed the directory and it is not there now. So this '
        'review has compared nothing, and that is exit 2 — a run that could '
        'not read its own output — not a screen that changed.');
    stderr.writeln('The cause on 2026-08-31 was a second regeneration '
        'emptying build/screenshots between the capture and the review. '
        'regenerate.sh now takes a lock to stop that, so check for a stale '
        'build/screenshots/.regenerate.lock before looking further.');
    exitCode = 2;
  } on FileSystemException catch (e) {
    stderr.writeln('The review could not reach ${e.path}: '
        '${e.osError ?? e.message}. A review that cannot read or write its '
        'own files has compared nothing, so this is exit 2 and not a screen '
        'that changed.');
    exitCode = 2;
  }
}

int _run(List<String> args) {
  final accept = args.contains('--accept');
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length != 2) {
    stderr.writeln('usage: review.dart <staging-dir> <profile> [--accept]');
    return 2;
  }
  final staging = Directory(positional[0]);
  final profile = positional[1];
  final committed = Directory('$committedRoot/$profile');

  if (!staging.existsSync()) {
    stderr.writeln('No staging directory at ${staging.path}. The capture run '
        'produced nothing, which is a failure and not an empty diff.');
    return 2;
  }

  final captured = _pngNames(staging);
  if (captured.isEmpty) {
    stderr.writeln('${staging.path} holds no screenshots. A review of nothing '
        'is not a green review.');
    return 2;
  }
  // **Did the run produce what it set out to?** Asked before anything is
  // compared, and answered from `shots.dart` — the same list the capture run
  // walks — rather than from what happens to be committed.
  //
  // This is the half the committed-image comparison cannot do. A screen that
  // stops being photographed is caught below as MISSING, because its old image
  // is still in the repository. **A brand-new state has no old image**, so on
  // the run that introduces it there is nothing for its absence to differ
  // from: a state that silently captured nothing would arrive as a complete,
  // green set. That is the shape exit 2 exists for — twice on this harness's
  // first day, `flutter drive` printed "All tests passed" over zero
  // screenshots — and it now covers every state, not only the ones with a
  // predecessor.
  final duplicate = duplicateShotName();
  if (duplicate != null) {
    stderr.writeln('Two shots are named "$duplicate" in shots.dart. The second '
        "would overwrite the first's image and this review would report one "
        'state where two were photographed. Rename one.');
    return 2;
  }
  final never = expectedScreenshotNames
      .where((name) => !captured.contains(name))
      .toList();
  if (never.isNotEmpty) {
    stderr.writeln('The run never photographed ${never.length} of '
        '${expectedScreenshotNames.length} states: ${never.join(', ')}. That is '
        'a run that did not happen, not a set with nothing to say about them.');
    return 2;
  }
  final unnamed = captured
      .where((name) => !expectedScreenshotNames.contains(name))
      .toList();
  if (unnamed.isNotEmpty) {
    stderr.writeln('The run produced ${unnamed.join(', ')}, which shots.dart '
        'does not name. The capture run and the manifest have drifted, so '
        'this review cannot say what a complete run looks like.');
    return 2;
  }

  final existing = committed.existsSync() ? _pngNames(committed) : <String>[];

  final unchanged = <String>[];
  final changed = <_Changed>[];
  // **Screens that moved and stayed under the threshold.** Printed, not
  // hidden: the comparison's verdict is a yes/no, but the number behind it is
  // the thing a person needs when the verdict is wrong. `/w-06` switched the
  // GPS fix on and the record screen's position line changed from *acquiring*
  // to a coordinate — 0.1069% of the screen against a 0.12% threshold, so the
  // comparison called it unchanged and said nothing. **That line is the most
  // guide-relevant text in the app**, and the sentence on the website
  // describing the old picture would have stayed there. The threshold cannot
  // be lowered to catch it (the pre-trip checklist genuinely varies by half of
  // it), so the instrument says what it found instead of only what it decided.
  final nearly = <_Changed>[];
  final added = <String>[];
  final removed = existing.where((n) => !captured.contains(n)).toList();
  // **Two names over one state.** The normalised bytes of each new image,
  // kept so the run can say when two shots came back identical — see
  // [_identicalGroups].
  final freshBytes = <String, Uint8List>{};

  for (final name in captured) {
    final Raster fresh;
    try {
      fresh = decodePng(
        Uint8List.fromList(File('${staging.path}/$name.png').readAsBytesSync()),
      );
    } on PngFormatException catch (e) {
      stderr.writeln('Could not read the new $name: $e');
      return 2;
    }
    // Normalising first means the committed file and the comparison see the
    // same bytes: the engine writes 16-bit RGBA, the repository holds 8-bit.
    final normalised = encodePng(fresh);
    File('${staging.path}/$name.png').writeAsBytesSync(normalised);
    freshBytes[name] = normalised;

    final committedFile = File('${committed.path}/$name.png');
    if (!committedFile.existsSync()) {
      added.add(name);
      continue;
    }
    final Raster old;
    try {
      old = decodePng(Uint8List.fromList(committedFile.readAsBytesSync()));
    } on PngFormatException catch (e) {
      stderr.writeln('Could not read the committed $name: $e');
      return 2;
    }
    if (old.width != fresh.width || old.height != fresh.height) {
      changed.add(_Changed(
        name,
        1.0,
        'size changed from ${old.width}x${old.height} to '
            '${fresh.width}x${fresh.height}',
      ));
      continue;
    }
    final result = _compare(old, fresh);
    if (result.movedFraction > areaTolerance) {
      File('${staging.path}/$name.diff.png')
          .writeAsBytesSync(encodePng(result.diff));
      changed.add(_Changed(
        name,
        result.movedFraction,
        '${_percent(result.movedFraction)} of pixels moved',
      ));
    } else {
      unchanged.add(name);
      if (result.movedFraction > 0) {
        nearly.add(_Changed(
          name,
          result.movedFraction,
          '${_percent(result.movedFraction)} of pixels moved, under the '
              '${_percent(areaTolerance)} threshold',
        ));
      }
    }
  }
  nearly.sort((a, b) => b.movedFraction.compareTo(a.movedFraction));

  stdout.writeln('Screenshot review — profile "$profile"');
  stdout.writeln('  ${captured.length} captured, '
      '${unchanged.length} unchanged, ${changed.length} changed, '
      '${added.length} new, ${removed.length} missing'
      '${nearly.isEmpty ? '' : '; ${nearly.length} moved but stayed under the '
          'threshold — see NEARLY below, and look at them'}');

  for (final c in changed) {
    stdout.writeln('  CHANGED  ${c.name}  (${c.detail})');
    stdout.writeln('           new:  ${staging.path}/${c.name}.png');
    stdout.writeln('           old:  ${committed.path}/${c.name}.png');
    stdout.writeln('           diff: ${staging.path}/${c.name}.diff.png');
  }
  for (final n in nearly) {
    stdout.writeln('  NEARLY   ${n.name}  (${n.detail})');
  }
  for (final group in _identicalGroups(freshBytes)) {
    stdout.writeln('  SAME     ${group.join(' = ')}  — these names photographed '
        'one state, not ${group.length}');
  }
  for (final name in added) {
    stdout.writeln('  NEW      $name  (${staging.path}/$name.png)');
  }
  for (final name in removed) {
    stdout.writeln('  MISSING  $name  — committed, but this run did not '
        'capture it');
  }

  if (changed.isEmpty && added.isEmpty && removed.isEmpty) {
    if (nearly.isEmpty) {
      stdout.writeln('Every screen matches what is committed. Nothing to do.');
      return 0;
    }
    if (!accept) {
      // Still exit 0 — the threshold is the contract, and moving it on a whim
      // is how a comparison becomes one nobody reads. But the last line says
      // what was found rather than that nothing was.
      stdout.writeln('No screen moved past the threshold, so nothing is being '
          'asked of you. ${nearly.length} did move: '
          '${nearly.map((n) => '${n.name} ${_percent(n.movedFraction)}').join(', ')}. '
          'A single short word changed in place lands about here, so open them '
          'if a screen you are writing about is on that list, and re-run with '
          '--accept to commit them.');
      return 0;
    }
    // `--accept` with only sub-threshold movers still writes them: the person
    // has said yes to this run's output, and leaving them behind is how a real
    // change small enough to sit under the threshold never lands.
  }

  if (!accept) {
    stdout.writeln('');
    stdout.writeln('Nothing has been written. Open the images named above — '
        'the diff picture marks every moved pixel in red — and if the new '
        'ones are right, run the same command again with --accept.');
    return 1;
  }

  committed.createSync(recursive: true);
  for (final c in changed) {
    File('${staging.path}/${c.name}.png')
        .copySync('${committed.path}/${c.name}.png');
    stdout.writeln('  accepted ${c.name}');
  }
  // **A screen that moved under the threshold is written too, once somebody
  // has said yes.** The threshold decides whether a person is *asked*; it is
  // not a rule about which images the repository keeps. Writing only the
  // screens past it leaves the committed set a patchwork of two runs, and the
  // pictures that get stranded are exactly the sub-threshold ones that were a
  // real content change rather than noise — on `/w-06` the record screen's
  // position line, on two screens, at 0.11% and 0.09%.
  for (final n in nearly) {
    File('${staging.path}/${n.name}.png')
        .copySync('${committed.path}/${n.name}.png');
    stdout.writeln('  accepted ${n.name} (moved ${_percent(n.movedFraction)}, '
        'under the threshold, written with the rest of this run)');
  }
  for (final name in added) {
    File('${staging.path}/$name.png').copySync('${committed.path}/$name.png');
    stdout.writeln('  accepted $name (new)');
  }
  if (removed.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Left alone, deliberately: ${removed.join(', ')}. '
        'This tool does not delete a committed image — if a screen is gone '
        'for good, remove its file by hand and say so in the commit message.');
  }
  return 0;
}

String _percent(double fraction) =>
    '${(fraction * 100).toStringAsFixed(fraction < 0.001 ? 4 : 2)}%';

List<String> _pngNames(Directory dir) => dir
    .listSync()
    .whereType<File>()
    .map((f) => f.uri.pathSegments.last)
    .where((n) => n.endsWith('.png') && !n.endsWith('.diff.png'))
    .map((n) => n.substring(0, n.length - 4))
    .toList()
  ..sort();

/// Names whose images came back byte-identical, grouped.
///
/// **Reported, not refused, and the distinction is the point** (`/w-08`).
///
/// `shots.dart` already refuses a duplicate *name*, because two shots sharing
/// one would have the second overwrite the first's file and the review would
/// report one state where two were photographed. This is the same lie arriving
/// by the other door: two different names that happen to photograph the same
/// pixels. `/w-08` found `owner-members-and-code` and `owner-pending-request`
/// byte-identical on the iPad — and identical in the *committed* set too, so
/// they had never differed there. The whole members screen fits on that
/// geometry, so scrolling to the pending request moves nothing, and the
/// manifest has claimed two states for one picture since the day it was
/// written. Nothing noticed, because nothing was looking.
///
/// **Why this prints rather than failing the run.** Whether two states collapse
/// into one picture is a fact about a device's geometry, and it can be
/// legitimate — the App Store set is not a user guide, and a duplicate there
/// wastes a slot rather than misleading a reader. A hard failure would force a
/// manifest redesign on whoever next regenerates, on a profile the guide does
/// not even use. **So the instrument says what it found and a person decides**
/// — which is the same trade `NEARLY` makes, and the same reason: the verdict
/// is not the useful part, the number behind it is.
List<List<String>> _identicalGroups(Map<String, Uint8List> images) {
  final names = images.keys.toList()..sort();
  final grouped = <List<String>>[];
  final taken = <String>{};
  for (final a in names) {
    if (taken.contains(a)) continue;
    final group = <String>[a];
    for (final b in names) {
      if (b == a || taken.contains(b)) continue;
      if (_sameBytes(images[a]!, images[b]!)) {
        group.add(b);
        taken.add(b);
      }
    }
    if (group.length > 1) {
      taken.add(a);
      grouped.add(group);
    }
  }
  return grouped;
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Changed {
  _Changed(this.name, this.movedFraction, this.detail);
  final String name;
  final double movedFraction;
  final String detail;
}

class _Comparison {
  _Comparison(this.movedFraction, this.diff);
  final double movedFraction;
  final Raster diff;
}

/// Counts moved pixels and paints a picture of where they are.
///
/// The diff picture is the new screenshot faded towards white, with every
/// moved pixel in solid red — so it is possible to see *what on the screen*
/// moved, not just how much of it did.
_Comparison _compare(Raster a, Raster b) {
  final diff = Uint8List(b.rgba.length);
  var moved = 0;
  for (var i = 0; i < b.rgba.length; i += 4) {
    var pixelMoved = false;
    for (var channel = 0; channel < 3; channel++) {
      if ((a.rgba[i + channel] - b.rgba[i + channel]).abs() >
          channelTolerance) {
        pixelMoved = true;
        break;
      }
    }
    if (pixelMoved) {
      moved++;
      diff[i] = 255;
      diff[i + 1] = 0;
      diff[i + 2] = 0;
    } else {
      for (var channel = 0; channel < 3; channel++) {
        diff[i + channel] = 255 - ((255 - b.rgba[i + channel]) * 0.25).round();
      }
    }
    diff[i + 3] = 255;
  }
  return _Comparison(moved / (b.width * b.height), Raster(b.width, b.height, diff));
}
