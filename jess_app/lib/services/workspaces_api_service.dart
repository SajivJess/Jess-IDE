import 'dart:convert';
import 'package:http/http.dart' as http;
import 'auth_api_service.dart';

enum WorkspaceStatusEnum {
  pending('PENDING', 'Pending'),
  creating('CREATING', 'Creating'),
  running('RUNNING', 'Running'),
  stopping('STOPPING', 'Stopping'),
  stopped('STOPPED', 'Stopped'),
  failed('FAILED', 'Failed');

  final String value;
  final String label;
  const WorkspaceStatusEnum(this.value, this.label);

  static WorkspaceStatusEnum fromString(String val) {
    for (final s in WorkspaceStatusEnum.values) {
      if (s.value.toUpperCase() == val.toUpperCase()) return s;
    }
    return WorkspaceStatusEnum.pending;
  }
}

class WorkspaceModel {
  final String id;
  final String? projectId;
  final String name;
  final WorkspaceStatusEnum status;
  final String? containerId;
  final String? imageName;
  final String? rootPath;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  WorkspaceModel({
    required this.id,
    this.projectId,
    required this.name,
    required this.status,
    this.containerId,
    this.imageName,
    this.rootPath,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  factory WorkspaceModel.fromJson(Map<String, dynamic> json) {
    return WorkspaceModel(
      id: json['id'] as String? ?? '',
      projectId: json['project_id'] as String?,
      name: json['name'] as String? ?? 'Workspace',
      status: WorkspaceStatusEnum.fromString(json['status'] as String? ?? 'PENDING'),
      containerId: json['container_id'] as String?,
      imageName: json['image_name'] as String?,
      rootPath: json['root_path'] as String?,
      errorMessage: json['error_message'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class WorkspaceCommandResult {
  final bool success;
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
  final double durationSeconds;
  final String? errorMessage;

  WorkspaceCommandResult({
    required this.success,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.timedOut,
    required this.durationSeconds,
    this.errorMessage,
  });

  factory WorkspaceCommandResult.fromJson(Map<String, dynamic> json) {
    return WorkspaceCommandResult(
      success: (json['exit_code'] as int? ?? 1) == 0,
      exitCode: json['exit_code'] as int? ?? -1,
      stdout: json['stdout'] as String? ?? '',
      stderr: json['stderr'] as String? ?? '',
      timedOut: json['timed_out'] as bool? ?? false,
      durationSeconds: (json['duration_seconds'] as num? ?? 0.0).toDouble(),
    );
  }
}

class WorkspaceFileItem {
  final String name;
  final String path;
  final bool isDirectory;
  final int sizeBytes;

  WorkspaceFileItem({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.sizeBytes,
  });

  factory WorkspaceFileItem.fromJson(Map<String, dynamic> json) {
    return WorkspaceFileItem(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      isDirectory: json['is_directory'] as bool? ?? false,
      sizeBytes: json['size_bytes'] as int? ?? 0,
    );
  }
}

class WorkspaceGitStatus {
  final String branch;
  final bool isClean;
  final List<String> modifiedFiles;
  final List<String> untrackedFiles;
  final List<String> stagedFiles;

  WorkspaceGitStatus({
    required this.branch,
    required this.isClean,
    required this.modifiedFiles,
    required this.untrackedFiles,
    required this.stagedFiles,
  });

  factory WorkspaceGitStatus.fromJson(Map<String, dynamic> json) {
    return WorkspaceGitStatus(
      branch: json['branch'] as String? ?? 'main',
      isClean: json['is_clean'] as bool? ?? true,
      modifiedFiles: (json['modified_files'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      untrackedFiles: (json['untracked_files'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      stagedFiles: (json['staged_files'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}

class WorkspaceGitFileDiff {
  final String path;
  final String status; // "modified", "added", "deleted"
  final int additions;
  final int deletions;
  final String patch;

  WorkspaceGitFileDiff({
    required this.path,
    required this.status,
    this.additions = 0,
    this.deletions = 0,
    this.patch = '',
  });

  factory WorkspaceGitFileDiff.fromJson(Map<String, dynamic> json) {
    return WorkspaceGitFileDiff(
      path: json['path'] as String? ?? 'file',
      status: json['status'] as String? ?? 'modified',
      additions: json['additions'] as int? ?? 0,
      deletions: json['deletions'] as int? ?? 0,
      patch: json['patch'] as String? ?? '',
    );
  }
}

class WorkspaceGitDiff {
  final String branch;
  final String diff;
  final int filesChanged;
  final int additions;
  final int deletions;
  final List<WorkspaceGitFileDiff> files;
  final List<Map<String, dynamic>> changedFiles;

  WorkspaceGitDiff({
    required this.branch,
    required this.diff,
    required this.filesChanged,
    this.additions = 0,
    this.deletions = 0,
    this.files = const [],
    this.changedFiles = const [],
  });

  factory WorkspaceGitDiff.fromJson(Map<String, dynamic> json) {
    final parsedFiles = (json['files'] as List<dynamic>?)
            ?.map((e) => WorkspaceGitFileDiff.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return WorkspaceGitDiff(
      branch: json['branch'] as String? ?? 'main',
      diff: json['diff'] as String? ?? '',
      filesChanged: json['files_changed'] as int? ?? parsedFiles.length,
      additions: json['additions'] as int? ?? 0,
      deletions: json['deletions'] as int? ?? 0,
      files: parsedFiles,
      changedFiles: (json['changed_files'] as List<dynamic>?)?.filterMapJson() ?? [],
    );
  }
}

class WorkspaceGitBranchItem {
  final String name;
  final bool isCurrent;
  final String? commitSha;
  final String? commitMessage;

  WorkspaceGitBranchItem({
    required this.name,
    this.isCurrent = false,
    this.commitSha,
    this.commitMessage,
  });

  factory WorkspaceGitBranchItem.fromJson(Map<String, dynamic> json) {
    return WorkspaceGitBranchItem(
      name: json['name'] as String? ?? 'main',
      isCurrent: json['is_current'] as bool? ?? false,
      commitSha: json['commit_sha'] as String?,
      commitMessage: json['commit_message'] as String?,
    );
  }
}

class WorkspaceGitBranchesResponse {
  final String currentBranch;
  final List<WorkspaceGitBranchItem> branches;

  WorkspaceGitBranchesResponse({
    required this.currentBranch,
    required this.branches,
  });

  factory WorkspaceGitBranchesResponse.fromJson(Map<String, dynamic> json) {
    final branchList = (json['branches'] as List<dynamic>?)
            ?.map((e) => WorkspaceGitBranchItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return WorkspaceGitBranchesResponse(
      currentBranch: json['current_branch'] as String? ?? 'main',
      branches: branchList,
    );
  }
}

class WorkspaceGitCommitResult {
  final bool success;
  final String commitSha;
  final String branch;
  final String message;
  final List<String> filesCommitted;
  final String? errorMessage;

  WorkspaceGitCommitResult({
    required this.success,
    required this.commitSha,
    required this.branch,
    required this.message,
    this.filesCommitted = const [],
    this.errorMessage,
  });

  factory WorkspaceGitCommitResult.fromJson(Map<String, dynamic> json) {
    return WorkspaceGitCommitResult(
      success: true,
      commitSha: json['commit_sha'] as String? ?? '',
      branch: json['branch'] as String? ?? 'main',
      message: json['message'] as String? ?? '',
      filesCommitted: (json['files_committed'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}

extension _DynamicListExtension on List<dynamic> {
  List<Map<String, dynamic>> filterMapJson() {
    return whereType<Map<String, dynamic>>().toList();
  }
}

class WorkspacesApiService {
  static final http.Client _client = http.Client();

  static Map<String, String> _headers() {
    final headers = {'Content-Type': 'application/json'};
    final token = AuthApiService.currentAccessToken;
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  /// List workspaces for a project
  static Future<List<WorkspaceModel>> listWorkspaces(String projectId) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces');
      final res = await _client.get(url, headers: _headers());
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List<dynamic>;
        return data.map((e) => WorkspaceModel.fromJson(e as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Provision a new workspace for a project
  static Future<WorkspaceModel?> provisionWorkspace(
    String projectId, {
    String? name,
    String? imageName,
  }) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces');
      final body = <String, dynamic>{
        'name': name ?? 'Project Workspace',
      };
      if (imageName != null) {
        body['image_name'] = imageName;
      }

      final res = await _client.post(
        url,
        headers: _headers(),
        body: jsonEncode(body),
      );

      if (res.statusCode == 201 || res.statusCode == 200) {
        return WorkspaceModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Start a stopped workspace
  static Future<WorkspaceModel?> startWorkspace(String projectId, String workspaceId) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/start');
      final res = await _client.post(url, headers: _headers());
      if (res.statusCode == 200) {
        return WorkspaceModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Stop a running workspace
  static Future<WorkspaceModel?> stopWorkspace(String projectId, String workspaceId) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/stop');
      final res = await _client.post(url, headers: _headers());
      if (res.statusCode == 200) {
        return WorkspaceModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Restart a workspace
  static Future<WorkspaceModel?> restartWorkspace(String projectId, String workspaceId) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/restart');
      final res = await _client.post(url, headers: _headers());
      if (res.statusCode == 200) {
        return WorkspaceModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Run a safe structured command inside the workspace
  static Future<WorkspaceCommandResult> runCommand(
    String projectId,
    String workspaceId,
    List<String> command, {
    int timeoutSeconds = 60,
  }) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/commands/run');
      final res = await _client.post(
        url,
        headers: _headers(),
        body: jsonEncode({
          'command': command,
          'timeout_seconds': timeoutSeconds,
        }),
      );

      if (res.statusCode == 200) {
        return WorkspaceCommandResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      } else {
        final err = jsonDecode(res.body);
        return WorkspaceCommandResult(
          success: false,
          exitCode: -1,
          stdout: '',
          stderr: err['detail']?.toString() ?? 'Command failed',
          timedOut: false,
          durationSeconds: 0,
          errorMessage: err['detail']?.toString(),
        );
      }
    } catch (e) {
      return WorkspaceCommandResult(
        success: false,
        exitCode: -1,
        stdout: '',
        stderr: e.toString(),
        timedOut: false,
        durationSeconds: 0,
        errorMessage: e.toString(),
      );
    }
  }

  /// List files inside workspace directory
  static Future<List<WorkspaceFileItem>> listFiles(
    String projectId,
    String workspaceId, {
    String path = '',
  }) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/files').replace(
        queryParameters: {'path': path},
      );
      final res = await _client.get(url, headers: _headers());
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final items = data['items'] as List<dynamic>? ?? [];
        return items.map((e) => WorkspaceFileItem.fromJson(e as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Read file content from workspace
  static Future<String?> readFile(String projectId, String workspaceId, String path) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/files/read').replace(
        queryParameters: {'path': path},
      );
      final res = await _client.get(url, headers: _headers());
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['content'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Write file content into workspace
  static Future<bool> writeFile(String projectId, String workspaceId, String path, String content) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/files/write');
      final res = await _client.post(
        url,
        headers: _headers(),
        body: jsonEncode({
          'path': path,
          'content': content,
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Inspect Git branch and working-tree status
  static Future<WorkspaceGitStatus?> getGitStatus(String projectId, String workspaceId) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/git/status');
      final res = await _client.get(url, headers: _headers());
      if (res.statusCode == 200) {
        return WorkspaceGitStatus.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Inspect Git diff
  static Future<WorkspaceGitDiff?> getGitDiff(String projectId, String workspaceId) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/git/diff');
      final res = await _client.get(url, headers: _headers());
      if (res.statusCode == 200) {
        return WorkspaceGitDiff.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// List Git branches in workspace
  static Future<WorkspaceGitBranchesResponse?> getGitBranches(
    String projectId,
    String workspaceId,
  ) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/git/branches');
      final res = await _client.get(url, headers: _headers());
      if (res.statusCode == 200) {
        return WorkspaceGitBranchesResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Switch or create Git branch in workspace
  static Future<WorkspaceGitStatus?> checkoutBranch(
    String projectId,
    String workspaceId,
    String branch, {
    bool createNew = false,
  }) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/git/branches/checkout');
      final res = await _client.post(
        url,
        headers: _headers(),
        body: jsonEncode({
          'branch': branch,
          'create_new': createNew,
        }),
      );
      if (res.statusCode == 200) {
        return WorkspaceGitStatus.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Stage and commit working tree changes in workspace
  static Future<WorkspaceGitCommitResult?> commitChanges(
    String projectId,
    String workspaceId,
    String message,
  ) async {
    try {
      final url = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/workspaces/$workspaceId/git/commit');
      final res = await _client.post(
        url,
        headers: _headers(),
        body: jsonEncode({'message': message}),
      );
      if (res.statusCode == 200) {
        return WorkspaceGitCommitResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return WorkspaceGitCommitResult(
        success: false,
        commitSha: '',
        branch: '',
        message: message,
        errorMessage: 'Commit failed with status ${res.statusCode}',
      );
    } catch (e) {
      return WorkspaceGitCommitResult(
        success: false,
        commitSha: '',
        branch: '',
        message: message,
        errorMessage: e.toString(),
      );
    }
  }
}
