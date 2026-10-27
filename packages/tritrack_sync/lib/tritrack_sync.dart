/// Shared sync/merge primitives for TriTrack's app and server.
///
/// Plain Dart — no Flutter, no sqflite — so both sides can depend on it
/// without disagreeing about the merge rule, the table/column set, or the
/// schema version.
library;

export 'src/backup_format.dart';
export 'src/db_codec.dart';
export 'src/deployment_interlock.dart';
export 'src/email_identity.dart';
export 'src/field_time_zone.dart';
export 'src/enums.dart';
export 'src/join_code.dart';
export 'src/membership_departure.dart';
export 'src/merge_resolver.dart';
export 'src/mutation_rules.dart';
export 'src/offer_order.dart';
export 'src/offer_rules.dart';
export 'src/private_network.dart';
export 'src/project_destruction.dart';
export 'src/project_directory.dart';
export 'src/project_join.dart';
export 'src/project_owners.dart';
export 'src/project_roles.dart';
export 'src/pulse_modes.dart';
export 'src/row_refusal.dart';
export 'src/row_validator.dart';
export 'src/schema_constants.dart';
export 'src/sync_protocol.dart';
export 'src/sync_tables.dart';
export 'src/table_columns.dart';
export 'src/tag_column_kinds.dart';
export 'src/tag_color_palette.dart';
export 'src/tombstone_retention.dart';
export 'src/untrusted_import.dart';
export 'src/wire_shape_freeze.dart';
