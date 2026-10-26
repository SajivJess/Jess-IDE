class AgentEventModel {
  final String schemaVersion;
  final String type;
  final String eventId;
  final String conversationId;
  final String? runId;
  final int sequence;
  final DateTime createdAt;
  final Map<String, dynamic> data;

  AgentEventModel({
    required this.schemaVersion,
    required this.type,
    required this.eventId,
    required this.conversationId,
    this.runId,
    required this.sequence,
    required this.createdAt,
    required this.data,
  });

  factory AgentEventModel.fromJson(Map<String, dynamic> json) {
    return AgentEventModel(
      schemaVersion: json['schema_version'] as String? ?? '1.0',
      type: json['type'] as String? ?? '',
      eventId: json['event_id'] as String? ?? '',
      conversationId: json['conversation_id'] as String? ?? '',
      runId: json['run_id'] as String?,
      sequence: json['sequence'] as int? ?? 0,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      data: (json['data'] as Map<String, dynamic>?) ?? {},
    );
  }
}

class ConversationModel {
  final String id;
  final String projectId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int messagesCount;
  final int runsCount;

  ConversationModel({
    required this.id,
    required this.projectId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.messagesCount = 0,
    this.runsCount = 0,
  });

  factory ConversationModel.fromJson(Map<String, dynamic> json) {
    return ConversationModel(
      id: json['id'] as String? ?? '',
      projectId: json['project_id'] as String? ?? '',
      title: json['title'] as String? ?? 'Coding Session',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      messagesCount: json['messages_count'] as int? ?? 0,
      runsCount: json['runs_count'] as int? ?? 0,
    );
  }
}

class ConversationMessageModel {
  final String id;
  final String conversationId;
  final String? runId;
  final String role; // "user", "assistant", "system"
  final String content;
  final DateTime createdAt;

  ConversationMessageModel({
    required this.id,
    required this.conversationId,
    this.runId,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  factory ConversationMessageModel.fromJson(Map<String, dynamic> json) {
    return ConversationMessageModel(
      id: json['id'] as String? ?? '',
      conversationId: json['conversation_id'] as String? ?? '',
      runId: json['run_id'] as String?,
      role: json['role'] as String? ?? 'user',
      content: json['content'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class AgentRunModel {
  final String id;
  final String projectId;
  final String conversationId;
  final String status;
  final String prompt;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  AgentRunModel({
    required this.id,
    required this.projectId,
    required this.conversationId,
    required this.status,
    required this.prompt,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AgentRunModel.fromJson(Map<String, dynamic> json) {
    return AgentRunModel(
      id: json['id'] as String? ?? '',
      projectId: json['project_id'] as String? ?? '',
      conversationId: json['conversation_id'] as String? ?? '',
      status: json['status'] as String? ?? 'QUEUED',
      prompt: json['prompt'] as String? ?? '',
      title: json['title'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class ChatMessageResponseModel {
  final ConversationMessageModel userMessage;
  final String intent;
  final ConversationMessageModel? assistantMessage;
  final AgentRunModel? run;

  ChatMessageResponseModel({
    required this.userMessage,
    required this.intent,
    this.assistantMessage,
    this.run,
  });

  factory ChatMessageResponseModel.fromJson(Map<String, dynamic> json) {
    return ChatMessageResponseModel(
      userMessage: ConversationMessageModel.fromJson(
        json['user_message'] as Map<String, dynamic>,
      ),
      intent: json['intent'] as String? ?? 'CONVERSATION',
      assistantMessage: json['assistant_message'] != null
          ? ConversationMessageModel.fromJson(
              json['assistant_message'] as Map<String, dynamic>,
            )
          : null,
      run: json['run'] != null
          ? AgentRunModel.fromJson(json['run'] as Map<String, dynamic>)
          : null,
    );
  }
}

