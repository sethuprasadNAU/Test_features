/// Rate limiting for the unauthenticated auth routes (task 10.14,
/// Security Model §4.4).
library;

import 'dart:io';

import 'request_identity.dart';
import 'security_config.dart';

/// One `count per window` rule.
class RateLimitRule {
  const RateLimitRule({required this.limit, required this.window});

  /// How many requests are allowed within [window]. Must be at least 1 —
  /// §4.4's `Violated by:` list names "limits configurable to zero or absent",
  /// since a zero limit is an outage disguised as a control.
  final int limit;
  final Duration window;
}

/// §4.4's table, as code.
///
/// | Route | Per normalized email | Per source address | Per user |
/// | --- | --- | --- | --- |
/// | Magic-link request | 3 / 15 min, 10 / day | 10 / 15 min, 60 / hour | — |
/// | Magic-link redemption | — | 20 / min | — |
/// | Link-status poll | — | 30 / min | — |
/// | Invite redemption (11.2) | — | — | 10 / 15 min, 40 / day |
///
/// **Both keyings are required, not alternatives.** Per-email alone lets one
/// attacker bomb a thousand different colleagues. Per-source alone lets a
/// botnet bomb one colleague. §4.4's `Violated by:` list names "a limit on only
/// one key" first for exactly this reason.
///
/// The last row is the exception the rule proves: it is the only *authenticated*
/// route limited here, and an authenticated route has a better key than an
/// address. See [joinRequestPerUser].
class RateLimitPolicy {
  const RateLimitPolicy({
    this.magicLinkPerEmail = const [
      RateLimitRule(limit: 3, window: Duration(minutes: 15)),
      RateLimitRule(limit: 10, window: Duration(days: 1)),
    ],
    this.magicLinkPerSource = const [
      RateLimitRule(limit: 10, window: Duration(minutes: 15)),
      RateLimitRule(limit: 60, window: Duration(hours: 1)),
    ],
    this.redemptionPerSource = const [
      RateLimitRule(limit: 20, window: Duration(minutes: 1)),
    ],
    this.linkStatusPerSource = const [
      RateLimitRule(limit: 30, window: Duration(minutes: 1)),
    ],
    this.joinRequestPerUser = const [
      RateLimitRule(limit: 10, window: Duration(minutes: 15)),
      RateLimitRule(limit: 40, window: Duration(days: 1)),
    ],
    this.sessionListPerUser = const [
      RateLimitRule(limit: 60, window: Duration(minutes: 15)),
    ],
    this.projectListPerUser = const [
      RateLimitRule(limit: 60, window: Duration(minutes: 15)),
    ],
    this.joinRequestListPerUser = const [
      RateLimitRule(limit: 60, window: Duration(minutes: 15)),
    ],
  });

  final List<RateLimitRule> magicLinkPerEmail;
  final List<RateLimitRule> magicLinkPerSource;
  final List<RateLimitRule> redemptionPerSource;

  /// Task 10.56, finding I-6: `/auth/link-status/<id>` is unauthenticated,
  /// like the two routes above, and had no limit at all — 60 requests all
  /// answered `200`, none refused, none audited. 30/min is generous enough for
  /// a device honestly polling while a 15-minute-lived link is pending (every
  /// couple of seconds) while still bounding a request id guessing sweep from
  /// one source.
  final List<RateLimitRule> linkStatusPerSource;

  /// Task 11.2: invite-code redemption, keyed on the **authenticated user**.
  ///
  /// **Not per source, and that is a deliberate departure from every other rule
  /// here.** The three rules above guard unauthenticated routes, where the
  /// caller's address is the only key available — which is what makes them
  /// vulnerable to §4.4.1's collapse, where one undeclared proxy turns every
  /// caller into one bucket and the control locks out the whole deployment.
  /// Redemption is authenticated, so a strictly better key is already in hand:
  /// the session's `user_id`. It cannot collapse, it cannot be shared by two
  /// callers, and a caller who exhausts it has locked out nobody but
  /// themselves.
  ///
  /// **What it bounds got larger with task 11.81, and the number did not — so
  /// say what it now covers rather than leaving the old sentence.** Until then
  /// a guessed code was worth nothing unless it happened to be one issued to
  /// the guesser's own authenticated address, so this rule was defence in depth
  /// over that binding. There is no address binding any more. A correct guess
  /// now produces a real join request and **confirms that a project exists**,
  /// which is the disclosure inventory entry 24 records as inherent to the
  /// design.
  ///
  /// So this is the *only* bound on sweeping codes. What it still is not is the
  /// thing standing between an attacker and a project — the owner's approval is
  /// that, and 40 bits plus this rule bound **nuisance** rather than access
  /// (`join_code.dart` carries the argument in full). Ten attempts per fifteen
  /// minutes remains far more than a person mistyping a code off a whiteboard
  /// will ever need, and entry 24 asks that this be **measured** rather than
  /// assumed when somebody attacks the route.
  final List<RateLimitRule> joinRequestPerUser;

