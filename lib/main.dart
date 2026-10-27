import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/providers/retry_policy.dart';

void main() {
  // `retry:` is not optional here — see `retry_policy.dart`. Without it every
  // awaited provider in the app runs Riverpod's default of ten attempts and
  // 38 seconds of silence before a failure can be reported (task 11.107).
  runApp(ProviderScope(retry: appRetryPolicy, child: const TriTrackApp()));
}
