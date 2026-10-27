import 'package:geolocator/geolocator.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'gps_provider.g.dart';

/// Throttled GPS stream (5-10s between fixes per the battery budget in the
/// technical doc). Screens should watch this rather than polling
/// `Geolocator.getCurrentPosition()` directly, so throttling/pausing stays
/// in one place. Pausing while the app is backgrounded is wired in whichever
/// phase adds app-lifecycle observation (Phase 4 UI shell).
///
/// **Asking this why it produced nothing is the one thing it cannot answer.**
/// It throws [LocationPermissionDeniedException] on a refusal, and that
/// exception does not survive the provider boundary — see its doc, and
/// [locationProblemProvider] for the answer that does.
@riverpod
Stream<Position> gpsPosition(Ref ref) async* {
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw const LocationPermissionDeniedException();
  }

  const settings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 5,
  );
  yield* Geolocator.getPositionStream(locationSettings: settings);
}

/// Thrown by [gpsPosition] when this device will not give the app a position.
///
/// **Do not rely on catching this to tell a person anything.** It is one of
/// the two live instances task 11.66 reproduced on an Android phone and task
/// 11.105 traced to its cause: `gpsPositionProvider` is autoDispose, so
/// `await ref.read(gpsPositionProvider.future)` holds no listener across the
/// await, the element is torn down while still loading, and — measured on
/// 2026-08-31 against riverpod 3.3.2 — the caller receives `StateError: "The
/// provider gpsPositionProvider was disposed during loading state, yet no
/// value could be emitted."` **This object never arrives.** It is destroyed,
/// not wrapped, so no amount of unwrapping at the `catch` recovers it. See
/// `provider_error.dart`.
///
/// It stays because it is the *enforcement*: it is what stops the stream
/// yielding positions the OS has not consented to give. Use
/// [locationProblemProvider] to tell somebody why there is no position.
class LocationPermissionDeniedException implements Exception {
  const LocationPermissionDeniedException();

  @override
  String toString() => 'Location permission was denied.';
}

/// Why this device will not give the app a position — the fault, not the
/// remedy.
enum LocationFault {
  /// Location is switched off for the whole device, so no app gets a fix.
  /// Distinct from the two below because the setting that fixes it is a
  /// different one, in a different place.
  serviceDisabled,

  /// This app has been refused, but asking again is still allowed — the OS
  /// will show its dialog on the next attempt.
  permissionDenied,

  /// This app has been refused permanently. **The OS will not show its dialog
  /// again**, so "allow it when asked" is advice that cannot be followed: the
  /// only route left is the system settings for this app.
  permissionDeniedForever,

  /// The device could not say. Reported as itself rather than folded into a
  /// denial, because telling somebody their permission is refused when it may
  /// not be is the wrong-cause defect in miniature.
  unknown,
}

/// A refused location, and the sentence to show a person.
///
/// **Carried as a value, never only as a thrown exception** — the same
/// architecture as `ServerUrlProblem`, and for the same measured reason. See
/// [LocationPermissionDeniedException].
class LocationProblem {
  const LocationProblem(this.fault, this.message);

  final LocationFault fault;

  /// **Always ends with something to try.** A diagnosis somebody cannot act on
  /// is not help — the standing rule from task 11.104.
  final String message;

  @override
  String toString() => 'LocationProblem(${fault.name}): $message';
}

/// The sentence for a device that could not be asked at all.
///
/// Its own constant because two callers need it: [describeLocationProblem]
/// when the platform channel is missing or throws, and any test that wants to
/// assert the honest-failure case without reproducing the wording.
const LocationProblem unknownLocationProblem = LocationProblem(
  LocationFault.unknown,
  'TriTrack could not check this device\'s location settings. Check that '
  'Location is on for the device and allowed for TriTrack, then try again.',
);

/// **What is wrong with this device's location, given what the OS says — or
/// null if nothing is.**
///
/// A pure function, separate from the call that fetches its two inputs, for
/// the same reason `describeServerUrlProblem` is: it is the *decision*, and a
/// decision that can only be exercised on a real phone is a decision nobody
/// checks. Every branch below is reachable from a test.
LocationProblem? locationProblemFor({
  required bool serviceEnabled,
  required LocationPermission permission,
}) {
  if (!serviceEnabled) {
    return const LocationProblem(
      LocationFault.serviceDisabled,
      'Location is switched off for this device. Turn it on in the system '
      'settings, then try again.',
    );
  }
  return switch (permission) {
    LocationPermission.denied => const LocationProblem(
      LocationFault.permissionDenied,
      'TriTrack has not been allowed to use your location. Try again and '
      'choose Allow when the phone asks.',
    ),
    LocationPermission.deniedForever => const LocationProblem(
      LocationFault.permissionDeniedForever,
      'TriTrack has been permanently denied your location. Turn Location on '
      'for TriTrack in system settings, then try again.',
    ),
    LocationPermission.unableToDetermine => unknownLocationProblem,
    LocationPermission.whileInUse || LocationPermission.always => null,
  };
}

/// **What is wrong with this device's location, or null if nothing is.**
///
/// Deliberately returns a value and never throws, so that it can be awaited
/// from anywhere without the boundary problem this whole file documents. Every
/// failure inside — including a platform channel that is not there, which is
/// what happens in a widget test — resolves to [unknownLocationProblem] rather
/// than an exception nobody will receive.
///
/// **Reads the permission; never requests it.** Requesting is a side effect
/// with a dialog attached, and it belongs to [gpsPosition], which is the thing
/// a person asked for. This one only explains, and it is called after a
/// failure, when the dialog has already had its turn.
Future<LocationProblem?> describeLocationProblem() async {
  try {
    return locationProblemFor(
      serviceEnabled: await Geolocator.isLocationServiceEnabled(),
      permission: await Geolocator.checkPermission(),
    );
  } catch (_) {
    // Nothing here is worth re-throwing: the caller is already handling a
    // failure and asked this only for a reason to show. An exception raised
    // while explaining an exception is how a screen ends up with no message
    // at all.
    return unknownLocationProblem;
  }
}

/// [describeLocationProblem] as a provider, so a screen can be put into the
/// refused state in a test.
///
/// **keepAlive, and it cannot throw.** Both matter: a `@riverpod` autoDispose
/// provider awaited with `ref.read(...future)` is torn down mid-load, which is
/// the defect this exists to route around, and a provider that throws hands
/// the caller nothing usable. See `provider_error.dart` for the measurements.
///
/// Not cached in any useful sense — permission changes while the app is
/// backgrounded and this is read once per failure — so callers should
/// `ref.invalidate` it before reading if they need a fresh answer. The screens
/// here read it immediately after a failed attempt, which is fresh enough.
@Riverpod(keepAlive: true)
Future<LocationProblem?> locationProblem(Ref ref) => describeLocationProblem();
