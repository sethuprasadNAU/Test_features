# gate-instrument: none - a reader imported by pre_commit_suite.sh to interpret a `flutter test` JSON stream; it runs nothing and reaches no server.
"""Read a `flutter test --reporter json` stream and say what it found.

**Task 11.180.** Two questions have to be answered separately, because the
exit code answers only one of them: *did every test file run*, and *did they
pass*. A run that reached nothing and a run that found nothing wrong look the
same from outside (task 11.150), so the scope is asserted against the tree
rather than against a number somebody picked.

Prints a verdict on stdout and exits 0 only when the run reached every
`*_test.dart` under `test/` and all of them passed.
"""

import json
import os
import sys


def main() -> int:
    repo_root = os.path.abspath(sys.argv[1])
    stream_path = sys.argv[2]

    on_disk = set()
    for dirpath, _dirnames, filenames in os.walk(os.path.join(repo_root, 'test')):
        for name in filenames:
            if name.endswith('_test.dart'):
                on_disk.add(
                    os.path.relpath(os.path.join(dirpath, name), repo_root))

    reached = set()
    tests = {}
    failures = []
    errors = {}
    done_success = None
    passed = 0
    skipped = 0
    saw_any_event = False

    with open(stream_path, errors='replace') as handle:
        for line in handle:
            line = line.strip()
            if not line.startswith('{'):
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            saw_any_event = True
            kind = event.get('type')
            if kind == 'suite':
                suite = event['suite']
                reached.add(os.path.relpath(suite['path'], repo_root))
                tests.setdefault(('suite', suite['id']), suite['path'])
            elif kind == 'testStart':
                test = event['test']
                tests[test['id']] = (
                    test.get('name', '?'),
                    tests.get(('suite', test.get('suiteID')), '?'),
                )
            elif kind == 'error':
                errors.setdefault(event.get('testID'), event.get('error', ''))
            elif kind == 'testDone':
                if event.get('hidden'):
                    continue
                if event.get('result') == 'success':
                    if event.get('skipped'):
                        skipped += 1
                    else:
                        passed += 1
                else:
                    failures.append(event.get('testID'))
            elif kind == 'done':
                done_success = event.get('success')

    if not saw_any_event:
        print('NOTHING WAS RUN. The test runner produced no events at all, so '
              'this says nothing about the tree.')
        return 1

    missing = sorted(on_disk - reached)
    if missing:
        print('The run reached {} of {} test files, so its verdict is about a '
              'subset and cannot stand for the suite.'.format(
                  len(reached & on_disk), len(on_disk)))
        for path in missing[:10]:
            print('  never ran: {}'.format(path))
        if len(missing) > 10:
            print('  ... and {} more'.format(len(missing) - 10))
        return 1

    if failures or done_success is False:
        print('{} of {} test files ran; {} test{} failed:'.format(
            len(on_disk), len(on_disk), len(failures),
            '' if len(failures) == 1 else 's'))
        for test_id in failures[:10]:
            name, suite = tests.get(test_id, ('?', '?'))
            print('  {}: {}'.format(os.path.relpath(suite, repo_root)
                                    if suite != '?' else '?', name))
            message = (errors.get(test_id) or '').strip().splitlines()
            if message:
                print('      {}'.format(message[0][:200]))
        if len(failures) > 10:
            print('  ... and {} more'.format(len(failures) - 10))
        if not failures and done_success is False:
            print('  the runner reported failure without naming a test — read '
                  'the raw output')
        return 1

    print('green: {} tests passed ({} skipped by tag) across all {} test '
          'files under test/.'.format(passed, skipped, len(on_disk)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
