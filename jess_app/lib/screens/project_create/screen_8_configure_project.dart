import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/app_text_field.dart';
import 'screen_7_choose_source.dart';
import '../../services/projects_api_service.dart';

class Screen8ConfigureProject extends StatefulWidget {
  final ProjectSource source;
  final VoidCallback? onBack;
  final void Function(ProjectModel? project)? onContinue;

  const Screen8ConfigureProject({
    super.key,
    this.source = ProjectSource.github,
    this.onBack,
    this.onContinue,
  });

  @override
  State<Screen8ConfigureProject> createState() => _Screen8ConfigureProjectState();
}

class _Screen8ConfigureProjectState extends State<Screen8ConfigureProject> {
  final TextEditingController _nameController =
      TextEditingController(text: 'cloudaiagent-mobile');
  final TextEditingController _descController =
      TextEditingController(text: 'AI coding agent orchestration backend and mobile interface.');
  final TextEditingController _repoController =
      TextEditingController(text: 'https://github.com/SajivJess/cloudaiagent.git');
  final TextEditingController _branchController =
      TextEditingController(text: 'main');

  bool _isChecking = false;

  void _handleContinue() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a project name')),
      );
      return;
    }

    setState(() => _isChecking = true);
    final result = await ProjectsApiService.createProject(
      name: name,
      description: _descController.text.trim().isNotEmpty ? _descController.text.trim() : null,
      sourceType: widget.source.name,
      repoUrl: _repoController.text.trim().isNotEmpty ? _repoController.text.trim() : null,
      defaultBranch: _branchController.text.trim().isNotEmpty ? _branchController.text.trim() : 'main',
    );

    if (mounted) {
      setState(() => _isChecking = false);
      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Project "${result.project?.name ?? name}" created successfully!'),
            backgroundColor: AppColors.statusSuccess,
          ),
        );
        widget.onContinue?.call(result.project);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.errorMessage ?? 'Failed to create project on server.'),
            backgroundColor: AppColors.statusError,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        showBack: true,
        onBackPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
        title: 'New Project',
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            children: [
              // Progress Bar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(
                  color: AppColors.surfaceMain,
                  border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Configure Project', style: AppTypography.labelMd),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Text('Step 2 of 4', style: AppTypography.codeSm.copyWith(color: AppColors.lavender)),
                    ),
                  ],
                ),
              ),

              // Active Source Strip
              Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceMain,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.source, size: 20, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('ACTIVE SOURCE', style: AppTypography.labelSm.copyWith(fontSize: 10)),
                          Text(
                            widget.source == ProjectSource.github
                                ? 'GitHub: SajivJess/cloudaiagent'
                                : widget.source == ProjectSource.host
                                    ? 'Local Host Folder'
                                    : widget.source == ProjectSource.zip
                                        ? 'ZIP Archive'
                                        : 'Starter Template',
                            style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: widget.onBack ?? () => Navigator.of(context).maybePop(),
                      child: Text('Change', style: AppTypography.bodySm.copyWith(color: AppColors.primary)),
                    ),
                  ],
                ),
              ),

              // Scrollable Form Fields
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Configure project details', style: AppTypography.headlineSm),
                      const SizedBox(height: 4),
                      Text(
                        'Set project identity, repository source, and default working branch.',
                        style: AppTypography.bodySm,
                      ),
                      const SizedBox(height: 16),

                      // Project Name
                      AppTextField(
                        label: 'Project name *',
                        prefixIcon: Icons.folder_outlined,
                        controller: _nameController,
                        hintText: 'my-coding-project',
                        helperText: 'A unique local identifier for this workspace.',
                      ),
                      const SizedBox(height: 14),

                      // Description
                      AppTextField(
                        label: 'Description (optional)',
                        controller: _descController,
                        maxLines: 3,
                        hintText: 'Describe this project...',
                      ),
                      const SizedBox(height: 14),

                      // GitHub / Host Source Specific Fields
                      if (widget.source == ProjectSource.github) ...[
                        AppTextField(
                          label: 'Repository URL',
                          prefixIcon: Icons.link,
                          controller: _repoController,
                          hintText: 'https://github.com/user/repo.git',
                        ),
                        const SizedBox(height: 14),
                        AppTextField(
                          label: 'Target branch',
                          prefixIcon: Icons.fork_right,
                          controller: _branchController,
                          hintText: 'main',
                          helperText: 'Default branch for checking out and proposing diffs.',
                        ),
                      ] else if (widget.source == ProjectSource.host) ...[
                        AppTextField(
                          label: 'Host folder path',
                          prefixIcon: Icons.computer,
                          initialValue: 'D:\\SajivJess\\jess dev ide',
                          hintText: 'e.g. D:\\projects\\my-app',
                          helperText: 'Absolute path on the development laptop machine.',
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // Bottom Actions
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border: Border(top: BorderSide(color: AppColors.borderSubtle)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        text: 'Back',
                        variant: AppButtonVariant.outline,
                        onPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: AppButton(
                        text: 'Continue',
                        isLoading: _isChecking,
                        onPressed: _handleContinue,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
