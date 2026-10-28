import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

class FileChangedCard extends StatefulWidget {
  final String file;
  final String? action;
  final String diff;
  final int additions;
  final int deletions;
  final bool initiallyExpanded;

  const FileChangedCard({
    super.key,
    required this.file,
    this.action,
    required this.diff,
    this.additions = 0,
    this.deletions = 0,
    this.initiallyExpanded = false,
  });

  @override
  State<FileChangedCard> createState() => _FileChangedCardState();
}

class _FileChangedCardState extends State<FileChangedCard> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
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
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.description_outlined, size: 14, color: AppColors.lavender),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.file,
                      style: AppTypography.codeSm.copyWith(
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (widget.additions > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.statusSuccess.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '+${widget.additions}',
                        style: const TextStyle(
                          color: AppColors.statusSuccess,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  if (widget.deletions > 0) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.statusError.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '-${widget.deletions}',
                        style: const TextStyle(
                          color: AppColors.statusError,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    _isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),

          // Diff Viewer
          if (_isExpanded && widget.diff.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.diff.split('\n').map((line) {
                  Color textColor = AppColors.textSecondary;
                  if (line.startsWith('+') && !line.startsWith('+++')) {
                    textColor = AppColors.statusSuccess;
                  } else if (line.startsWith('-') && !line.startsWith('---')) {
                    textColor = AppColors.statusError;
                  } else if (line.startsWith('@')) {
                    textColor = AppColors.lavender;
                  }

                  return Text(
                    line,
                    style: AppTypography.codeSm.copyWith(
                      color: textColor,
                      fontSize: 10,
                      height: 1.3,
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}
