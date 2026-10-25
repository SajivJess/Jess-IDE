import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'auth_api_service.dart';

class ProjectModel {
  final String id;
  final String userId;
  final String name;
  final String? description;
  final String sourceType;
  final String? repoUrl;
  final String defaultBranch;
  final String? workspacePath;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int taskCount;

  ProjectModel({
    required this.id,
    required this.userId,
    required this.name,
    this.description,
    required this.sourceType,
    this.repoUrl,
    required this.defaultBranch,
    this.workspacePath,
    required this.createdAt,
    required this.updatedAt,
    this.taskCount = 0,
  });

  factory ProjectModel.fromJson(Map<String, dynamic> json) {
    return ProjectModel(
      id: json['id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      name: json['name'] as String? ?? 'Untitled Project',
      description: json['description'] as String?,
      sourceType: json['source_type'] as String? ?? 'local',
      repoUrl: json['repo_url'] as String?,
      defaultBranch: json['default_branch'] as String? ?? 'main',
      workspacePath: json['workspace_path'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      taskCount: json['task_count'] as int? ?? 0,
    );
  }
}

class ProjectsListResult {
  final bool success;
  final List<ProjectModel> items;
  final int total;
  final String? errorMessage;
  final bool isAuthExpired;

  ProjectsListResult({
    required this.success,
    this.items = const [],
    this.total = 0,
    this.errorMessage,
    this.isAuthExpired = false,
  });
}

class ProjectResult {
  final bool success;
  final ProjectModel? project;
  final String? errorMessage;

  ProjectResult({
    required this.success,
    this.project,
    this.errorMessage,
  });
}

class ProjectsApiService {
  static final http.Client _client = http.Client();

  /// In-memory cache of loaded projects
  static List<ProjectModel> cachedProjects = [];

  static Map<String, String> _headers() {
    final headers = {'Content-Type': 'application/json'};
    final token = AuthApiService.currentAccessToken;
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  /// List user-owned projects with optional filtering and search
  static Future<ProjectsListResult> listProjects({
    int skip = 0,
    int limit = 50,
    String? sourceType,
    String? search,
  }) async {
    try {
      final queryParams = <String, String>{
        'skip': skip.toString(),
        'limit': limit.toString(),
      };
      if (sourceType != null && sourceType.isNotEmpty && sourceType != 'all') {
        queryParams['source_type'] = sourceType.toLowerCase();
      }
      if (search != null && search.trim().isNotEmpty) {
        queryParams['search'] = search.trim();
      }

      final uri = Uri.parse('${AuthApiService.baseUrl}/projects').replace(
        queryParameters: queryParams,
      );

      final response = await _client
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rawItems = data['items'] as List<dynamic>? ?? [];
        final items = rawItems
            .map((i) => ProjectModel.fromJson(i as Map<String, dynamic>))
            .toList();
        final total = data['total'] as int? ?? items.length;

        if (skip == 0 && (sourceType == null || sourceType == 'all') && (search == null || search.isEmpty)) {
          cachedProjects = items;
        }

        return ProjectsListResult(
          success: true,
          items: items,
          total: total,
        );
      } else if (response.statusCode == 401) {
        return ProjectsListResult(
          success: false,
          errorMessage: 'Session expired. Please sign in again.',
          isAuthExpired: true,
        );
      } else {
        final errorMsg = _extractError(response.body);
        return ProjectsListResult(success: false, errorMessage: errorMsg);
      }
    } catch (e) {
      if (kDebugMode) print('ProjectsApiService.listProjects error: $e');
      if (AuthApiService.baseUrl.contains('127.0.0.1')) {
        try {
          AuthApiService.baseUrl = 'http://172.30.17.207:8000/api/v1';
          return listProjects(skip: skip, limit: limit, sourceType: sourceType, search: search);
        } catch (_) {}
      }
      return ProjectsListResult(
        success: false,
        errorMessage: 'Unable to connect to backend server. Operating offline.',
      );
    }
  }

  /// Get project by ID
  static Future<ProjectResult> getProject(String projectId) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId');
      final response = await _client
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final project = ProjectModel.fromJson(data);
        return ProjectResult(success: true, project: project);
      } else {
        return ProjectResult(
          success: false,
          errorMessage: _extractError(response.body),
        );
      }
    } catch (e) {
      if (kDebugMode) print('ProjectsApiService.getProject error: $e');
      return ProjectResult(
        success: false,
        errorMessage: 'Unable to reach backend server.',
      );
    }
  }

  /// Create a new project metadata record
  static Future<ProjectResult> createProject({
    required String name,
    String? description,
    String sourceType = 'local',
    String? repoUrl,
    String defaultBranch = 'main',
    String? workspacePath,
  }) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects');
      final response = await _client
          .post(
            uri,
            headers: _headers(),
            body: jsonEncode({
              'name': name.trim(),
              'description': description?.trim(),
              'source_type': sourceType.toLowerCase(),
              'repo_url': repoUrl?.trim(),
              'default_branch': defaultBranch.trim().isEmpty ? 'main' : defaultBranch.trim(),
              'workspace_path': workspacePath?.trim(),
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final project = ProjectModel.fromJson(data);
        cachedProjects.insert(0, project);
        return ProjectResult(success: true, project: project);
      } else {
        return ProjectResult(
          success: false,
          errorMessage: _extractError(response.body),
        );
      }
    } catch (e) {
      if (kDebugMode) print('ProjectsApiService.createProject error: $e');
      return ProjectResult(
        success: false,
        errorMessage: 'Network error creating project. Please check server connectivity.',
      );
    }
  }

  /// Delete a project by ID
  static Future<bool> deleteProject(String projectId) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId');
      final response = await _client
          .delete(uri, headers: _headers())
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        cachedProjects.removeWhere((p) => p.id == projectId);
        return true;
      }
      return false;
    } catch (e) {
      if (kDebugMode) print('ProjectsApiService.deleteProject error: $e');
      return false;
    }
  }

  static String _extractError(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data.containsKey('detail')) {
        final detail = data['detail'];
        if (detail is String) return detail;
        if (detail is List && detail.isNotEmpty) {
          final first = detail[0];
          if (first is Map && first.containsKey('msg')) {
            return first['msg'].toString();
          }
        }
      }
      if (data.containsKey('error')) return data['error'].toString();
    } catch (_) {}
    return 'Operation failed on server.';
  }
}
