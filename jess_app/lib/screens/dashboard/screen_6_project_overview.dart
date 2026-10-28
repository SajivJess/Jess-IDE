import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';
import '../../services/projects_api_service.dart';
import '../../services/tasks_api_service.dart';
import '../../services/workspaces_api_service.dart';
import '../../models/agent_event.dart';
import '../../services/conversations_api_service.dart';
import '../../services/chat_stream_service.dart';
import '../../widgets/chat/chat_message_bubble.dart';
import '../../widgets/chat/tool_activity_card.dart';
import '../../widgets/chat/approval_request_card.dart';
import '../../widgets/chat/file_changed_card.dart';
import '../../widgets/chat/chat_composer.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/auth_api_service.dart';
import '../../widgets/chat/live_preview_card.dart';
import '../../widgets/chat/agent_progress_card.dart';
import '../../widgets/workspace/workspace_file_editor_dialog.dart';

// Timeline Item Model hierarchy for Conversational Chat
abstract class ChatTimelineItem {
  String id;
  final DateTime timestamp;
  ChatTimelineItem({required this.id, required this.timestamp});
}

class ChatUserMessageItem extends ChatTimelineItem {
  final String content;
  ChatUserMessageItem({required super.id, required super.timestamp, required this.content});
}

class ChatAssistantMessageItem extends ChatTimelineItem {
  String content;
  bool isStreaming;
  String? eventId;

  ChatAssistantMessageItem({
    required super.id,
    required super.timestamp,
    required this.content,
    this.isStreaming = false,
    this.eventId,
  });
}

/// Helper that reconciles assistant messages between WebSocket streaming events
/// and HTTP POST responses with deduplication and state preservation.
class ChatTimelineReconciler {
  /// Handles `message.started` event from WebSocket.
  /// Deduplicates against existing messages (e.g. if HTTP arrived first or repeated event).
  static ChatAssistantMessageItem onMessageStarted({
    required List<ChatTimelineItem> timelineItems,
    required String eventId,
    String? messageId,
    required DateTime createdAt,
  }) {
    final rawMsgId = (messageId != null && messageId.trim().isNotEmpty) ? messageId.trim() : null;
    final effectiveId = rawMsgId ?? eventId;

    // 1. Check if message already exists by canonical ID or event ID
    final existingIndex = timelineItems.indexWhere(
      (item) =>
          item is ChatAssistantMessageItem &&
          (item.id == effectiveId ||
              (rawMsgId != null && item.id == rawMsgId) ||
              (item.eventId != null && item.eventId == eventId)),
    );

    if (existingIndex != -1) {
      final existing = timelineItems[existingIndex] as ChatAssistantMessageItem;
      if (rawMsgId != null && existing.id != rawMsgId) {
        existing.id = rawMsgId;
      }
      existing.eventId ??= eventId;
      return existing;
    }

    final newItem = ChatAssistantMessageItem(
      id: effectiveId,
      timestamp: createdAt,
      content: '',
      isStreaming: true,
      eventId: eventId,
    );
    timelineItems.add(newItem);
    return newItem;
  }

  /// Handles `message.delta` event from WebSocket.
  static ChatAssistantMessageItem onMessageDelta({
    required List<ChatTimelineItem> timelineItems,
    ChatAssistantMessageItem? activeMessage,
    required String eventId,
    String? messageId,
    required String text,
    required DateTime createdAt,
  }) {
    final rawMsgId = (messageId != null && messageId.trim().isNotEmpty) ? messageId.trim() : null;
    final effectiveId = rawMsgId ?? eventId;

    if (activeMessage != null) {
      activeMessage.content += text;
      if (rawMsgId != null && activeMessage.id != rawMsgId) {
        activeMessage.id = rawMsgId;
      }
      return activeMessage;
    }

    final existingIndex = timelineItems.indexWhere(
      (item) =>
          item is ChatAssistantMessageItem &&
          (item.id == effectiveId ||
              (rawMsgId != null && item.id == rawMsgId) ||
              (item.eventId != null && item.eventId == eventId)),
    );

    if (existingIndex != -1) {
      final existing = timelineItems[existingIndex] as ChatAssistantMessageItem;
      existing.content += text;
      if (rawMsgId != null && existing.id != rawMsgId) {
        existing.id = rawMsgId;
      }
      return existing;
    }

    final newItem = ChatAssistantMessageItem(
      id: effectiveId,
      timestamp: createdAt,
      content: text,
      isStreaming: true,
      eventId: eventId,
    );
    timelineItems.add(newItem);
    return newItem;
  }

  /// Handles `message.completed` event from WebSocket idempotently.
  static void onMessageCompleted({
    required List<ChatTimelineItem> timelineItems,
    ChatAssistantMessageItem? activeMessage,
    required String eventId,
    String? messageId,
    String? text,
    required DateTime createdAt,
  }) {
    final rawMsgId = (messageId != null && messageId.trim().isNotEmpty) ? messageId.trim() : null;
    final effectiveId = rawMsgId ?? eventId;

    if (activeMessage != null) {
      activeMessage.isStreaming = false;
      if (text != null && text.isNotEmpty) {
        activeMessage.content = text;
      }
      if (rawMsgId != null && activeMessage.id != rawMsgId) {
        activeMessage.id = rawMsgId;
      }
      return;
    }

    final existingIndex = timelineItems.indexWhere(
      (item) =>
          item is ChatAssistantMessageItem &&
          (item.id == effectiveId ||
              (rawMsgId != null && item.id == rawMsgId) ||
              (item.eventId != null && item.eventId == eventId)),
    );

    if (existingIndex != -1) {
      final existing = timelineItems[existingIndex] as ChatAssistantMessageItem;
      existing.isStreaming = false;
      if (text != null && text.isNotEmpty) {
        existing.content = text;
      }
      if (rawMsgId != null && existing.id != rawMsgId) {
        existing.id = rawMsgId;
      }
    } else if (text != null && text.isNotEmpty) {
      timelineItems.add(
        ChatAssistantMessageItem(
          id: effectiveId,
          timestamp: createdAt,
          content: text,
          isStreaming: false,
          eventId: eventId,
        ),
      );
    }
  }

  /// Handles assistant reply received via HTTP POST response.
  /// Reconciles with provisional WebSocket bubble or adds a single new bubble.
  static void onHttpResponse({
    required List<ChatTimelineItem> timelineItems,
    ChatAssistantMessageItem? activeMessage,
    required ConversationMessageModel assistantMessage,
  }) {
    // 1. Primary check: exact match by canonical DB message ID
    final indexById = timelineItems.indexWhere(
      (item) => item is ChatAssistantMessageItem && item.id == assistantMessage.id,
    );

    if (indexById != -1) {
      // WebSocket arrived first with canonical message ID. Finalize streaming and sync content.
      final existing = timelineItems[indexById] as ChatAssistantMessageItem;
      existing.isStreaming = false;
      if (assistantMessage.content.isNotEmpty) {
        existing.content = assistantMessage.content;
      }
      return;
    }

    // 2. Secondary check: reconcile provisional bubble if WebSocket arrived first with eventId
    // Scoped strictly to the most recent in-flight assistant message for this user turn.
    final provisionalIndex = timelineItems.lastIndexWhere((item) {
      if (item is! ChatAssistantMessageItem) return false;
      final isStreamingCandidate = item.isStreaming || item == activeMessage;
      final isProvisionalEvent = item.eventId != null && item.content.trim() == assistantMessage.content.trim();
      return isStreamingCandidate || isProvisionalEvent;
    });

    if (provisionalIndex != -1) {
      final provisional = timelineItems[provisionalIndex] as ChatAssistantMessageItem;
      provisional.id = assistantMessage.id;
      provisional.content = assistantMessage.content;
      provisional.isStreaming = false;
      return;
    }

    // 3. Brand new message (e.g. HTTP arrived before any WebSocket event)
    timelineItems.add(
      ChatAssistantMessageItem(
        id: assistantMessage.id,
        timestamp: assistantMessage.createdAt,
        content: assistantMessage.content,
        isStreaming: false,
      ),
    );
  }
}

class ChatToolActivityItem extends ChatTimelineItem {
  final String tool;
  final String label;
  String status; // "running", "completed", "failed"
  String? output;
  String? command;
  int? exitCode;
  ChatToolActivityItem({
    required super.id,
    required super.timestamp,
    required this.tool,
    required this.label,
    required this.status,
    this.output,
    this.command,
    this.exitCode,
  });
}

class ChatFileChangedItem extends ChatTimelineItem {
  final String file;
  final String? action;
  final String diff;
  final int additions;
  final int deletions;
  ChatFileChangedItem({
    required super.id,
    required super.timestamp,
    required this.file,
    this.action,
    required this.diff,
    this.additions = 0,
    this.deletions = 0,
  });
}

