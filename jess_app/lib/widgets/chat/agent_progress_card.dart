import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../status_badge.dart';
import 'tool_activity_card.dart';
import '../../screens/dashboard/screen_6_project_overview.dart' show ChatToolActivityItem;

/// Grouped, collapsible card for agent activities and tool runs.
/// Replaces multiple scattered tool cards with a calm, structured progress panel.
class AgentProgressCard extends StatefulWidget {
  final List<ChatToolActivityItem> activities;

  const AgentProgressCard({
    super.key,
    required this.activities,
  });

  @override
  State<AgentProgressCard> createState() => _AgentProgressCardState();
}

class _AgentProgressCardState extends State<AgentProgressCard> {
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _isExpanded = false;
  }

  @override
  void didUpdateWidget(covariant AgentProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasRunning = oldWidget.activities.any((a) => a.status.toLowerCase() == 'running');
    final isRunning = widget.activities.any((a) => a.status.toLowerCase() == 'running');
    if (wasRunning && !isRunning) {
      // Auto-collapse when agent completes its intermediate tool actions
      setState(() => _isExpanded = false);
    }
  }

  String _formatSummary() {
    final total = widget.activities.length;
    final isRunning = widget.activities.any((a) => a.status.toLowerCase() == 'running');
    final hasFailed = widget.activities.any((a) => a.status.toLowerCase() == 'failed' || (a.exitCode != null && a.exitCode != 0));

    if (isRunning) {
      return '$total actions • In progress...';
    } else if (hasFailed) {
      return '$total actions • Checks captured';
    } else {
      return '$total actions • Passed';
    }
  }

  StatusType _summaryStatusType() {
    final isRunning = widget.activities.any((a) => a.status.toLowerCase() == 'running');
    final hasFailed = widget.activities.any((a) => a.status.toLowerCase() == 'failed' || (a.exitCode != null && a.exitCode != 0));

    if (isRunning) return StatusType.info;
    if (hasFailed) return StatusType.warning;
    return StatusType.success;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.activities.isEmpty) return const SizedBox.shrink();

    final isRunning = widget.activities.any((a) => a.status.toLowerCase() == 'running');
    final statusType = _summaryStatusType();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isRunning ? AppColors.primary : AppColors.borderSubtle,
          width: isRunning ? 1.2 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Bar
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: AppColors.lavender.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.bolt, size: 14, color: AppColors.lavender),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'AGENT PROGRESS',
                    style: AppTypography.codeSm.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                      letterSpacing: 0.6,
                      fontSize: 11,
                    ),
                  ),
                  const Spacer(),
                  StatusBadge(
                    label: _formatSummary(),
                    type: statusType,
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),

          // Collapsed Clean Checklist Preview
          if (!_isExpanded)
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 10),
              child: Column(
                children: widget.activities.take(3).map((act) {
                  final isDone = act.status.toLowerCase() == 'completed' || (act.exitCode == 0);
                  final isRun = act.status.toLowerCase() == 'running';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Icon(
                          isRun
                              ? Icons.sync
                              : (isDone ? Icons.check_circle_outline : Icons.error_outline),
                          size: 13,
                          color: isRun
                              ? AppColors.primary
                              : (isDone ? AppColors.statusSuccess : AppColors.statusWarning),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            act.label,
                            style: AppTypography.bodySm.copyWith(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          isRun
                              ? 'Running'
                              : (act.exitCode != null ? 'EXIT ${act.exitCode}' : 'Done'),
                          style: AppTypography.codeSm.copyWith(
                            fontSize: 10,
                            color: isDone ? AppColors.statusSuccess : AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),

          // Expanded Full Details
          if (_isExpanded) ...[
            const Divider(color: AppColors.borderSubtle, height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: widget.activities.map((act) {
                  return ToolActivityCard(
                    tool: act.tool,
                    label: act.label,
                    status: act.status,
                    output: act.output,
                    command: act.command,
                    exitCode: act.exitCode,
                    initialExpanded: act.status.toLowerCase() == 'running',
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
