import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'auth_api_service.dart';

enum TaskStatusEnum {
  queued,
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
  final DateTime createdAt;
  final DateTime updatedAt;
  final int eventsCount;

  TaskModel({
    required this.id,
    required this.projectId,
    this.workspaceId,
    required this.title,
    required this.prompt,
    required this.status,
    this.activeBranch,
    this.commitSha,
    required this.createdAt,
    required this.updatedAt,
    this.eventsCount = 0,
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
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      eventsCount: json['events_count'] as int? ?? 0,
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
}
