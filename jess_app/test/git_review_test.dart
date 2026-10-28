import 'package:flutter_test/flutter_test.dart';
import 'package:jess_app/services/workspaces_api_service.dart';

void main() {
  group('Batch 4 Git Review & Branch Models', () {
    test('WorkspaceGitFileDiff parses modified, added, and deleted files', () {
      final json = {
        'path': 'lib/screens/dashboard.dart',
        'status': 'modified',
        'additions': 14,
        'deletions': 3,
        'patch': '@@ -10,3 +10,14 @@\n+new line',
      };

      final fileDiff = WorkspaceGitFileDiff.fromJson(json);
      expect(fileDiff.path, 'lib/screens/dashboard.dart');
      expect(fileDiff.status, 'modified');
      expect(fileDiff.additions, 14);
      expect(fileDiff.deletions, 3);
      expect(fileDiff.patch, contains('+new line'));
    });

    test('WorkspaceGitDiff parses per-file breakdown and stats', () {
      final json = {
        'branch': 'feature/git-review',
        'diff': 'diff --git a/file1.py b/file1.py\n+hello',
        'files_changed': 2,
        'additions': 25,
        'deletions': 5,
        'files': [
          {
            'path': 'file1.py',
            'status': 'modified',
            'additions': 20,
            'deletions': 5,
            'patch': '@@ -1 +1 @@\n+hello',
          },
          {
            'path': 'file2.py',
            'status': 'added',
            'additions': 5,
            'deletions': 0,
            'patch': '@@ -0,0 +1,5 @@\n+new file',
          },
        ],
      };

      final gitDiff = WorkspaceGitDiff.fromJson(json);
      expect(gitDiff.branch, 'feature/git-review');
      expect(gitDiff.filesChanged, 2);
      expect(gitDiff.additions, 25);
      expect(gitDiff.deletions, 5);
      expect(gitDiff.files.length, 2);
      expect(gitDiff.files[0].path, 'file1.py');
      expect(gitDiff.files[1].path, 'file2.py');
      expect(gitDiff.files[1].status, 'added');
    });

    test('WorkspaceGitBranchesResponse parses branch list with active indicator', () {
      final json = {
        'current_branch': 'feat/mobile-diff',
        'branches': [
          {
            'name': 'main',
            'is_current': false,
            'commit_sha': 'a1b2c3d4e5f6',
            'commit_message': 'Initial commit',
          },
          {
            'name': 'feat/mobile-diff',
            'is_current': true,
            'commit_sha': 'f6e5d4c3b2a1',
            'commit_message': 'Add diff review',
          },
        ],
      };

      final branchesResp = WorkspaceGitBranchesResponse.fromJson(json);
      expect(branchesResp.currentBranch, 'feat/mobile-diff');
      expect(branchesResp.branches.length, 2);

      final mainBranch = branchesResp.branches.firstWhere((b) => b.name == 'main');
      expect(mainBranch.isCurrent, isFalse);
      expect(mainBranch.commitSha, 'a1b2c3d4e5f6');

      final featBranch = branchesResp.branches.firstWhere((b) => b.name == 'feat/mobile-diff');
      expect(featBranch.isCurrent, isTrue);
      expect(featBranch.commitMessage, 'Add diff review');
    });

    test('WorkspaceGitCommitResult parses successful commit', () {
      final json = {
        'success': true,
        'commit_sha': '9a8b7c6d5e4f3a2b1c',
        'branch': 'main',
        'message': 'feat: implement git review workflow',
        'files_committed': ['lib/main.dart', 'pubspec.yaml'],
      };

      final commitResult = WorkspaceGitCommitResult.fromJson(json);
      expect(commitResult.success, isTrue);
      expect(commitResult.commitSha, '9a8b7c6d5e4f3a2b1c');
      expect(commitResult.branch, 'main');
      expect(commitResult.message, 'feat: implement git review workflow');
      expect(commitResult.filesCommitted, contains('lib/main.dart'));
      expect(commitResult.filesCommitted, contains('pubspec.yaml'));
    });
  });
}
