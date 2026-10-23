import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/app_text_field.dart';

enum RecoveryState { requestForm, linkSent, setPassword, expired }

class Screen3PasswordRecovery extends StatefulWidget {
  final VoidCallback? onBackToLogin;

  const Screen3PasswordRecovery({
    super.key,
    this.onBackToLogin,
  });

  @override
  State<Screen3PasswordRecovery> createState() => _Screen3PasswordRecoveryState();
}

class _Screen3PasswordRecoveryState extends State<Screen3PasswordRecovery> {
  RecoveryState _state = RecoveryState.requestForm;
  bool _isLoading = false;

  final TextEditingController _emailController =
      TextEditingController(text: 'lead.dev@workspace.internal');
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();

  void _sendResetLink() async {
    setState(() => _isLoading = true);
    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted) {
      setState(() {
        _isLoading = false;
        _state = RecoveryState.linkSent;
      });
    }
  }

  void _updatePassword() async {
    setState(() => _isLoading = true);
    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated successfully!')),
      );
      if (widget.onBackToLogin != null) {
        widget.onBackToLogin!();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        showBack: true,
        onBackPressed: widget.onBackToLogin ?? () => Navigator.of(context).maybePop(),
      ),
      body: Column(
        children: [
          // State Switcher (Demo Rail)
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
                      children: RecoveryState.values.map((s) {
                        final isSelected = _state == s;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InkWell(
                            onTap: () => setState(() => _state = s),
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
                                s.name.toUpperCase(),
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
          // Content
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
                    child: _buildFormContent(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormContent() {
    switch (_state) {
      case RecoveryState.requestForm:
        return _buildRequestForm();
      case RecoveryState.linkSent:
        return _buildLinkSent();
      case RecoveryState.setPassword:
        return _buildSetPassword();
      case RecoveryState.expired:
        return _buildExpired();
    }
  }

  Widget _buildRequestForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: const Icon(Icons.key_outlined, color: AppColors.lavender, size: 24),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text('Reset your password', style: AppTypography.headlineMd),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            'Enter the email address associated with your account. If an account matches, we\'ll send instructions to reset your password.',
            style: AppTypography.bodySm,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 20),
        AppTextField(
          label: 'Email address',
          prefixIcon: Icons.mail_outline,
          controller: _emailController,
          hintText: 'you@example.com',
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 20),
        AppButton(
          text: 'Send reset link',
          isLoading: _isLoading,
          onPressed: _sendResetLink,
          icon: const Icon(Icons.arrow_forward, size: 18, color: Colors.white),
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: widget.onBackToLogin ?? () => Navigator.of(context).maybePop(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.arrow_back, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 4),
                Text('Back to sign in', style: AppTypography.labelMd.copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated.withOpacity(0.7),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.shield_outlined, size: 16, color: AppColors.lavender),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'ZERO-ENUMERATION RECOVERY: For security perimeter integrity, responses are identical regardless of whether an email exists.',
                  style: AppTypography.codeSm.copyWith(fontSize: 10, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLinkSent() {
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: AppColors.successBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.successBorder),
          ),
          child: const Icon(Icons.mark_email_read_outlined,
              color: AppColors.statusSuccess, size: 28),
        ),
        const SizedBox(height: 16),
        Text('Check your inbox', style: AppTypography.headlineMd),
        const SizedBox(height: 8),
        Text(
          'If an account matches that email, reset instructions will be sent. The link remains valid for 15 minutes.',
          style: AppTypography.bodyMd,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        AppButton(
          text: 'Proceed to Set Password',
          variant: AppButtonVariant.primary,
          onPressed: () => setState(() => _state = RecoveryState.setPassword),
        ),
        const SizedBox(height: 12),
        AppButton(
          text: 'Return to sign in',
          variant: AppButtonVariant.secondary,
          onPressed: widget.onBackToLogin ?? () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _buildSetPassword() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Text('Create new password', style: AppTypography.headlineMd),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            'Your new password must be at least 10 characters and distinct from earlier passwords.',
            style: AppTypography.bodySm,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 20),
        AppTextField(
          label: 'New password',
          prefixIcon: Icons.lock_outline,
          isPassword: true,
          controller: _newPasswordController,
          hintText: 'Enter new password',
        ),
        const SizedBox(height: 14),
        AppTextField(
          label: 'Confirm new password',
          prefixIcon: Icons.lock_clock_outlined,
          isPassword: true,
          controller: _confirmPasswordController,
          hintText: 'Confirm new password',
          helperText: 'Requires uppercase, lowercase, numbers, and symbols.',
        ),
        const SizedBox(height: 20),
        AppButton(
          text: 'Update password',
          isLoading: _isLoading,
          onPressed: _updatePassword,
        ),
      ],
    );
  }

  Widget _buildExpired() {
    return Column(
      children: [
        const Icon(Icons.error_outline, size: 48, color: AppColors.statusWarning),
        const SizedBox(height: 16),
        Text('Link expired', style: AppTypography.headlineMd),
        const SizedBox(height: 8),
        Text(
          'This password recovery token has expired. Please submit another request.',
          style: AppTypography.bodyMd,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        AppButton(
          text: 'Request another link',
          onPressed: () => setState(() => _state = RecoveryState.requestForm),
        ),
      ],
    );
  }
}
