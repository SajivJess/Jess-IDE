import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/agent_event.dart';
import 'auth_api_service.dart';

class ConversationsApiService {
  ConversationsApiService._();

  static Map<String, String> _headers() {
    final token = AuthApiService.currentAccessToken;
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// List conversations for a project (creates default if empty)
  static asyncFetchConversations(String projectId) => listConversations(projectId);

  static Future<List<ConversationModel>> listConversations(String projectId) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/conversations');
      final res = await http.get(uri, headers: _headers());
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final items = (data['items'] as List<dynamic>?) ?? [];
        return items.map((e) => ConversationModel.fromJson(e as Map<String, dynamic>)).toList();
      }
      debugPrint('[ConversationsApiService] listConversations status: ${res.statusCode}');
      return [];
    } catch (e) {
      debugPrint('[ConversationsApiService] listConversations error: $e');
      return [];
    }
  }

  /// Create a new conversation
  static Future<ConversationModel?> createConversation(
    String projectId, {
    String title = 'Coding Session',
  }) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/conversations');
      final res = await http.post(
        uri,
        headers: _headers(),
        body: jsonEncode({'title': title}),
      );
      if (res.statusCode == 201) {
        return ConversationModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      debugPrint('[ConversationsApiService] createConversation error: $e');
      return null;
    }
  }

  /// Fetch message history for a conversation
  static Future<List<ConversationMessageModel>> getMessages(
    String projectId,
    String conversationId,
  ) async {
    try {
      final uri = Uri.parse(
        '${AuthApiService.baseUrl}/projects/$projectId/conversations/$conversationId/messages',
      );
      final res = await http.get(uri, headers: _headers());
      if (res.statusCode == 200) {
        final items = jsonDecode(res.body) as List<dynamic>;
        return items
            .map((e) => ConversationMessageModel.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      debugPrint('[ConversationsApiService] getMessages error: $e');
      return [];
    }
  }

  /// Send a message into conversation with backend intent routing
  static Future<ChatMessageResponseModel?> sendMessage(
    String projectId,
    String conversationId,
    String content,
  ) async {
    try {
      final uri = Uri.parse(
        '${AuthApiService.baseUrl}/projects/$projectId/conversations/$conversationId/messages',
      );
      final res = await http.post(
        uri,
        headers: _headers(),
        body: jsonEncode({'content': content}),
      );
      if (res.statusCode == 201) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return ChatMessageResponseModel.fromJson(data);
      }
      debugPrint('[ConversationsApiService] sendMessage failed: ${res.statusCode} ${res.body}');
      return null;
    } catch (e) {
      debugPrint('[ConversationsApiService] sendMessage error: $e');
      return null;
    }
  }

  /// Start an agent run in a conversation
  static Future<AgentRunModel?> startRun(
    String projectId,
    String conversationId,
    String prompt, {
    String? title,
  }) async {
    try {
      final uri = Uri.parse(
        '${AuthApiService.baseUrl}/projects/$projectId/conversations/$conversationId/runs',
      );
      final res = await http.post(
        uri,
        headers: _headers(),
        body: jsonEncode({
          'prompt': prompt,
          if (title != null && title.isNotEmpty) 'title': title,
        }),
      );
      if (res.statusCode == 201) {
        return AgentRunModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      debugPrint('[ConversationsApiService] startRun failed: ${res.statusCode} ${res.body}');
      return null;
    } catch (e) {
      debugPrint('[ConversationsApiService] startRun error: $e');
      return null;
    }
  }

  /// Replay events after a sequence number
  static Future<List<AgentEventModel>> replayEvents(
    String projectId,
    String conversationId,
    int afterSequence,
  ) async {
    try {
      final uri = Uri.parse(
        '${AuthApiService.baseUrl}/projects/$projectId/conversations/$conversationId/events?after=$afterSequence',
      );
      final res = await http.get(uri, headers: _headers());
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final items = (data['items'] as List<dynamic>?) ?? [];
        return items.map((e) => AgentEventModel.fromJson(e as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('[ConversationsApiService] replayEvents error: $e');
      return [];
    }
  }

  /// Submit user decision for an approval gate
  static Future<bool> submitApproval(
    String projectId,
    String runId, {
    required bool approve,
    String? reason,
  }) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/runs/$runId/approval');
      final res = await http.post(
        uri,
        headers: _headers(),
        body: jsonEncode({
          'action': approve ? 'approve' : 'reject',
          if (reason != null) 'reason': reason,
        }),
      );
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[ConversationsApiService] submitApproval error: $e');
      return false;
    }
  }

  /// Request run cancellation
  static Future<bool> cancelRun(String projectId, String runId) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/runs/$runId/cancel');
      final res = await http.post(uri, headers: _headers());
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[ConversationsApiService] cancelRun error: $e');
      return false;
    }
  }

  /// Fetch run status
  static Future<AgentRunModel?> getRun(String projectId, String runId) async {
    try {
      final uri = Uri.parse('${AuthApiService.baseUrl}/projects/$projectId/runs/$runId');
      final res = await http.get(uri, headers: _headers());
      if (res.statusCode == 200) {
        return AgentRunModel.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      debugPrint('[ConversationsApiService] getRun error: $e');
      return null;
    }
  }
}
