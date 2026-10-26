import 'dart:async';
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

// Timeline Item Model hierarchy for Conversational Chat
abstract class ChatTimelineItem {
  final String id;
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
  ChatAssistantMessageItem({
    required super.id,
    required super.timestamp,
    required this.content,
    this.isStreaming = false,
  });
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
    this.isDecided = false,
    this.wasApproved,
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

class _Screen6ProjectOverviewState extends State<Screen6ProjectOverview> {
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

  // Terminal Runner State
  final TextEditingController _cmdController = TextEditingController(text: 'git status');
  bool _isRunningCommand = false;
  WorkspaceCommandResult? _lastCommandResult;

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab;
    _resolveProjectAndLoadData();
  }

  @override
  void dispose() {
    _chatStreamSub?.cancel();
    _chatStatusSub?.cancel();
    _chatStreamService?.dispose();
    _chatScrollController.dispose();
    _cmdController.dispose();
    super.dispose();
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
        if (_project == null && listRes.items.isNotEmpty) {
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
        });
      }
    }
  }

  Future<void> _loadConversation(String projectId) async {
    final convs = await ConversationsApiService.listConversations(projectId);
    if (!mounted || convs.isEmpty) return;

    _currentConversation = convs.first;

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
          _activeAssistantMessage = ChatAssistantMessageItem(
            id: event.eventId,
            timestamp: event.createdAt,
            content: '',
            isStreaming: true,
          );
          _timelineItems.add(_activeAssistantMessage!);
          _scrollToBottom();
          break;

        case 'message.delta':
          final text = event.data['text'] as String? ?? '';
          if (_activeAssistantMessage != null) {
            _activeAssistantMessage!.content += text;
          } else {
            _activeAssistantMessage = ChatAssistantMessageItem(
              id: event.eventId,
              timestamp: event.createdAt,
              content: text,
              isStreaming: true,
            );
            _timelineItems.add(_activeAssistantMessage!);
          }
          _scrollToBottom();
          break;

        case 'message.completed':
          if (_activeAssistantMessage != null) {
            _activeAssistantMessage!.isStreaming = false;
            final full = event.data['text'] as String?;
            if (full != null && full.isNotEmpty) {
              _activeAssistantMessage!.content = full;
            }
            _activeAssistantMessage = null;
          }
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
            ),
          );
          _scrollToBottom();
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
    if (_projectId == null || _currentConversation == null) return;

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
            // Only add if not already received from WebSocket stream
            final exists = _timelineItems.any(
              (item) => item is ChatAssistantMessageItem && item.id == response.assistantMessage!.id,
            );
            if (!exists) {
              _timelineItems.add(
                ChatAssistantMessageItem(
                  id: response.assistantMessage!.id,
                  timestamp: response.assistantMessage!.createdAt,
                  content: response.assistantMessage!.content,
                  isStreaming: false,
                ),
              );
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

  Future<void> _handleApprovalDecision(ChatApprovalItem item, bool approve) async {
    if (_projectId == null) return;
    final runId = item.runId.isNotEmpty ? item.runId : (_currentRunId ?? '');
    final success = await ConversationsApiService.submitApproval(
      _projectId!,
      runId,
      approve: approve,
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
    }
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
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceMain,
        title: Text(fileName, style: AppTypography.headlineSm),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              content ?? 'Empty or binary file',
              style: AppTypography.codeSm.copyWith(fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
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
              version: 'v0.9.4-beta',
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

  // TAB 1: Conversational Chat UI (ChatGPT / Gemini style)
  Widget _buildChatSessionTab() {
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
                ],
              ),
              Row(
                children: [
                  StatusBadge(
                    label: _chatStatusText.toUpperCase(),
                    type: _isRunActive
                        ? StatusType.info
                        : (_chatStatusText == 'Completed' ? StatusType.success : StatusType.neutral),
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
          child: _timelineItems.isEmpty
              ? _buildChatEmptyState()
              : ListView.builder(
                  controller: _chatScrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  itemCount: _timelineItems.length,
                  itemBuilder: (context, idx) {
                    final item = _timelineItems[idx];
                    if (item is ChatUserMessageItem) {
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
                        isDecided: item.isDecided,
                        wasApproved: item.wasApproved,
                        onDecision: (approve) => _handleApprovalDecision(item, approve),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
        ),

        // Bottom Multiline Composer
        ChatComposer(
          isRunning: _isRunActive,
          statusText: _chatStatusText,
          isConnected: _streamStatus == ChatStreamStatus.connected,
          onSend: _onSendMessage,
          onStop: _onStopRun,
        ),
      ],
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
                    trailing: Text(
                      item.isDirectory ? 'dir' : '${item.sizeBytes} B',
                      style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
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

  // TAB 3: Changes (Git Status & Diff Review)
  Widget _buildChangesTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Git Changes & Review', style: AppTypography.headlineSm),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 14, color: AppColors.lavender),
                label: Text('Refresh', style: AppTypography.labelSm.copyWith(color: AppColors.lavender)),
                onPressed: _loadGitStatus,
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Status Strip
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
                    const Icon(Icons.fork_right, size: 16, color: AppColors.lavender),
                    const SizedBox(width: 6),
                    Text(
                      _gitStatus?.branch ?? 'main',
                      style: AppTypography.codeSm.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                StatusBadge(
                  label: _gitStatus?.isClean == true ? 'CLEAN' : 'MODIFIED',
                  type: _gitStatus?.isClean == true ? StatusType.success : StatusType.warning,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Unified Diff Viewer
          Text('Working Tree Diff', style: AppTypography.labelMd),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Text(
              _gitDiff?.diff.isNotEmpty == true
                  ? _gitDiff!.diff
                  : (_gitStatus?.isClean == true ? 'Working tree clean. No uncommitted modifications.' : 'No diff detected.'),
              style: AppTypography.codeSm.copyWith(fontSize: 11),
            ),
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

  Widget _buildMetaPill(IconData icon, String label) {
    return Container(
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
          Text(
            label,
            style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary, fontSize: 10),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
