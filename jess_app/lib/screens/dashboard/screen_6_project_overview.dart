import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';
import '../../services/projects_api_service.dart';
import '../../services/tasks_api_service.dart';
import '../../services/task_stream_service.dart';
import '../../services/workspaces_api_service.dart';

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
  TaskModel? _activeTask;
  TaskStreamService? _streamService;
  StreamSubscription? _streamSub;
  final List<String> _streamLogs = [];
  String? _proposedDiff;
  bool _isLoadingTasks = false;
  bool _isActing = false;

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
    _streamSub?.cancel();
    _streamService?.dispose();
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
      _tasks = taskRes.items;
      if (_tasks.isNotEmpty && _activeTask == null) {
        _selectAndStreamTask(_tasks.first);
      }
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

  Future<void> _stopWorkspace() async {
    if (_projectId == null || _workspace == null) return;
    setState(() => _isActingWorkspace = true);
    final ws = await WorkspacesApiService.stopWorkspace(_projectId!, _workspace!.id);
    if (mounted) {
      setState(() {
        _isActingWorkspace = false;
        if (ws != null) _workspace = ws;
      });
    }
  }

  Future<void> _restartWorkspace() async {
    if (_projectId == null || _workspace == null) return;
    setState(() => _isActingWorkspace = true);
    final ws = await WorkspacesApiService.restartWorkspace(_projectId!, _workspace!.id);
    if (mounted) {
      setState(() {
        _isActingWorkspace = false;
        if (ws != null) _workspace = ws;
      });
      if (ws != null) {
        _loadGitStatus();
        _loadWorkspaceFiles();
      }
    }
  }

  void _selectAndStreamTask(TaskModel task) {
    _streamSub?.cancel();
    _streamService?.dispose();

    setState(() {
      _activeTask = task;
      _streamLogs.clear();
      _streamLogs.add('Loaded task: ${task.title} [Status: ${task.status.label}]');
      _proposedDiff = null;
    });

    _streamService = TaskStreamService(taskId: task.id);
    _streamSub = _streamService!.events.listen((event) {
      if (!mounted) return;
      setState(() {
        final payload = event.payload;
        switch (event.eventType) {
          case 'task.started':
            _streamLogs.add('● [Agent] Execution started...');
            _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.running);
            break;
          case 'task.progress':
            final msg = payload['message'] ?? 'In progress...';
            _streamLogs.add('→ [Progress] $msg');
            break;
          case 'tool.requested':
            final tool = payload['tool'] ?? 'tool';
            final params = payload['parameters'] ?? payload['args'] ?? '';
            _streamLogs.add('⚡ [Tool Request] $tool($params)');
            break;
          case 'diff.proposed':
            _proposedDiff = payload['diff'] as String?;
            final file = payload['file_path'] ?? 'file';
            _streamLogs.add('📝 [Diff Proposed] $file');
            _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.approvalRequired);
            break;
          case 'approval.submitted':
            final approved = payload['approved'] == true;
            _streamLogs.add(approved ? '✔ [Approved] Changes accepted.' : '✖ [Rejected] Changes declined.');
            break;
          case 'approval.rejected':
            _streamLogs.add('✖ [Approval Rejected] Task aborted.');
            _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.cancelled);
            break;
          case 'task.completed':
            _streamLogs.add('✔ [Completed] ${payload['summary'] ?? 'Task finished.'}');
            _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.completed);
            break;
          case 'task.cancelled':
            _streamLogs.add('■ [Cancelled] ${payload['reason'] ?? 'Task cancelled.'}');
            _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.cancelled);
            break;
          case 'task.failed':
            _streamLogs.add('✖ [Failed] ${payload['error'] ?? 'Task execution error.'}');
            _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.failed);
            break;
        }
      });
    });
  }

  TaskModel _copyWithStatus(TaskModel task, TaskStatusEnum newStatus) {
    return TaskModel(
      id: task.id,
      projectId: task.projectId,
      workspaceId: task.workspaceId,
      title: task.title,
      prompt: task.prompt,
      status: newStatus,
      activeBranch: task.activeBranch,
      commitSha: task.commitSha,
      createdAt: task.createdAt,
      updatedAt: DateTime.now(),
      eventsCount: task.eventsCount + 1,
    );
  }

  Future<void> _handleApproval(bool approved) async {
    if (_activeTask == null || _projectId == null) return;
    setState(() => _isActing = true);

    final success = await TasksApiService.submitApproval(
      projectId: _projectId!,
      taskId: _activeTask!.id,
      approve: approved,
      reason: approved ? 'Approved via mobile overview' : 'Rejected via mobile overview',
    );

    if (mounted) {
      setState(() => _isActing = false);
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to submit approval')),
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

  void _showNewTaskDialog() {
    final titleCtrl = TextEditingController();
    final promptCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceMain,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('New Agent Task', style: AppTypography.headlineSm),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Task Title', style: AppTypography.labelMd),
              const SizedBox(height: 6),
              TextField(
                controller: titleCtrl,
                style: AppTypography.bodyMd,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppColors.surfaceElevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.borderSubtle),
                  ),
                  hintText: 'e.g. Implement retry policy',
                ),
              ),
              const SizedBox(height: 14),
              Text('Task Instructions / Prompt', style: AppTypography.labelMd),
              const SizedBox(height: 6),
              TextField(
                controller: promptCtrl,
                maxLines: 3,
                style: AppTypography.bodyMd,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppColors.surfaceElevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.borderSubtle),
                  ),
                  hintText: 'Describe what the agent should investigate or modify...',
                ),
              ),
              const SizedBox(height: 18),
              AppButton(
                text: 'Launch Agent Task',
                icon: const Icon(Icons.play_circle_fill, size: 18, color: Colors.white),
                onPressed: () async {
                  final title = titleCtrl.text.trim();
                  final prompt = promptCtrl.text.trim();
                  if (title.isEmpty || prompt.isEmpty || _projectId == null) return;
                  Navigator.pop(ctx);

                  final res = await TasksApiService.createTask(
                    projectId: _projectId!,
                    title: title,
                    prompt: prompt,
                  );

                  if (res.success && res.task != null) {
                    setState(() {
                      _tasks.insert(0, res.task!);
                      _selectAndStreamTask(res.task!);
                      _selectedTab = 1; // Switch to Chat/Coding Session
                    });
                  } else {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(res.errorMessage ?? 'Failed to create task')),
                      );
                    }
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showFileContentDialog(String filePath, String fileName) async {
    if (_projectId == null || _workspace == null) return;
    final content = await WorkspacesApiService.readFile(
      _projectId!,
      _workspace!.id,
      filePath,
    );

    if (mounted && content != null) {
      showDialog(
        context: context,
        builder: (dCtx) => AlertDialog(
          backgroundColor: AppColors.surfaceMain,
          title: Text(fileName, style: AppTypography.labelMd),
          content: SizedBox(
            width: double.maxFinite,
            height: 380,
            child: SingleChildScrollView(
              child: Text(
                content,
                style: AppTypography.codeSm.copyWith(fontSize: 11),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dCtx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }

  StatusType _statusType(TaskStatusEnum status) {
    switch (status) {
      case TaskStatusEnum.completed:
        return StatusType.success;
      case TaskStatusEnum.running:
        return StatusType.primary;
      case TaskStatusEnum.approvalRequired:
        return StatusType.warning;
      case TaskStatusEnum.failed:
      case TaskStatusEnum.cancelled:
      case TaskStatusEnum.queued:
      default:
        return StatusType.neutral;
    }
  }

  StatusType _workspaceStatusType(WorkspaceStatusEnum status) {
    switch (status) {
      case WorkspaceStatusEnum.running:
        return StatusType.success;
      case WorkspaceStatusEnum.creating:
      case WorkspaceStatusEnum.pending:
        return StatusType.primary;
      case WorkspaceStatusEnum.stopping:
      case WorkspaceStatusEnum.stopped:
        return StatusType.neutral;
      case WorkspaceStatusEnum.failed:
        return StatusType.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        showBack: true,
        onBackPressed: () => Navigator.of(context).maybePop(),
        title: widget.projectName,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary, size: 20),
            onPressed: _resolveProjectAndLoadData,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            children: [
              // Contextual Project Navigation Tabs (Overview, Chat, Workspace, Changes)
              Container(
                decoration: const BoxDecoration(
                  color: AppColors.surfaceMain,
                  border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
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

              // Tab Body
              Expanded(
                child: _buildSelectedTabContent(),
              ),
            ],
          ),
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

  // TAB 0: Project Overview (Metadata, Primary Session CTA, Workspace Status, Recent Tasks)
  Widget _buildOverviewTab() {
    final defaultBranch = _project?.defaultBranch ?? _gitStatus?.branch ?? 'main';
    final repoOrPath = _project?.workspacePath ?? _project?.repoUrl ?? 'Local Folder';
    final isDockerRunning = _workspace != null && _workspace!.status == WorkspaceStatusEnum.running;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Project Title & Status Badge
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  widget.projectName,
                  style: AppTypography.headlineLg,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              StatusBadge(
                label: isDockerRunning ? 'Docker: Running' : 'Connected',
                type: StatusType.success,
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Metadata Chips
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _buildMetaPill(Icons.fork_right, defaultBranch),
              _buildMetaPill(Icons.folder_outlined, repoOrPath),
              if (_project?.sourceType != null)
                _buildMetaPill(Icons.tag, _project!.sourceType.toUpperCase()),
            ],
          ),
          const SizedBox(height: 16),

          // Primary Actions Row: Open Coding Session + Open Workspace
          Row(
            children: [
              Expanded(
                child: AppButton(
                  text: 'Open Coding Session',
                  icon: const Icon(Icons.play_circle_outline, size: 18, color: Colors.white),
                  onPressed: () => setState(() => _selectedTab = 1),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
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
              Text('Project Tasks', style: AppTypography.headlineSm),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 14, color: AppColors.lavender),
                label: Text('New Task', style: AppTypography.labelSm.copyWith(color: AppColors.lavender)),
                onPressed: _showNewTaskDialog,
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
                      'No tasks created yet. Tap "Open Coding Session" to start.',
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
                  onTap: () {
                    _selectAndStreamTask(task);
                    setState(() => _selectedTab = 1);
                  },
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

  // TAB 1: Coding Session (Agent Chat, WebSocket Stream, Approvals, Diff)
  Widget _buildChatSessionTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Agent Coding Session', style: AppTypography.headlineSm),
              AppButton(
                text: '+ New Task',
                width: 105,
                height: 36,
                onPressed: _showNewTaskDialog,
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Active Task Card
          if (_activeTask != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
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
                          _activeTask!.title,
                          style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusBadge(
                        label: _activeTask!.status.label.toUpperCase(),
                        type: _statusType(_activeTask!.status),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _activeTask!.prompt,
                    style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Approval Gate Card
          if (_activeTask != null && _activeTask!.status == TaskStatusEnum.approvalRequired) ...[
            _buildApprovalGateCard(),
            const SizedBox(height: 12),
          ],

          // Live WebSocket Agent Event Stream Box
          _buildLiveAgentStreamCard(),
          const SizedBox(height: 12),

          // Proposed Diff Preview
          if (_proposedDiff != null) ...[
            _buildDiffPreviewCard(),
            const SizedBox(height: 12),
          ],
        ],
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

  Widget _buildLiveAgentStreamCard() {
    return Container(
      padding: const EdgeInsets.all(12),
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
              Row(
                children: [
                  const Icon(Icons.stream, size: 14, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Text('Agent Live Stream', style: AppTypography.labelMd),
                ],
              ),
              StatusBadge(
                label: _streamLogs.isNotEmpty ? 'STREAMING' : 'IDLE',
                type: _streamLogs.isNotEmpty ? StatusType.success : StatusType.neutral,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            height: 150,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: SingleChildScrollView(
              reverse: true,
              child: Text(
                _streamLogs.isEmpty ? 'No events yet. Launch a task to start agent execution.' : _streamLogs.join('\n'),
                style: AppTypography.codeSm.copyWith(fontSize: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApprovalGateCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.statusWarning),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const StatusBadge(
            label: 'APPROVAL REQUIRED',
            type: StatusType.warning,
            icon: Icons.lock_outline,
          ),
          const SizedBox(height: 8),
          Text(
            'The agent has prepared modifications that require your review and approval.',
            style: AppTypography.bodySm,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.statusSuccess,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  icon: const Icon(Icons.check, size: 16, color: Colors.white),
                  label: const Text('Approve', style: TextStyle(color: Colors.white)),
                  onPressed: _isActing ? null : () => _handleApproval(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.statusError,
                    side: const BorderSide(color: AppColors.statusError),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Reject'),
                  onPressed: _isActing ? null : () => _handleApproval(false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDiffPreviewCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Proposed Changes', style: AppTypography.labelMd),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Text(
              _proposedDiff ?? '',
              style: AppTypography.codeSm.copyWith(fontSize: 10),
            ),
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
