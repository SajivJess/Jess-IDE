import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

enum StatusType { success, warning, error, info, neutral, primary }

class StatusBadge extends StatelessWidget {
  final String label;
  final StatusType type;
  final bool showDot;
  final IconData? icon;

  const StatusBadge({
    super.key,
    required this.label,
    this.type = StatusType.neutral,
    this.showDot = true,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (type) {
      case StatusType.success:
        color = AppColors.statusSuccess;
        break;
      case StatusType.warning:
        color = AppColors.statusWarning;
        break;
      case StatusType.error:
        color = AppColors.statusError;
        break;
      case StatusType.info:
        color = AppColors.statusInfo;
        break;
      case StatusType.primary:
        color = AppColors.primary;
        break;
      case StatusType.neutral:
        color = AppColors.textSecondary;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 5),
          ] else if (showDot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              style: AppTypography.labelSm.copyWith(
                color: color,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}
