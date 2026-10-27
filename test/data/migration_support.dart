import 'package:tritrack_sync/tritrack_sync.dart';

/// **The last schema version before task 11.243's wipe.**
///
/// Schema v17 deletes every collar, bearing, session, estimate, truth point,
/// no-signal entry and animal on the device, on purpose
/// (`ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §9). So a test about **what an
/// earlier migration did** cannot run the chain to [latestSchemaVersion]: it
/// would find the tables empty and would be measuring the wipe rather than
/// the migration it is named after.
///
/// Every such test stops here instead. That is a real narrowing and it is
/// stated rather than hidden: those tests no longer exercise the *current*
/// schema, only the schema as of the version they are about, which is what
/// they were always asking about anyway.
///
/// **Derived, not typed.** `schemaMajorFirstMinor[_wipeMajor]` is where major
/// 5 begins, and major 5 begins at the wipe — so this stays correct when a
/// later minor lands, and goes red rather than silently wrong if somebody
/// changes where the major starts.
final int lastVersionBeforeTheWipe = schemaMajorFirstMinor[_wipeMajor]! - 1;

/// The major task 11.243 spent. Named so the derivation above reads as what
/// it is rather than as an index.
const int _wipeMajor = 5;