  /// Task 11.35: `GET /auth/sessions`, keyed on the **authenticated user**,
  /// for the same reason as [joinRequestPerUser] — an authenticated route
  /// has a better key than an address, and a per-user bucket cannot be
  /// collapsed by a proxy or shared between callers.
  ///
  /// It is not defending a secret; the caller may read their own sessions as
  /// often as they like and learns nothing new by asking twice. What it bounds
  /// is a database read per call on a route every signed-in device can reach,
  /// which task 10.56 made standard for every route rather than for the ones
  /// somebody thought were risky. Sixty per fifteen minutes is far above a
  /// screen that re-reads the list after each revocation.
  final List<RateLimitRule> sessionListPerUser;

  /// Task 11.64, finding P-1: `GET /projects/mine`, keyed on the
  /// **authenticated user**, for exactly the reasons [sessionListPerUser]
  /// gives — and given the same numbers, because it is the same shape of
  /// route answering the same kind of question.
  ///
  /// **Why it was missing.** Task 10.56 bounded "every field on every route",
  /// and `/projects/mine` has no fields: no body, no query, no path segment.
  /// So the sweep that produced [linkStatusPerSource] passed over it, and the
  /// route kept the one property 10.56 was actually about — an unbounded
  /// database read that any signed-in device can ask for as fast as it likes.
  /// A route with nothing to validate is not a route with nothing to bound.
  final List<RateLimitRule> projectListPerUser;

  /// Task 11.81: `GET /projects/join-requests/mine`, keyed on the
  /// authenticated user. Same shape and same number as the two reads above,
  /// because it is the same kind of question — "what does the server hold
  /// about me?" — and inventory entry 29 asks that it be bounded and limited
  /// like entry 27 was.
  final List<RateLimitRule> joinRequestListPerUser;

  /// Every rule this policy declares, in one place.
  ///
  /// **Exists so [RateLimiter.evictExpired] cannot be wrong about a bucket
  /// somebody added later.** That method has to know the longest window any
  /// rule uses, and it did so by listing four of the five fields by hand —
  /// [joinRequestPerUser] was added by task 11.2 and never appeared in
  /// it. Harmless by coincidence (the per-email daily rule happens to be just
  /// as long, so nothing was evicted early), which is exactly why nobody
  /// noticed. Adding the fifth field to that hand-written list would have
  /// fixed the instance; this fixes the class, which task 10.66 made a
  /// standing requirement. A new bucket is now covered by declaring it.
  List<RateLimitRule> get allRules => [
    ...magicLinkPerEmail,
    ...magicLinkPerSource,
    ...redemptionPerSource,
    ...linkStatusPerSource,
    ...joinRequestPerUser,
    ...sessionListPerUser,
    ...projectListPerUser,
    ...joinRequestListPerUser,
  ];

