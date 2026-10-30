import 'package:flutter/material.dart';
import '../../services/tasks_api_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

class ContractApprovalCard extends StatefulWidget {
  final TaskContractModel contract;
  final Future<void> Function(bool approved, {String? reason}) onDecision;
  final bool isDecided;
  final bool? wasApproved;
  final String? rejectionReason;

  const ContractApprovalCard({
    super.key,
    required this.contract,
    required this.onDecision,
    this.isDecided = false,
    this.wasApproved,
    this.rejectionReason,
  });

  @override
  State<ContractApprovalCard> createState() => _ContractApprovalCardState();
}

class _ContractApprovalCardState extends State<ContractApprovalCard> {
  bool _isSubmitting = false;

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

  void _showRejectSheet(BuildContext context) {
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
                    'Reject Proposed Contract',
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
                'Provide feedback or cancel the task if the contract terms or file scope are unacceptable.',
                style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                autofocus: true,
                maxLines: 3,
                style: AppTypography.bodyMd.copyWith(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'e.g. Scope too broad, protect utils.py, add boundary tests...',
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
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text('Cancel', style: AppTypography.bodySm),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.statusError,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () {
                      final reason = noteController.text.trim();
                      Navigator.pop(ctx);
                      _handle(false, reason: reason.isNotEmpty ? reason : null);
                    },
                    child: Text(
                      'Reject & Cancel Task',
                      style: AppTypography.labelMd.copyWith(color: Colors.white),
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

  @override
  Widget build(BuildContext context) {
    final contract = widget.contract;
    final hashShort = contract.contractHash != null && contract.contractHash!.length >= 10
        ? contract.contractHash!.substring(0, 10)
        : (contract.contractHash ?? 'unsigned');

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.isDecided
              ? (widget.wasApproved == true
                  ? AppColors.statusSuccess.withValues(alpha: 0.5)
                  : AppColors.statusError.withValues(alpha: 0.5))
              : AppColors.primary.withValues(alpha: 0.6),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: widget.isDecided
                ? (widget.wasApproved == true
                    ? AppColors.statusSuccess.withValues(alpha: 0.08)
                    : AppColors.statusError.withValues(alpha: 0.08))
                : AppColors.primary.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: const BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.assignment_turned_in_outlined,
                    color: AppColors.primaryLight,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Gate 1: Contract Review',
                            style: AppTypography.headlineSm.copyWith(
                              fontSize: 14,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceContainer,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: AppColors.borderSubtle),
                            ),
                            child: Text(
                              'v${contract.contractVersion} • #$hashShort',
                              style: AppTypography.codeSm.copyWith(
                                fontSize: 10,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Proof, Not Vibes: Scope & verification criteria must be approved before edits begin.',
                        style: AppTypography.bodySm.copyWith(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Summary Section
                Text(
                  'TASK SUMMARY',
                  style: AppTypography.labelSm.copyWith(
                    color: AppColors.textMuted,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  contract.summary,
                  style: AppTypography.bodyMd.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 14),

                // Acceptance Criteria Section
                Row(
                  children: [
                    Text(
                      'ACCEPTANCE CRITERIA',
                      style: AppTypography.labelSm.copyWith(
                        color: AppColors.textMuted,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${contract.criteria.length} rules',
                        style: AppTypography.codeSm.copyWith(fontSize: 10, color: AppColors.lavender),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.borderSubtle.withValues(alpha: 0.6)),
                  ),
                  child: Column(
                    children: contract.criteria.map((crit) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(top: 2),
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceElevated,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                crit.id,
                                style: AppTypography.codeSm.copyWith(
                                  fontSize: 10,
                                  color: AppColors.primaryLight,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                crit.description,
                                style: AppTypography.bodySm.copyWith(
                                  color: AppColors.textPrimary,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              crit.verified ? Icons.check_circle : Icons.radio_button_unchecked,
                              size: 16,
                              color: crit.verified ? AppColors.statusSuccess : AppColors.textMuted,
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 14),

                // Scope: Permitted Files & Protected Files
                Text(
                  'ENFORCED FILE SCOPE',
                  style: AppTypography.labelSm.copyWith(
                    color: AppColors.textMuted,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ...contract.allowedFiles.map((file) {
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
                            const Icon(Icons.code_rounded, size: 12, color: AppColors.lavender),
                            const SizedBox(width: 5),
                            Text(
                              file,
                              style: AppTypography.codeSm.copyWith(fontSize: 11),
                            ),
                          ],
                        ),
                      );
                    }),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: contract.allowNewFiles
                            ? AppColors.statusSuccess.withValues(alpha: 0.12)
                            : AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: contract.allowNewFiles
                              ? AppColors.statusSuccess.withValues(alpha: 0.4)
                              : AppColors.borderSubtle,
                        ),
                      ),
                      child: Text(
                        contract.allowNewFiles ? '+ New files permitted' : 'Existing files only',
                        style: AppTypography.codeSm.copyWith(
                          fontSize: 11,
                          color: contract.allowNewFiles ? AppColors.statusSuccess : AppColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Protected Files Warning Banner
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.statusWarning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.statusWarning.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.shield_outlined, color: AppColors.statusWarning, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Strict Protection Boundary',
                              style: AppTypography.labelSm.copyWith(
                                color: AppColors.statusWarning,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Modifications to ${contract.protectedFiles.join(", ")} are strictly blocked. Any attempt will immediately fail the run with a Scope Breach verdict.',
                              style: AppTypography.bodySm.copyWith(
                                fontSize: 11,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Required Verification Checks
                Text(
                  'REQUIRED VERIFICATION CHECKS',
                  style: AppTypography.labelSm.copyWith(
                    color: AppColors.textMuted,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: contract.testCommands.map((cmd) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.terminal_rounded, size: 12, color: AppColors.primaryLight),
                          const SizedBox(width: 5),
                          Text(
                            cmd,
                            style: AppTypography.codeSm.copyWith(
                              fontSize: 11,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                // Decision Action Bar
                if (widget.isDecided) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: widget.wasApproved == true
                          ? AppColors.statusSuccess.withValues(alpha: 0.12)
                          : AppColors.statusError.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: widget.wasApproved == true
                            ? AppColors.statusSuccess.withValues(alpha: 0.4)
                            : AppColors.statusError.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          widget.wasApproved == true ? Icons.check_circle : Icons.cancel,
                          size: 16,
                          color: widget.wasApproved == true
                              ? AppColors.statusSuccess
                              : AppColors.statusError,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.wasApproved == true
                                ? 'Contract Approved • Agent authorized to implement in scope'
                                : 'Contract Rejected: ${widget.rejectionReason ?? "User rejected plan."}',
                            style: AppTypography.bodySm.copyWith(
                              fontWeight: FontWeight.w500,
                              color: widget.wasApproved == true
                                  ? AppColors.statusSuccess
                                  : AppColors.statusError,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppColors.borderSubtle),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: _isSubmitting ? null : () => _showRejectSheet(context),
                          child: Text(
                            'Reject Contract',
                            style: AppTypography.labelMd.copyWith(color: AppColors.statusError),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: _isSubmitting ? null : () => _handle(true),
                          child: _isSubmitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.check, size: 16, color: Colors.white),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Approve Contract',
                                      style: AppTypography.labelMd.copyWith(color: Colors.white),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
