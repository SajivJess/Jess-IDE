import 'package:flutter_test/flutter_test.dart';
import 'package:jess_app/services/workspaces_api_service.dart';

void main() {
  group('Workspaces API Models Test', () {
    test('WorkspaceModel deserializes correctly', () {
      final json = {
        'id': 'ws-12345678',
        'project_id': 'proj-abcdef',
        'name': 'Cloud AI Workspace',
        'status': 'RUNNING',
        'container_id': 'container-xyz',
        'image_name': 'python:3.10-slim',
        'root_path': '/workspace/proj-abcdef',
        'error_message': null,
        'created_at': '2026-10-25T00:00:00Z',
        'updated_at': '2026-10-25T00:05:00Z',
      };

      final ws = WorkspaceModel.fromJson(json);
      expect(ws.id, 'ws-12345678');
      expect(ws.projectId, 'proj-abcdef');
      expect(ws.name, 'Cloud AI Workspace');
      expect(ws.status, WorkspaceStatusEnum.running);
      expect(ws.containerId, 'container-xyz');
      expect(ws.imageName, 'python:3.10-slim');
      expect(ws.rootPath, '/workspace/proj-abcdef');
      expect(ws.errorMessage, isNull);
    });

    test('WorkspaceCommandResult deserializes stdout and exitCode', () {
      final json = {
        'command': ['echo', 'hello'],
        'exit_code': 0,
        'stdout': 'hello\n',
        'stderr': '',
        'timed_out': false,
        'duration_seconds': 0.042,
      };

      final result = WorkspaceCommandResult.fromJson(json);
      expect(result.success, isTrue);
      expect(result.exitCode, 0);
      expect(result.stdout, 'hello\n');
      expect(result.stderr, '');
      expect(result.timedOut, isFalse);
      expect(result.durationSeconds, 0.042);
    });

    test('WorkspaceFileItem deserializes file and directory metadata', () {
      final fileJson = {
        'name': 'main.py',
        'path': 'src/main.py',
        'is_directory': false,
        'size_bytes': 1024,
      };

      final dirJson = {
        'name': 'src',
        'path': 'src',
        'is_directory': true,
        'size_bytes': 0,
      };

      final file = WorkspaceFileItem.fromJson(fileJson);
      expect(file.name, 'main.py');
      expect(file.isDirectory, isFalse);
      expect(file.sizeBytes, 1024);

      final dir = WorkspaceFileItem.fromJson(dirJson);
      expect(dir.name, 'src');
      expect(dir.isDirectory, isTrue);
    });

    test('WorkspaceGitStatus and WorkspaceGitDiff deserialize correctly', () {
      final statusJson = {
        'branch': 'main',
        'is_clean': false,
        'modified_files': ['README.md'],
        'untracked_files': ['new_file.txt'],
        'staged_files': [],
      };

      final gitStatus = WorkspaceGitStatus.fromJson(statusJson);
      expect(gitStatus.branch, 'main');
      expect(gitStatus.isClean, isFalse);
      expect(gitStatus.modifiedFiles, contains('README.md'));
      expect(gitStatus.untrackedFiles, contains('new_file.txt'));

      final diffJson = {
        'branch': 'main',
        'diff': '--- a/README.md\n+++ b/README.md\n@@ -1 +1,2 @@\n+New line',
        'files_changed': 1,
        'changed_files': [
          {'file': 'README.md', 'status': 'M'}
        ],
      };

      final gitDiff = WorkspaceGitDiff.fromJson(diffJson);
      expect(gitDiff.branch, 'main');
      expect(gitDiff.filesChanged, 1);
      expect(gitDiff.diff, contains('New line'));
    });
  });
}