  /// The table above, unless [env] carries the e2e-only escape hatch.
  ///
  /// **Exists for one reason.** The e2e integration suite (task 10.17) runs
  /// its client against a server published through Docker's port proxy,
  /// which rewrites every connection's source address to the same
  /// Docker-bridge address before it reaches [SourceIdentity] — the same
  /// collapse as finding I-1, one hop earlier and with no HTTP proxy in the
  /// path to carry a forwarding header, so §4.4.1's trusted-proxy scheme does
  /// not reach it. The suite's seven files mint more than 10 magic links
  /// between them, so the per-source rule §4.4 designed against a botnet
  /// trips on a single well-behaved test run instead, turning a real signal
  /// into 429s nobody can act on — task 10.26's whole reason for existing.
  ///
  /// **Read the paragraph above as a security finding, because it is one, and
  /// for four gates it was read as a test-harness inconvenience instead.** It
  /// describes, accurately, a source key that cannot tell callers apart in a
  /// deployment this repository ships — and the conclusion drawn from it was
  /// "so the e2e suite needs an escape hatch" rather than "so the LAN
  /// deployment `README.md` documents has no per-source rate limit either."
  /// The knowledge was present, correct, and unlinked. That is finding J-2;
  /// §4.4.2 is the design that closes it, `scripts/verify_source_identity.sh`
  /// measures it, and the exposed proxy-less deployment it describes now
  /// refuses to start. Nothing about the escape hatch below changed — the e2e
  /// suite still runs on loopback, where one bucket and a per-source bucket
  /// are the same bucket.
  ///
  /// `TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED=1` is read nowhere but here,
  /// set nowhere but `docker-compose.e2e.yml`, and deliberately has no
  /// `.env.example` entry — this is not a knob a real deployment should ever
  /// touch, so [isProduction] refuses it outright rather than let a
  /// copy-pasted `.env` line quietly disable a real control.
  factory RateLimitPolicy.fromEnvironment([Map<String, String>? env]) {
    final environment = env ?? Platform.environment;
    final disablePerSource =
        environment['TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED'] == '1';
    if (!disablePerSource) return const RateLimitPolicy();
    if (isProductionEnvironment(environment)) {
      throw StateError(
        'TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED=1 is set but '
        'TRITRACK_ENV=production. Disabling the per-source magic-link and '
        'redemption limits is a test-only affordance (Security Model §4.4) '
        'and is refused in production.',
      );
    }
    const unbounded = RateLimitRule(limit: 1 << 30, window: Duration(days: 1));
    return const RateLimitPolicy(
      magicLinkPerSource: [unbounded],
      redemptionPerSource: [unbounded],
      // Same Docker-bridge source collapse would trip this the moment any
      // e2e file polls link-status more than 30 times behind the proxy.
      linkStatusPerSource: [unbounded],
    );
  }
}

/// What a caller should do about a limit being reached.
///
/// **The two outcomes differ in what they are allowed to reveal, and this is
/// the subtlest requirement in §4.4.**
///
/// - [RateLimitOutcome.emailLimited] must produce the *same* 202 a successful
///   request produces, and silently not send. A 429 keyed on an email address
///   tells the caller that somebody recently requested links for that address —
///   a weak but real oracle about a third party, and one that would undo §4.5's
///   anti-enumeration guarantee that the response is byte-identical for a
///   registered address, an unregistered one, and a rate-limited one.
/// - [RateLimitOutcome.sourceLimited] returns an honest 429. That fact is about
///   the caller, not about anyone else, and telling them is useful.
enum RateLimitOutcome {
  allowed,

  /// The per-email limit tripped. Respond exactly as if allowed; do not send.
  emailLimited,

  /// The per-source limit tripped. Respond 429.
  sourceLimited,
}

/// In-process fixed-window counters.
///
/// **This is explicitly a prototype-only shortcut, and §4.4 says so.** Before
/// any second instance or any load-balanced deployment, these must move to
/// Postgres or Redis: per-instance counters silently multiply the effective
/// limit by the instance count, which is the failure mode that looks like the
/// control is working. Recorded as a deployment precondition in the server
/// README and re-checked at task 10.16, per §4.4 and §6 item 7.
///
/// Fixed windows rather than a sliding log: a sliding window needs a timestamp
/// list per key, which is unbounded memory keyed on attacker-controlled input
/// (arbitrary email addresses). A fixed window is one integer and one instant
/// per key, and its known weakness — up to 2× the limit across a boundary — is
/// irrelevant against the two attacks §4.4 names, both of which are about
/// sustained volume rather than a burst of exactly the wrong shape.
class RateLimiter {
  RateLimiter({RateLimitPolicy? policy, DateTime Function()? clock})
    : policy = policy ?? const RateLimitPolicy(),
      _clock = clock ?? DateTime.now;

