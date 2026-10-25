import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';
import '../../services/projects_api_service.dart';

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

  List<ProjectModel> _projects = [];
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchProjects();
  }

  Future<void> _fetchProjects() async {
    setState(() => _isLoading = true);
    final result = await ProjectsApiService.listProjects(
      sourceType: _selectedSource == 'all' ? null : _selectedSource,
      search: _searchController.text.trim().isNotEmpty ? _searchController.text.trim() : null,
    );
    if (mounted) {
      setState(() {
        _isLoading = false;
        if (result.success) {
          _projects = result.items;
          _errorMessage = null;
        } else {
          _errorMessage = result.errorMessage;
        }
      });
    }
  }

  String _formatTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _projects.where((p) {
      if (_selectedSource != 'all' && p.sourceType.toLowerCase() != _selectedSource.toLowerCase()) {
        return false;
      }
      final q = _searchController.text.trim().toLowerCase();
      if (q.isNotEmpty) {
        return p.name.toLowerCase().contains(q) ||
            (p.description?.toLowerCase().contains(q) ?? false) ||
            (p.workspacePath?.toLowerCase().contains(q) ?? false) ||
            (p.repoUrl?.toLowerCase().contains(q) ?? false);
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
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary, size: 20),
            onPressed: _fetchProjects,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            children: [
              // Title & New Project Action Row
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text('Projects', style: AppTypography.headlineLg),
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
                    AppButton(
                      text: '+ New Project',
                      width: 120,
                      height: 38,
                      onPressed: widget.onNewProject,
                    ),
                  ],
                ),
              ),

              // Search Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
                          onChanged: (_) => setState(() {}),
                          style: AppTypography.bodyMd.copyWith(color: AppColors.textPrimary),
                          decoration: InputDecoration(
                            hintText: 'Search projects by name or path...',
                            hintStyle: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
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
                    _buildFilterChip('all', 'All'),
                    _buildFilterChip('github', 'GitHub'),
                    _buildFilterChip('local', 'Local'),
                    _buildFilterChip('scratch', 'Scratch'),
                    _buildFilterChip('ideation', 'Ideation'),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Error Banner
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceMain,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.statusError.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.cloud_off, color: AppColors.statusError, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: _fetchProjects,
                          child: Text('Retry', style: AppTypography.labelSm.copyWith(color: AppColors.lavender)),
                        ),
                      ],
                    ),
                  ),
                ),

              // Projects List
              Expanded(
                child: _isLoading && _projects.isEmpty
                    ? const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                        ),
                      )
                    : filtered.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.folder_open, size: 36, color: AppColors.textSecondary),
                                const SizedBox(height: 10),
                                Text(
                                  'No projects found',
                                  style: AppTypography.headlineSm,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Tap "+ New Project" to create your first workspace.',
                                  style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                                ),
                              ],
                            ),
                          )
                        : RefreshIndicator(
                            color: AppColors.primary,
                            onRefresh: _fetchProjects,
                            child: ListView.separated(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              itemCount: filtered.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final project = filtered[index];
                                return _buildProjectRow(project);
                              },
                            ),
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
        onTap: () {
          setState(() => _selectedSource = value);
          _fetchProjects();
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProjectRow(ProjectModel project) {
    IconData icon = Icons.folder_outlined;
    if (project.sourceType == 'github') icon = Icons.code;
    if (project.sourceType == 'ideation') icon = Icons.lightbulb_outline;
    if (project.sourceType == 'scratch') icon = Icons.alt_route;

    return InkWell(
      onTap: () => widget.onSelectProject?.call(project.name),
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
                      Icon(icon, color: AppColors.lavender, size: 16),
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
                StatusBadge(label: project.sourceType.toUpperCase(), type: StatusType.success),
              ],
            ),
            if (project.description != null && project.description!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                project.description!,
                style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
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
                          Text(project.defaultBranch, style: AppTypography.codeSm.copyWith(fontSize: 10)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      project.workspacePath ?? project.repoUrl ?? 'Local',
                      style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Text(_formatTime(project.updatedAt), style: AppTypography.codeSm.copyWith(fontSize: 10)),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 14, color: AppColors.textSecondary),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
