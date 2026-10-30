import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'auth_api_service.dart';

enum TaskStatusEnum {
  queued,
  contractProposed,
  contractApproved,
  running,
  approvalRequired,
  completed,
  failed,
  cancelled,
  unknown;

  static TaskStatusEnum fromString(String val) {
    switch (val.toUpperCase()) {
      case 'QUEUED':
        return TaskStatusEnum.queued;
      case 'CONTRACT_PROPOSED':
        return TaskStatusEnum.contractProposed;
      case 'CONTRACT_APPROVED':
        return TaskStatusEnum.contractApproved;
      case 'RUNNING':
        return TaskStatusEnum.running;
      case 'APPROVAL_REQUIRED':
        return TaskStatusEnum.approvalRequired;
      case 'COMPLETED':
        return TaskStatusEnum.completed;
      case 'FAILED':
        return TaskStatusEnum.failed;
      case 'CANCELLED':
        return TaskStatusEnum.cancelled;
      default:
        return TaskStatusEnum.unknown;
    }
  }

  String get label {
    switch (this) {
      case TaskStatusEnum.queued:
        return 'Queued';
      case TaskStatusEnum.contractProposed:
        return 'Contract Review';
      case TaskStatusEnum.contractApproved:
        return 'Contract Approved';
      case TaskStatusEnum.running:
        return 'Running';
      case TaskStatusEnum.approvalRequired:
        return 'Approval Required';
      case TaskStatusEnum.completed:
        return 'Completed';
      case TaskStatusEnum.failed:
        return 'Failed';
      case TaskStatusEnum.cancelled:
        return 'Cancelled';
      case TaskStatusEnum.unknown:
        return 'Unknown';
    }
  }
}

class TaskModel {
  final String id;
  final String projectId;
  final String? workspaceId;
  final String title;
  final String prompt;
  final TaskStatusEnum status;
  final String? activeBranch;
  final String? commitSha;
  final String? executionLog;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int eventsCount;
  final Map<String, dynamic>? contract;
  final Map<String, dynamic>? verification;
  final bool requireContract;

  TaskModel({
    required this.id,
    required this.projectId,
    this.workspaceId,
    required this.title,
    required this.prompt,
    required this.status,
    this.activeBranch,
    this.commitSha,
    this.executionLog,
    required this.createdAt,
    required this.updatedAt,
    this.eventsCount = 0,
    this.contract,
    this.verification,
    this.requireContract = false,
  });

  factory TaskModel.fromJson(Map<String, dynamic> json) {
    return TaskModel(
      id: json['id'] as String? ?? '',
      projectId: json['project_id'] as String? ?? '',
      workspaceId: json['workspace_id'] as String?,
      title: json['title'] as String? ?? 'Untitled Task',
      prompt: json['prompt'] as String? ?? '',
      status: TaskStatusEnum.fromString(json['status'] as String? ?? ''),
      activeBranch: json['active_branch'] as String?,
      commitSha: json['commit_sha'] as String?,
      executionLog: json['execution_log'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      eventsCount: json['events_count'] as int? ?? 0,
      contract: json['contract'] as Map<String, dynamic>?,
      verification: json['verification'] as Map<String, dynamic>?,
      requireContract: json['require_contract'] as bool? ?? false,
    );
  }
}

class AcceptanceCriterionModel {
  final String id;
  final String description;
  final bool verified;
  final String? evidenceNote;

  AcceptanceCriterionModel({
    required this.id,
    required this.description,
    this.verified = false,
    this.evidenceNote,
  });