class ChatApprovalItem extends ChatTimelineItem {
  final String runId;
  final String prompt;
  final String? target;
  final String? action;
  final String? diff;
  final String? branch;
  final String? baseCommit;
  final String? checkCommand;
  final int? checkExitCode;
  final bool? checkPassed;
  bool isStale;
  bool isDecided;
  bool? wasApproved;

  ChatApprovalItem({
    required super.id,
    required super.timestamp,
    required this.runId,
    required this.prompt,
    this.target,
    this.action,
    this.diff,
    this.branch,
    this.baseCommit,
    this.checkCommand,
    this.checkExitCode,
    this.checkPassed,
    this.isStale = false,
    this.isDecided = false,
    this.wasApproved,
  });
}

class ChatPreviewItem extends ChatTimelineItem {
  final String previewUrl;
  final String file;
  final String hostingType;
  final String title;

  ChatPreviewItem({
    required super.id,
    required super.timestamp,
    required this.previewUrl,
    required this.file,
    this.hostingType = 'temp_tunnel',
    this.title = 'Live Web Application',
  });
}

class Screen6ProjectOverview extends StatefulWidget {
  final String? projectId;
  final String projectName;
  final int initialTab;
  final VoidCallback? onOpenChat;
  final VoidCallback? onBrowseFiles;
  final VoidCallback? onReviewChanges;

  const Screen6ProjectOverview({
    super.key,
    this.projectId,
    this.projectName = 'cloudaiagent',
    this.initialTab = 0,
    this.onOpenChat,
    this.onBrowseFiles,
    this.onReviewChanges,
  });

  @override
  State<Screen6ProjectOverview> createState() => _Screen6ProjectOverviewState();
}

