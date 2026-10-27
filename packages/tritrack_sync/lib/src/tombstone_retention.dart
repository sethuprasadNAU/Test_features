/// Tombstone retention policy (task 10.11).
///
/// Lives in the shared package for the same reason `latestSchemaVersion` does:
/// the server enforces it, the client has to be able to explain it, and two
/// numbers that drift apart would produce a refusal nobody can account for.
library;

/// How long a tombstone is kept before it becomes eligible for purging.
///
/// **24 months, sized against the field scenario rather than against storage.**
/// The case that sets the floor is a device shelved between seasons: last
/// synced early in season one, put in a drawer over the off-season, brought
/// back late in season two. That is roughly eighteen months, and a season that
/// starts late or a device that misses a full year of fieldwork pushes past it.
/// Twenty-four months clears the realistic worst case with room left over.
///
/// The asymmetry is what decides this, not the exact number. A window that is
/// too *short* silently corrupts data — a device past it resurrects deleted
/// records, and nobody finds out until someone notices an observation they
/// deleted months ago is back. A window that is too *long* costs a few
/// kilobytes of rows that nothing reads. At TriTrack's data scale (a project is
/// thousands of observations, and deletes are the rare correction of a
/// mis-recorded one, not routine churn) the storage side of that trade is close
/// to free. When one direction fails silently and the other fails by wasting
/// almost nothing, generosity is the only defensible choice.
///
/// **Do not shorten this to reclaim space without reading
/// [tombstonePurgeIsHeldBackByActiveDevices].** The window is only half the
/// protection, and the half that matters least.
const Duration tombstoneRetention = Duration(days: 730);

/// Documentation anchor, deliberately not a flag: purging is additionally held
/// back by the cursor of every device that has synced inside
/// [tombstoneRetention].
///
/// A tombstone is purged only when it is **both** older than the window **and**
/// below every still-active device's acknowledged position. Age alone is not
/// sufficient, because "old" says nothing about whether anyone still needs it —
/// a device that syncs every week is perfectly current and yet may sit below a
/// three-year-old tombstone if it joined the project recently.
///
/// The practical effect is that the stale-device refusal is reserved for
/// devices that have genuinely been gone longer than the window. A device that
/// keeps syncing can never be stranded by a purge, no matter how far behind it
/// is in absolute terms, which is what makes it safe to refuse hard rather than
/// attempting an automatic recovery.
const bool tombstonePurgeIsHeldBackByActiveDevices = true;
