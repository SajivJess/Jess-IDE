import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

class ApprovalRequestCard extends StatefulWidget {
  final String prompt;
  final String? target;
  final String? action;
  final String? diff;
  final Future<void> Function(bool approved, {String? reason}) onDecision;
  final bool isDecided;
  final bool? wasApproved;
  final String? branch;
  final String? baseCommit;
  final String? taskId;
  final String? checkCommand;
  final int? checkExitCode;
  final bool? checkPassed;
  final bool isStale;

  const ApprovalRequestCard({
    super.key,
    required this.prompt,
    this.target,
    this.action,
    this.diff,
    required this.onDecision,
    this.isDecided = false,
    this.wasApproved,
    this.branch,
    this.baseCommit,
    this.taskId,
    this.checkCommand,
    this.checkExitCode,
    this.checkPassed,
    this.isStale = false,
  });

  @override
  State<ApprovalRequestCard> createState() => _ApprovalRequestCardState();
}

class _ApprovalRequestCardState extends State<ApprovalRequestCard> {
  bool _isSubmitting = false;
  bool _isDiffExpanded = false;

  Future<void> _handle(bool approve, {String? reason}) async {
    if (_isSubmitting || widget.isDecided) return;
    setState(() => _isSubmitting = true);
    try {
      await widget.onDecision(approve, reason: reason);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _showRequestChangesSheet(BuildContext context) {
    final noteController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceMain,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Request Changes',
                    style: AppTypography.headlineSm.copyWith(color: AppColors.textPrimary),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Reject the proposed changes and guide the agent on what to fix.',
                style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                maxLines: 3,
                style: AppTypography.bodyMd.copyWith(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Feedback for the agent (e.g. "Add error handling for division by zero")',
                  hintStyle: AppTypography.bodySm.copyWith(color: AppColors.textMuted),
                  filled: true,
                  fillColor: AppColors.surfaceElevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.borderSubtle),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.primary),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                        side: const BorderSide(color: AppColors.borderSubtle),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.statusError,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('Confirm Reject'),
                      onPressed: () {
                        final note = noteController.text.trim();
                        Navigator.pop(ctx);
                        _handle(false, reason: note.isNotEmpty ? note : null);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDiffView(String rawDiff) {
    final lines = rawDiff.split('\n');
    final isNoChanges = rawDiff.contains('(No file modifications detected)') || rawDiff.trim().isEmpty;

    if (isNoChanges) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Text(
          'Workspace files updated directly. Review target file contents before approving.',
          style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11),
        ),
      );
    }

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F17),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines.map((line) {
            Color textColor = AppColors.textSecondary;
            Color bgColor = Colors.transparent;

            if (line.startsWith('+') && !line.startsWith('+++')) {
              textColor = const Color(0xFF4ADE80);
              bgColor = const Color(0xFF14532D).withValues(alpha: 0.25);
            } else if (line.startsWith('-') && !line.startsWith('---')) {
              textColor = const Color(0xFFF87171);
              bgColor = const Color(0xFF7F1D1D).withValues(alpha: 0.25);
            } else if (line.startsWith('@@')) {
              textColor = AppColors.lavender;
            }

            return Container(
              width: double.infinity,
              color: bgColor,
              padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 2),
              child: Text(
                line,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: textColor,
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasDiff = widget.diff != null && widget.diff!.isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.isDecided
              ? (widget.wasApproved == true ? AppColors.statusSuccess : AppColors.statusError)
              : AppColors.statusWarning,
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Bar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    widget.isDecided
                        ? (widget.wasApproved == true ? Icons.check_circle : Icons.cancel)
                        : Icons.lock_clock,
                    size: 16,
                    color: widget.isDecided
                        ? (widget.wasApproved == true ? AppColors.statusSuccess : AppColors.statusError)
                        : AppColors.statusWarning,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.isDecided
                        ? (widget.wasApproved == true ? 'APPROVAL GRANTED' : 'ACTION REJECTED')
                        : 'APPROVAL REQUIRED',
                    style: AppTypography.codeSm.copyWith(
                      fontWeight: FontWeight.w700,
                      color: widget.isDecided
                          ? (widget.wasApproved == true ? AppColors.statusSuccess : AppColors.statusError)
                          : AppColors.statusWarning,
                      letterSpacing: 0.5,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              if (widget.target != null && widget.target!.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: Text(
                    widget.target!,
                    style: AppTypography.codeSm.copyWith(color: AppColors.lavender, fontSize: 10),
                  ),
                ),
            ],
          ),
          if (widget.isStale) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.statusError.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.statusError.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.statusError),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Review is stale. Branch or working tree changed since diff generation. Stale approvals are rejected.',
                      style: AppTypography.codeSm.copyWith(
                        color: AppColors.statusError,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (widget.branch != null || widget.baseCommit != null || widget.taskId != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (widget.branch != null && widget.branch!.isNotEmpty)
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
                        const Icon(Icons.fork_right, size: 12, color: AppColors.statusInfo),
                        const SizedBox(width: 4),
                        Text(
                          widget.branch!,
                          style: AppTypography.codeSm.copyWith(color: AppColors.statusInfo, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                if (widget.baseCommit != null && widget.baseCommit!.isNotEmpty)
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
                        const Icon(Icons.commit, size: 12, color: AppColors.lavender),
                        const SizedBox(width: 4),
                        Text(
                          widget.baseCommit!.length > 7 ? widget.baseCommit!.substring(0, 7) : widget.baseCommit!,
                          style: AppTypography.codeSm.copyWith(color: AppColors.lavender, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                if (widget.taskId != null && widget.taskId!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: Text(
                      'Task #${widget.taskId!.length > 8 ? widget.taskId!.substring(0, 8) : widget.taskId!}',
                      style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                    ),
                  ),
              ],
            ),
          ],
          if (widget.checkCommand != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: widget.checkPassed == true
                    ? AppColors.statusSuccess.withValues(alpha: 0.1)
                    : AppColors.statusError.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: widget.checkPassed == true
                      ? AppColors.statusSuccess.withValues(alpha: 0.3)
                      : AppColors.statusError.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.checkPassed == true ? Icons.check_circle_outline : Icons.highlight_off,
                    size: 13,
                    color: widget.checkPassed == true ? AppColors.statusSuccess : AppColors.statusError,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Check: ${widget.checkCommand!} (${widget.checkPassed == true ? "passed" : "exit code ${widget.checkExitCode ?? 1}"})',
                      style: AppTypography.codeSm.copyWith(
                        color: widget.checkPassed == true ? AppColors.statusSuccess : AppColors.statusError,
                        fontSize: 10,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),

          // Prompt description
          Text(
            widget.prompt,
            style: AppTypography.bodySm.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),

          // Expandable Diff Review Button & View
          if (hasDiff) ...[
            const SizedBox(height: 10),
            InkWell(
              onTap: () => setState(() => _isDiffExpanded = !_isDiffExpanded),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.difference_outlined, size: 14, color: AppColors.lavender),
                    const SizedBox(width: 6),
                    Text(
                      _isDiffExpanded ? 'Hide changes' : 'Review changes',
                      style: AppTypography.codeSm.copyWith(
                        color: AppColors.lavender,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _isDiffExpanded ? 'Tap to collapse' : 'View diff',
                      style: AppTypography.bodySm.copyWith(color: AppColors.textMuted, fontSize: 10),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _isDiffExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
            if (_isDiffExpanded) ...[
              const SizedBox(height: 8),
              _buildDiffView(widget.diff!),
            ],
          ],

          // Paused Notice & Action Buttons
          if (!widget.isDecided) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.statusWarning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  const Icon(Icons.pause_circle_outline, size: 13, color: AppColors.statusWarning),
                  const SizedBox(width: 6),
                  Text(
                    'The agent is paused until you decide.',
                    style: AppTypography.codeSm.copyWith(
                      color: AppColors.statusWarning,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.statusSuccess,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      elevation: 0,
                    ),
                    icon: _isSubmitting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.check, size: 16),
                    label: const Text(
                      'Approve Action',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                    ),
                    onPressed: (_isSubmitting || widget.isStale) ? null : () => _handle(true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.statusError,
                      side: const BorderSide(color: AppColors.statusError),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text(
                      'Reject',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                    ),
                    onPressed: _isSubmitting ? null : () => _showRequestChangesSheet(context),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
