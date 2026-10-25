import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';
import '../../services/projects_api_service.dart';
import '../../services/tasks_api_service.dart';
import '../../services/auth_api_service.dart';

class Screen4HomeDashboard extends StatefulWidget {
  final VoidCallback? onNewProject;
  final ValueChanged<String>? onOpenProject;
  final VoidCallback? onViewAllProjects;
  final VoidCallback? onOpenDrawer;

  const Screen4HomeDashboard({
    super.key,
    this.onNewProject,
    this.onOpenProject,
    this.onViewAllProjects,
    this.onOpenDrawer,
  });

  @override
  State<Screen4HomeDashboard> createState() => _Screen4HomeDashboardState();
}

class _Screen4HomeDashboardState extends State<Screen4HomeDashboard> {
  final TextEditingController _searchController = TextEditingController();

  List<ProjectModel> _liveProjects = [];
  List<TaskModel> _recentTasks = [];
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
  }

  Future<void> _loadDashboardData() async {
    setState(() => _isLoading = true);
    final projResult = await ProjectsApiService.listProjects(limit: 5);

    List<TaskModel> tasks = [];
    if (projResult.success && projResult.items.isNotEmpty) {
      for (final p in projResult.items.take(2)) {
        final taskRes = await TasksApiService.listTasks(projectId: p.id, limit: 3);
        if (taskRes.success) {
          tasks.addAll(taskRes.items);
        }
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
        if (projResult.success) {
          _liveProjects = projResult.items;
          _recentTasks = tasks;
          _errorMessage = null;
        } else {
          _errorMessage = projResult.errorMessage;
        }
      });
    }
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  StatusType _statusTypeForTask(TaskStatusEnum status) {
    switch (status) {
      case TaskStatusEnum.running:
        return StatusType.primary;
      case TaskStatusEnum.approvalRequired:
        return StatusType.warning;
      case TaskStatusEnum.completed:
        return StatusType.success;
      case TaskStatusEnum.failed:
        return StatusType.error;
      case TaskStatusEnum.cancelled:
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
        onMenuPressed: widget.onOpenDrawer,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary, size: 20),
            onPressed: _loadDashboardData,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: CircleAvatar(
              radius: 14,
              backgroundColor: AppColors.secondaryContainer,
              child: Text(
                'DEV',
                style: AppTypography.codeSm.copyWith(
                  color: AppColors.lavender,
                  fontWeight: FontWeight.w600,
                  fontSize: 10,
                ),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadDashboardData,
        color: AppColors.primary,
        backgroundColor: AppColors.surfaceMain,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Developer Hub', style: AppTypography.headlineMd),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _errorMessage == null
                              ? AppColors.statusSuccess.withOpacity(0.12)
                              : AppColors.statusError.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _errorMessage == null
                                ? AppColors.statusSuccess.withOpacity(0.3)
                                : AppColors.statusError.withOpacity(0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: _errorMessage == null
                                    ? AppColors.statusSuccess
                                    : AppColors.statusError,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _errorMessage == null ? 'Backend Online' : 'Offline',
                              style: AppTypography.codeSm.copyWith(
                                color: _errorMessage == null
                                    ? AppColors.statusSuccess
                                    : AppColors.statusError,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Stat Tiles Strip
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricTile(
                          icon: Icons.folder_outlined,
                          value: '${_liveProjects.length}',
                          label: 'Projects',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricTile(
                          icon: Icons.bolt,
                          value: '${_recentTasks.length}',
                          label: 'Tasks',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricTile(
                          icon: Icons.dns_outlined,
                          value: 'Docker',
                          label: 'Workspace',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Search + Action Row
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 40,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceMain,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.borderSubtle),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.search, color: AppColors.textSecondary, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _searchController,
                                  style: AppTypography.bodyMd.copyWith(color: AppColors.textPrimary),
                                  onChanged: (_) => setState(() {}),
                                  decoration: InputDecoration(
                                    hintText: 'Filter projects...',
                                    hintStyle: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                                    border: InputBorder.none,
                                    isDense: true,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      AppButton(
                        text: '+ New',
                        width: 90,
                        height: 40,
                        onPressed: widget.onNewProject,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // Error / Offline Banner
                  if (_errorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceMain,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.statusError.withOpacity(0.5)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.cloud_off, color: AppColors.statusError, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Backend Unreachable', style: AppTypography.labelMd),
                                Text(
                                  _errorMessage!,
                                  style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: _loadDashboardData,
                            child: Text('Retry', style: AppTypography.labelSm.copyWith(color: AppColors.lavender)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Loading Indicator
                  if (_isLoading && _liveProjects.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 36),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                        ),
                      ),
                    ),

                  // Empty State
                  if (!_isLoading && _liveProjects.isEmpty && _errorMessage == null)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceMain,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Column(
                        children: [
                          const Icon(Icons.folder_open, size: 36, color: AppColors.textSecondary),
                          const SizedBox(height: 10),
                          Text('No Projects Found', style: AppTypography.headlineSm),
                          const SizedBox(height: 4),
                          Text(
                            'Create a project from GitHub, local files, or scratch.',
                            style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 14),
                          AppButton(
                            text: '+ Create Project',
                            onPressed: widget.onNewProject,
                          ),
                        ],
                      ),
                    ),

                  // Recent Projects List
                  if (_liveProjects.isNotEmpty) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Projects', style: AppTypography.headlineSm),
                        GestureDetector(
                          onTap: widget.onViewAllProjects,
                          child: Row(
                            children: [
                              Text('View all', style: AppTypography.labelSm.copyWith(color: AppColors.lavender)),
                              const Icon(Icons.arrow_forward, size: 12, color: AppColors.lavender),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    ..._filterProjects().map((project) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: _buildProjectCard(project),
                      );
                    }),
                    const SizedBox(height: 18),
                  ],

                  // Recent Activity / Tasks
                  if (_recentTasks.isNotEmpty) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Recent Tasks', style: AppTypography.headlineSm),
                        Text(
                          '${_recentTasks.length} active',
                          style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    ..._recentTasks.take(3).map((task) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: _buildTaskCard(task),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<ProjectModel> _filterProjects() {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _liveProjects;
    return _liveProjects.where((p) {
      return p.name.toLowerCase().contains(q) ||
          (p.description?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  Widget _buildMetricTile({
    required IconData icon,
    required String value,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.lavender),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  label,
                  style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProjectCard(ProjectModel project) {
    IconData icon = Icons.folder_outlined;
    if (project.sourceType == 'github') icon = Icons.code;
    if (project.sourceType == 'ideation') icon = Icons.lightbulb_outline;
    if (project.sourceType == 'scratch') icon = Icons.alt_route;

    final timeAgo = _formatTimeAgo(project.updatedAt);

    return InkWell(
      onTap: () => widget.onOpenProject?.call(project.name),
      borderRadius: BorderRadius.circular(8),
      child: Container(
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
                  child: Row(
                    children: [
                      Icon(icon, size: 16, color: AppColors.lavender),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          project.name,
                          style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusBadge(
                  label: project.sourceType.toUpperCase(),
                  type: StatusType.success,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fork_right, size: 12, color: AppColors.textPrimary),
                      const SizedBox(width: 4),
                      Text(project.defaultBranch, style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary, fontSize: 10)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    project.workspacePath ?? project.repoUrl ?? 'Local',
                    style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(timeAgo, style: AppTypography.codeSm.copyWith(fontSize: 10)),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 14, color: AppColors.textSecondary),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskCard(TaskModel task) {
    return Container(
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusBadge(
                label: task.status.label.toUpperCase(),
                type: _statusTypeForTask(task.status),
              ),
              Text(
                _formatTimeAgo(task.updatedAt),
                style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(task.title, style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
          if (task.prompt.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              task.prompt,
              style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