class _Screen6ProjectOverviewState extends State<Screen6ProjectOverview>
    with WidgetsBindingObserver {
  int _selectedTab = 0;
  final List<String> _tabs = ['Overview', 'Chat', 'Workspace', 'Changes'];

  // Project & Task State
  String? _projectId;
  ProjectModel? _project;
  List<TaskModel> _tasks = [];
  bool _isLoadingTasks = false;

  // Conversational Agent State
  ConversationModel? _currentConversation;
  ChatStreamService? _chatStreamService;
  StreamSubscription<AgentEventModel>? _chatStreamSub;
  StreamSubscription<ChatStreamStatus>? _chatStatusSub;
  final List<ChatTimelineItem> _timelineItems = [];
  final Map<String, ChatToolActivityItem> _activeTools = {};
  ChatAssistantMessageItem? _activeAssistantMessage;
  final ScrollController _chatScrollController = ScrollController();
  bool _isRunActive = false;
  String? _currentRunId;
  String _chatStatusText = 'Ready';
  ChatStreamStatus _streamStatus = ChatStreamStatus.disconnected;
  int _lastSeenSeq = 0;

  // Phase 6 Workspace State
  WorkspaceModel? _workspace;
  bool _isLoadingWorkspace = false;
  bool _isActingWorkspace = false;
  WorkspaceGitStatus? _gitStatus;
  WorkspaceGitDiff? _gitDiff;
  List<WorkspaceFileItem> _workspaceFiles = [];
  bool _isLoadingFiles = false;

  // Batch 4 Git Review & Branch State
  List<WorkspaceGitBranchItem> _branches = [];
  bool _isLoadingBranches = false;
  String? _selectedDiffFile;
  bool _isCommitting = false;

  // Terminal Runner State
  final TextEditingController _cmdController = TextEditingController(text: 'git status');
  final TextEditingController _chatInputController = TextEditingController();
  bool _isRunningCommand = false;
  WorkspaceCommandResult? _lastCommandResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedTab = widget.initialTab;
    _resolveProjectAndLoadData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chatStreamSub?.cancel();
    _chatStatusSub?.cancel();
    _chatStreamService?.dispose();
    _chatScrollController.dispose();
    _cmdController.dispose();
    _chatInputController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Re-check WebSocket connection and retry with backoff/jitter if dropped
      _chatStreamService?.retryNow();
      // Re-fetch project tasks and reconcile timeline status after backgrounding
      if (_projectId != null) {
        _loadTasks(_projectId!);
      }
    }
  }

  Future<void> _resolveProjectAndLoadData() async {
    setState(() {
      _isLoadingTasks = true;
      _isLoadingWorkspace = true;
    });

    if (widget.projectId != null) {
      _projectId = widget.projectId;
      for (final p in ProjectsApiService.cachedProjects) {
        if (p.id == widget.projectId) {
          _project = p;
          break;
        }
      }
      if (_project == null) {
        final res = await ProjectsApiService.getProject(widget.projectId!);
        if (res.success && res.project != null) {
          _project = res.project;
        }
      }
    }

    if (_projectId == null || _project == null) {
      final listRes = await ProjectsApiService.listProjects();
      if (listRes.success && listRes.items.isNotEmpty) {
        for (final p in listRes.items) {
          if ((widget.projectId != null && p.id == widget.projectId) ||
              p.name.toLowerCase() == widget.projectName.toLowerCase()) {
            _project = p;
            _projectId = p.id;
            break;
          }
        }
        if (_project == null && widget.projectId == null && listRes.items.isNotEmpty) {
          _project = listRes.items.first;
          _projectId = _project!.id;
        }
      }
    }

    if (_projectId != null) {
      await Future.wait([
        _loadTasks(_projectId!),
        _loadWorkspace(_projectId!),
        _loadConversation(_projectId!),
      ]);
    }

    if (mounted) {
      setState(() {
        _isLoadingTasks = false;
        _isLoadingWorkspace = false;
      });
    }
  }

  Future<void> _loadTasks(String projectId) async {
    final taskRes = await TasksApiService.listTasks(projectId: projectId);
    if (taskRes.success) {
      if (mounted) {
        setState(() {
          _tasks = taskRes.items;
          _reconcilePendingTaskState();
        });
      }
    }
  }

  void _reconcilePendingTaskState() {
    if (!mounted) return;

    // 1. Check for pending approval
    final pendingTask = _tasks.where((t) => t.status == TaskStatusEnum.approvalRequired).firstOrNull;
    if (pendingTask != null) {
      final alreadyPresent = _timelineItems.any(
        (item) => item is ChatApprovalItem && item.runId == pendingTask.id,
      );
      if (!alreadyPresent) {
        Map<String, dynamic>? logData;
        if (pendingTask.executionLog != null && pendingTask.executionLog!.isNotEmpty) {
          try {
            logData = jsonDecode(pendingTask.executionLog!) as Map<String, dynamic>;
          } catch (_) {}
        }
        final diff = logData?['diff'] as String?;
        final prompt = logData?['prompt'] as String? ??
            'Approval required for proposed changes in ${pendingTask.title}';
        final target = logData?['target_file'] as String? ??
            (logData?['task_owned_files'] is List
                ? (logData!['task_owned_files'] as List).join(', ')
                : null);
        final branch = logData?['baseline_branch'] as String?;
        final baseCommit = logData?['baseline_sha'] as String?;
        final checkCommand = logData?['last_check_command'] as String?;
        final checkExitCode = logData?['last_check_exit_code'] as int?;
        final checkPassed = logData?['last_check_passed'] as bool?;

        _timelineItems.add(
          ChatApprovalItem(
            id: 'approval_${pendingTask.id}',
            timestamp: pendingTask.updatedAt ?? DateTime.now(),
            runId: pendingTask.id,
            prompt: prompt,
            target: target,
            action: 'apply_code_diff',
            diff: diff,
            branch: branch,
            baseCommit: baseCommit,
            checkCommand: checkCommand,
            checkExitCode: checkExitCode,
            checkPassed: checkPassed,
          ),
        );
      }
      _chatStatusText = 'Waiting for approval';
      return;
    }

    // 2. Check for running or queued task
    final activeTask = _tasks.where(
      (t) => t.status == TaskStatusEnum.running || t.status == TaskStatusEnum.queued,
    ).firstOrNull;
    if (activeTask != null) {
      _isRunActive = true;
      _currentRunId = activeTask.id;
      _chatStatusText = 'Working...';
      return;
    }

    // 3. Interrupted task check
    if (_tasks.isNotEmpty) {
      final latest = _tasks.first;
      if (latest.status == TaskStatusEnum.failed &&
          latest.executionLog != null &&
          latest.executionLog!.contains('"interrupted": true')) {
        _chatStatusText = 'Interrupted';
        return;
      }
    }
  }

  Future<void> _loadConversation(String projectId) async {
    final convs = await ConversationsApiService.listConversations(projectId);
    if (!mounted) return;

    ConversationModel? activeConv;
    if (convs.isNotEmpty) {
      activeConv = convs.first;
    } else {
      activeConv = await ConversationsApiService.createConversation(projectId, title: 'Coding Session');
    }
    if (!mounted || activeConv == null) return;

    _currentConversation = activeConv;

    // Load persistent message history
    final history = await ConversationsApiService.getMessages(projectId, _currentConversation!.id);
    if (!mounted) return;

    setState(() {
      _timelineItems.clear();
      for (final m in history) {
        if (m.role == 'user') {
          _timelineItems.add(
            ChatUserMessageItem(
              id: m.id,
              timestamp: m.createdAt,
              content: m.content,
            ),
          );
        } else {
          _timelineItems.add(
            ChatAssistantMessageItem(
              id: m.id,
              timestamp: m.createdAt,
              content: m.content,
              isStreaming: false,
            ),
          );
        }
      }
      _reconcilePendingTaskState();
    });

    _connectChatStream();
  }

  void _connectChatStream() {
    if (_currentConversation == null) return;
    _chatStreamSub?.cancel();
    _chatStatusSub?.cancel();
    _chatStreamService?.dispose();

    _chatStreamService = ChatStreamService(
      conversationId: _currentConversation!.id,
      lastSequenceNumber: _lastSeenSeq,
    );

    _chatStatusSub = _chatStreamService!.status.listen((s) {
      if (!mounted) return;
      setState(() {
        _streamStatus = s;
        if (s == ChatStreamStatus.connected && !_isRunActive) {
          _chatStatusText = 'Ready';
        } else if (s == ChatStreamStatus.reconnecting) {
          _chatStatusText = 'Reconnecting...';
        } else if (s == ChatStreamStatus.disconnected) {
          _chatStatusText = 'Offline';
        }
      });
    });

    _chatStreamSub = _chatStreamService!.events.listen(_onAgentEventReceived);
    _chatStreamService!.connect();
  }

  void _onAgentEventReceived(AgentEventModel event) {
    if (!mounted) return;
    if (event.sequence > _lastSeenSeq) {
      _lastSeenSeq = event.sequence;
    }

    setState(() {
      switch (event.type) {
        case 'run.started':
          _isRunActive = true;
          _currentRunId = event.runId;
          _chatStatusText = 'Working...';
          break;

        case 'message.started':
          final msgId = (event.data['message_id'] as String?)?.trim();
          _activeAssistantMessage = ChatTimelineReconciler.onMessageStarted(
            timelineItems: _timelineItems,
            eventId: event.eventId,
            messageId: msgId,
            createdAt: event.createdAt,
          );
          _scrollToBottom();
          break;

        case 'message.delta':
          final text = event.data['text'] as String? ?? '';
          final msgId = (event.data['message_id'] as String?)?.trim();
          _activeAssistantMessage = ChatTimelineReconciler.onMessageDelta(
            timelineItems: _timelineItems,
            activeMessage: _activeAssistantMessage,
            eventId: event.eventId,
            messageId: msgId,
            text: text,
            createdAt: event.createdAt,
          );
          _scrollToBottom();
          break;

        case 'message.completed':
          final msgId = (event.data['message_id'] as String?)?.trim();
          final full = event.data['text'] as String?;
          ChatTimelineReconciler.onMessageCompleted(
            timelineItems: _timelineItems,
            activeMessage: _activeAssistantMessage,
            eventId: event.eventId,
            messageId: msgId,
            text: full,
            createdAt: event.createdAt,
          );
          _activeAssistantMessage = null;
          break;

        case 'tool.started':
          final tool = event.data['tool'] as String? ?? 'terminal';
          final label = event.data['label'] as String? ?? 'Running tool';
          final cmd = event.data['command'] as String?;
          final item = ChatToolActivityItem(
            id: event.eventId,
            timestamp: event.createdAt,
            tool: tool,
            label: label,
            status: 'running',
            command: cmd,
          );
          _activeTools[tool] = item;
          _timelineItems.add(item);
          _scrollToBottom();
          break;

        case 'tool.output':
          final tool = event.data['tool'] as String? ?? 'terminal';
          final out = event.data['output'] as String? ?? '';
          final item = _activeTools[tool];
          if (item != null) {
            item.output = (item.output == null || item.output!.isEmpty)
                ? out
                : '${item.output}\n$out';
          }
          break;

        case 'tool.completed':
          final tool = event.data['tool'] as String? ?? 'terminal';
          final item = _activeTools[tool];
          if (item != null) {
            item.status = 'completed';
            item.exitCode = event.data['exit_code'] as int? ?? 0;
            if (event.data['summary'] != null) {
              item.output = event.data['summary'] as String;
            }
            _activeTools.remove(tool);
          }
          break;

        case 'file.changed':
          _timelineItems.add(
            ChatFileChangedItem(
              id: event.eventId,
              timestamp: event.createdAt,
              file: event.data['file'] as String? ?? 'file',
              action: event.data['action'] as String? ?? 'modified',
              diff: event.data['diff'] as String? ?? '',
              additions: event.data['additions'] as int? ?? 0,
              deletions: event.data['deletions'] as int? ?? 0,
            ),
          );
          _scrollToBottom();
          break;

        case 'preview.launched':
          _timelineItems.add(
            ChatPreviewItem(
              id: event.eventId,
              timestamp: event.createdAt,
              previewUrl: event.data['preview_url'] as String? ?? '',
              file: event.data['file'] as String? ?? 'app',
              hostingType: event.data['hosting_type'] as String? ?? 'temp_tunnel',
              title: event.data['title'] as String? ?? 'Live Web Application',
            ),
          );
          _scrollToBottom();
          break;

        case 'approval.required':
          _chatStatusText = 'Waiting for approval';
          _timelineItems.add(
            ChatApprovalItem(
              id: event.eventId,
              timestamp: event.createdAt,
              runId: event.runId ?? _currentRunId ?? '',
              prompt: event.data['prompt'] as String? ?? 'Approval required for proposed action',
              target: event.data['target'] as String?,
              action: event.data['action'] as String?,
              diff: event.data['diff'] as String?,
              branch: event.data['branch'] as String?,
              baseCommit: event.data['base_commit'] as String?,
              checkCommand: event.data['check_command'] as String?,
              checkExitCode: event.data['check_exit_code'] as int?,
              checkPassed: event.data['check_passed'] as bool?,
              isStale: event.data['is_stale'] as bool? ?? false,
            ),
          );
          _scrollToBottom();
          break;

        case 'approval.stale':
          _chatStatusText = 'Review stale';
          for (final item in _timelineItems) {
            if (item is ChatApprovalItem && !item.isDecided) {
              item.isStale = true;
            }
          }
          break;

        case 'run.completed':
          _isRunActive = false;
          _chatStatusText = 'Completed';
          _currentRunId = null;
          if (_projectId != null) {
            _loadTasks(_projectId!);
            _loadGitStatus();
          }
          break;

        case 'run.cancelled':
          _isRunActive = false;
          _chatStatusText = 'Cancelled';
          _currentRunId = null;
          break;

        case 'run.failed':
          _isRunActive = false;
          _chatStatusText = 'Failed';
          _currentRunId = null;
          break;
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _onSendMessage(String text) async {
    if (_projectId == null) return;
    if (_currentConversation == null) {
      _currentConversation = await ConversationsApiService.createConversation(_projectId!, title: 'Coding Session');
      if (_currentConversation != null) {
        _connectChatStream();
      }
    }
    if (_currentConversation == null) return;

    setState(() {
      _timelineItems.add(
        ChatUserMessageItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          timestamp: DateTime.now(),
          content: text,
        ),
      );
      _isRunActive = false;
      _chatStatusText = 'Thinking...';
    });
    _scrollToBottom();

    final response = await ConversationsApiService.sendMessage(
      _projectId!,
      _currentConversation!.id,
      text,
    );

    if (response != null) {
      if (_timelineItems.isNotEmpty && _timelineItems.last is ChatUserMessageItem) {
        final lastUser = _timelineItems.last as ChatUserMessageItem;
        if (lastUser.content == response.userMessage.content) {
          lastUser.id = response.userMessage.id;
        }
      }

      if (response.run != null) {
        // Coding instruction intent: Agent run started
        if (mounted) {
          setState(() {
            _isRunActive = true;
            _currentRunId = response.run!.id;
            _chatStatusText = 'Working...';
          });
        }
      } else if (response.assistantMessage != null) {
        // Conversational / Question / Clarification intent: Normal chat bubble
        if (mounted) {
          setState(() {
            _isRunActive = false;
            _chatStatusText = 'Idle';
            ChatTimelineReconciler.onHttpResponse(
              timelineItems: _timelineItems,
              activeMessage: _activeAssistantMessage,
              assistantMessage: response.assistantMessage!,
            );
            if (_activeAssistantMessage != null &&
                _activeAssistantMessage!.id == response.assistantMessage!.id) {
              _activeAssistantMessage = null;
            }
          });
          _scrollToBottom();
        }
      } else {
        if (mounted) {
          setState(() {
            _isRunActive = false;
            _chatStatusText = 'Idle';
          });
        }
      }
    } else {
      if (mounted) {
        setState(() {
          _isRunActive = false;
          _chatStatusText = 'Error sending message';
        });
      }
    }
  }

  Future<void> _onStopRun() async {
    if (_projectId == null || _currentRunId == null) return;
    final success = await ConversationsApiService.cancelRun(_projectId!, _currentRunId!);
    if (mounted && success) {
      setState(() {
        _isRunActive = false;
        _chatStatusText = 'Cancelled';
      });
    }
  }

  Future<void> _handleApprovalDecision(ChatApprovalItem item, bool approve, {String? reason}) async {
    if (_projectId == null) return;
    final runId = item.runId.isNotEmpty ? item.runId : (_currentRunId ?? '');
    final success = await ConversationsApiService.submitApproval(
      _projectId!,
      runId,
      approve: approve,
      reason: reason,
    );

    if (mounted && success) {
      setState(() {
        item.isDecided = true;
        item.wasApproved = approve;
        if (approve) {
          _chatStatusText = 'Working...';
        } else {
          _chatStatusText = 'Cancelled';
          _isRunActive = false;
        }
      });
    }
  }

  Future<void> _loadWorkspace(String projectId) async {
    final wsList = await WorkspacesApiService.listWorkspaces(projectId);
    if (mounted) {
      setState(() {
        _workspace = wsList.isNotEmpty ? wsList.first : null;
      });
      if (_workspace != null && _workspace!.status == WorkspaceStatusEnum.running) {
        _loadGitStatus();
        _loadWorkspaceFiles();
      }
    }
  }

  Future<void> _loadGitStatus() async {
    if (_projectId == null || _workspace == null) return;
    final status = await WorkspacesApiService.getGitStatus(_projectId!, _workspace!.id);
    final diff = await WorkspacesApiService.getGitDiff(_projectId!, _workspace!.id);
    if (mounted) {
      setState(() {
        _gitStatus = status;
        _gitDiff = diff;
      });
      _loadGitBranches();
    }
  }

  Future<void> _loadGitBranches() async {
    if (_projectId == null || _workspace == null) return;
    setState(() => _isLoadingBranches = true);
    final branchesResp = await WorkspacesApiService.getGitBranches(_projectId!, _workspace!.id);
    if (mounted) {
      setState(() {
        _isLoadingBranches = false;
        if (branchesResp != null) {
          _branches = branchesResp.branches;
        }
      });
    }
  }

  Future<void> _checkoutBranch(String branchName, {bool createNew = false}) async {
    if (_projectId == null || _workspace == null) return;
    final cleanBranch = branchName.trim();
    if (cleanBranch.isEmpty) return;

    final result = await WorkspacesApiService.checkoutBranch(
      _projectId!,
      _workspace!.id,
      cleanBranch,
      createNew: createNew,
    );

    if (!mounted) return;
    if (result != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Switched to branch "${result.branch}"'),
          backgroundColor: AppColors.statusSuccess,
        ),
      );
      _loadGitStatus();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Branch checkout failed. Check if working tree has conflicting changes.'),
          backgroundColor: AppColors.statusError,
        ),
      );
    }
  }

  Future<void> _commitWorkingTreeChanges(String message) async {
    if (_projectId == null || _workspace == null) return;
    final cleanMsg = message.trim();
    if (cleanMsg.isEmpty) return;

    setState(() => _isCommitting = true);
    final result = await WorkspacesApiService.commitChanges(
      _projectId!,
      _workspace!.id,
      cleanMsg,
    );

    if (!mounted) return;
    setState(() => _isCommitting = false);

    if (result != null && result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Committed ${result.commitSha.length > 7 ? result.commitSha.substring(0, 7) : result.commitSha} on ${result.branch}'),
          backgroundColor: AppColors.statusSuccess,
        ),
      );
      _loadGitStatus();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result?.errorMessage ?? 'Commit failed.'),
          backgroundColor: AppColors.statusError,
        ),
      );
    }
  }

  Future<void> _handleReviewDecision(ChatApprovalItem? item, TaskModel? task, bool approve) async {
    if (_projectId == null) return;
    if (item != null) {
      await _handleApprovalDecision(item, approve);
    } else if (task != null) {
      if (approve) {
        await TasksApiService.approveTask(_projectId!, task.id);
      } else {
        await TasksApiService.rejectTask(_projectId!, task.id);
      }
    }
    _loadTasks(_projectId!);
    _loadGitStatus();
  }

  Future<void> _loadWorkspaceFiles() async {
    if (_projectId == null || _workspace == null) return;
    setState(() => _isLoadingFiles = true);
    final files = await WorkspacesApiService.listFiles(_projectId!, _workspace!.id);
    if (mounted) {
      setState(() {
        _workspaceFiles = files;
        _isLoadingFiles = false;
      });
    }
  }

  Future<void> _provisionWorkspace() async {
    if (_projectId == null) return;
    setState(() => _isActingWorkspace = true);
    final ws = await WorkspacesApiService.provisionWorkspace(
      _projectId!,
      name: '${widget.projectName} Workspace',
    );
    if (mounted) {
      setState(() {
        _isActingWorkspace = false;
        if (ws != null) {
          _workspace = ws;
        }
      });
      if (ws != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Workspace provisioned successfully.')),
        );
        _loadGitStatus();
        _loadWorkspaceFiles();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to provision workspace.')),
        );
      }
    }
  }

  Future<void> _runTerminalCommand() async {
    final raw = _cmdController.text.trim();
    if (raw.isEmpty || _projectId == null || _workspace == null) return;
    final parts = raw.split(RegExp(r'\s+'));
    setState(() => _isRunningCommand = true);

    final res = await WorkspacesApiService.runCommand(
      _projectId!,
      _workspace!.id,
      parts,
    );

    if (mounted) {
      setState(() {
        _isRunningCommand = false;
        _lastCommandResult = res;
      });
      _loadGitStatus();
    }
  }

  void _showFileContentDialog(String filePath, String fileName) async {
    if (_projectId == null || _workspace == null) return;
    final content = await WorkspacesApiService.readFile(_projectId!, _workspace!.id, filePath);

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => WorkspaceFileEditorDialog(
        filePath: filePath,
        fileName: fileName,
        initialContent: content ?? '',
        onSave: (newContent) async {
          final ok = await WorkspacesApiService.writeFile(_projectId!, _workspace!.id, filePath, newContent);
          if (ok) {
            _loadWorkspaceFiles();
            _loadGitStatus();
          }
          return ok;
        },
      ),
    );
  }

  StatusType _statusType(TaskStatusEnum status) {
    switch (status) {
      case TaskStatusEnum.completed:
        return StatusType.success;
      case TaskStatusEnum.running:
        return StatusType.info;
      case TaskStatusEnum.approvalRequired:
        return StatusType.warning;
      case TaskStatusEnum.failed:
      case TaskStatusEnum.cancelled:
        return StatusType.error;
      default:
        return StatusType.neutral;
    }
  }

  StatusType _workspaceStatusType(WorkspaceStatusEnum status) {
    switch (status) {
      case WorkspaceStatusEnum.running:
        return StatusType.success;
      case WorkspaceStatusEnum.creating:
        return StatusType.info;
      case WorkspaceStatusEnum.stopping:
      case WorkspaceStatusEnum.stopped:
        return StatusType.neutral;
      case WorkspaceStatusEnum.failed:
        return StatusType.error;
      default:
        return StatusType.neutral;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // App Header
            AppHeader(
              title: widget.projectName,
              version: 'v0.9.6',
              showBack: true,
              onBackPressed: () => Navigator.pop(context),
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh, color: AppColors.textSecondary, size: 20),
                  onPressed: _resolveProjectAndLoadData,
                ),
              ],
            ),

            // Tab Bar Row
            Container(
              decoration: const BoxDecoration(
                color: AppColors.surfaceMain,
                border: Border(
                  bottom: BorderSide(color: AppColors.borderSubtle),
                ),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: List.generate(_tabs.length, (index) {
                    final isSelected = _selectedTab == index;
                    IconData tabIcon;
                    switch (index) {
                      case 0:
                        tabIcon = Icons.info_outline;
                        break;
                      case 1:
                        tabIcon = Icons.chat_bubble_outline;
                        break;
                      case 2:
                        tabIcon = Icons.terminal;
                        break;
                      case 3:
                        tabIcon = Icons.difference_outlined;
                        break;
                      default:
                        tabIcon = Icons.circle;
                    }

                    return InkWell(
                      onTap: () {
                        setState(() => _selectedTab = index);
                        if (index == 2 && _workspaceFiles.isEmpty && _workspace != null) {
                          _loadWorkspaceFiles();
                        } else if (index == 3) {
                          _loadGitStatus();
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: isSelected ? AppColors.primary : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              tabIcon,
                              size: 14,
                              color: isSelected ? AppColors.lavender : AppColors.textSecondary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _tabs[index],
                              style: AppTypography.labelMd.copyWith(
                                color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),

            // Tab Body (Expanded so Chat timeline can stretch and scroll properly)
            Expanded(
              child: _buildSelectedTabContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedTabContent() {
    switch (_selectedTab) {
      case 0:
        return _buildOverviewTab();
      case 1:
        return _buildChatSessionTab();
      case 2:
        return _buildWorkspaceTab();
      case 3:
        return _buildChangesTab();
      default:
        return _buildOverviewTab();
    }
  }

  // TAB 0: Project Overview
  Widget _buildOverviewTab() {
    final defaultBranch = _project?.defaultBranch ?? _gitStatus?.branch ?? 'main';
    final repoOrPath = _project?.workspacePath ?? _project?.repoUrl ?? 'Local Folder';
    final isDockerRunning = _workspace != null && _workspace!.status == WorkspaceStatusEnum.running;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Project Meta Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surfaceMain,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        _project?.name ?? widget.projectName,
                        style: AppTypography.headlineMd,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    StatusBadge(
                      label: isDockerRunning ? 'CONNECTED' : 'IDLE',
                      type: isDockerRunning ? StatusType.success : StatusType.neutral,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _buildMetaPill(Icons.fork_right, defaultBranch),
                    _buildMetaPill(
                      _project?.sourceType == 'git' ? Icons.link : Icons.folder_open,
                      repoOrPath,
                    ),
                    if (_workspace != null)
                      _buildMetaPill(Icons.dns, _workspace!.status.label.toUpperCase()),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Action Shortcuts
          AppButton(
            text: 'Open Coding Session',
            icon: const Icon(Icons.forum_outlined, size: 18, color: Colors.white),
            onPressed: () => setState(() => _selectedTab = 1),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.lavender,
                    side: const BorderSide(color: AppColors.primary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.difference_outlined, size: 16),
                  label: const Text('Changes'),
                  onPressed: () => setState(() => _selectedTab = 3),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.lavender,
                    side: const BorderSide(color: AppColors.primary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.terminal, size: 16),
                  label: const Text('Workspace'),
                  onPressed: () => setState(() => _selectedTab = 2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Remote Docker Workspace Summary Card
          _buildWorkspaceSummaryCard(),
          const SizedBox(height: 16),

          // Recent Tasks Section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Project Activity & Tasks', style: AppTypography.headlineSm),
              TextButton.icon(
                icon: const Icon(Icons.chat_bubble_outline, size: 14, color: AppColors.lavender),
                label: Text('Chat', style: AppTypography.labelSm.copyWith(color: AppColors.lavender)),
                onPressed: () => setState(() => _selectedTab = 1),
              ),
            ],
          ),
          const SizedBox(height: 6),

          if (_isLoadingTasks)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                ),
              ),
            )
          else if (_tasks.isEmpty)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surfaceMain,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, color: AppColors.textSecondary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No tasks launched yet. Tap "Open Coding Session" to converse with the agent.',
                      style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            )
          else
            ..._tasks.map((task) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: () => setState(() => _selectedTab = 1),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceMain,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: task.status == TaskStatusEnum.approvalRequired
                            ? AppColors.statusWarning.withOpacity(0.5)
                            : AppColors.borderSubtle,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(task.title, style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(
                                task.prompt,
                                style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        StatusBadge(label: task.status.label.toUpperCase(), type: _statusType(task.status)),
                        const Icon(Icons.chevron_right, size: 16, color: AppColors.textSecondary),
                      ],
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  List<dynamic> _groupTimelineItems(List<ChatTimelineItem> items) {
    final result = <dynamic>[];
    List<ChatToolActivityItem>? currentGroup;

    for (final item in items) {
      if (item is ChatToolActivityItem) {
        currentGroup ??= [];
        currentGroup.add(item);
      } else {
        if (currentGroup != null) {
          result.add(currentGroup);
          currentGroup = null;
        }
        result.add(item);
      }
    }
    if (currentGroup != null) {
      result.add(currentGroup);
    }
    return result;
  }

  // TAB 1: Conversational Chat UI (ChatGPT / Gemini style)
  Widget _buildChatSessionTab() {
    final groupedItems = _groupTimelineItems(_timelineItems);
    final isApprovalPending = _timelineItems.any(
      (item) =>
          item is ChatApprovalItem &&
          !item.isDecided &&
          item.diff != null &&
          item.diff!.isNotEmpty &&
          item.diff != '(No file modifications detected)',
    );
    final effectiveStatusText = isApprovalPending
        ? 'Review needed'
        : (_isRunActive
            ? 'Working...'
            : (_chatStatusText.isNotEmpty ? _chatStatusText : 'Ready'));

    return Column(
      children: [
        // Top session status bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: AppColors.surfaceMain,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.forum_outlined, size: 14, color: AppColors.lavender),
                  const SizedBox(width: 6),
                  Text(
                    _currentConversation?.title ?? 'Coding Session',
                    style: AppTypography.codeSm.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: _exportChatSession,
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.lavender.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppColors.lavender.withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.file_download_outlined, size: 12, color: AppColors.lavender),
                          const SizedBox(width: 4),
                          Text(
                            'EXPORT',
                            style: AppTypography.codeSm.copyWith(
                              color: AppColors.lavender,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  // 1. Connection status pill (LIVE / CONNECTING / OFFLINE)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: _streamStatus == ChatStreamStatus.connected
                          ? AppColors.statusSuccess.withOpacity(0.12)
                          : (_streamStatus == ChatStreamStatus.reconnecting
                              ? AppColors.statusWarning.withOpacity(0.12)
                              : AppColors.textMuted.withOpacity(0.12)),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: _streamStatus == ChatStreamStatus.connected
                            ? AppColors.statusSuccess.withOpacity(0.35)
                            : (_streamStatus == ChatStreamStatus.reconnecting
                                ? AppColors.statusWarning.withOpacity(0.35)
                                : AppColors.textMuted.withOpacity(0.25)),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _streamStatus == ChatStreamStatus.connected
                                ? AppColors.statusSuccess
                                : (_streamStatus == ChatStreamStatus.reconnecting
                                    ? AppColors.statusWarning
                                    : AppColors.textMuted),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _streamStatus == ChatStreamStatus.connected
                              ? 'LIVE'
                              : (_streamStatus == ChatStreamStatus.reconnecting
                                  ? 'CONNECTING'
                                  : 'OFFLINE'),
                          style: AppTypography.codeSm.copyWith(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: _streamStatus == ChatStreamStatus.connected
                                ? AppColors.statusSuccess
                                : (_streamStatus == ChatStreamStatus.reconnecting
                                    ? AppColors.statusWarning
                                    : AppColors.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),

                  // 2. Task lifecycle status badge
                  StatusBadge(
                    label: isApprovalPending
                        ? 'REVIEW NEEDED'
                        : (_isRunActive
                            ? 'WORKING...'
                            : (_chatStatusText == 'Completed'
                                ? 'COMPLETED'
                                : (_chatStatusText == 'Interrupted'
                                    ? 'INTERRUPTED'
                                    : (_chatStatusText.isNotEmpty ? _chatStatusText.toUpperCase() : 'READY')))),
                    type: isApprovalPending
                        ? StatusType.warning
                        : (_isRunActive
                            ? StatusType.info
                            : (_chatStatusText == 'Completed'
                                ? StatusType.success
                                : (_chatStatusText == 'Interrupted'
                                    ? StatusType.error
                                    : StatusType.neutral))),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 16, color: AppColors.textSecondary),
                    tooltip: 'Refresh conversation',
                    onPressed: _projectId != null ? () => _loadConversation(_projectId!) : null,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(color: AppColors.borderSubtle, height: 1),

        // Timeline Message List
        Expanded(
          child: Stack(
            children: [
              _timelineItems.isEmpty
                  ? _buildChatEmptyState()
                  : ListView.builder(
                      controller: _chatScrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      itemCount: groupedItems.length,
                      itemBuilder: (context, idx) {
                        final item = groupedItems[idx];
                        if (item is List<ChatToolActivityItem>) {
                          return AgentProgressCard(activities: item);
                        } else if (item is ChatUserMessageItem) {
                          return ChatMessageBubble(
                            role: 'user',
                            content: item.content,
                            timestamp: item.timestamp,
                          );
                        } else if (item is ChatAssistantMessageItem) {
                          return ChatMessageBubble(
                            role: 'assistant',
                            content: item.content,
                            isStreaming: item.isStreaming,
                            timestamp: item.timestamp,
                          );
                        } else if (item is ChatToolActivityItem) {
                          return ToolActivityCard(
                            tool: item.tool,
                            label: item.label,
                            status: item.status,
                            output: item.output,
                            command: item.command,
                            exitCode: item.exitCode,
                          );
                        } else if (item is ChatFileChangedItem) {
                          return FileChangedCard(
                            file: item.file,
                            diff: item.diff,
                            action: item.action,
                            additions: item.additions,
                            deletions: item.deletions,
                          );
                        } else if (item is ChatApprovalItem) {
                          return ApprovalRequestCard(
                            prompt: item.prompt,
                            target: item.target,
                            action: item.action,
                            diff: item.diff,
                            branch: item.branch,
                            baseCommit: item.baseCommit,
                            taskId: item.runId,
                            checkCommand: item.checkCommand,
                            checkExitCode: item.checkExitCode,
                            checkPassed: item.checkPassed,
                            isStale: item.isStale,
                            isDecided: item.isDecided,
                            wasApproved: item.wasApproved,
                            onDecision: (approve, {reason}) => _handleApprovalDecision(item, approve, reason: reason),
                          );
                        } else if (item is ChatPreviewItem) {
                          return LivePreviewCard(
                            previewUrl: item.previewUrl,
                            file: item.file,
                            hostingType: item.hostingType,
                            title: item.title,
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
              if (_timelineItems.isNotEmpty)
                Positioned(
                  right: 14,
                  bottom: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'scroll_to_bottom',
                    backgroundColor: AppColors.surfaceElevated,
                    foregroundColor: AppColors.lavender,
                    elevation: 3,
                    shape: const CircleBorder(side: BorderSide(color: AppColors.borderSubtle)),
                    onPressed: () {
                      if (_chatScrollController.hasClients) {
                        _chatScrollController.animateTo(
                          _chatScrollController.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      }
                    },
                    child: const Icon(Icons.keyboard_arrow_down, size: 20),
                  ),
                ),
            ],
          ),
        ),

        // Bottom Multiline Composer
        ChatComposer(
          controller: _chatInputController,
          onAttach: _openAttachDialog,
          isRunning: _isRunActive,
          isApprovalPending: isApprovalPending,
          statusText: effectiveStatusText,
          isConnected: _streamStatus == ChatStreamStatus.connected,
          onSend: _onSendMessage,
          onStop: _onStopRun,
        ),
      ],
    );
  }

  void _openAttachDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceMain,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final nonDirFiles = _workspaceFiles.where((f) => !f.isDirectory).toList();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.attach_file, color: AppColors.lavender, size: 18),
                      const SizedBox(width: 8),
                      Text('Attach to Prompt', style: AppTypography.headlineSm.copyWith(fontSize: 15)),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Select a workspace file to reference in your agent prompt:',
                style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
              ),
              const SizedBox(height: 12),
              if (nonDirFiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      'No workspace files found. Open the Workspace tab to refresh files.',
                      style: AppTypography.codeSm.copyWith(color: AppColors.textMuted, fontSize: 11),
                    ),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: nonDirFiles.length,
                    separatorBuilder: (_, __) => const Divider(color: AppColors.borderSubtle, height: 1),
                    itemBuilder: (context, idx) {
                      final item = nonDirFiles[idx];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file_outlined, size: 16, color: AppColors.lavender),
                        title: Text(item.name, style: AppTypography.codeSm.copyWith(fontSize: 12)),
                        subtitle: Text(item.path, style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10)),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.surfaceElevated,
                            foregroundColor: AppColors.lavender,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _attachFileToPrompt(item.path);
                          },
                          child: const Text('Attach', style: TextStyle(fontSize: 11)),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _attachFileToPrompt(String filePath) {
    final current = _chatInputController.text;
    final prefix = current.isEmpty ? '' : '$current ';
    _chatInputController.text = '$prefix@$filePath ';
    _chatInputController.selection = TextSelection.fromPosition(
      TextPosition(offset: _chatInputController.text.length),
    );
  }

  void _exportChatSession() {
    final buffer = StringBuffer();
    final nowStr = DateTime.now().toUtc().toIso8601String();
    buffer.writeln('==============================================================');
    buffer.writeln('JESS IDE — CHAT CONVERSATION EXPORT');
    buffer.writeln('Project: ${widget.projectName} (${_projectId ?? "default"})');
    buffer.writeln('Export Date: $nowStr');
    buffer.writeln('==============================================================\n');

    for (final item in _timelineItems) {
      final timeStr = item.timestamp.toLocal().toString().split('.')[0];
      if (item is ChatUserMessageItem) {
        buffer.writeln('[$timeStr] USER:');
        buffer.writeln(item.content);
        buffer.writeln('--------------------------------------------------------------\n');
      } else if (item is ChatAssistantMessageItem) {
        buffer.writeln('[$timeStr] ASSISTANT (Jess Meta Agent):');
        buffer.writeln(item.content);
        buffer.writeln('--------------------------------------------------------------\n');
      } else if (item is ChatToolActivityItem) {
        buffer.writeln('[$timeStr] TOOL: ${item.tool} (Status: ${item.status}, Exit: ${item.exitCode})');
        if (item.output != null && item.output!.isNotEmpty) {
          buffer.writeln('Output: ${item.output}');
        }
        buffer.writeln('--------------------------------------------------------------\n');
      } else if (item is ChatFileChangedItem) {
        buffer.writeln('[$timeStr] FILE MODIFIED: ${item.file} (+${item.additions} / -${item.deletions})');
        buffer.writeln(item.diff);
        buffer.writeln('--------------------------------------------------------------\n');
      } else if (item is ChatApprovalItem) {
        final status = item.isDecided ? (item.wasApproved == true ? 'APPROVED' : 'REJECTED') : 'PENDING';
        buffer.writeln('[$timeStr] APPROVAL: $status (${item.target ?? "workspace"})');
        buffer.writeln(item.prompt);
        buffer.writeln('--------------------------------------------------------------\n');
      } else if (item is ChatPreviewItem) {
        buffer.writeln('[$timeStr] LIVE HOSTED PREVIEW:');
        buffer.writeln('URL: ${item.previewUrl} (${item.hostingType})');
        buffer.writeln('--------------------------------------------------------------\n');
      }
    }

    final exportText = buffer.toString();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceMain,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.borderSubtle),
        ),
        title: Row(
          children: [
            const Icon(Icons.file_download_outlined, color: AppColors.lavender, size: 20),
            const SizedBox(width: 8),
            Text('Export Chat History', style: AppTypography.headlineSm),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Complete chat transcript with all user instructions, tool activities, code diffs, and verification results.',
                style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              Container(
                height: 220,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    exportText,
                    style: AppTypography.codeSm.copyWith(fontSize: 10, color: AppColors.textPrimary),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Close', style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary)),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('Copy Transcript'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.lavender,
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: exportText));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Chat transcript copied to clipboard!')),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildChatEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.primary.withOpacity(0.3)),
              ),
              child: const Icon(Icons.smart_toy_outlined, size: 28, color: AppColors.lavender),
            ),
            const SizedBox(height: 14),
            Text('Jess Coding Assistant', style: AppTypography.headlineSm),
            const SizedBox(height: 6),
            Text(
              'Describe what you want to build or refactor. The remote agent inspects the project, runs tools, proposes changes, and streams progress into this conversation.',
              style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildPromptSuggestion('Run tests and verify project'),
                _buildPromptSuggestion('Add retry policy with exponential backoff'),
                _buildPromptSuggestion('Inspect project structure & git status'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPromptSuggestion(String prompt) {
    return InkWell(
      onTap: () => _onSendMessage(prompt),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.surfaceMain,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bolt, size: 12, color: AppColors.lavender),
            const SizedBox(width: 4),
            Text(prompt, style: AppTypography.codeSm.copyWith(fontSize: 11, color: AppColors.textPrimary)),
          ],
        ),
      ),
    );
  }

  // TAB 2: Workspace (Sandboxed Terminal Runner & File Explorer)
  Widget _buildWorkspaceTab() {
    if (_isLoadingWorkspace) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_workspace == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.dns_outlined, size: 48, color: AppColors.textSecondary),
              const SizedBox(height: 12),
              Text('No Workspace Provisioned', style: AppTypography.headlineSm),
              const SizedBox(height: 6),
              Text(
                'Create an isolated Docker container sandbox to run terminal commands and inspect project files.',
                style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              AppButton(
                text: 'Provision Docker Workspace',
                width: 230,
                onPressed: _isActingWorkspace ? null : _provisionWorkspace,
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Container Banner
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceMain,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.dns, color: AppColors.lavender, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      _workspace!.imageName ?? 'python:3.10-slim',
                      style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                StatusBadge(
                  label: _workspace!.status.label.toUpperCase(),
                  type: _workspaceStatusType(_workspace!.status),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Terminal Execution Section
          Text('Terminal Command Execution', style: AppTypography.headlineSm),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _cmdController,
                  style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AppColors.surfaceMain,
                    hintText: 'e.g. git status, ls -la, python -V',
                    hintStyle: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                    prefixText: r'$ ',
                    prefixStyle: AppTypography.codeSm.copyWith(color: AppColors.lavender),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.borderSubtle),
                    ),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 42,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: _isRunningCommand ? null : _runTerminalCommand,
                  child: _isRunningCommand
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Run', style: TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Terminal Output Window
          if (_lastCommandResult != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      StatusBadge(
                        label: _lastCommandResult!.exitCode == 0 ? 'EXIT 0' : 'EXIT ${_lastCommandResult!.exitCode}',
                        type: _lastCommandResult!.exitCode == 0 ? StatusType.success : StatusType.error,
                      ),
                      Text(
                        '${(_lastCommandResult!.durationSeconds * 1000).toInt()}ms',
                        style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    (_lastCommandResult!.stdout.isNotEmpty ? _lastCommandResult!.stdout : _lastCommandResult!.stderr).trim(),
                    style: AppTypography.codeSm.copyWith(
                      color: _lastCommandResult!.exitCode == 0 ? AppColors.textPrimary : AppColors.statusError,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Workspace Files Explorer
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Workspace Files', style: AppTypography.headlineSm),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16, color: AppColors.textSecondary),
                onPressed: _loadWorkspaceFiles,
              ),
            ],
          ),
          const SizedBox(height: 6),

          if (_isLoadingFiles)
            const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
          else if (_workspaceFiles.isEmpty)
            Text('No files found in container root.', style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary))
          else
            Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceMain,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _workspaceFiles.length,
                separatorBuilder: (_, __) => const Divider(color: AppColors.borderSubtle, height: 1),
                itemBuilder: (context, idx) {
                  final item = _workspaceFiles[idx];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      item.isDirectory ? Icons.folder : Icons.insert_drive_file_outlined,
                      color: item.isDirectory ? AppColors.primary : AppColors.lavender,
                      size: 16,
                    ),
                    title: Text(item.name, style: AppTypography.codeSm),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (item.name.toLowerCase().endsWith('.html') || item.name.toLowerCase().endsWith('.htm')) ...[
                          InkWell(
                            onTap: () {
                              final base = AuthApiService.baseUrl.replaceAll('/api/v1', '');
                              final previewUrl = '$base/api/v1/workspaces/${_workspace?.id}/preview/${item.path}';
                              final uri = Uri.parse(previewUrl);
                              launchUrl(uri, mode: LaunchMode.externalApplication);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00E5FF).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.open_in_browser, size: 12, color: Color(0xFF00E5FF)),
                                  const SizedBox(width: 3),
                                  Text(
                                    'PREVIEW',
                                    style: AppTypography.codeSm.copyWith(
                                      color: const Color(0xFF00E5FF),
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          item.isDirectory ? 'dir' : '${item.sizeBytes} B',
                          style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                        ),
                      ],
                    ),
                    onTap: item.isDirectory ? null : () => _showFileContentDialog(item.path, item.name),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  // TAB 3: Changes (Git Review, Branch Management & Diff Inspection)
  Widget _buildChangesTab() {
    final pendingApproval = _timelineItems
        .whereType<ChatApprovalItem>()
        .where((i) => !i.isDecided)
        .firstOrNull;
    final pendingTask = _tasks
        .where((t) => t.status == TaskStatusEnum.approvalRequired)
        .firstOrNull;
    final interruptedTask = _tasks.where((t) {
      return t.status == TaskStatusEnum.failed &&
          t.executionLog != null &&
          t.executionLog!.contains('"interrupted": true');
    }).firstOrNull;

    final currentBranch = _gitStatus?.branch ?? 'main';
    final hasDiff = _gitDiff != null && _gitDiff!.diff.trim().isNotEmpty;
    final isClean = _gitStatus?.isClean == true && !hasDiff;

    // Filtered diff if specific file selected
    String displayDiff = _gitDiff?.diff ?? '';
    if (_selectedDiffFile != null && _gitDiff != null) {
      final fileDiff = _gitDiff!.files
          .where((f) => f.path == _selectedDiffFile)
          .firstOrNull;
      if (fileDiff != null && fileDiff.patch.isNotEmpty) {
        displayDiff = fileDiff.patch;
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Git Changes & Review', style: AppTypography.headlineSm),
              Row(
                children: [
                  if (_isLoadingBranches)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.lavender),
                      ),
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh, size: 14, color: AppColors.lavender),
                    label: Text('Refresh', style: AppTypography.labelSm.copyWith(color: AppColors.lavender)),
                    onPressed: _loadGitStatus,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Branch & Working Tree Strip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surfaceMain,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.fork_right, size: 18, color: AppColors.lavender),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          currentBranch,
                          style: AppTypography.codeSm.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusBadge(
                        label: isClean ? 'CLEAN' : 'MODIFIED',
                        type: isClean ? StatusType.success : StatusType.warning,
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: _showBranchSwitcherModal,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.primary.withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.swap_horiz, size: 14, color: AppColors.lavender),
                        const SizedBox(width: 4),
                        Text(
                          'Switch Branch',
                          style: AppTypography.labelSm.copyWith(color: AppColors.lavender),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Active Task Approval Banner (Safe Approval Workflow)
          if (pendingTask != null || pendingApproval != null) ...[
            _buildActiveTaskReviewBanner(pendingApproval, pendingTask),
            const SizedBox(height: 14),
          ],

          // Interrupted Uncommitted Changes Recovery Notice
          if (interruptedTask != null && !isClean) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.lavender.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.lavender.withOpacity(0.25)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 18, color: AppColors.lavender),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Uncommitted Changes Preserved',
                          style: AppTypography.labelMd.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'A previous task was interrupted by a restart or worker disconnection. Your workspace file modifications are preserved on disk below. You can inspect the diff, commit them, or reject them.',
                          style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],

          // File Navigator Bar
          if (_gitDiff != null && _gitDiff!.files.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Changed Files (${_gitDiff!.files.length})',
                  style: AppTypography.labelMd.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                ),
                Text(
                  '+${_gitDiff!.additions}  -${_gitDiff!.deletions}',
                  style: AppTypography.codeSm.copyWith(
                    color: AppColors.statusSuccess,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // All Files chip
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('All Files (${_gitDiff!.files.length})'),
                      selected: _selectedDiffFile == null,
                      onSelected: (_) => setState(() => _selectedDiffFile = null),
                      selectedColor: AppColors.primary,
                      backgroundColor: AppColors.surfaceMain,
                      labelStyle: AppTypography.codeSm.copyWith(
                        color: _selectedDiffFile == null ? Colors.white : AppColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  // Individual file chips
                  ..._gitDiff!.files.map((file) {
                    final isSelected = _selectedDiffFile == file.path;
                    final fileName = file.path.split('/').last;
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              file.status == 'added' ? 'A' : (file.status == 'deleted' ? 'D' : 'M'),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: file.status == 'added'
                                    ? AppColors.statusSuccess
                                    : (file.status == 'deleted' ? AppColors.statusError : AppColors.statusWarning),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(fileName),
                            const SizedBox(width: 4),
                            Text(
                              '+${file.additions}',
                              style: const TextStyle(fontSize: 10, color: AppColors.statusSuccess),
                            ),
                          ],
                        ),
                        selected: isSelected,
                        onSelected: (_) => setState(() => _selectedDiffFile = isSelected ? null : file.path),
                        selectedColor: AppColors.primary,
                        backgroundColor: AppColors.surfaceMain,
                        labelStyle: AppTypography.codeSm.copyWith(
                          color: isSelected ? Colors.white : AppColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Diff Viewer
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _selectedDiffFile != null ? 'Diff: $_selectedDiffFile' : 'Working Tree Diff',
                style: AppTypography.labelMd,
              ),
              if (_selectedDiffFile != null)
                TextButton(
                  onPressed: () => setState(() => _selectedDiffFile = null),
                  child: Text('Show all', style: AppTypography.labelSm.copyWith(color: AppColors.lavender)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: displayDiff.trim().isNotEmpty
                ? _buildSyntaxDiffView(displayDiff)
                : Text(
                    isClean
                        ? 'Working tree clean. No uncommitted modifications.'
                        : 'No diff detected.',
                    style: AppTypography.codeSm.copyWith(fontSize: 11, color: AppColors.textSecondary),
                  ),
          ),
          const SizedBox(height: 16),

          // Working Tree Commit Action Card
          if (!isClean) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surfaceMain,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Commit Working Tree Changes',
                        style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${_gitDiff?.filesChanged ?? 0} files affected',
                        style: AppTypography.codeSm.copyWith(fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Create a local Git commit with these modifications on the "$currentBranch" branch.',
                    style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: _isCommitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.check_circle_outline, size: 16, color: Colors.white),
                      label: Text(
                        _isCommitting ? 'Committing...' : 'Commit Changes to $currentBranch',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      onPressed: _isCommitting ? null : _showCommitDialog,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }

  Widget _buildActiveTaskReviewBanner(ChatApprovalItem? item, TaskModel? task) {
    final prompt = item?.prompt ?? task?.prompt ?? 'Code modifications proposed';
    final target = item?.target;
    final checkPassed = item?.checkPassed;
    final checkCommand = item?.checkCommand;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.statusWarning.withOpacity(0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.verified_outlined, size: 16, color: AppColors.statusWarning),
                  const SizedBox(width: 6),
                  Text(
                    'APPROVAL REQUIRED',
                    style: AppTypography.codeSm.copyWith(
                      color: AppColors.statusWarning,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (checkPassed != null)
                StatusBadge(
                  label: checkPassed ? 'CHECKS PASSED' : 'CHECKS FAILED',
                  type: checkPassed ? StatusType.success : StatusType.error,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            prompt,
            style: AppTypography.headlineSm.copyWith(fontSize: 13),
          ),
          if (target != null && target.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Target: $target',
              style: AppTypography.codeSm.copyWith(color: AppColors.lavender, fontSize: 11),
            ),
          ],
          if (checkCommand != null && checkCommand.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Verified via: $checkCommand',
              style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.statusError,
                    side: const BorderSide(color: AppColors.statusError),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () => _handleReviewDecision(item, task, false),
                  child: const Text('Reject Changes'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.statusSuccess,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () => _handleReviewDecision(item, task, true),
                  child: const Text('Approve & Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSyntaxDiffView(String diff) {
    final lines = diff.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: lines.map((line) {
        Color? bgColor;
        Color textColor = AppColors.textPrimary;
        FontWeight fontWeight = FontWeight.normal;

        if (line.startsWith('+++') || line.startsWith('---')) {
          textColor = AppColors.textSecondary;
          fontWeight = FontWeight.w600;
        } else if (line.startsWith('+')) {
          bgColor = const Color(0x1F22C55E); // green with opacity
          textColor = const Color(0xFF4ADE80);
        } else if (line.startsWith('-')) {
          bgColor = const Color(0x1FEF4444); // red with opacity
          textColor = const Color(0xFFF87171);
        } else if (line.startsWith('@@')) {
          bgColor = const Color(0x1F818CF8); // lavender with opacity
          textColor = const Color(0xFFA5B4FC);
          fontWeight = FontWeight.w600;
        } else if (line.startsWith('diff --git') || line.startsWith('index ')) {
          textColor = AppColors.lavender;
          fontWeight = FontWeight.w600;
        }

        return Container(
          width: double.infinity,
          color: bgColor,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Text(
            line.isEmpty ? ' ' : line,
            style: AppTypography.codeSm.copyWith(
              color: textColor,
              fontWeight: fontWeight,
              fontSize: 11,
              height: 1.4,
            ),
          ),
        );
      }).toList(),
    );
  }

  void _showBranchSwitcherModal() {
    final newBranchCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceMain,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            final currentBranch = _gitStatus?.branch ?? 'main';
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(modalCtx).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Git Branch Management', style: AppTypography.headlineSm),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                          onPressed: () => Navigator.pop(modalCtx),
                        ),
                      ],
                    ),
                    const Divider(color: AppColors.borderSubtle),
                    const SizedBox(height: 8),

                    // Existing Branches List
                    Text('Local Branches', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    if (_branches.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text('No other branches found.', style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary)),
                      )
                    else
                      Container(
                        decoration: BoxDecoration(
                          color: AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _branches.length,
                          separatorBuilder: (_, __) => const Divider(color: AppColors.borderSubtle, height: 1),
                          itemBuilder: (context, idx) {
                            final b = _branches[idx];
                            final isActive = b.name == currentBranch || b.isCurrent;
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                Icons.fork_right,
                                size: 18,
                                color: isActive ? AppColors.statusSuccess : AppColors.lavender,
                              ),
                              title: Text(
                                b.name,
                                style: AppTypography.codeSm.copyWith(
                                  fontWeight: isActive ? FontWeight.w700 : FontWeight.normal,
                                  color: isActive ? AppColors.statusSuccess : AppColors.textPrimary,
                                ),
                              ),
                              subtitle: b.commitSha != null
                                  ? Text(
                                      '${b.commitSha!.substring(0, b.commitSha!.length > 7 ? 7 : b.commitSha!.length)} ${b.commitMessage ?? ''}',
                                      style: AppTypography.codeSm.copyWith(fontSize: 10, color: AppColors.textSecondary),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    )
                                  : null,
                              trailing: isActive
                                  ? const StatusBadge(label: 'ACTIVE', type: StatusType.success)
                                  : OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        side: const BorderSide(color: AppColors.lavender),
                                      ),
                                      onPressed: () {
                                        Navigator.pop(modalCtx);
                                        _checkoutBranch(b.name, createNew: false);
                                      },
                                      child: const Text('Checkout', style: TextStyle(fontSize: 11, color: AppColors.lavender)),
                                    ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 16),

                    // Create & Checkout New Branch
                    Text('Create New Branch', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(
                      'Branch off current HEAD ($currentBranch)',
                      style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: newBranchCtrl,
                            style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary),
                            decoration: InputDecoration(
                              hintText: 'e.g. feat/recovery-hardening',
                              hintStyle: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                              filled: true,
                              fillColor: AppColors.surfaceElevated,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: AppColors.borderSubtle),
                              ),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () {
                            final name = newBranchCtrl.text.trim();
                            if (name.isEmpty) return;
                            Navigator.pop(modalCtx);
                            _checkoutBranch(name, createNew: true);
                          },
                          child: const Text('Create', style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showCommitDialog() {
    final commitMsgCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceMain,
        title: Text('Commit Changes', style: AppTypography.headlineSm),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Branch: ${_gitStatus?.branch ?? "main"}',
              style: AppTypography.codeSm.copyWith(color: AppColors.lavender, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '${_gitDiff?.filesChanged ?? 0} files affected (+${_gitDiff?.additions ?? 0} -${_gitDiff?.deletions ?? 0})',
              style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: commitMsgCtrl,
              maxLines: 3,
              style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Enter commit message...',
                hintStyle: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surfaceElevated,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.borderSubtle),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              final msg = commitMsgCtrl.text.trim();
              if (msg.isEmpty) return;
              Navigator.pop(ctx);
              _commitWorkingTreeChanges(msg);
            },
            child: const Text('Commit', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkspaceSummaryCard() {
    if (_isLoadingWorkspace) {
      return const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()));
    }

    if (_workspace == null) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surfaceMain,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Docker Workspace', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
                const StatusBadge(label: 'UNPROVISIONED', type: StatusType.neutral),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'No container environment active for this project.',
              style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
            ),
            const SizedBox(height: 10),
            AppButton(
              text: 'Provision Docker Workspace',
              onPressed: _isActingWorkspace ? null : _provisionWorkspace,
            ),
          ],
        ),
      );
    }

    final ws = _workspace!;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Docker Workspace', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
              StatusBadge(label: ws.status.label.toUpperCase(), type: _workspaceStatusType(ws.status)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Image: ${ws.imageName ?? 'python:3.10-slim'} · ID: ${ws.id.substring(0, ws.id.length > 8 ? 8 : ws.id.length)}',
            style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaPill(IconData icon, String label, {double? maxWidth}) {
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth ?? 260),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.lavender),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
