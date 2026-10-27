/// Normalizes an email into the canonical form used as TriTrack's cross-device
/// identity anchor: trimmed and lower-cased.
///
/// **This must be shared, not reimplemented.** It is the join key in three
/// separate places that have to agree exactly or identity silently fractures:
/// Phase 6's `ProjectMerger` user dedup, Phase 7's `Users`/`User_Emails`
/// matching, and — from task 10.6 — the server's `auth_accounts.email`, which
/// is *authoritative* for which `user_id` an address maps to. A server that
/// normalized differently from a client would hand two devices different ids
/// for the same person, which is exactly the split-brain the shared package
/// exists to prevent.
///
/// **Deliberately conservative: case and surrounding whitespace only.** No
/// Unicode/IDN folding, no Gmail dot-stripping, no `+tag` removal. Those are
/// provider-specific policies, and applying them would make two genuinely
/// distinct addresses collide — `a.b@example.org` and `ab@example.org` are the
/// same mailbox at Gmail and different mailboxes almost everywhere else.
/// Collapsing identities that should stay separate is a worse failure here than
/// failing to collapse ones that could have merged: the former silently
/// attributes one researcher's field records to another, and the latter is
/// visible and recoverable (the user signs in with the address they actually
/// use).
String normalizeEmail(String email) => email.trim().toLowerCase();

/// The domain Phase 7 mints first-run placeholder addresses under, when a
/// device has a local user but its owner has not yet completed identity
/// capture (`field-user-<uuid>@local.tritrack`).
///
/// A reserved, non-routable-looking domain on purpose: a placeholder must never
/// collide with a real mailbox, because cross-device dedup treats the address
/// as an identity and matching two devices' placeholders together would fuse
/// two different people.
const String placeholderEmailDomain = '@local.tritrack';

/// Whether [email] is a Phase 7 placeholder rather than a real address.
///
/// Shared because three call sites need the same answer and must not drift:
/// the `User` model's `hasPlaceholderIdentity` (drives the first-run gate),
/// task 10.6's identity adoption (a placeholder user is unambiguously the
/// person now signing in, so it is adopted even though its address does not
/// match), and the same task's prior-email recording (a placeholder was never
/// a real mailbox, so recording it as a prior address would be noise that
/// matches nobody).
bool isPlaceholderEmail(String email) =>
    normalizeEmail(email).endsWith(placeholderEmailDomain);
