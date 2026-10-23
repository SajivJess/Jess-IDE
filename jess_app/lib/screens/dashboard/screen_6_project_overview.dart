import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';

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
            icon: const Icon(Icons.sync, color: AppColors.textSecondary, size: 20),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Repository synced with host')),
              );
            },
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
                          const StatusBadge(label: 'Active', type: StatusType.success),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'AI coding agent orchestration backend and mobile interface control plane.',
                        style: AppTypography.bodyMd,
                      ),
                      const SizedBox(height: 12),

                      // Metadata Pills
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildMetaPill(Icons.terminal, 'SajivJess/cloudaiagent'),
                          _buildMetaPill(Icons.fork_right, 'main (255d346)'),
                          _buildMetaPill(Icons.laptop_mac, 'Laptop (Nagercoil)'),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Primary Action: Open Chat
                      AppButton(
                        text: 'Open AI Coding Chat',
                        icon: const Icon(Icons.chat_bubble_outline, size: 18, color: Colors.white),
                        onPressed: widget.onOpenChat,
                      ),
                      const SizedBox(height: 16),

                      // Assigned Workspace Health Card
                      _buildSectionCard(
                        title: 'Assigned Workspace',
                        badge: const StatusBadge(label: 'Online', type: StatusType.success),
                        children: [
                          _buildInfoRow('Host Device:', 'Windows Laptop (Nagercoil)'),
                          _buildInfoRow('Root Directory:', 'D:\\SajivJess\\jess dev ide'),
                          _buildInfoRow('Isolation Level:', 'Host Folder (Shares user permissions)'),
                          _buildInfoRow('Last Heartbeat:', '15s ago (WebSocket active)'),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Agent Session Card
                      _buildSectionCard(
                        title: 'Agent Connection',
                        badge: const StatusBadge(label: 'Ready', type: StatusType.info),
                        children: [
                          _buildInfoRow('Provider:', 'Antigravity CLI (agy)'),
                          _buildInfoRow('Active Model:', 'Gemini 2.5 Flash / Pro'),
                          _buildInfoRow('Session Continuity:', 'Resumable (thread_01a149)'),
                          _buildInfoRow('Execution Policy:', 'Safe Confirmation Required'),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Proposed Changes / Review Card
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceMain,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.statusWarning.withOpacity(0.4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Proposed Changes', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
                                const StatusBadge(label: 'Needs Review', type: StatusType.warning),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text('3 files modified · +124 / -18 lines', style: AppTypography.codeSm),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: AppButton(
                                    text: 'Review Diff',
                                    height: 38,
                                    variant: AppButtonVariant.secondary,
                                    onPressed: widget.onReviewChanges,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: AppButton(
                                    text: 'Browse Files',
                                    height: 38,
                                    variant: AppButtonVariant.outline,
                                    onPressed: widget.onBrowseFiles,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
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
