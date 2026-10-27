import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  group('ProjectSummary', () {
    test('toJson/fromJson round-trips', () {
      const summary = ProjectSummary(
        projectId: 'proj-1',
        projectName: 'Test Project',
        ownerUserId: 'user-1',
        role: 'owner',
      );
      final decoded = ProjectSummary.fromJson(summary.toJson());
      expect(decoded.projectId, summary.projectId);
      expect(decoded.projectName, summary.projectName);
      expect(decoded.ownerUserId, summary.ownerUserId);
      expect(decoded.role, summary.role);
    });

    // Task 10.67: every field here used a naked `json[key]! as String` — a
    // wrong-typed entry in `GET /projects/mine`'s `projects` array threw an
    // uncaught TypeError instead of the SyncProtocolException every other
    // field on this wire already draws. `owner_user_id` is the identity
    // field the audit specifically asked about.
    group('rejection paths (task 10.67)', () {
      test('a wrongly-typed project_id is a protocol error, not a crash', () {
        expect(
          () => ProjectSummary.fromJson({
            'project_id': 12345,
            'project_name': 'p',
            'owner_user_id': 'user-1',
            'role': 'owner',
          }),
          throwsA(isA<SyncProtocolException>()),
        );
      });

      test(
        'a wrongly-typed project_name is a protocol error, not a crash',
        () {
          expect(
            () => ProjectSummary.fromJson({
              'project_id': 'proj-1',
              'project_name': false,
              'owner_user_id': 'user-1',
              'role': 'owner',
            }),
            throwsA(isA<SyncProtocolException>()),
          );
        },
      );

      test(
        'a wrongly-typed owner_user_id is a protocol error, not a crash',
        () {
          expect(
            () => ProjectSummary.fromJson({
              'project_id': 'proj-1',
              'project_name': 'p',
              'owner_user_id': 12345,
              'role': 'owner',
            }),
            throwsA(isA<SyncProtocolException>()),
          );
        },
      );

      test('a wrongly-typed role is a protocol error, not a crash', () {
        expect(
          () => ProjectSummary.fromJson({
            'project_id': 'proj-1',
            'project_name': 'p',
            'owner_user_id': 'user-1',
            'role': {'not': 'a string'},
          }),
          throwsA(isA<SyncProtocolException>()),
        );
      });

      test('a missing field is a protocol error, not a crash', () {
        expect(
          () => ProjectSummary.fromJson({
            'project_id': 'proj-1',
            'project_name': 'p',
            'owner_user_id': 'user-1',
          }),
          throwsA(isA<SyncProtocolException>()),
        );
      });
    });
  });

  group('ProjectDirectoryResponse', () {
    test('toJson/fromJson round-trips a list of projects', () {
      const response = ProjectDirectoryResponse(
        projects: [
          ProjectSummary(
            projectId: 'proj-1',
            projectName: 'p1',
            ownerUserId: 'user-1',
            role: 'owner',
          ),
        ],
      );
      final decoded = ProjectDirectoryResponse.fromJson(response.toJson());
      expect(decoded.projects, hasLength(1));
      expect(decoded.projects.single.projectId, 'proj-1');
    });

    test('a non-list "projects" field yields no projects, not a crash', () {
      final decoded = ProjectDirectoryResponse.fromJson({
        ...const SyncEnvelope().toJson(),
        'projects': 'not-a-list',
      });
      expect(decoded.projects, isEmpty);
    });

    test(
      'a malformed entry in an otherwise well-formed list still throws '
      '(task 10.67) rather than silently dropping the bad row',
      () {
        expect(
          () => ProjectDirectoryResponse.fromJson({
            ...const SyncEnvelope().toJson(),
            'projects': [
              {
                'project_id': 'proj-1',
                'project_name': 'p1',
                'owner_user_id': 'user-1',
                'role': 'owner',
              },
              {
                'project_id': 999,
                'project_name': 'p2',
                'owner_user_id': 'user-1',
                'role': 'owner',
              },
            ],
          }),
          throwsA(isA<SyncProtocolException>()),
        );
      },
    );
  });
}
