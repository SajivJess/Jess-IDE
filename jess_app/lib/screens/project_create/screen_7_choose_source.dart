import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';

enum ProjectSource { github, host, zip, template, ideation }

class Screen7ChooseSource extends StatefulWidget {
  final ValueChanged<ProjectSource>? onContinue;
  final VoidCallback? onCancel;

  const Screen7ChooseSource({
    super.key,
    this.onContinue,
    this.onCancel,
  });

  @override
  State<Screen7ChooseSource> createState() => _Screen7ChooseSourceState();
}

class _Screen7ChooseSourceState extends State<Screen7ChooseSource> {
  ProjectSource? _selectedSource = ProjectSource.github;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        showBack: true,
        onBackPressed: widget.onCancel ?? () => Navigator.of(context).maybePop(),
        title: 'New Project',
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            children: [
              // Wizard Progress Strip
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(
                  color: AppColors.surfaceMain,
                  border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Choose Source', style: AppTypography.labelMd),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Text(
                        'Step 1 of 4',
                        style: AppTypography.codeSm.copyWith(color: AppColors.lavender),
                      ),
                    ),
                  ],
                ),
              ),

              // Scrollable Options
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Choose a project source', style: AppTypography.headlineLg),
                      const SizedBox(height: 4),
                      Text(
                        'Start from an existing repository, host files, a starter template, or a raw idea.',
                        style: AppTypography.bodyMd,
                      ),
                      const SizedBox(height: 18),

                      // 1. GitHub
                      _buildSourceCard(
                        source: ProjectSource.github,
                        icon: Icons.fork_right,
                        title: 'GitHub repository',
                        tag: 'Cloud sync',
                        description: 'Connect your GitHub account and clone or import an existing repository.',
                        nextStep: 'Select repo & branch',
                      ),
                      const SizedBox(height: 10),

                      // 2. Local Folder
                      _buildSourceCard(
                        source: ProjectSource.host,
                        icon: Icons.folder_outlined,
                        title: 'Local host folder',
                        tag: 'Laptop path',
                        description: 'Work directly inside a folder located on your development laptop host.',
                        nextStep: 'Select folder on host',
                      ),
                      const SizedBox(height: 10),

                      // 3. ZIP Archive
                      _buildSourceCard(
                        source: ProjectSource.zip,
                        icon: Icons.archive_outlined,
                        title: 'ZIP archive',
                        tag: 'File import',
                        description: 'Extract and import a zipped codebase archive directly into an isolated workspace.',
                        nextStep: 'Upload or pick .zip',
                      ),
                      const SizedBox(height: 10),

                      // 4. Starter Template
                      _buildSourceCard(
                        source: ProjectSource.template,
                        icon: Icons.dashboard_customize_outlined,
                        title: 'Starter template',
                        tag: 'Pre-configured',
                        description: 'Begin with a pre-configured stack: FastAPI, Next.js, Flutter, or Node.js.',
                        nextStep: 'Browse template gallery',
                      ),
                      const SizedBox(height: 10),

                      // 5. Ideation
                      _buildSourceCard(
                        source: ProjectSource.ideation,
                        icon: Icons.lightbulb_outline,
                        title: 'Ideation funnel',
                        tag: 'AI synthesis',
                        description: 'Turn an unstructured idea and reference documents into a full technical specification.',
                        nextStep: 'Capture idea & documents',
                      ),
                      const SizedBox(height: 16),

                      // Host Boundary Notice
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.info_outline, size: 16, color: AppColors.lavender),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Local folder and ZIP selection use files accessible to the development host. Selecting a file on your phone does not automatically place it on the host.',
                                style: AppTypography.codeSm.copyWith(fontSize: 11, color: AppColors.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom Actions Bar
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
                        text: 'Cancel',
                        variant: AppButtonVariant.outline,
                        onPressed: widget.onCancel ?? () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: AppButton(
                        text: 'Continue',
                        onPressed: _selectedSource != null
                            ? () => widget.onContinue?.call(_selectedSource!)
                            : null,
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

  Widget _buildSourceCard({
    required ProjectSource source,
    required IconData icon,
    required String title,
    required String tag,
    required String description,
    required String nextStep,
  }) {
    final isSelected = _selectedSource == source;
    return InkWell(
      onTap: () => setState(() => _selectedSource = source),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.surfaceElevated : AppColors.surfaceMain,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.borderSubtle,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary.withOpacity(0.15) : AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.borderSubtle,
                ),
              ),
              child: Icon(icon, color: isSelected ? AppColors.primary : AppColors.lavender, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: AppTypography.labelMd.copyWith(
                            fontWeight: FontWeight.w600,
                            color: isSelected ? AppColors.textPrimary : AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: AppColors.primary.withOpacity(0.25)),
                        ),
                        child: Text(
                          tag,
                          style: AppTypography.labelSm.copyWith(color: AppColors.lavender, fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(description, style: AppTypography.bodySm),
                  const SizedBox(height: 6),
                  Text(
                    'Next: $nextStep',
                    style: AppTypography.codeSm.copyWith(color: AppColors.lavender, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? AppColors.primary : Colors.transparent,
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.borderSubtle,
                  width: 2,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