  factory AcceptanceCriterionModel.fromJson(Map<String, dynamic> json) {
    return AcceptanceCriterionModel(
      id: json['id'] as String? ?? '',
      description: json['description'] as String? ?? '',
      verified: json['verified'] as bool? ?? false,
      evidenceNote: json['evidence_note'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'verified': verified,
    if (evidenceNote != null) 'evidence_note': evidenceNote,
  };
}

class TaskContractModel {
  final String taskId;
  final int contractVersion;
  final String summary;
  final List<AcceptanceCriterionModel> criteria;
  final List<String> allowedFiles;
  final bool allowNewFiles;
  final List<String> protectedFiles;
  final List<String> testCommands;
  final List<String> ambiguities;
  final bool isApprovedByUser;
  final String? contractHash;
  final DateTime? approvedAt;

  TaskContractModel({
    required this.taskId,
    this.contractVersion = 1,
    required this.summary,
    required this.criteria,
    required this.allowedFiles,
    this.allowNewFiles = true,
    this.protectedFiles = const ['auth.py', '.env', 'config.py', 'database.py'],
    this.testCommands = const ['python -m unittest'],
    this.ambiguities = const [],
    this.isApprovedByUser = false,
    this.contractHash,
    this.approvedAt,
  });

  factory TaskContractModel.fromJson(Map<String, dynamic> json) {
    final criteriaRaw = json['criteria'] as List<dynamic>? ?? [];
    return TaskContractModel(
      taskId: json['task_id'] as String? ?? '',
      contractVersion: json['contract_version'] as int? ?? 1,
      summary: json['summary'] as String? ?? '',
      criteria: criteriaRaw
          .map((c) => AcceptanceCriterionModel.fromJson(c as Map<String, dynamic>))
          .toList(),
      allowedFiles: (json['allowed_files'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      allowNewFiles: json['allow_new_files'] as bool? ?? true,
      protectedFiles: (json['protected_files'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      testCommands: (json['test_commands'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      ambiguities: (json['ambiguities'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      isApprovedByUser: json['is_approved_by_user'] as bool? ?? false,
      contractHash: json['contract_hash'] as String?,
      approvedAt: json['approved_at'] != null
          ? DateTime.tryParse(json['approved_at'] as String)
          : null,
    );
  }
}

class CommandEvidenceModel {
  final String command;
  final int exitCode;
  final int durationMs;
  final String stdoutSnippet;
  final String? stderrSnippet;
  final String status;

  CommandEvidenceModel({
    required this.command,
    required this.exitCode,
    required this.durationMs,
    required this.stdoutSnippet,
    this.stderrSnippet,
    required this.status,
  });

  factory CommandEvidenceModel.fromJson(Map<String, dynamic> json) {
    return CommandEvidenceModel(
      command: json['command'] as String? ?? '',
      exitCode: json['exit_code'] as int? ?? 0,
      durationMs: json['duration_ms'] as int? ?? 0,
      stdoutSnippet: json['stdout_snippet'] as String? ?? '',
      stderrSnippet: json['stderr_snippet'] as String?,
      status: json['status'] as String? ?? 'PASSED',
    );
  }
}

class BreakItCheckModel {
  final String name;
  final String inputDescription;
  final String expectedBehavior;
  final String actualBehavior;
  final bool passed;

  BreakItCheckModel({
    required this.name,
    required this.inputDescription,
    required this.expectedBehavior,
    required this.actualBehavior,
    required this.passed,
  });

  factory BreakItCheckModel.fromJson(Map<String, dynamic> json) {
    return BreakItCheckModel(
      name: json['name'] as String? ?? '',
      inputDescription: json['input_description'] as String? ?? '',
      expectedBehavior: json['expected_behavior'] as String? ?? '',
      actualBehavior: json['actual_behavior'] as String? ?? '',
      passed: json['passed'] as bool? ?? false,
    );
  }
}

class VerificationEvidenceModel {
  final String taskId;
  final String scopeStatus;
  final List<String> unexpectedFilesModified;
  final List<String> protectedFilesViolated;
  final List<CommandEvidenceModel> commandRuns;
  final List<BreakItCheckModel> breakItChecks;
  final Map<String, dynamic> diffStat;
  final bool allCriteriaMet;
  final String overallVerdict;

  VerificationEvidenceModel({
    required this.taskId,
    required this.scopeStatus,
    this.unexpectedFilesModified = const [],
    this.protectedFilesViolated = const [],
    this.commandRuns = const [],
    this.breakItChecks = const [],
    this.diffStat = const {},
    this.allCriteriaMet = false,
    this.overallVerdict = 'PENDING',
  });

  factory VerificationEvidenceModel.fromJson(Map<String, dynamic> json) {
    final cmds = json['command_runs'] as List<dynamic>? ?? [];
    final breaks = json['break_it_checks'] as List<dynamic>? ?? [];
    return VerificationEvidenceModel(
      taskId: json['task_id'] as String? ?? '',
      scopeStatus: json['scope_status'] as String? ?? 'CLEAN',
      unexpectedFilesModified: (json['unexpected_files_modified'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      protectedFilesViolated: (json['protected_files_violated'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      commandRuns: cmds
          .map((c) => CommandEvidenceModel.fromJson(c as Map<String, dynamic>))
          .toList(),
      breakItChecks: breaks
          .map((b) => BreakItCheckModel.fromJson(b as Map<String, dynamic>))
          .toList(),
      diffStat: json['diff_stat'] is Map<String, dynamic>
          ? json['diff_stat'] as Map<String, dynamic>
          : {},
      allCriteriaMet: json['all_criteria_met'] as bool? ?? false,
      overallVerdict: json['overall_verdict'] as String? ?? 'PENDING',
    );
  }
}

class TaskEventModel {
  final String id;
  final String taskId;
  final int sequenceNum;
  final String eventType;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  TaskEventModel({
    required this.id,
    required this.taskId,
    required this.sequenceNum,
    required this.eventType,
    required this.payload,
    required this.createdAt,
  });

  factory TaskEventModel.fromJson(Map<String, dynamic> json) {
    return TaskEventModel(
      id: json['id'] as String? ?? '',
      taskId: json['task_id'] as String? ?? '',
      sequenceNum: json['sequence_num'] as int? ?? 0,
      eventType: json['event_type'] as String? ?? '',
      payload: json['payload'] is Map<String, dynamic>
          ? json['payload'] as Map<String, dynamic>
          : {},
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class TaskListResult {
  final bool success;
  final List<TaskModel> items;
  final int total;
  final String? errorMessage;

  TaskListResult({
    required this.success,
    this.items = const [],
    this.total = 0,
    this.errorMessage,
  });
}

class TaskResult {
  final bool success;
  final TaskModel? task;
  final String? errorMessage;

  TaskResult({
    required this.success,
    this.task,
    this.errorMessage,
  });
}

class TaskCancelResult {
  final bool success;
  final String message;
  final String? errorMessage;

  TaskCancelResult({
    required this.success,
    this.message = '',
    this.errorMessage,
  });
}

class TasksApiService {
  static final http.Client _client = http.Client();

  static Map<String, String> _headers() {
    final headers = {'Content-Type': 'application/json'};
    final token = AuthApiService.currentAccessToken;
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  /// Create and queue a new task in a project
  static Future<TaskResult> createTask({
    required String projectId,
    required String title,
    required String prompt,
  }) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/tasks');
      final response = await _client.post(
        uri,
        headers: _headers(),
        body: jsonEncode({
          'title': title.trim(),
          'prompt': prompt.trim(),
        }),
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 201) {
        final task = TaskModel.fromJson(data);
        return TaskResult(success: true, task: task);
      } else {
        final error = data['detail'] ?? data['message'] ?? 'Failed to create task';
        return TaskResult(success: false, errorMessage: error.toString());
      }
    } catch (e) {
      debugPrint('[TasksApiService] createTask error: $e');
      return TaskResult(success: false, errorMessage: 'Network error creating task: $e');
    }
  }

  /// List tasks belonging to a project
  static Future<TaskListResult> listTasks({
    required String projectId,
    int skip = 0,
    int limit = 50,
  }) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/tasks?skip=$skip&limit=$limit');
      final response = await _client.get(uri, headers: _headers());

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        final itemsRaw = data['items'] as List<dynamic>? ?? [];
        final items = itemsRaw
            .map((item) => TaskModel.fromJson(item as Map<String, dynamic>))
            .toList();
        final total = data['total'] as int? ?? items.length;
        return TaskListResult(success: true, items: items, total: total);
      } else {
        final error = data['detail'] ?? 'Failed to load tasks';
        return TaskListResult(success: false, errorMessage: error.toString());
      }
    } catch (e) {
      debugPrint('[TasksApiService] listTasks error: $e');
      return TaskListResult(success: false, errorMessage: 'Network error loading tasks: $e');
    }
  }

  /// Get details for a specific task
  static Future<TaskResult> getTask(String taskId) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/tasks/$taskId');
      final response = await _client.get(uri, headers: _headers());

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        return TaskResult(success: true, task: TaskModel.fromJson(data));
      } else {
        return TaskResult(success: false, errorMessage: data['detail']?.toString() ?? 'Task not found');
      }
    } catch (e) {
      return TaskResult(success: false, errorMessage: 'Network error: $e');
    }
  }

  /// Cancel a running or queued task
  static Future<TaskCancelResult> cancelTask({
    required String projectId,
    required String taskId,
  }) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/tasks/$taskId/cancel');
      final response = await _client.post(uri, headers: _headers());

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        return TaskCancelResult(
          success: true,
          message: data['message'] as String? ?? 'Task cancelled successfully',
        );
      } else {
        return TaskCancelResult(
          success: false,
          errorMessage: data['detail']?.toString() ?? 'Could not cancel task',
        );
      }
    } catch (e) {
      return TaskCancelResult(success: false, errorMessage: 'Network error: $e');
    }
  }

  /// Submit user decision for a task in APPROVAL_REQUIRED status
  static Future<bool> submitApproval({
    required String projectId,
    required String taskId,
    required bool approve,
    String? reason,
  }) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/tasks/$taskId/approve');
      final response = await _client.post(
        uri,
        headers: _headers(),
        body: jsonEncode({
          'action': approve ? 'approve' : 'reject',
          if (reason != null && reason.isNotEmpty) 'reason': reason,
        }),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[TasksApiService] submitApproval error: $e');
      return false;
    }
  }

  /// Convenience helper to approve a pending task
  static Future<bool> approveTask(String projectId, String taskId) =>
      submitApproval(projectId: projectId, taskId: taskId, approve: true);

  /// Convenience helper to reject a pending task
  static Future<bool> rejectTask(String projectId, String taskId, {String? reason}) =>
      submitApproval(projectId: projectId, taskId: taskId, approve: false, reason: reason);

  /// Retrieve replayable event history
  static Future<List<TaskEventModel>> getEvents({
    required String projectId,
    required String taskId,
    int after = 0,
  }) async {
    try {
      final uri = Uri.parse(
        '${AuthApiService.baseUrl}/projects/$projectId/tasks/$taskId/events?after=$after',
      );
      final response = await _client.get(uri, headers: _headers());
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final itemsRaw = data['items'] as List<dynamic>? ?? [];
        return itemsRaw
            .map((item) => TaskEventModel.fromJson(item as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      debugPrint('[TasksApiService] getEvents error: $e');
      return [];
    }
  }

  /// Retrieve proposed or approved task contract
  static Future<TaskContractModel?> getContract({
    required String projectId,
    required String taskId,
  }) async {
    try {
      final uri = Uri.parse(
        '${AuthApiService.baseUrl}/projects/$projectId/tasks/$taskId/contract',
      );
      final response = await _client.get(uri, headers: _headers());
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return TaskContractModel.fromJson(data);
      }
      return null;
    } catch (e) {
      debugPrint('[TasksApiService] getContract error: $e');
      return null;
    }
  }

  /// Submit Gate 1 contract approval decision tied to the current contract hash
  static Future<bool> submitContractApproval({
    required String projectId,
    required String taskId,
    required bool approve,
    required String contractHash,
    String? reason,
  }) async {
    try {
      final uri = Uri.parse(
        '${AuthApiService.baseUrl}/projects/$projectId/tasks/$taskId/contract/approve',
      );
      final response = await _client.post(
        uri,
        headers: _headers(),
        body: jsonEncode({
          'action': approve ? 'approve' : 'reject',
          'contract_hash': contractHash,
          if (reason != null && reason.isNotEmpty) 'reason': reason,
        }),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[TasksApiService] submitContractApproval error: $e');
      return false;
    }
  }

  /// Retrieve actual recorded verification evidence for a task
  static Future<VerificationEvidenceModel?> getVerification({
    required String projectId,
    required String taskId,
  }) async {
    try {
      final uri = Uri.parse(
        '${AuthApiService.baseUrl}/projects/$projectId/tasks/$taskId/verification',
      );
      final response = await _client.get(uri, headers: _headers());
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return VerificationEvidenceModel.fromJson(data);
      }
      return null;
    } catch (e) {
      debugPrint('[TasksApiService] getVerification error: $e');
      return null;
    }
  }
}

