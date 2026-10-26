import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

class ChatMessageBubble extends StatelessWidget {
  final String role; // "user" or "assistant"
  final String content;
  final bool isStreaming;
  final DateTime? timestamp;

  const ChatMessageBubble({
    super.key,
    required this.role,
    required this.content,
    this.isStreaming = false,
    this.timestamp,
  });

  bool get isUser => role == 'user';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.primary.withOpacity(0.3)),
              ),
              child: const Icon(Icons.auto_awesome, size: 14, color: AppColors.lavender),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? const Color(0xFF2C2442) : AppColors.surfaceMain,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(12),
                  topRight: const Radius.circular(12),
                  bottomLeft: Radius.circular(isUser ? 12 : 2),
                  bottomRight: Radius.circular(isUser ? 2 : 12),
                ),
                border: Border.all(
                  color: isUser ? AppColors.primary.withOpacity(0.4) : AppColors.borderSubtle,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      text: content,
                      style: isUser
                          ? AppTypography.bodyMd.copyWith(color: AppColors.textPrimary)
                          : AppTypography.bodyMd.copyWith(color: AppColors.textPrimary, height: 1.45),
                      children: [
                        if (isStreaming)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Container(
                              margin: const EdgeInsets.only(left: 3),
                              width: 7,
                              height: 13,
                              color: AppColors.primaryLight,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: const Icon(Icons.person_outline, size: 15, color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}
