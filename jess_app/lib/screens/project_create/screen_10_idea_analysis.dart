import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';

class Screen10IdeaAnalysis extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback? onConfirmAnalysis;

  const Screen10IdeaAnalysis({
    super.key,
    this.onBack,
    this.onConfirmAnalysis,
  });

  @override
  State<Screen10IdeaAnalysis> createState() => _Screen10IdeaAnalysisState();
}

class _Screen10IdeaAnalysisState extends State<Screen10IdeaAnalysis> {
  bool _isConfirming = false;
  final Map<int, bool?> _assumptionStates = {
    0: true, // confirmed
    1: null, // pending
    2: null, // pending
  };

  final List<String> _assumptions = [
    'Workspaces are hosted on Linux/Ubuntu environments with Docker & Go installed.',
    'SQLite is acceptable for local daemon state cache before syncing to PostgreSQL.',
    'Mobile clients maintain event ordering via incremental sequence numbers.',
  ];

  @override
  Widget build(BuildContext context) {
    final pendingCount = _assumptionStates.values.where((v) => v == null).length;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        showBack: true,
        onBackPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
        title: 'Review Idea Analysis',
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
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
                    Text('Structured Brief', style: AppTypography.labelMd),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Text('Step 3 of 5', style: AppTypography.codeSm.copyWith(color: AppColors.lavender)),
                    ),
                  ],
                ),
              ),

              // Scrollable Analysis Cards
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Review your idea', style: AppTypography.headlineLg),
                      const SizedBox(height: 4),
                      Text(
                        'Review the structured technical analysis and confirm assumptions before selecting your stack.',
                        style: AppTypography.bodyMd,
                      ),
                      const SizedBox(height: 16),

                      // Warning Banner for Pending Assumptions
                      if (pendingCount > 0) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.statusWarning.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.statusWarning.withOpacity(0.3)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.warning_amber_rounded, color: AppColors.statusWarning, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text('Action required', style: AppTypography.labelMd.copyWith(color: AppColors.statusWarning, fontWeight: FontWeight.w600)),
                                        ),
                                        const SizedBox(width: 8),
                                        StatusBadge(label: '$pendingCount unconfirmed', type: StatusType.warning),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Inferred assumptions require explicit confirmation before Jess IDE can finalize your architecture graph.',
                                      style: AppTypography.bodySm,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],

                      // 1. Problem Summary
                      _buildSectionCard(
                        number: '1',
                        title: 'Problem Summary',
                        badgeText: 'From your input',
                        badgeType: StatusType.primary,
                        content:
                            'Developers require autonomous background execution of coding agent workloads on remote laptop/cloud workspaces without maintaining an active browser session.',
                      ),
                      const SizedBox(height: 12),

                      // 2. Proposed Solution
                      _buildSectionCard(
                        number: '2',
                        title: 'Proposed Solution',
                        badgeText: 'AI suggestion',
                        badgeType: StatusType.info,
                        content:
                            'An event-driven Go Workspace Daemon running inside ephemeral Linux compute, with WebSocket normalized event streams and automated Git checkpoint rollbacks.',
                      ),
                      const SizedBox(height: 12),

                      // 3. Target Users
                      _buildSectionCard(
                        number: '3',
                        title: 'Target Users & Use Cases',
                        badgeText: 'AI suggestion',
                        badgeType: StatusType.info,
                        content:
                            'Solo developers, engineering leads, and DevOps engineers managing multiple asynchronous agent tasks from mobile devices.',
                      ),
                      const SizedBox(height: 12),

                      // 4. Key Features
                      _buildFeaturesCard(),
                      const SizedBox(height: 12),

                      // 5. Inferred Assumptions (Interactive)
                      _buildAssumptionsCard(),
                      const SizedBox(height: 12),

                      // 6. Constraints & Risks
                      _buildSectionCard(
                        number: '6',
                        title: 'Constraints & Safety Gates',
                        badgeText: 'Enforced Policy',
                        badgeType: StatusType.warning,
                        content:
                            'Zero screen streaming; all agent actions (Git push, rm -rf, bash execution) pass through an Action Gate policy requiring explicit user approval on mobile.',
                      ),
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
                        text: 'Edit Idea',
                        variant: AppButtonVariant.outline,
                        onPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: AppButton(
                        text: 'Confirm & Continue',
                        isLoading: _isConfirming,
                        onPressed: () async {
                          setState(() => _isConfirming = true);
                          await Future.delayed(const Duration(milliseconds: 700));
                          if (mounted) {
                            setState(() => _isConfirming = false);
                            widget.onConfirmAnalysis?.call();
                          }
                        },
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

  Widget _buildSectionCard({
    required String number,
    required String title,
    required String badgeText,
    required StatusType badgeType,
    required String content,
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
                child: Text('$number. $title', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              StatusBadge(label: badgeText, type: badgeType),
            ],
          ),
          const SizedBox(height: 8),
          Text(content, style: AppTypography.bodyMd),
        ],
      ),
    );
  }

  Widget _buildFeaturesCard() {
    final features = [
      'Phase 1: Daemon Lifecycle & Heartbeats (MVP)',
      'Phase 1: WebSocket Normalized Event Stream (MVP)',
      'Phase 1: Git Auto-Checkpoint & Safe Rollback (MVP)',
      'Phase 2: Live Preview Tunnel via Cloudflare',
      'Phase 2: Push Notifications via FCM',
    ];

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
                child: Text('4. Key Features', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              const StatusBadge(label: 'Milestone Roadmap', type: StatusType.info),
            ],
          ),
          const SizedBox(height: 10),
          ...features.map(
            (f) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3.0),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, size: 15, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(f, style: AppTypography.bodySm.copyWith(color: AppColors.textPrimary)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssumptionsCard() {
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
                child: Text('5. Assumptions Requiring Approval', style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              const StatusBadge(label: 'Needs Confirmation', type: StatusType.warning),
            ],
          ),
          const SizedBox(height: 10),
          ...List.generate(_assumptions.length, (i) {
            final state = _assumptionStates[i];
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: state == true
                      ? AppColors.statusSuccess.withOpacity(0.3)
                      : state == false
                          ? AppColors.statusError.withOpacity(0.3)
                          : AppColors.borderSubtle,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_assumptions[i], style: AppTypography.bodySm.copyWith(color: AppColors.textPrimary)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      InkWell(
                        onTap: () => setState(() => _assumptionStates[i] = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: state == false ? AppColors.statusError.withOpacity(0.2) : Colors.transparent,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppColors.borderSubtle),
                          ),
                          child: Text('Reject', style: AppTypography.codeSm.copyWith(fontSize: 10, color: state == false ? AppColors.statusError : AppColors.textSecondary)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => setState(() => _assumptionStates[i] = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: state == true ? AppColors.statusSuccess.withOpacity(0.2) : Colors.transparent,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: state == true ? AppColors.statusSuccess : AppColors.borderSubtle,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (state == true) const Icon(Icons.check, size: 12, color: AppColors.statusSuccess),
                              if (state == true) const SizedBox(width: 4),
                              Text('Confirm', style: AppTypography.codeSm.copyWith(fontSize: 10, color: state == true ? AppColors.statusSuccess : AppColors.textPrimary)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
