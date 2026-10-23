import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';

enum VerificationState { waiting, resent, verified, expired }

class Screen2EmailVerification extends StatefulWidget {
  final String email;
  final VoidCallback? onContinue;
  final VoidCallback? onChangeEmail;

  const Screen2EmailVerification({
    super.key,
    this.email = 'sajiv@example.com',
    this.onContinue,
    this.onChangeEmail,
  });

  @override
  State<Screen2EmailVerification> createState() => _Screen2EmailVerificationState();
}

class _Screen2EmailVerificationState extends State<Screen2EmailVerification> {
  VerificationState _currentState = VerificationState.waiting;
  bool _isChecking = false;
  int _cooldownSeconds = 30;

  void _checkVerification() async {
    setState(() => _isChecking = true);
    await Future.delayed(const Duration(milliseconds: 1000));
    if (mounted) {
      setState(() {
        _isChecking = false;
        _currentState = VerificationState.verified;
      });
    }
  }

  void _simulateResend() {
    setState(() {
      _currentState = VerificationState.resent;
      _cooldownSeconds = 30;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        showBack: true,
        onBackPressed: () => Navigator.of(context).maybePop(),
      ),
      body: Column(
        children: [
          // State Switcher Rail (Demo Helper)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              color: AppColors.surfaceMain,
              border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
            ),
            child: Row(
              children: [
                Text('State:', style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary)),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: VerificationState.values.map((state) {
                        final isSelected = _currentState == state;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InkWell(
                            onTap: () => setState(() => _currentState = state),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: isSelected ? AppColors.surfaceElevated : Colors.transparent,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: isSelected ? AppColors.primary : AppColors.borderSubtle,
                                ),
                              ),
                              child: Text(
                                state.name.toUpperCase(),
                                style: AppTypography.labelSm.copyWith(
                                  color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Main Body
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceMain,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: _buildStateContent(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStateContent() {
    switch (_currentState) {
      case VerificationState.waiting:
        return _buildWaitingState();
      case VerificationState.resent:
        return _buildResentState();
      case VerificationState.verified:
        return _buildVerifiedState();
      case VerificationState.expired:
        return _buildExpiredState();
    }
  }

  Widget _buildWaitingState() {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: const Icon(Icons.mark_email_unread_outlined,
              color: AppColors.lavender, size: 32),
        ),
        const SizedBox(height: 18),
        Text('Verify your email', style: AppTypography.headlineLg, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'We\'ve sent a verification link to your email address. Open the message and follow the link to activate your workspace.',
          style: AppTypography.bodyMd,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        _buildEmailCapsule(),
        const SizedBox(height: 20),
        AppButton(
          text: 'I\'ve verified my email',
          isLoading: _isChecking,
          icon: const Icon(Icons.check, size: 18, color: Colors.white),
          onPressed: _checkVerification,
        ),
        const SizedBox(height: 16),
        Text('Didn\'t receive the email?', style: AppTypography.bodySm),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: _simulateResend,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.refresh, size: 16, color: AppColors.primary),
              const SizedBox(width: 4),
              Text(
                'Resend verification email',
                style: AppTypography.labelMd.copyWith(color: AppColors.primary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'You can request another email in ${_cooldownSeconds}s',
          style: AppTypography.labelSm,
        ),
        const SizedBox(height: 24),
        _buildSecurityBadge(),
      ],
    );
  }

  Widget _buildResentState() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.successBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.successBorder),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline, color: AppColors.statusSuccess, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Verification email dispatched. Check your inbox and spam folder.',
                  style: AppTypography.bodySm.copyWith(color: AppColors.statusSuccess),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: const Icon(Icons.forward_to_inbox, color: AppColors.statusInfo, size: 32),
        ),
        const SizedBox(height: 18),
        Text('Fresh email sent', style: AppTypography.headlineLg, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'A new security token has been generated and sent to your registered address.',
          style: AppTypography.bodyMd,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        _buildEmailCapsule(),
        const SizedBox(height: 20),
        AppButton(
          text: 'I\'ve verified my email',
          onPressed: _checkVerification,
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () => setState(() => _currentState = VerificationState.waiting),
          child: Text('Return to previous view', style: AppTypography.bodySm),
        ),
      ],
    );
  }

  Widget _buildVerifiedState() {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.statusSuccess.withOpacity(0.4)),
          ),
          child: const Icon(Icons.verified, color: AppColors.statusSuccess, size: 34),
        ),
        const SizedBox(height: 16),
        const StatusBadge(
          label: 'Security Handshake Complete',
          type: StatusType.success,
          icon: Icons.lock_open,
        ),
        const SizedBox(height: 12),
        Text('Email verified', style: AppTypography.headlineLg, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'Your email address has been confirmed. You\'re ready to continue to Jess Ide Dev.',
          style: AppTypography.bodyMd,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        AppButton(
          text: 'Continue to Jess Ide Dev',
          onPressed: widget.onContinue ??
              () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Welcome to Jess Ide Dev!')),
                );
              },
        ),
      ],
    );
  }

  Widget _buildExpiredState() {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.statusWarning.withOpacity(0.4)),
          ),
          child: const Icon(Icons.timer_off_outlined, color: AppColors.statusWarning, size: 34),
        ),
        const SizedBox(height: 16),
        Text('Link expired', style: AppTypography.headlineLg, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'The security link in that email has expired. Please request a new verification link.',
          style: AppTypography.bodyMd,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        AppButton(
          text: 'Resend verification email',
          onPressed: _simulateResend,
        ),
      ],
    );
  }

  Widget _buildEmailCapsule() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          const Icon(Icons.alternate_email, color: AppColors.textSecondary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.email,
              style: AppTypography.codeMd,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: widget.onChangeEmail ??
                () => Navigator.of(context).maybePop(),
            child: Text(
              'Change',
              style: AppTypography.bodySm.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityBadge() {
    return Container(
      padding: const EdgeInsets.only(top: 16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, size: 15, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text('Token nonce: 15m ttl', style: AppTypography.labelSm),
            ],
          ),
          Text('SHA-256 Validated', style: AppTypography.labelSm),
        ],
      ),
    );
  }
}
