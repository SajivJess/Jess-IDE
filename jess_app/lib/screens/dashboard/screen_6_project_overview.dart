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

  // Phase 5 Task & Streaming State
  String? _projectId;
  List<TaskModel> _tasks = [];
  TaskModel? _activeTask;
  TaskStreamService? _streamService;
  StreamSubscription? _streamSub;
  final List<String> _streamLogs = [];
  String? _proposedDiff;
  bool _isLoadingTasks = false;
  bool _isActing = false;

  @override
  void initState() {
    super.initState();
    _resolveProjectAndLoadTasks();
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _streamService?.dispose();
    super.dispose();
  }

  Future<void> _resolveProjectAndLoadTasks() async {
    setState(() => _isLoadingTasks = true);

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
      final taskRes = await TasksApiService.listTasks(projectId: matchingProject.id);
      if (taskRes.success) {
        _tasks = taskRes.items;
        if (_tasks.isNotEmpty) {
          _selectAndStreamTask(_tasks.first);
        }
      }
    }

    if (mounted) {
      setState(() => _isLoadingTasks = false);
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
            _streamLogs.add('🛑 [Cancelled] ${payload['reason'] ?? 'Task cancelled.'}');
            _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.cancelled);
            break;
          case 'task.failed':
            _streamLogs.add('❌ [Failed] ${payload['error'] ?? 'Task encountered an error.'}');
            _activeTask = _copyWithStatus(_activeTask!, TaskStatusEnum.failed);
            break;
          default:
            _streamLogs.add('· [${event.eventType}]');
        }
      });
    });

    _streamService!.connect();
  }

  TaskModel _copyWithStatus(TaskModel task, TaskStatusEnum status) {
    return TaskModel(
      id: task.id,
      projectId: task.projectId,
      workspaceId: task.workspaceId,
      title: task.title,
      prompt: task.prompt,
      status: status,
      activeBranch: task.activeBranch,
      commitSha: task.commitSha,
      createdAt: task.createdAt,
      updatedAt: DateTime.now(),
      eventsCount: task.eventsCount + 1,
    );
  }

  Future<void> _handleApproval(bool approve) async {
    if (_activeTask == null || _projectId == null) return;
    setState(() => _isActing = true);

    final success = await TasksApiService.submitApproval(
      projectId: _projectId!,
      taskId: _activeTask!.id,
      approve: approve,
      reason: approve ? 'Approved via mobile overview' : 'Rejected via mobile overview',
    );

    if (mounted) {
      setState(() => _isActing = false);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(approve ? 'Changes approved! Resuming agent...' : 'Changes rejected.'),
            backgroundColor: approve ? AppColors.statusSuccess : AppColors.statusWarning,
          ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Task cancelled successfully.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.errorMessage ?? 'Failed to cancel task.')),
        );
      }
    }
  }

  void _showNewTaskDialog() {
    final titleCtrl = TextEditingController(text: 'Implement Retry Policy');
    final promptCtrl = TextEditingController(
      text: 'Add exponential backoff retry logic to API client with 3 max retries.',
    );

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
            onPressed: _resolveProjectAndLoadTasks,
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
                      const SizedBox(height: 6),
                      Text(
                        'Project registered and stored in Jess Ide Dev database.',
                        style: AppTypography.bodyMd,
                      ),
                      const SizedBox(height: 12),

                      // Metadata Pills
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildMetaPill(Icons.terminal, widget.projectName),
                          _buildMetaPill(Icons.fork_right, 'main'),
                          _buildMetaPill(Icons.laptop_mac, 'Local dev host'),
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

                      // Assigned Workspace Card (Truthful status)
                      _buildSectionCard(
                        title: 'Assigned Workspace',
                        badge: const StatusBadge(label: 'Phase 6 Pending', type: StatusType.neutral),
                        children: [
                          _buildInfoRow('Host Device:', 'Local developer host'),
                          _buildInfoRow('Workspace Sandbox:', 'Decoupled Docker container (Phase 6)'),
                          _buildInfoRow('State:', 'Metadata stored; container runner pending Phase 6'),
                        ],
                      ),
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
                      'Live WebSocket Event Stream (Phase 5)',
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
                      'No events received yet. Tap "Create Agent Task" to trigger simulation.',
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
                  '${_tasks.length} tasks registered in database',
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
              Text('Approval Gate Required', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600, color: AppColors.statusWarning)),
              const StatusBadge(label: 'Pending Approval', type: StatusType.warning),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'The agent has prepared modifications to lib/services/api_client.dart. Review proposed changes below and decide whether to approve.',
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
