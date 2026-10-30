import 'package:flutter/material.dart';
import '../../services/tasks_api_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

class VerificationEvidenceCard extends StatefulWidget {
  final VerificationEvidenceModel evidence;
  final List<AcceptanceCriterionModel>? criteria;

  const VerificationEvidenceCard({
    super.key,
    required this.evidence,
    this.criteria,
  });

  @override
  State<VerificationEvidenceCard> createState() => _VerificationEvidenceCardState();
}

class _VerificationEvidenceCardState extends State<VerificationEvidenceCard> {
  final Map<int, bool> _expandedLogs = {};

  @override
  Widget build(BuildContext context) {
    final evidence = widget.evidence;
    final isProven = evidence.overallVerdict == 'PROVEN';
    final isScopeBreach = evidence.overallVerdict == 'SCOPE_BREACH' || evidence.scopeStatus == 'VIOLATED';

    Color verdictColor;
    String verdictLabel;
    IconData verdictIcon;

    if (isProven) {
      verdictColor = AppColors.statusSuccess;
      verdictLabel = 'PROVEN';
      verdictIcon = Icons.verified;
    } else if (isScopeBreach) {
      verdictColor = AppColors.statusError;
      verdictLabel = 'SCOPE BREACH';
      verdictIcon = Icons.gpp_bad_outlined;
    } else {
      verdictColor = AppColors.statusWarning;
      verdictLabel = 'FAILED CHECKS';
      verdictIcon = Icons.error_outline;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: verdictColor.withValues(alpha: 0.5),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: verdictColor.withValues(alpha: 0.08),
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
                    color: verdictColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(verdictIcon, color: verdictColor, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Verification Evidence',
                            style: AppTypography.headlineSm.copyWith(
                              fontSize: 14,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: verdictColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: verdictColor.withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(verdictIcon, size: 12, color: verdictColor),
                                const SizedBox(width: 4),
                                Text(
                                  verdictLabel,
                                  style: AppTypography.labelSm.copyWith(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: verdictColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Actual recorded test results and deterministic edge-case probes.',
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
                // 1. Scope Status Banner
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: isScopeBreach
                        ? AppColors.statusError.withValues(alpha: 0.1)
                        : AppColors.statusSuccess.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isScopeBreach
                          ? AppColors.statusError.withValues(alpha: 0.3)
                          : AppColors.statusSuccess.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isScopeBreach ? Icons.shield_outlined : Icons.verified_user_outlined,
                        size: 16,
                        color: isScopeBreach ? AppColors.statusError : AppColors.statusSuccess,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isScopeBreach
                              ? 'Scope Violation: Touched protected files (${evidence.protectedFilesViolated.join(", ")})'
                              : 'Enforced Scope: Clean adherence (no protected files touched)',
                          style: AppTypography.bodySm.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: isScopeBreach ? AppColors.statusError : AppColors.statusSuccess,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 2. Deterministic Edge-Case Probes (Calculator Demo)
                if (evidence.breakItChecks.isNotEmpty) ...[
                  Row(
                    children: [
                      Text(
                        'DETERMINISTIC EDGE-CASE PROBES',
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
                          '${evidence.breakItChecks.length} probes',
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
                      children: evidence.breakItChecks.map((probe) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                probe.passed ? Icons.check_circle : Icons.cancel,
                                size: 16,
                                color: probe.passed ? AppColors.statusSuccess : AppColors.statusError,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          probe.name,
                                          style: AppTypography.bodySm.copyWith(
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                        const Spacer(),
                                        Text(
                                          probe.inputDescription,
                                          style: AppTypography.codeSm.copyWith(
                                            fontSize: 11,
                                            color: AppColors.lavender,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      probe.actualBehavior,
                                      style: AppTypography.bodySm.copyWith(
                                        fontSize: 11,
                                        color: probe.passed
                                            ? AppColors.textSecondary
                                            : AppColors.statusError,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // 3. Command Execution Evidence
                if (evidence.commandRuns.isNotEmpty) ...[
                  Text(
                    'EXECUTED VERIFICATION CHECKS',
                    style: AppTypography.labelSm.copyWith(
                      color: AppColors.textMuted,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...evidence.commandRuns.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final run = entry.value;
                    final isPassed = run.status == 'PASSED' && run.exitCodeZero;
                    final isExpanded = _expandedLogs[idx] ?? false;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () {
                              setState(() {
                                _expandedLogs[idx] = !isExpanded;
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              child: Row(
                                children: [
                                  Icon(
                                    isPassed ? Icons.check_circle : Icons.error,
                                    size: 15,
                                    color: isPassed ? AppColors.statusSuccess : AppColors.statusError,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      run.command,
                                      style: AppTypography.codeSm.copyWith(
                                        fontSize: 11,
                                        color: AppColors.textPrimary,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isPassed
                                          ? AppColors.statusSuccess.withValues(alpha: 0.15)
                                          : AppColors.statusError.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'exit ${run.exitCode} (${run.durationMs}ms)',
                                      style: AppTypography.codeSm.copyWith(
                                        fontSize: 10,
                                        color: isPassed ? AppColors.statusSuccess : AppColors.statusError,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    isExpanded ? Icons.expand_less : Icons.expand_more,
                                    size: 16,
                                    color: AppColors.textMuted,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (isExpanded) ...[
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(
                                color: Color(0xFF100F15),
                                borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                              ),
                              child: Text(
                                (run.stdoutSnippet.isNotEmpty ? run.stdoutSnippet : (run.stderrSnippet ?? 'No output recorded.')).trim(),
                                style: AppTypography.codeSm.copyWith(
                                  fontSize: 10,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 10),
                ],

                // 4. Criteria Verification Checklist
                if (widget.criteria != null && widget.criteria!.isNotEmpty) ...[
                  Text(
                    'CRITERIA VERIFICATION RESULTS',
                    style: AppTypography.labelSm.copyWith(
                      color: AppColors.textMuted,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.borderSubtle.withValues(alpha: 0.6)),
                    ),
                    child: Column(
                      children: widget.criteria!.map((crit) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Row(
                            children: [
                              Icon(
                                crit.verified ? Icons.check_circle : Icons.cancel,
                                size: 14,
                                color: crit.verified ? AppColors.statusSuccess : AppColors.statusError,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  crit.description,
                                  style: AppTypography.bodySm.copyWith(
                                    fontSize: 12,
                                    color: crit.verified ? AppColors.textPrimary : AppColors.textSecondary,
                                  ),
                                ),
                              ),
                              if (crit.evidenceNote != null) ...[
                                const SizedBox(width: 6),
                                Text(
                                  crit.evidenceNote!,
                                  style: AppTypography.codeSm.copyWith(fontSize: 10, color: AppColors.lavender),
                                ),
                              ],
                            ],
                          ),
                        );
                      }).toList(),
                    ),
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

extension on CommandEvidenceModel {
  bool get exitCodeZero => exitCode == 0;
}
