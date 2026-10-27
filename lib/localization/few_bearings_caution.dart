/// **When an estimate's 95% ellipse rests on too few bearings to be trusted as
/// 95%** — the one rule the Position screen, the Map's estimate card and Past
/// estimates share, so they cannot come to disagree about it (task 11.336).
///
/// The ellipse is the standard one: Lenth's (1981) covariance with the
/// chi-square 95% scale White & Garrott (1990) use. That scale is exact only
/// when the bearing scatter is known; the app estimates it from the same
/// bearings, and with few of them it comes out too small. Task 11.323's
/// simulation measured how often the ellipse then contains the animal: about
/// 40–60% at three and four bearings, 68–70% at five, 72–76% at six and
/// 83–86% at ten, against the 95% it is labeled. **The line is drawn between
/// five and six**: five is the last count whose measured coverage is 70% or
/// less.
///
/// A caution, not a correction: the estimate, κ and the ellipse are not
/// changed (`CLAUDE.md`, standing decision 5).
abstract final class FewBearingsCaution {
  /// The most bearings the caution is shown for.
  static const int atMostBearings = 5;

  /// The words, in the app's one-line caution style.
  ///
  /// **The last sentence names the guide page in words, not a link** (task
  /// 11.338): the app is used offline in the field, and a caution is plain
  /// text, so a URL that may not load would be worse than a title the person
  /// can look up later. The title is the published page's own; if the page is
  /// renamed, this sentence and the guide's quotes of it change together
  /// (`check_app_quotes` goes red until they do).
  static const String text = 'Few bearings — the 95% ellipse usually '
      'understates the uncertainty. Add bearings if you can. '
      'See “How the estimate is calculated” in the TriTrack guide.';

  /// Whether to show [text] for an estimate made from [bearings] bearings.
  ///
  /// **Only when there is an ellipse.** With none — two bearings always cross
  /// exactly — there is no "95%" to understate, and that case already has its
  /// own caution saying why.
  static bool applies({required int bearings, required bool hasEllipse}) =>
      hasEllipse && bearings <= atMostBearings;
}
