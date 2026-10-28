import 'dart:convert';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../services/ui_suggestions_api_service.dart';

class UiSuggestionCard extends StatelessWidget {
  final UiSuggestionModel suggestion;
  final ValueChanged<String>? onCodeDesign;
  final ValueChanged<UiSuggestionModel>? onRefineDesign;

  const UiSuggestionCard({
    super.key,
    required this.suggestion,
    this.onCodeDesign,
    this.onRefineDesign,
  });

  @override
  Widget build(BuildContext context) {
    Widget? imageWidget;

    if (suggestion.imageDataUri != null && suggestion.imageDataUri!.startsWith('data:image')) {
      try {
        final commaIdx = suggestion.imageDataUri!.indexOf(',');
        if (commaIdx != -1) {
          final b64 = suggestion.imageDataUri!.substring(commaIdx + 1);
          final bytes = base64Decode(b64);
          imageWidget = Image.memory(
            bytes,
            fit: BoxFit.cover,
            height: 240,
            width: double.infinity,
          );
        }
      } catch (_) {
        imageWidget = null;
      }
    } else if (suggestion.previewUrl != null) {
      imageWidget = Image.network(
        suggestion.previewUrl!,
        fit: BoxFit.cover,
        height: 240,
        width: double.infinity,
        errorBuilder: (_, __, ___) => const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Icon(Icons.broken_image, color: AppColors.textSecondary, size: 36),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceMain,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBD93F9).withOpacity(0.4), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFBD93F9).withOpacity(0.08),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFBD93F9).withOpacity(0.18),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFFBD93F9).withOpacity(0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.auto_awesome, size: 12, color: Color(0xFFBD93F9)),
                      const SizedBox(width: 4),
                      Text(
                        'MUSE IMAGE 1.0 • UI PROPOSAL',
                        style: AppTypography.codeSm.copyWith(
                          color: const Color(0xFFBD93F9),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                const Icon(Icons.brush_outlined, size: 16, color: AppColors.textSecondary),
              ],
            ),
          ),

          // Prompt description
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              suggestion.prompt,
              style: AppTypography.bodySm.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Image Mockup Preview
          if (imageWidget != null)
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(0), bottom: Radius.circular(0)),
              child: Container(
                color: const Color(0xFF0F0E17),
                child: imageWidget,
              ),
            )
          else
            Container(
              height: 120,
              color: AppColors.surfaceElevated,
              child: Center(
                child: Text(
                  'Mockup preview unavailable',
                  style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ),

          // Action Buttons Bar
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(11)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    icon: const Icon(Icons.code, size: 14),
                    label: Text(
                      'Code This Design',
                      style: AppTypography.codeSm.copyWith(
                        color: Colors.black,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                    onPressed: onCodeDesign != null
                        ? () => onCodeDesign!(
                              'Implement the following UI design with code:\n${suggestion.prompt}',
                            )
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.lavender,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  icon: const Icon(Icons.tune, size: 14),
                  label: Text('Refine', style: AppTypography.codeSm.copyWith(fontSize: 11)),
                  onPressed: onRefineDesign != null ? () => onRefineDesign!(suggestion) : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
