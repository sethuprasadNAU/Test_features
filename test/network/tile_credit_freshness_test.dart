@Tags(['network'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tritrack/features/map/services/tile_user_agent.dart';

import '../support/tile_credit_probes.dart';

/// **Task 11.134 item 2 — link 1: are the providers still publishing what
/// `tile_credit_probes.dart` recorded?**
///
/// This is the only part of the mechanism that needs the network, so it is
/// the only part that is not in the default suite. `dart_test.yaml` skips the
/// `network` tag, the same way it skips `e2e`, so `flutter test` stays green
/// with no network — the property README.md promises and
/// `run_offline_suite.sh` verifies. Run it deliberately:
///
///     flutter test test/network --tags network --run-skipped
///
/// and `.github/workflows/tile-credit-freshness.yml` runs it weekly, which is
/// the schedule the chosen design buys instead of catching drift the instant
/// it happens. That trade is priced in `tile_credit_probes.dart`.
///
/// **A red here is not an app defect and does not block anything.** It means
/// a provider changed the credit it requires, and somebody has to read the
/// page, update the probe and the app's `const` together, and — because
/// showing the credit is a licence condition — ship it.
///
/// **The requests carry [tileUserAgent], the same identity the app's tiles
/// do.** Not decoration: a check that identifies itself as something else is
/// not measuring what the app would be served.
///
/// **Task 11.135 — a red here now says which of two things happened.** The
/// non-200 branch below has always been careful; a DNS failure, a TLS error
/// or the 30-second timeout threw, and the run went red with a raw exception.
/// In a five-line CI tail that is indistinguishable from the credit having
/// actually changed — and the two need completely different responses. One
/// means somebody reads a licence page and edits two strings. The other means
/// a runner had no route out and the right move is to re-run.
///
/// So every request in this file goes through [_fetchOrSayWhyNot], and its
/// last words are the finding rather than a stack trace.
void main() {
  // **The verdict, printed after the last test rather than only beside the
  // first failure** (task 11.135). With three probes unreachable the run
  // prints three near-identical failures and then a summary listing three
  // test *names* — and every one of those names reads "still publishes the
  // recorded credit", which is the drift reading, not the transport one. A
  // short CI tail would show only the names. This puts the finding back
  // inside the last ten lines, where the project's rule about an
  // instrument's last words needs it.
  tearDownAll(() {
    if (_unreachable.isEmpty) return;
    // ignore: avoid_print
    print(
      '\nVERDICT: this run could not reach ${_unreachable.length} of the '
      'hosts it asks. Nothing was learned about any credit. Re-run.\n'
      '  ${_unreachable.join('\n  ')}',
    );
  });

  for (final probe in tileCreditProbes) {
    test('${probe.sourceId} still publishes the recorded credit', () async {
      final response = await _fetchOrSayWhyNot(probe.probeUrl);

      expect(
        response.statusCode,
        200,
        reason:
            '${probe.probeUrl} answered ${response.statusCode}. That is '
            'not drift and not an app defect — the page may have moved, or '
            'the host may be down. Re-run before changing anything.',
      );

      // **Decoded by what the probe declares, not by what the response
      // header says.** OpenTopoMap's about page is ISO-8859-1 and says so
      // only in a `<meta>` tag inside the document; its `Content-Type` header
      // does not carry a charset at all, so sniffing the header gets it
      // wrong. Read as UTF-8 its "©" arrives as a replacement character and
      // this check reports a credit change that did not happen — a wrong
      // cause in an instrument. Measured, then fixed.
      final body = probe.bodyEncoding.decode(response.bodyBytes);

      final drift = publishedCreditDrift(probe, body);
      expect(drift, isNull, reason: drift ?? '');
    });
  }

  // **Task 11.135's one extra request.** Task 11.134 put a contact address
  // into the `User-Agent` every tile request carries, choosing a web page
  // over an email so that no address goes out in the clear to three companies
  // on every tile. That was the right call and it left behind a claim nobody
  // checks: the app tells three tile operators where to reach whoever runs
  // it, and if that page stops answering the app is claiming a policy it does
  // not meet. **A dead contact is not a broken app** — nothing on a phone
  // changes — so this failing means somebody republishes a page, not that a
  // release is blocked.
  test('the contact address the app publishes to tile operators still answers',
      () async {
    final url = _contactUrlInUserAgent;
    expect(
      url,
      isNotNull,
      reason:
          'THE USER-AGENT NO LONGER CARRIES A CONTACT ADDRESS. The header '
          'the app sends is "$tileUserAgent", and nothing in it matches the '
          '"+https://…" form the OpenStreetMap tile policy asks for. Either '
          'the constant was edited or this check needs teaching the new '
          'shape; the app is not broken either way.',
    );

    final response = await _fetchOrSayWhyNot(url!);
    expect(
      response.statusCode,
      200,
      reason:
          'THE CONTACT ADDRESS IN THE APP\'S TILE USER-AGENT ANSWERED '
          '${response.statusCode}. Every tile request this app makes hands '
          '$url to OpenStreetMap, OpenTopoMap and Esri as the way to reach '
          'whoever runs it. Nothing on a phone is broken; a policy the app '
          'claims to meet is not being met, and the fix is to republish that '
          'page or change the constant in tile_user_agent.dart.',
    );
  });
}

/// The contact address out of [tileUserAgent] itself, never written down a
/// second time.
///
/// **A copy here could stay green while the header the app actually sends
/// pointed somewhere else** — which is the whole failure this check exists to
/// catch, reproduced inside the check. Null when the constant carries no
/// `+https://…` at all, which the test above reports as its own finding
/// rather than as a dead link.
final String? _contactUrlInUserAgent =
    RegExp(r'\+(https?://[^\s)]+)').firstMatch(tileUserAgent)?.group(1);

/// GETs [url] with the app's own tile identity, or **fails saying it could
/// not reach it** — never with a raw exception.
///
/// **This is the whole of task 11.135 item 2.** The two outcomes a red here
/// can mean are "the provider changed the credit" and "this runner could not
/// get out to the internet", and until now the second arrived as an
/// unhandled `SocketException`, `HandshakeException` or `TimeoutException`.
/// A five-line CI tail showed a stack trace, and the reader's first move —
/// go and read three licence pages — was the wrong one.
/// Every host this run failed to reach, for the verdict printed at the end.
/// A `Set` because three probes behind one dead resolver produce one fact,
/// not three.
final Set<String> _unreachable = {};

Future<http.Response> _fetchOrSayWhyNot(String url) async {
  try {
    return await http
        .get(Uri.parse(url), headers: tileRequestHeaders())
        .timeout(const Duration(seconds: 30));
  } catch (error) {
    _unreachable.add('$url — ${error.runtimeType}');
    // `fail` rather than a rethrow: the point is the sentence, and an
    // exception's own message does not carry any of it.
    fail(
      'COULD NOT REACH $url — ${error.runtimeType}: $error\n'
      'NOTHING CAME BACK, so this run learned nothing about what that host '
      'publishes. **That is not drift and not an app defect** — the host may '
      'be down, this runner may have no route out, or the address may have '
      'moved. Re-run before changing anything; if it fails the same way '
      'twice, open the address in a browser before editing any credit.',
    );
  }
}
