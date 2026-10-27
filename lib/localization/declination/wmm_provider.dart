import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'wmm.dart';

part 'wmm_provider.g.dart';

/// The magnetic-declination service, loaded once from the embedded coefficient
/// asset. Phase 3 (compass) and Phase 4 (observation logging) watch this to
/// convert magnetic bearings to true north for the observation's own date.
@Riverpod(keepAlive: true)
Future<WmmService> wmmService(Ref ref) => WmmService.load();
