// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_held_rows_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Rows this device is holding for [projectId] because the server refused them
/// (task 10.28 / finding D-3) — the reviewable half of "something did not sync,
/// and here is why."
///
/// Same shape and lifetime as [syncConflictsProvider]: not `keepAlive`, read by
/// the status screen, and invalidated by [SyncController] after every sync round
/// so it cannot go stale while something is watching it.

@ProviderFor(syncHeldRows)
final syncHeldRowsProvider = SyncHeldRowsFamily._();

/// Rows this device is holding for [projectId] because the server refused them
/// (task 10.28 / finding D-3) — the reviewable half of "something did not sync,
/// and here is why."
///
/// Same shape and lifetime as [syncConflictsProvider]: not `keepAlive`, read by
/// the status screen, and invalidated by [SyncController] after every sync round
/// so it cannot go stale while something is watching it.

final class SyncHeldRowsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<HeldRow>>,
          List<HeldRow>,
          FutureOr<List<HeldRow>>
        >
    with $FutureModifier<List<HeldRow>>, $FutureProvider<List<HeldRow>> {
  /// Rows this device is holding for [projectId] because the server refused them
  /// (task 10.28 / finding D-3) — the reviewable half of "something did not sync,
  /// and here is why."
  ///
  /// Same shape and lifetime as [syncConflictsProvider]: not `keepAlive`, read by
  /// the status screen, and invalidated by [SyncController] after every sync round
  /// so it cannot go stale while something is watching it.
  SyncHeldRowsProvider._({
    required SyncHeldRowsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'syncHeldRowsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$syncHeldRowsHash();

  @override
  String toString() {
    return r'syncHeldRowsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<HeldRow>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<HeldRow>> create(Ref ref) {
    final argument = this.argument as String;
    return syncHeldRows(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is SyncHeldRowsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$syncHeldRowsHash() => r'7f96386cb5685868579d5a93000f954997df5b45';

/// Rows this device is holding for [projectId] because the server refused them
/// (task 10.28 / finding D-3) — the reviewable half of "something did not sync,
/// and here is why."
///
/// Same shape and lifetime as [syncConflictsProvider]: not `keepAlive`, read by
/// the status screen, and invalidated by [SyncController] after every sync round
/// so it cannot go stale while something is watching it.

final class SyncHeldRowsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<List<HeldRow>>, String> {
  SyncHeldRowsFamily._()
    : super(
        retry: null,
        name: r'syncHeldRowsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// Rows this device is holding for [projectId] because the server refused them
  /// (task 10.28 / finding D-3) — the reviewable half of "something did not sync,
  /// and here is why."
  ///
  /// Same shape and lifetime as [syncConflictsProvider]: not `keepAlive`, read by
  /// the status screen, and invalidated by [SyncController] after every sync round
  /// so it cannot go stale while something is watching it.

  SyncHeldRowsProvider call(String projectId) =>
      SyncHeldRowsProvider._(argument: projectId, from: this);

  @override
  String toString() => r'syncHeldRowsProvider';
}

/// The same holds, resolved into which record, which rule, and what to do —
/// what the status screen actually renders (task 11.41).
///
/// A separate provider rather than a change to [syncHeldRows] so the raw rows
/// stay available to anything that only needs to count them, and so the reads
/// this one performs (the record itself, the people it names, the project's
/// tags) happen once per screen build rather than once per tile.
///
/// **The signed-in user is resolved here and not inside the resolver.** Every
/// sentence the screen shows turns on "is this you?", and a resolver that
/// looked the answer up itself could not be handed the no-identity case to
/// test.

@ProviderFor(syncHeldRowDetails)
final syncHeldRowDetailsProvider = SyncHeldRowDetailsFamily._();

/// The same holds, resolved into which record, which rule, and what to do —
/// what the status screen actually renders (task 11.41).
///
/// A separate provider rather than a change to [syncHeldRows] so the raw rows
/// stay available to anything that only needs to count them, and so the reads
/// this one performs (the record itself, the people it names, the project's
/// tags) happen once per screen build rather than once per tile.
///
/// **The signed-in user is resolved here and not inside the resolver.** Every
/// sentence the screen shows turns on "is this you?", and a resolver that
/// looked the answer up itself could not be handed the no-identity case to
/// test.

final class SyncHeldRowDetailsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<HeldRowDetail>>,
          List<HeldRowDetail>,
          FutureOr<List<HeldRowDetail>>
        >
    with
        $FutureModifier<List<HeldRowDetail>>,
        $FutureProvider<List<HeldRowDetail>> {
  /// The same holds, resolved into which record, which rule, and what to do —
  /// what the status screen actually renders (task 11.41).
  ///
  /// A separate provider rather than a change to [syncHeldRows] so the raw rows
  /// stay available to anything that only needs to count them, and so the reads
  /// this one performs (the record itself, the people it names, the project's
  /// tags) happen once per screen build rather than once per tile.
  ///
  /// **The signed-in user is resolved here and not inside the resolver.** Every
  /// sentence the screen shows turns on "is this you?", and a resolver that
  /// looked the answer up itself could not be handed the no-identity case to
  /// test.
  SyncHeldRowDetailsProvider._({
    required SyncHeldRowDetailsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'syncHeldRowDetailsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$syncHeldRowDetailsHash();

  @override
  String toString() {
    return r'syncHeldRowDetailsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<HeldRowDetail>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<HeldRowDetail>> create(Ref ref) {
    final argument = this.argument as String;
    return syncHeldRowDetails(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is SyncHeldRowDetailsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$syncHeldRowDetailsHash() =>
    r'042f15c6f57a4620a7bcb350a597fc486c0b7421';

/// The same holds, resolved into which record, which rule, and what to do —
/// what the status screen actually renders (task 11.41).
///
/// A separate provider rather than a change to [syncHeldRows] so the raw rows
/// stay available to anything that only needs to count them, and so the reads
/// this one performs (the record itself, the people it names, the project's
/// tags) happen once per screen build rather than once per tile.
///
/// **The signed-in user is resolved here and not inside the resolver.** Every
/// sentence the screen shows turns on "is this you?", and a resolver that
/// looked the answer up itself could not be handed the no-identity case to
/// test.

final class SyncHeldRowDetailsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<List<HeldRowDetail>>, String> {
  SyncHeldRowDetailsFamily._()
    : super(
        retry: null,
        name: r'syncHeldRowDetailsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// The same holds, resolved into which record, which rule, and what to do —
  /// what the status screen actually renders (task 11.41).
  ///
  /// A separate provider rather than a change to [syncHeldRows] so the raw rows
  /// stay available to anything that only needs to count them, and so the reads
  /// this one performs (the record itself, the people it names, the project's
  /// tags) happen once per screen build rather than once per tile.
  ///
  /// **The signed-in user is resolved here and not inside the resolver.** Every
  /// sentence the screen shows turns on "is this you?", and a resolver that
  /// looked the answer up itself could not be handed the no-identity case to
  /// test.

  SyncHeldRowDetailsProvider call(String projectId) =>
      SyncHeldRowDetailsProvider._(argument: projectId, from: this);

  @override
  String toString() => r'syncHeldRowDetailsProvider';
}

/// The "Try again" action: [releaseHeldRowForRetry], then sync now.
///
/// Syncs immediately rather than waiting for the schedule because the user has
/// just told the app the situation changed, and the answer to "did it work this
/// time" should arrive while they are still looking at the screen.
///
/// Exposed as a provider rather than a bare function so a widget test can assert
/// that the button is wired to it without putting a real database in the tap
/// path — under `testWidgets`' fake clock, SQLite work started from a tap never
/// completes, so a widget test written the obvious way hangs instead of failing.
/// The action's own rules are covered by [releaseHeldRowForRetry]'s tests.
///
/// ## Every `ref.watch` before the first `await` — task 11.236, same fix as
/// task 11.235's [_ensureOwnerMembership]
///
/// This is [heldRowRetryProvider], **auto-disposing**, read bare by the status
/// screen (`ref.read(heldRowRetryProvider)(...)` — a read with no listener
/// behind it). Riverpod disposes a provider like that a microtask after the
/// read returns; the closure below keeps running through the database write
/// that follows. **It used to `ref.invalidate` and `ref.read` again after that
/// write** — after an `await`, on a `Ref` that may already be dead — and a
/// probe calling it exactly as the screen does threw *"Cannot use the Ref of
/// heldRowRetryProvider after it has been disposed"*, the same exception task
/// 11.235 found on the tag database's + button.
///
/// The database and the sync controller are both resolved here, synchronously,
/// before the closure's first `await`; nothing inside the closure touches
/// `ref` at all. **The explicit `ref.invalidate(syncHeldRowsProvider(...))`
/// this used to do here is gone rather than moved** — [SyncController] is
/// `keepAlive`, so its own `_run` already invalidates
/// `syncHeldRowsProvider(projectId)` whenever a round changes what is held
/// (`report.refused.isNotEmpty || counts.held != current.heldCount`), which
/// [syncNow] below runs into. And it changed nothing a person could see: the
/// release only clears `held_updated_at`, which [syncHeldRows] never reads —
/// `held()`'s query filters on `resolved_at_utc`, not that column — so the
/// tile renders identically with or without this call between the release and
/// the sync round it was standing in front of.

@ProviderFor(heldRowRetry)
final heldRowRetryProvider = HeldRowRetryProvider._();

/// The "Try again" action: [releaseHeldRowForRetry], then sync now.
///
/// Syncs immediately rather than waiting for the schedule because the user has
/// just told the app the situation changed, and the answer to "did it work this
/// time" should arrive while they are still looking at the screen.
///
/// Exposed as a provider rather than a bare function so a widget test can assert
/// that the button is wired to it without putting a real database in the tap
/// path — under `testWidgets`' fake clock, SQLite work started from a tap never
/// completes, so a widget test written the obvious way hangs instead of failing.
/// The action's own rules are covered by [releaseHeldRowForRetry]'s tests.
///
/// ## Every `ref.watch` before the first `await` — task 11.236, same fix as
/// task 11.235's [_ensureOwnerMembership]
///
/// This is [heldRowRetryProvider], **auto-disposing**, read bare by the status
/// screen (`ref.read(heldRowRetryProvider)(...)` — a read with no listener
/// behind it). Riverpod disposes a provider like that a microtask after the
/// read returns; the closure below keeps running through the database write
/// that follows. **It used to `ref.invalidate` and `ref.read` again after that
/// write** — after an `await`, on a `Ref` that may already be dead — and a
/// probe calling it exactly as the screen does threw *"Cannot use the Ref of
/// heldRowRetryProvider after it has been disposed"*, the same exception task
/// 11.235 found on the tag database's + button.
///
/// The database and the sync controller are both resolved here, synchronously,
/// before the closure's first `await`; nothing inside the closure touches
/// `ref` at all. **The explicit `ref.invalidate(syncHeldRowsProvider(...))`
/// this used to do here is gone rather than moved** — [SyncController] is
/// `keepAlive`, so its own `_run` already invalidates
/// `syncHeldRowsProvider(projectId)` whenever a round changes what is held
/// (`report.refused.isNotEmpty || counts.held != current.heldCount`), which
/// [syncNow] below runs into. And it changed nothing a person could see: the
/// release only clears `held_updated_at`, which [syncHeldRows] never reads —
/// `held()`'s query filters on `resolved_at_utc`, not that column — so the
/// tile renders identically with or without this call between the release and
/// the sync round it was standing in front of.

final class HeldRowRetryProvider
    extends $FunctionalProvider<HeldRowRetry, HeldRowRetry, HeldRowRetry>
    with $Provider<HeldRowRetry> {
  /// The "Try again" action: [releaseHeldRowForRetry], then sync now.
  ///
  /// Syncs immediately rather than waiting for the schedule because the user has
  /// just told the app the situation changed, and the answer to "did it work this
  /// time" should arrive while they are still looking at the screen.
  ///
  /// Exposed as a provider rather than a bare function so a widget test can assert
  /// that the button is wired to it without putting a real database in the tap
  /// path — under `testWidgets`' fake clock, SQLite work started from a tap never
  /// completes, so a widget test written the obvious way hangs instead of failing.
  /// The action's own rules are covered by [releaseHeldRowForRetry]'s tests.
  ///
  /// ## Every `ref.watch` before the first `await` — task 11.236, same fix as
  /// task 11.235's [_ensureOwnerMembership]
  ///
  /// This is [heldRowRetryProvider], **auto-disposing**, read bare by the status
  /// screen (`ref.read(heldRowRetryProvider)(...)` — a read with no listener
  /// behind it). Riverpod disposes a provider like that a microtask after the
  /// read returns; the closure below keeps running through the database write
  /// that follows. **It used to `ref.invalidate` and `ref.read` again after that
  /// write** — after an `await`, on a `Ref` that may already be dead — and a
  /// probe calling it exactly as the screen does threw *"Cannot use the Ref of
  /// heldRowRetryProvider after it has been disposed"*, the same exception task
  /// 11.235 found on the tag database's + button.
  ///
  /// The database and the sync controller are both resolved here, synchronously,
  /// before the closure's first `await`; nothing inside the closure touches
  /// `ref` at all. **The explicit `ref.invalidate(syncHeldRowsProvider(...))`
  /// this used to do here is gone rather than moved** — [SyncController] is
  /// `keepAlive`, so its own `_run` already invalidates
  /// `syncHeldRowsProvider(projectId)` whenever a round changes what is held
  /// (`report.refused.isNotEmpty || counts.held != current.heldCount`), which
  /// [syncNow] below runs into. And it changed nothing a person could see: the
  /// release only clears `held_updated_at`, which [syncHeldRows] never reads —
  /// `held()`'s query filters on `resolved_at_utc`, not that column — so the
  /// tile renders identically with or without this call between the release and
  /// the sync round it was standing in front of.
  HeldRowRetryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'heldRowRetryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$heldRowRetryHash();

  @$internal
  @override
  $ProviderElement<HeldRowRetry> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  HeldRowRetry create(Ref ref) {
    return heldRowRetry(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(HeldRowRetry value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<HeldRowRetry>(value),
    );
  }
}

String _$heldRowRetryHash() => r'19be44d2dd6d3399040afcc8d55f9116a94083ac';
