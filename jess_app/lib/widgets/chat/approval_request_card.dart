import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../status_badge.dart';

class ApprovalRequestCard extends StatefulWidget {
  final String prompt;
  final String? target;
  final String? action;
  final String? diff;
  final Future<void> Function(bool approved) onDecision;
  final bool isDecided;
  final bool? wasApproved;

  const ApprovalRequestCard({
    super.key,
    required this.prompt,
    this.target,
    this.action,
    this.diff,
    required this.onDecision,
    this.isDecided = false,
    this.wasApproved,
  });

  @override
  State<ApprovalRequestCard> createState() => _ApprovalRequestCardState();
}

class _ApprovalRequestCardState extends State<ApprovalRequestCard> {
  bool _isSubmitting = false;

  Future<void> _handle(bool approve) async {
    if (_isSubmitting || widget.isDecided) return;
    setState(() => _isSubmitting = true);
    try {
      await widget.onDecision(approve);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(10),
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    widget.isDecided
                        ? (widget.wasApproved == true ? Icons.check_circle : Icons.cancel)
                        : Icons.lock_outline,
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
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              if (widget.target != null)
                Text(
                  widget.target!,
                  style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            widget.prompt,
            style: AppTypography.bodySm.copyWith(color: AppColors.textPrimary),
          ),

          // Code diff snippet
          if (widget.diff != null && widget.diff!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Text(
                widget.diff!.trim(),
                style: AppTypography.codeSm.copyWith(fontSize: 10),
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],

          if (!widget.isDecided) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.statusSuccess,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    icon: _isSubmitting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.check, size: 16),
                    label: const Text('Approve Action', style: TextStyle(fontWeight: FontWeight.w600)),
                    onPressed: _isSubmitting ? null : () => _handle(true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.statusError,
                      side: const BorderSide(color: AppColors.statusError),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Reject', style: TextStyle(fontWeight: FontWeight.w600)),
                    onPressed: _isSubmitting ? null : () => _handle(false),
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
