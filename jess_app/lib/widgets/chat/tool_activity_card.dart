import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../status_badge.dart';

class ToolActivityCard extends StatefulWidget {
  final String tool;
  final String label;
  final String status; // "running", "completed", "failed"
  final String? output;
  final String? command;
  final int? exitCode;
  final bool initialExpanded;

  const ToolActivityCard({
    super.key,
    required this.tool,
    required this.label,
    required this.status,
    this.output,
    this.command,
    this.exitCode,
    this.initialExpanded = false,
  });

  @override
  State<ToolActivityCard> createState() => _ToolActivityCardState();
}

class _ToolActivityCardState extends State<ToolActivityCard> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initialExpanded || widget.status == 'running';
  }

  IconData _toolIcon(String tool) {
    switch (tool.toLowerCase()) {
      case 'terminal':
      case 'cli_process':
      case 'cli_agent':
        return Icons.terminal;
      case 'file_edit':
      case 'edit_file':
        return Icons.edit_note;
      case 'find_files':
      case 'search_files':
        return Icons.manage_search;
      case 'test_runner':
        return Icons.fact_check_outlined;
      default:
        return Icons.build_outlined;
    }
  }

  StatusType _statusType(String status) {
    switch (status.toLowerCase()) {
      case 'completed':
        return StatusType.success;
      case 'running':
        return StatusType.info;
      case 'failed':
        return StatusType.error;
      default:
        return StatusType.neutral;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasDetails = (widget.command != null && widget.command!.isNotEmpty) ||
        (widget.output != null && widget.output!.isNotEmpty);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Bar
          InkWell(
            onTap: hasDetails ? () => setState(() => _isExpanded = !_isExpanded) : null,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(_toolIcon(widget.tool), size: 14, color: AppColors.lavender),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: AppTypography.codeSm.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (widget.status == 'running')
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.primary),
                    )
                  else
                    StatusBadge(
                      label: widget.exitCode != null
                          ? 'EXIT ${widget.exitCode}'
                          : widget.status.toUpperCase(),
                      type: _statusType(widget.status),
                    ),
                  if (hasDetails) ...[
                    const SizedBox(width: 4),
                    Icon(
                      _isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Expandable Body
          if (_isExpanded && hasDetails) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.command != null && widget.command!.isNotEmpty) ...[
                    Row(
                      children: [
                        const Text(r'$ ', style: TextStyle(color: AppColors.lavender, fontSize: 10, fontFamily: 'monospace')),
                        Expanded(
                          child: Text(
                            widget.command!,
                            style: AppTypography.codeSm.copyWith(fontSize: 10, color: AppColors.textPrimary),
                          ),
                        ),
                      ],
                    ),
                    if (widget.output != null && widget.output!.isNotEmpty)
                      const Divider(color: AppColors.borderSubtle, height: 12),
                  ],
                  if (widget.output != null && widget.output!.isNotEmpty)
                    Text(
                      widget.output!.trim(),
                      style: AppTypography.codeSm.copyWith(
                        fontSize: 10,
                        color: widget.status == 'failed' ? AppColors.statusError : AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