  final RateLimitPolicy policy;
  final DateTime Function() _clock;

  final Map<String, _Window> _windows = {};

  DateTime get _now => _clock().toUtc();

  /// Checks and records a magic-link request keyed **both** ways.
  ///
  /// Order matters: the per-source check runs first, so a caller flooding many
  /// different addresses gets an honest 429 rather than a stream of silent
  /// 202s. If it were the other way round, a source-limited attacker
  /// enumerating addresses would still learn per-address information from
  /// which requests were silently dropped.
  ///
  /// **The per-source rule is skipped when [source] cannot distinguish one
  /// caller from another** (`RequestSource.isDistinguishing`), and the per-email
  /// rule alone governs the request. Task 10.52 / §4.4; this is the fail-safe,
  /// and it is deliberately a fallback to *fewer* refusals rather than more:
  ///
  /// - A degenerate key refuses everybody or nobody. Finding I-1 is what
  ///   "everybody" looks like — ten unauthenticated requests behind an
  ///   undeclared proxy locked every user of the deployment out of sign-in for
  ///   15 minutes, using the control §4.4 wrote to *protect* them.
  /// - The attack the per-source rule names — "a botnet bombing one colleague"
  ///   — is defined by its *victim's* address, not the attacker's, so the
  ///   per-email rule still bounds it exactly as before. What is genuinely lost
  ///   is the volume bound on enumeration, which §4.5 already treats as
  ///   residual and bounds by the per-email daily cap and by the email body
  ///   carrying no attacker-controlled content.
  /// - It is reachable only from a misconfiguration (a declared proxy that
  ///   names nobody), which `SourceIdentity` warns about on a repeating
  ///   interval and which `TrustedProxies.fromEnvironment` refuses to leave
  ///   undeclared in production.
  ///
  /// [RequestSource.inProcess] takes the same path for the same reason it
  /// always did: there is no key to count against, and the only way to produce
  /// one is to already be inside this process.
  RateLimitOutcome checkMagicLink({
    required String email,
    required RequestSource source,
  }) {
    if (source.isDistinguishing &&
        !_admit(
          'magic-link:source:${source.address}',
          policy.magicLinkPerSource,
        )) {
      return RateLimitOutcome.sourceLimited;
    }
    if (!_admit('magic-link:email:$email', policy.magicLinkPerEmail)) {
      return RateLimitOutcome.emailLimited;
    }
    return RateLimitOutcome.allowed;
  }

  /// Checks and records a redemption attempt, per source only.
  ///
  /// No per-email rule, because the request carries no email — it carries a
  /// token, and keying a limit on the token would bound nothing (a guesser uses
  /// a different token each time). What this bounds is token *guessing volume*
  /// from one source.
  ///
  /// A degenerate [source] skips the rule, as in [checkMagicLink], and here the
  /// trade is even more one-sided: this rule is defence in depth over §4.2's
  /// 256 bits of token entropy, so suspending it costs a rounding error of
  /// security, while enforcing it on a merged key hands one caller the power to
  /// stop every user in the deployment from completing a sign-in they have
  /// already been emailed.
  RateLimitOutcome checkRedemption({required RequestSource source}) {
    if (source.isDistinguishing &&
        !_admit(
          'redeem:source:${source.address}',
          policy.redemptionPerSource,
        )) {
      return RateLimitOutcome.sourceLimited;
    }
    return RateLimitOutcome.allowed;
  }

  /// Checks and records a join-code request attempt, per authenticated
  /// user (tasks 11.2, 11.81).
  ///
  /// No `isDistinguishing` guard, because there is nothing to guard against: a
  /// `user_id` comes from a validated session row, not from a header a proxy
  /// might have rewritten, so the degenerate-key failure mode §4.4.1 describes
  /// cannot arise. Returns [RateLimitOutcome.sourceLimited] when tripped — an
  /// honest 429, since the fact is about the caller and nobody else.
  RateLimitOutcome checkJoinRequest({required String userId}) =>
      _admit('join-request:user:$userId', policy.joinRequestPerUser)
      ? RateLimitOutcome.allowed
      : RateLimitOutcome.sourceLimited;

