import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';
import '../../services/projects_api_service.dart';

enum DashboardState { populated, offline, empty, skeleton }

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
  DashboardState _state = DashboardState.populated;
  final TextEditingController _searchController = TextEditingController();

  List<ProjectModel> _liveProjects = [];
  bool _isLoadingProjects = false;
  String? _projectsError;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    setState(() => _isLoadingProjects = true);
    final result = await ProjectsApiService.listProjects(limit: 5);
    if (mounted) {
      setState(() {
        _isLoadingProjects = false;
        if (result.success) {
          _liveProjects = result.items;
          _projectsError = null;
        } else {
          _projectsError = result.errorMessage;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        onMenuPressed: widget.onOpenDrawer,
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined, color: AppColors.textSecondary, size: 20),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Notifications (3 new)')),
                  );
                },
              ),
              Positioned(
                right: 12,
                top: 12,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: AppColors.statusWarning,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: CircleAvatar(
              radius: 15,
              backgroundColor: AppColors.secondaryContainer,
              child: Text(
                'SD',
                style: AppTypography.labelSm.copyWith(
                  color: AppColors.lavender,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // State Switcher (Demo Rail)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              color: AppColors.surfaceMain,
              border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
            ),
            child: Row(
              children: [
                Text('STATE:', style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11)),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: DashboardState.values.map((s) {
                        final isSelected = _state == s;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InkWell(
                            onTap: () => setState(() => _state = s),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isSelected ? AppColors.surfaceElevated : Colors.transparent,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: isSelected ? AppColors.primary : AppColors.borderSubtle,
                                ),
                              ),
                              child: Text(
                                s.name.toUpperCase(),
                                style: AppTypography.labelSm.copyWith(
                                  color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Main Body
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: _buildContent(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_state) {
      case DashboardState.populated:
        return _buildPopulatedView();
      case DashboardState.offline:
        return _buildOfflineView();
      case DashboardState.empty:
        return _buildEmptyView();
      case DashboardState.skeleton:
        return _buildSkeletonView();
    }
  }

  Widget _buildPopulatedView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Greeting & Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Good morning, Sajiv', style: AppTypography.headlineMd),
                  const SizedBox(height: 2),
                  Text('Pick up where you left off.', style: AppTypography.bodySm),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const StatusBadge(
              label: '3 active',
              type: StatusType.success,
              showDot: true,
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Search Bar
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceMain,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Row(
            children: [
              const Icon(Icons.search, color: AppColors.textSecondary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  style: AppTypography.bodyMd.copyWith(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search projects, tasks, or conversations...',
                    hintStyle: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Text('⌘K', style: AppTypography.labelSm.copyWith(fontSize: 10)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Primary Action CTA: New Project
        AppButton(
          text: '+ New project',
          icon: const Icon(Icons.add, size: 18, color: Colors.white),
          onPressed: widget.onNewProject,
        ),
        const SizedBox(height: 16),

        // Workspace Connectivity Status Strip
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.statusSuccess,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Laptop (Nagercoil)',
                            style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          ' · Online',
                          style: AppTypography.codeSm.copyWith(color: AppColors.statusSuccess),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Manage',
                        style: AppTypography.labelSm.copyWith(color: AppColors.lavender),
                      ),
                      const Icon(Icons.chevron_right, size: 14, color: AppColors.lavender),
                    ],
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Divider(color: AppColors.borderSubtle),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        const Icon(Icons.terminal, size: 16, color: AppColors.lavender),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Antigravity CLI · Ready',
                            style: AppTypography.codeSm,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.speed, size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Text('us-east-2 · 28ms', style: AppTypography.codeSm.copyWith(fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Recent Projects Section
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text('Recent Projects', style: AppTypography.headlineSm),
                const SizedBox(width: 6),
                Text(
                  _isLoadingProjects ? '(...)' : '(${_liveProjects.length})',
                  style: AppTypography.codeSm,
                ),
              ],
            ),
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
        const SizedBox(height: 10),

        if (_isLoadingProjects)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
              ),
            ),
          )
        else if (_liveProjects.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Column(
              children: [
                const Icon(Icons.folder_open, size: 28, color: AppColors.textSecondary),
                const SizedBox(height: 8),
                Text('No projects found', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  'Create your first project to start agentic development.',
                  style: AppTypography.bodySm,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                AppButton(
                  text: '+ Create Project',
                  onPressed: widget.onNewProject,
                ),
              ],
            ),
          )
        else
          ..._liveProjects.take(3).map((project) {
            IconData icon = Icons.folder_outlined;
            if (project.sourceType == 'github') icon = Icons.code;
            if (project.sourceType == 'ideation') icon = Icons.lightbulb_outline;
            if (project.sourceType == 'scratch') icon = Icons.alt_route;

            final timeAgo = _formatTimeAgo(project.updatedAt);

            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: _buildProjectCard(
                name: project.name,
                icon: icon,
                badgeLabel: project.sourceType.toUpperCase(),
                badgeType: StatusType.success,
                branch: project.defaultBranch,
                commit: project.workspacePath ?? project.repoUrl ?? 'Local',
                timeAgo: timeAgo,
                agentInfo: project.description ?? 'Project ready',
                onTap: () => widget.onOpenProject?.call(project.name),
              ),
            );
          }),
        const SizedBox(height: 22),

        // Recent Tasks & Activity Section
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'Recent Tasks & Activity',
                style: AppTypography.headlineSm,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text('Real-time log', style: AppTypography.codeSm.copyWith(fontSize: 11)),
          ],
        ),
        const SizedBox(height: 10),

        // Task 1: Running
        _buildTaskCard(
          status: 'RUNNING · 12m ago',
          statusType: StatusType.info,
          project: 'jess-ide-backend',
          title: 'Add JWT authentication to FastAPI backend',
          subtitle: 'Generating test suites for token invalidation...',
        ),
        const SizedBox(height: 8),

        // Task 2: Approval Required
        _buildApprovalTaskCard(
          status: 'APPROVAL REQUIRED · 45m ago',
          project: 'stitch-orchestrator',
          title: 'Git Push: Deploy staging schema migrations',
          diffSummary: '+142 / -18 lines',
        ),
        const SizedBox(height: 8),

        // Task 3: Completed
        _buildTaskCard(
          status: 'COMPLETED · 2h ago',
          statusType: StatusType.success,
          project: 'cloudaiagent',
          title: 'Setup ephemeral workspace state machine',
          subtitle: '27 unit tests passing',
        ),
      ],
    );
  }

  Widget _buildProjectCard({
    required String name,
    required IconData icon,
    required String badgeLabel,
    required StatusType badgeType,
    required String branch,
    required String commit,
    required String timeAgo,
    required String agentInfo,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surfaceMain,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          name,
                          style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusBadge(label: badgeLabel, type: badgeType),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainer,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fork_right, size: 12, color: AppColors.textPrimary),
                      const SizedBox(width: 4),
                      Text(branch, style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary)),
                    ],
                  ),
                ),
                Text(commit, style: AppTypography.codeSm),
                Text('•', style: AppTypography.codeSm),
                Text(timeAgo, style: AppTypography.codeSm),
              ],
            ),
            const SizedBox(height: 8),
            const Divider(color: AppColors.borderSubtle),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.smart_toy_outlined, size: 14, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Text(agentInfo, style: AppTypography.codeSm.copyWith(fontSize: 11)),
                  ],
                ),
                const Icon(Icons.chevron_right, size: 16, color: AppColors.textSecondary),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskCard({
    required String status,
    required StatusType statusType,
    required String project,
    required String title,
    required String subtitle,
  }) {
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
              StatusBadge(label: status, type: statusType),
              Text(project, style: AppTypography.codeSm.copyWith(fontSize: 11)),
            ],
          ),
          const SizedBox(height: 6),
          Text(title, style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(subtitle, style: AppTypography.codeSm.copyWith(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildApprovalTaskCard({
    required String status,
    required String project,
    required String title,
    required String diffSummary,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.statusWarning.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Flexible(
                child: StatusBadge(
                  label: 'APPROVAL REQUIRED',
                  type: StatusType.warning,
                  icon: Icons.lock_outline,
                ),
              ),
              const SizedBox(width: 8),
              Text(project, style: AppTypography.codeSm.copyWith(fontSize: 11)),
            ],
          ),
          const SizedBox(height: 6),
          Text(title, style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.rule, size: 14, color: AppColors.statusWarning),
                    const SizedBox(width: 6),
                    Text('Review Diff & Approve', style: AppTypography.labelSm),
                  ],
                ),
              ),
              Text(diffSummary, style: AppTypography.codeSm.copyWith(fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.cloud_off, size: 48, color: AppColors.statusError),
            const SizedBox(height: 16),
            Text('Development Host Offline', style: AppTypography.headlineMd),
            const SizedBox(height: 8),
            Text(
              'Cannot connect to laptop daemon at us-east-2. Please verify your internet connection or start the local daemon.',
              style: AppTypography.bodyMd,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            AppButton(
              text: 'Retry Connection',
              variant: AppButtonVariant.primary,
              onPressed: () => setState(() => _state = DashboardState.populated),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.folder_open, size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text('No Projects Yet', style: AppTypography.headlineMd),
            const SizedBox(height: 8),
            Text(
              'Create your first project from a repository, local directory, template, or idea.',
              style: AppTypography.bodyMd,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            AppButton(
              text: 'Create your first project',
              onPressed: widget.onNewProject,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkeletonView() {
    return Column(
      children: List.generate(
        4,
        (i) => Container(
          margin: const EdgeInsets.only(bottom: 12),
          height: 100,
          decoration: BoxDecoration(
            color: AppColors.surfaceMain,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.borderSubtle),
          ),
        ),
      ),
    );
  }
}
