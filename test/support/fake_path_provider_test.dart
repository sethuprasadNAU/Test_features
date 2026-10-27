import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'fake_path_provider.dart';

/// Task 11.296. `installFakePathProvider()` created a fresh temp directory
/// per test and deleted none of them — **199,261 counted, all empty, in
/// Michael's real system temp folder**, found by task 11.294 after `ls`
/// there stopped returning within two minutes.
///
/// `flutter_test_config.dart` calls `installFakePathProvider` in a global
/// `setUp` for every test in this suite, including these two, so there is
/// nothing to install here — the two tests below just read the directory
/// [main]'s first test was given and check it again after that test has
/// fully finished. `package:test` runs one test's `tearDown`s to completion
/// — including whatever `addTearDown` registered — before the next test's
/// `setUp` begins, so a directory still present in the second test is
/// exactly the leak this task fixes.
void main() {
  late String firstTestDirPath;

  test(
    'the fake path provider installed for this test has a real backing directory',
    () {
      final platform = PathProviderPlatform.instance as FakePathProviderPlatform;
      firstTestDirPath = platform.path;
      expect(Directory(firstTestDirPath).existsSync(), isTrue);
    },
  );

  test(
    'and that directory is gone once the test above has ended',
    () {
      expect(
        Directory(firstTestDirPath).existsSync(),
        isFalse,
        reason:
            'installFakePathProvider should delete its temp directory once '
            'its own test ends; a directory still here after the previous '
            'test finished is exactly what filled Michael\'s real system '
            'temp folder',
      );
    },
  );
}
