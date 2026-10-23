import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';

class ProjectItem {
  final String id;
  final String name;
  final String description;
  final String source; // github, host, zip, ideation, template
  final String? branch;
  final String workspacePath;
  final String lastActivity;
  final String status;
  final StatusType statusType;

  const ProjectItem({
    required this.id,
    required this.name,
    required this.description,
    required this.source,
    this.branch,
    required this.workspacePath,
    required this.lastActivity,
    required this.status,
    required this.statusType,
  });
}

class Screen5ProjectsList extends StatefulWidget {
  final VoidCallback? onNewProject;
  final ValueChanged<String>? onSelectProject;

  const Screen5ProjectsList({
    super.key,
    this.onNewProject,
    this.onSelectProject,
  });

  @override
  State<Screen5ProjectsList> createState() => _Screen5ProjectsListState();
}

class _Screen5ProjectsListState extends State<Screen5ProjectsList> {
  String _selectedSource = 'all';
  final TextEditingController _searchController = TextEditingController();

  final List<ProjectItem> _allProjects = const [
    ProjectItem(
      id: 'cloudaiagent',
      name: 'cloudaiagent',
      description: 'Jess IDE Dev backend & agent orchestration daemon for Android.',
      source: 'github',
      branch: 'main',
      workspacePath: 'D:\\SajivJess\\jess dev ide',
      lastActivity: '24m ago',
      status: 'Active',
      statusType: StatusType.success,
    ),
    ProjectItem(
      id: 'jess-ide-backend',
      name: 'jess-ide-backend',
      description: 'FastAPI microservice for task queue and JWT security enforcement.',
      source: 'github',
      branch: 'feature/auth-jwt',
      workspacePath: 'E:\\cloudaiagent\\backend',
      lastActivity: '2h ago',
      status: 'Ready',
      statusType: StatusType.success,
    ),
    ProjectItem(
      id: 'stitch-orchestrator',
      name: 'stitch-orchestrator',
      description: 'Design spec generator and Stitch prompt synchronizer service.',
      source: 'github',
      branch: 'release/v1.2',
      workspacePath: '/workspace/stitch-orchestrator',
      lastActivity: 'Yesterday',
      status: 'Approval req',
      statusType: StatusType.warning,
    ),
    ProjectItem(
      id: 'mobile-flutter-client',
      name: 'mobile-flutter-client',
      description: 'Flutter Android & multiplatform client for mobile developer control.',
      source: 'host',
      branch: 'develop',
      workspacePath: 'D:\\SajivJess\\jess_app',
      lastActivity: 'Just now',
      status: 'Building',
      statusType: StatusType.info,
    ),
    ProjectItem(
      id: 'ai-prompt-archive',
      name: 'ai-prompt-archive',
      description: 'Archived prompts, technical briefs, and system design specifications.',
      source: 'zip',
      workspacePath: 'E:\\backups\\prompts.zip',
      lastActivity: '3d ago',
      status: 'Archived',
      statusType: StatusType.neutral,
    ),
    ProjectItem(
      id: 'autonomous-code-editor',
      name: 'autonomous-code-editor',
      description: 'Idea draft: Zero-screen streaming Android control plane with Sora editor.',
      source: 'ideation',
      workspacePath: 'Ideation draft #104',
      lastActivity: '5d ago',
      status: 'Ideation',
      statusType: StatusType.primary,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final filtered = _allProjects.where((p) {
      if (_selectedSource != 'all' && p.source != _selectedSource) return false;
      final q = _searchController.text.trim().toLowerCase();
      if (q.isNotEmpty) {
        return p.name.toLowerCase().contains(q) ||
            p.description.toLowerCase().contains(q) ||
            p.workspacePath.toLowerCase().contains(q);
      }
      return true;
    }).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        showBack: true,
        onBackPressed: () => Navigator.of(context).maybePop(),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_outlined, color: AppColors.textSecondary, size: 20),
            onPressed: () {},
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              // Title & New Project Action
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text('Projects', style: AppTypography.headlineLg, overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceElevated,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppColors.borderSubtle),
                            ),
                            child: Text('(${filtered.length})', style: AppTypography.codeSm),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AppButton(
                      text: '+ New project',
                      width: 125,
                      height: 40,
                      onPressed: widget.onNewProject,
                    ),
                  ],
                ),
              ),

              // Search Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
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
                          onChanged: (_) => setState(() {}),
                          style: AppTypography.bodyMd.copyWith(color: AppColors.textPrimary),
                          decoration: InputDecoration(
                            hintText: 'Search projects by name or path...',
                            hintStyle: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            setState(() {});
                          },
                          child: const Icon(Icons.close, size: 16, color: AppColors.textSecondary),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Filter Chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    _buildFilterChip('all', 'All sources'),
                    _buildFilterChip('github', 'GitHub (3)'),
                    _buildFilterChip('host', 'Host Folder (1)'),
                    _buildFilterChip('zip', 'ZIP Archive (1)'),
                    _buildFilterChip('ideation', 'Ideation (1)'),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Projects List
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          'No projects match your search.',
                          style: AppTypography.bodyMd,
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final project = filtered[index];
                          return _buildProjectRow(project);
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip(String value, String label) {
    final isSelected = _selectedSource == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: () => setState(() => _selectedSource = value),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.surfaceElevated : AppColors.surfaceMain,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isSelected ? AppColors.primary : AppColors.borderSubtle,
            ),
          ),
          child: Text(
            label,
            style: AppTypography.labelSm.copyWith(
              color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProjectRow(ProjectItem project) {
    return InkWell(
      onTap: () => widget.onSelectProject?.call(project.id),
      borderRadius: BorderRadius.circular(10),
      child: Container(
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
                  child: Row(
                    children: [
                      Icon(
                        project.source == 'github'
                            ? Icons.code
                            : project.source == 'host'
                                ? Icons.folder_outlined
                                : project.source == 'zip'
                                    ? Icons.archive_outlined
                                    : Icons.lightbulb_outline,
                        color: AppColors.lavender,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          project.name,
                          style: AppTypography.headlineSm.copyWith(fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusBadge(label: project.status, type: project.statusType),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              project.description,
              style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    if (project.branch != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainer,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.fork_right, size: 11, color: AppColors.textPrimary),
                            const SizedBox(width: 3),
                            Text(project.branch!, style: AppTypography.codeSm.copyWith(fontSize: 10)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(project.lastActivity, style: AppTypography.codeSm.copyWith(fontSize: 11)),
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
}
