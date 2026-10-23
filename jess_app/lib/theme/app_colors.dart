import 'package:flutter/material.dart';

/// Jess IDE Design System Colors matching stitch UI/jess_ide_dev/DESIGN.md
class AppColors {
  AppColors._();

  // Background & Surfaces
  static const Color background = Color(0xFF15141B);
  static const Color surface = Color(0xFF15141B);
  static const Color surfaceMain = Color(0xFF1C1A24);
  static const Color surfaceElevated = Color(0xFF24222D);
  static const Color surfaceBright = Color(0xFF3A3840);
  static const Color surfaceContainerLow = Color(0xFF1C1B22);
  static const Color surfaceContainer = Color(0xFF201F26);
  static const Color surfaceContainerHigh = Color(0xFF2A2931);

  // Brand Accents
  static const Color primary = Color(0xFF8B5CF6);
  static const Color primaryHover = Color(0xFF7C3AED);
  static const Color primaryActive = Color(0xFF6D28D9);
  static const Color primaryLight = Color(0xFFC4B5FD);
  static const Color lavender = Color(0xFFC4B5FD);
  static const Color secondary = Color(0xFFC4B5FD);
  static const Color secondaryContainer = Color(0xFF4A3D7C);

  // Text
  static const Color textPrimary = Color(0xFFF5F3FA);
  static const Color textSecondary = Color(0xFFA6A1B3);
  static const Color textMuted = Color(0xFF837E8F);

  // Borders & Outlines
  static const Color borderSubtle = Color(0xFF353140);
  static const Color outlineVariant = Color(0xFF494454);

  // Status & Diagnostics
  static const Color statusSuccess = Color(0xFF34D399);
  static const Color statusWarning = Color(0xFFFBBF24);
  static const Color statusError = Color(0xFFF87171);
  static const Color statusInfo = Color(0xFF60A5FA);

  // Containers with opacity helpers
  static Color errorBg = const Color(0xFFF87171).withOpacity(0.12);
  static Color errorBorder = const Color(0xFFF87171).withOpacity(0.25);
  static Color successBg = const Color(0xFF34D399).withOpacity(0.12);
  static Color successBorder = const Color(0xFF34D399).withOpacity(0.25);
}