  /// Checks and records a `GET /auth/sessions` read, per authenticated user
  /// (task 11.35). See [RateLimitPolicy.sessionListPerUser].
  RateLimitOutcome checkSessionList({required String userId}) =>
      _admit('session-list:user:$userId', policy.sessionListPerUser)
      ? RateLimitOutcome.allowed
      : RateLimitOutcome.sourceLimited;

  /// Checks and records a `GET /projects/mine` read, per authenticated user
  /// (task 11.64, finding P-1). See [RateLimitPolicy.projectListPerUser].
  ///
  /// A distinct bucket name from [checkSessionList] on purpose: sharing one
  /// would mean a device that re-read its project list could deny itself the
  /// device list, and the two screens are unrelated.
  RateLimitOutcome checkProjectList({required String userId}) =>
      _admit('project-list:user:$userId', policy.projectListPerUser)
      ? RateLimitOutcome.allowed
      : RateLimitOutcome.sourceLimited;

  /// Checks and records a `GET /projects/join-requests/mine` read, per
  /// authenticated user (task 11.81, inventory entry 29).
  ///
  /// Its own bucket, for the reason [checkProjectList] has one: a device
  /// polling for "has the owner approved me yet" must not be able to deny
  /// itself the project list.
  RateLimitOutcome checkJoinRequestList({required String userId}) =>
      _admit('join-request-list:user:$userId', policy.joinRequestListPerUser)
      ? RateLimitOutcome.allowed
      : RateLimitOutcome.sourceLimited;

  /// Checks and records a `/auth/link-status/<id>` poll, per source only
  /// (task 10.56, I-6). No per-email rule for the same reason as
  /// [checkRedemption]: the request carries a request id, not an address, and
  /// the request id is not itself sensitive (`auth_schema.dart`'s comment on
  /// `auth_link_requests`) — what this bounds is guessing/polling volume from
  /// one source, not disclosure to a third party.
  RateLimitOutcome checkLinkStatus({required RequestSource source}) {
    if (source.isDistinguishing &&
        !_admit(
          'link-status:source:${source.address}',
          policy.linkStatusPerSource,
        )) {
      return RateLimitOutcome.sourceLimited;
    }
    return RateLimitOutcome.allowed;
  }

  /// Consumes one unit against every rule for [key], or none at all.
  ///
  /// **All-or-nothing on purpose.** Incrementing the 15-minute counter while
  /// the daily counter is already exhausted would keep pushing the short window
  /// forward on requests that were refused anyway, so a caller who kept trying
  /// would stay locked out of the short window long after it should have
  /// reset — a limit that gets stricter the more it is hit is not the limit
  /// that was specified.
  bool _admit(String key, List<RateLimitRule> rules) {
    final now = _now;
    for (var i = 0; i < rules.length; i++) {
      final window = _windows['$key#$i'];
      if (window != null && !window.isExpired(now, rules[i].window)) {
        if (window.count >= rules[i].limit) return false;
      }
    }
    for (var i = 0; i < rules.length; i++) {
      final slot = '$key#$i';
      final window = _windows[slot];
      if (window == null || window.isExpired(now, rules[i].window)) {
        _windows[slot] = _Window(startedAt: now, count: 1);
      } else {
        window.count++;
      }
    }
    return true;
  }

  /// Drops windows that can no longer refuse anything.
  ///
  /// Counters are keyed partly on attacker-supplied email addresses, so
  /// without this the map is an unbounded-growth primitive on an
  /// unauthenticated route — the same class of problem as the request body
  /// limits (§3.1). Called opportunistically rather than on a timer so there
  /// is no background task to fail silently.
  void evictExpired() {
    final now = _now;
    final longest = policy.allRules
        .map((r) => r.window)
        .reduce((a, b) => a > b ? a : b);
    _windows.removeWhere((_, window) => window.isExpired(now, longest));
  }

  /// How many keys are currently held. For tests and the diagnostics console;
  /// never exposed to an unauthenticated caller, since it is a count of recent
  /// distinct addresses.
  int get trackedKeys => _windows.length;
}

class _Window {
  _Window({required this.startedAt, required this.count});

  final DateTime startedAt;
  int count;

  bool isExpired(DateTime now, Duration window) =>
      now.difference(startedAt) >= window;
}
