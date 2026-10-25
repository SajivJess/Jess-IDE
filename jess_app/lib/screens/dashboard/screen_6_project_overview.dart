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
  final String projectName;
  final VoidCallback? onOpenChat;
  final VoidCallback? onBrowseFiles;
  final VoidCallback? onReviewChanges;

  const Screen6ProjectOverview({
    super.key,
    this.projectName = 'cloudaiagent',
    this.onOpenChat,
    this.onBrowseFiles,
    this.onReviewChanges,
  });

  @override
  State<Screen6ProjectOverview> createState() => _Screen6ProjectOverviewState();
}

class _Screen6ProjectOverviewState extends State<Screen6ProjectOverview> {
  int _selectedTab = 0;
  final List<String> _tabs = ['Overview', 'Chat', 'Files', 'Changes', 'Activity', 'Artifacts'];

  // Project & Task State
  String? _projectId;
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

  @override
  void initState() {
    super.initState();
    _resolveProjectAndLoadData();
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _streamService?.dispose();
    super.dispose();
  }

  Future<void> _resolveProjectAndLoadData() async {
    setState(() {
      _isLoadingTasks = true;
      _isLoadingWorkspace = true;
    });

    // Look for matching project in cached projects
    ProjectModel? matchingProject;
    for (final p in ProjectsApiService.cachedProjects) {
      if (p.name.toLowerCase() == widget.projectName.toLowerCase()) {
        matchingProject = p;
        break;
      }
    }

    if (matchingProject == null) {
      final listRes = await ProjectsApiService.listProjects();
      if (listRes.success && listRes.items.isNotEmpty) {
        for (final p in listRes.items) {
          if (p.name.toLowerCase() == widget.projectName.toLowerCase()) {
            matchingProject = p;
            break;
          }
        }
        matchingProject ??= listRes.items.first;
      }
    }

    if (matchingProject != null) {
      _projectId = matchingProject.id;
      await Future.wait([
        _loadTasks(matchingProject.id),
        _loadWorkspace(matchingProject.id),
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
      if (_tasks.isNotEmpty) {
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
      }
    }
  }

  Future<void> _loadGitStatus() async {
    if (_projectId == null || _workspace == null) return;
    final status = await WorkspacesApiService.getGitStatus(_projectId!, _workspace!.id);
    if (mounted) {
      setState(() => _gitStatus = status);
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
          const SnackBar(content: Text('Workspace provisioned successfully')),
        );
        _loadGitStatus();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to provision workspace')),
        );
      }
    }
  }

  Future<void> _startWorkspace() async {
    if (_projectId == null || _workspace == null) return;
    setState(() => _isActingWorkspace = true);
    final ws = await WorkspacesApiService.startWorkspace(_projectId!, _workspace!.id);
    if (mounted) {
      setState(() {
        _isActingWorkspace = false;
        if (ws != null) _workspace = ws;
      });
      if (ws != null) {
        _loadGitStatus();
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
            _streamLogs.add('📄 [Diff Proposed] Patch prepared for $file');
            break;
          case 'approval.required':
            _streamLogs.add('⚠️ [Approval Gate] User confirmation required.');
            _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.approvalRequired);
            break;
          case 'approval.granted':
            _streamLogs.add('✔ [Approval Granted] Resuming execution...');
            _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.running);
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

  Future<void> _handleCancelTask() async {
    if (_activeTask == null || _projectId == null) return;
    setState(() => _isActing = true);

    final res = await TasksApiService.cancelTask(
      projectId: _projectId!,
      taskId: _activeTask!.id,
    );

    if (mounted) {
      setState(() => _isActing = false);
      if (res.success) {
        setState(() {
          _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.cancelled);
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.errorMessage ?? 'Failed to cancel task')),
        );
      }
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
                  Text('Create Agent Coding Task', style: AppTypography.headlineSm),
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
                  hintText: 'e.g. Implement Retry Policy',
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
                icon: const Icon(Icons.play_arrow, size: 18, color: Colors.white),
                onPressed: () async {
                  if (_projectId == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Cannot create task: Project not loaded.')),
                    );
                    return;
                  }
                  Navigator.pop(ctx);
                  setState(() => _isLoadingTasks = true);

                  final res = await TasksApiService.createTask(
                    projectId: _projectId!,
                    title: titleCtrl.text,
                    prompt: promptCtrl.text,
                  );

                  if (mounted) {
                    setState(() => _isLoadingTasks = false);
                    if (res.success && res.task != null) {
                      setState(() {
                        _tasks.insert(0, res.task!);
                      });
                      _selectAndStreamTask(res.task!);
                    } else {
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

  void _showRunCommandBottomSheet() {
    if (_projectId == null || _workspace == null) return;
    final cmdCtrl = TextEditingController(text: 'git status');
    WorkspaceCommandResult? lastResult;
    bool isRunning = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceMain,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
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
                      Row(
                        children: [
                          const Icon(Icons.terminal, color: AppColors.lavender, size: 20),
                          const SizedBox(width: 8),
                          Text('Workspace Terminal', style: AppTypography.headlineSm),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: AppColors.textSecondary),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text('Quick presets:', style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: ['git status', 'ls -la', 'git diff', 'python -V'].map((preset) {
                      return ActionChip(
                        label: Text(preset, style: AppTypography.codeSm.copyWith(fontSize: 11)),
                        backgroundColor: AppColors.surfaceElevated,
                        onPressed: () {
                          setModalState(() {
                            cmdCtrl.text = preset;
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: cmdCtrl,
                          style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: AppColors.background,
                            hintText: 'e.g. git status',
                            hintStyle: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                            prefixText: r'$ ',
                            prefixStyle: AppTypography.codeSm.copyWith(color: AppColors.lavender),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: AppColors.borderSubtle),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: isRunning
                              ? null
                              : () async {
                                  final raw = cmdCtrl.text.trim();
                                  if (raw.isEmpty) return;
                                  final parts = raw.split(RegExp(r'\s+'));
                                  setModalState(() => isRunning = true);
                                  final res = await WorkspacesApiService.runCommand(
                                    _projectId!,
                                    _workspace!.id,
                                    parts,
                                  );
                                  setModalState(() {
                                    isRunning = false;
                                    lastResult = res;
                                  });
                                },
                          child: isRunning
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Text('Run', style: TextStyle(color: Colors.white)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (lastResult != null) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        StatusBadge(
                          label: lastResult!.exitCode == 0 ? 'Exit 0' : 'Exit ${lastResult!.exitCode}',
                          type: lastResult!.exitCode == 0 ? StatusType.success : StatusType.error,
                        ),
                        Text(
                          '${(lastResult!.durationSeconds * 1000).toInt()}ms',
                          style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      height: 160,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          (lastResult!.stdout.isNotEmpty ? lastResult!.stdout : lastResult!.stderr).isEmpty
                              ? '(No output returned)'
                              : (lastResult!.stdout.isNotEmpty ? lastResult!.stdout : lastResult!.stderr),
                          style: AppTypography.codeSm.copyWith(
                            color: lastResult!.exitCode == 0 ? AppColors.textPrimary : AppColors.statusError,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showBrowseFilesBottomSheet() {
    if (_projectId == null || _workspace == null) {
      if (widget.onBrowseFiles != null) widget.onBrowseFiles!();
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceMain,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return FutureBuilder<List<WorkspaceFileItem>>(
          future: WorkspacesApiService.listFiles(_projectId!, _workspace!.id),
          builder: (context, snapshot) {
            return Container(
              height: 480,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.folder_open, color: AppColors.primary, size: 20),
                          const SizedBox(width: 8),
                          Text('Workspace Files', style: AppTypography.headlineSm),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: AppColors.textSecondary),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: snapshot.connectionState == ConnectionState.waiting
                        ? const Center(child: CircularProgressIndicator())
                        : snapshot.hasError || !snapshot.hasData || snapshot.data!.isEmpty
                            ? Center(
                                child: Text(
                                  'No files found in workspace.',
                                  style: AppTypography.bodyMd.copyWith(color: AppColors.textSecondary),
                                ),
                              )
                            : ListView.separated(
                                itemCount: snapshot.data!.length,
                                separatorBuilder: (_, __) => const Divider(color: AppColors.borderSubtle),
                                itemBuilder: (context, idx) {
                                  final item = snapshot.data![idx];
                                  return ListTile(
                                    dense: true,
                                    leading: Icon(
                                      item.isDirectory ? Icons.folder : Icons.insert_drive_file,
                                      color: item.isDirectory ? AppColors.primary : AppColors.lavender,
                                      size: 18,
                                    ),
                                    title: Text(item.name, style: AppTypography.codeSm),
                                    trailing: Text(
                                      item.isDirectory ? 'dir' : '${item.sizeBytes} B',
                                      style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                                    ),
                                    onTap: item.isDirectory
                                        ? null
                                        : () async {
                                            final content = await WorkspacesApiService.readFile(
                                              _projectId!,
                                              _workspace!.id,
                                              item.path,
                                            );
                                            if (context.mounted && content != null) {
                                              showDialog(
                                                context: context,
                                                builder: (dCtx) => AlertDialog(
                                                  backgroundColor: AppColors.surfaceMain,
                                                  title: Text(item.name, style: AppTypography.labelMd),
                                                  content: SizedBox(
                                                    width: double.maxFinite,
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
                                          },
                                  );
                                },
                              ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showGitDiffBottomSheet() {
    if (_projectId == null || _workspace == null) {
      if (widget.onReviewChanges != null) widget.onReviewChanges!();
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceMain,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return FutureBuilder<WorkspaceGitDiff?>(
          future: WorkspacesApiService.getGitDiff(_projectId!, _workspace!.id),
          builder: (context, snapshot) {
            return Container(
              height: 480,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.difference_outlined, color: AppColors.lavender, size: 20),
                          const SizedBox(width: 8),
                          Text('Workspace Git Diff', style: AppTypography.headlineSm),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: AppColors.textSecondary),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: snapshot.connectionState == ConnectionState.waiting
                        ? const Center(child: CircularProgressIndicator())
                        : snapshot.hasError || !snapshot.hasData || snapshot.data!.diff.isEmpty
                            ? Center(
                                child: Text(
                                  'Working tree clean. No active Git changes.',
                                  style: AppTypography.bodyMd.copyWith(color: AppColors.statusSuccess),
                                ),
                              )
                            : Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: AppColors.background,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.borderSubtle),
                                ),
                                child: SingleChildScrollView(
                                  child: Text(
                                    snapshot.data!.diff,
                                    style: AppTypography.codeSm.copyWith(
                                      color: AppColors.textPrimary,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  StatusType _statusTypeFromEnum(TaskStatusEnum status) {
    switch (status) {
      case TaskStatusEnum.completed:
        return StatusType.success;
      case TaskStatusEnum.running:
        return StatusType.primary;
      case TaskStatusEnum.approvalRequired:
        return StatusType.warning;
      case TaskStatusEnum.failed:
      case TaskStatusEnum.cancelled:
        return StatusType.neutral;
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
        title: 'Projects / ${widget.projectName}',
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary, size: 20),
            onPressed: _resolveProjectAndLoadData,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              // Horizontal Project Tabs
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
                      return InkWell(
                        onTap: () {
                          setState(() => _selectedTab = index);
                          if (index == 1 && widget.onOpenChat != null) {
                            widget.onOpenChat!();
                          } else if (index == 2) {
                            _showBrowseFilesBottomSheet();
                          } else if (index == 3) {
                            _showGitDiffBottomSheet();
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
                          child: Text(
                            _tabs[index],
                            style: AppTypography.labelMd.copyWith(
                              color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),

              // Overview Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Project Header Block
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
                          const StatusBadge(label: 'Registered', type: StatusType.success),
                        ],
                      ),
                      // Metadata Pills
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildMetaPill(Icons.terminal, widget.projectName),
                          _buildMetaPill(Icons.fork_right, _gitStatus?.branch ?? 'main'),
                          _buildMetaPill(
                            Icons.check_circle_outline,
                            _gitStatus?.isClean == true ? 'clean' : 'modified',
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Phase 5 Action: Launch or View Tasks
                      Row(
                        children: [
                          Expanded(
                            child: AppButton(
                              text: 'Create Agent Task',
                              icon: const Icon(Icons.play_circle_outline, size: 18, color: Colors.white),
                              onPressed: _showNewTaskDialog,
                            ),
                          ),
                          const SizedBox(width: 8),
                          AppButton(
                            text: 'Chat',
                            width: 90,
                            variant: AppButtonVariant.outline,
                            icon: const Icon(Icons.chat_bubble_outline, size: 16),
                            onPressed: widget.onOpenChat,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Real-time Agent Streaming & Task Engine Section
                      _buildLiveAgentStreamCard(),
                      const SizedBox(height: 14),

                      // Proposed Changes / Approval Card
                      if (_activeTask != null && _activeTask!.status == TaskStatusEnum.approvalRequired)
                        _buildApprovalGateCard()
                      else if (_proposedDiff != null)
                        _buildDiffPreviewCard(),

                      const SizedBox(height: 14),

                      // Phase 6 Remote Workspace Card
                      _buildWorkspaceManagementCard(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWorkspaceManagementCard() {
    if (_isLoadingWorkspace) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surfaceMain,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_workspace == null) {
      return _buildSectionCard(
        title: 'Remote Docker Workspace',
        badge: const StatusBadge(label: 'Unprovisioned', type: StatusType.neutral),
        children: [
          Text(
            'No isolated sandbox environment provisioned for this project.',
            style: AppTypography.bodyMd.copyWith(fontSize: 12),
          ),
          const SizedBox(height: 14),
          AppButton(
            text: 'Provision Remote Workspace',
            icon: const Icon(Icons.add_box_outlined, size: 18, color: Colors.white),
            onPressed: _isActingWorkspace ? null : _provisionWorkspace,
          ),
        ],
      );
    }

    final ws = _workspace!;
    final isRunning = ws.status == WorkspaceStatusEnum.running;

    return _buildSectionCard(
      title: 'Remote Docker Workspace',
      badge: StatusBadge(
        label: ws.status.label,
        type: _workspaceStatusType(ws.status),
      ),
      children: [
        _buildInfoRow('Workspace ID:', ws.id.substring(0, ws.id.length > 8 ? 8 : ws.id.length)),
        _buildInfoRow('Container:', ws.containerId ?? 'Isolated Sandbox'),
        _buildInfoRow('Environment:', ws.imageName ?? 'Standard Dev Container'),
        if (ws.rootPath != null)
          _buildInfoRow('Root Path:', ws.rootPath!),
        if (ws.errorMessage != null) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.statusError.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.statusError.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, size: 16, color: AppColors.statusError),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ws.errorMessage!,
                    style: AppTypography.codeSm.copyWith(color: AppColors.statusError, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),

        // Workspace Controls
        Row(
          children: [
            if (isRunning) ...[
              Expanded(
                child: AppButton(
                  text: 'Terminal',
                  variant: AppButtonVariant.primary,
                  icon: const Icon(Icons.terminal, size: 16, color: Colors.white),
                  onPressed: _showRunCommandBottomSheet,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppButton(
                  text: 'Stop',
                  variant: AppButtonVariant.outline,
                  icon: const Icon(Icons.stop, size: 16),
                  onPressed: _isActingWorkspace ? null : _stopWorkspace,
                ),
              ),
            ] else ...[
              Expanded(
                child: AppButton(
                  text: 'Start Workspace',
                  variant: AppButtonVariant.primary,
                  icon: const Icon(Icons.play_arrow, size: 16, color: Colors.white),
                  onPressed: _isActingWorkspace ? null : _startWorkspace,
                ),
              ),
            ],
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18, color: AppColors.textSecondary),
              tooltip: 'Restart Workspace',
              onPressed: _isActingWorkspace ? null : _restartWorkspace,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: const BorderSide(color: AppColors.borderSubtle),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.folder_open, size: 16, color: AppColors.primary),
                label: const Text('Browse Files', style: TextStyle(fontSize: 12)),
                onPressed: _showBrowseFilesBottomSheet,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: const BorderSide(color: AppColors.borderSubtle),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.difference_outlined, size: 16, color: AppColors.lavender),
                label: const Text('Review Diff', style: TextStyle(fontSize: 12)),
                onPressed: _showGitDiffBottomSheet,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLiveAgentStreamCard() {
    final status = _activeTask?.status ?? TaskStatusEnum.queued;
    final isStreaming = status == TaskStatusEnum.running || status == TaskStatusEnum.queued;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: status == TaskStatusEnum.approvalRequired
              ? AppColors.statusWarning
              : AppColors.borderSubtle,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _activeTask?.title ?? 'Agent Task Engine',
                      style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Live WebSocket Event Stream',
                      style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                    ),
                  ],
                ),
              ),
              StatusBadge(
                label: status.label,
                type: _statusTypeFromEnum(status),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: AppColors.borderSubtle),
          const SizedBox(height: 8),

          // Real-time Event Terminal
          Container(
            height: 120,
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: _streamLogs.isEmpty
                ? Center(
                    child: Text(
                      'Terminal idle · Ready for task execution',
                      style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    reverse: false,
                    itemCount: _streamLogs.length,
                    itemBuilder: (ctx, i) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.0),
                        child: Text(
                          _streamLogs[i],
                          style: AppTypography.codeSm.copyWith(
                            color: _streamLogs[i].contains('⚠️')
                                ? AppColors.statusWarning
                                : _streamLogs[i].contains('✔')
                                    ? AppColors.statusSuccess
                                    : _streamLogs[i].contains('⚡')
                                        ? AppColors.lavender
                                        : AppColors.textPrimary,
                            fontSize: 11,
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 10),

          // Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (isStreaming)
                TextButton.icon(
                  icon: const Icon(Icons.cancel_outlined, size: 16, color: AppColors.statusError),
                  label: Text('Cancel Task', style: AppTypography.codeSm.copyWith(color: AppColors.statusError)),
                  onPressed: _isActing ? null : _handleCancelTask,
                )
              else
                Text(
                  '${_tasks.length} tasks',
                  style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                ),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16, color: AppColors.primary),
                label: Text('New Task', style: AppTypography.codeSm.copyWith(color: AppColors.primary)),
                onPressed: _showNewTaskDialog,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildApprovalGateCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.statusWarning, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Approval Required', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600, color: AppColors.statusWarning)),
              const StatusBadge(label: 'Pending', type: StatusType.warning),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Review proposed modifications and decide whether to apply changes.',
            style: AppTypography.bodyMd.copyWith(fontSize: 12),
          ),
          const SizedBox(height: 10),
          if (_proposedDiff != null)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _proposedDiff!,
                style: AppTypography.codeSm.copyWith(color: AppColors.statusSuccess, fontSize: 11),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  text: 'Approve & Apply',
                  height: 38,
                  onPressed: _isActing ? null : () => _handleApproval(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppButton(
                  text: 'Reject',
                  height: 38,
                  variant: AppButtonVariant.outline,
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Proposed Diff Applied', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _proposedDiff!,
              style: AppTypography.codeSm.copyWith(color: AppColors.statusSuccess, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaPill(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.lavender),
          const SizedBox(width: 6),
          Text(label, style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required Widget badge,
    required List<Widget> children,
  }) {
    return Container(
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
              Expanded(
                child: Text(title, style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              badge,
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: AppColors.borderSubtle),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: AppTypography.codeSm.copyWith(fontSize: 11)),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
