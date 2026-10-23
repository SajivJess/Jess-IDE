import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/app_text_field.dart';
import '../../services/auth_api_service.dart';

class Screen1LoginRegister extends StatefulWidget {
  final VoidCallback? onLoginSuccess;
  final VoidCallback? onNavigateToVerification;
  final VoidCallback? onNavigateToRecovery;

  const Screen1LoginRegister({
    super.key,
    this.onLoginSuccess,
    this.onNavigateToVerification,
    this.onNavigateToRecovery,
  });

  @override
  State<Screen1LoginRegister> createState() => _Screen1LoginRegisterState();
}

class _Screen1LoginRegisterState extends State<Screen1LoginRegister> {
  bool isSignUp = false;
  bool isLoading = false;
  bool showErrorBanner = false;
  bool rememberSession = true;
  bool agreeTerms = false;
  String? errorMessage;

  final TextEditingController _signInEmailController =
      TextEditingController(text: 'lead.dev@workspace.internal');
  final TextEditingController _signInPasswordController =
      TextEditingController(text: 'supersecretdevkey');

  final TextEditingController _signUpNameController = TextEditingController();
  final TextEditingController _signUpEmailController = TextEditingController();
  final TextEditingController _signUpPasswordController = TextEditingController();
  final TextEditingController _signUpConfirmPasswordController = TextEditingController();

  void _handleSignIn() async {
    final email = _signInEmailController.text.trim();
    final password = _signInPasswordController.text;

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your email and password')),
      );
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    final result = await AuthApiService.login(email: email, password: password);

    if (mounted) {
      setState(() => isLoading = false);
      if (result.success) {
        if (widget.onLoginSuccess != null) {
          widget.onLoginSuccess!();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Signed in successfully!')),
          );
        }
      } else {
        setState(() {
          errorMessage = result.message;
          showErrorBanner = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: AppColors.statusError,
          ),
        );
      }
    }
  }

  void _handleSignUp() async {
    if (!agreeTerms) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please accept the developer agreement')),
      );
      return;
    }

    final email = _signUpEmailController.text.trim();
    final password = _signUpPasswordController.text;
    final confirmPassword = _signUpConfirmPasswordController.text;
    final fullName = _signUpNameController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter email and password')),
      );
      return;
    }

    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passwords do not match')),
      );
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    final result = await AuthApiService.register(
      email: email,
      password: password,
      fullName: fullName.isNotEmpty ? fullName : null,
    );

    if (mounted) {
      setState(() => isLoading = false);
      if (result.success) {
        if (widget.onNavigateToVerification != null) {
          widget.onNavigateToVerification!();
        }
      } else {
        setState(() {
          errorMessage = result.message;
          showErrorBanner = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: AppColors.statusError,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        onHelpPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Documentation & Support')),
          );
        },
      ),
      body: Column(
        children: [
          // Interactive Demo Bar (matches Stitch preview rail)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              color: AppColors.surfaceMain,
              border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: AppColors.statusSuccess,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Demo Controls:',
                  style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => setState(() => showErrorBanner = !showErrorBanner),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 13,
                          color: showErrorBanner ? AppColors.statusError : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          showErrorBanner ? 'Hide Error' : 'Sim Error',
                          style: AppTypography.labelSm,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Main Scrollable Content
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Kicker Badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceMain,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: AppColors.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'orchestration node',
                              style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        isSignUp ? 'Create your account' : 'Your workspace. Your agent. Your code.',
                        style: AppTypography.headlineLg,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isSignUp
                            ? 'Set up your workspace and start managing your coding projects.'
                            : 'Sign in to manage your projects, continue coding sessions, and review changes from anywhere.',
                        style: AppTypography.bodyMd,
                      ),
                      const SizedBox(height: 20),

                      // Segmented Tab Switch
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceMain,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setState(() => isSignUp = false),
                                child: Container(
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: !isSignUp ? AppColors.surfaceElevated : Colors.transparent,
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    'Sign In',
                                    style: AppTypography.labelMd.copyWith(
                                      color: !isSignUp ? AppColors.textPrimary : AppColors.textSecondary,
                                      fontWeight: !isSignUp ? FontWeight.w600 : FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setState(() => isSignUp = true),
                                child: Container(
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: isSignUp ? AppColors.surfaceElevated : Colors.transparent,
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    'Create Account',
                                    style: AppTypography.labelMd.copyWith(
                                      color: isSignUp ? AppColors.textPrimary : AppColors.textSecondary,
                                      fontWeight: isSignUp ? FontWeight.w600 : FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Surface Card Wrapper
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceMain,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Error Banner
                            if (showErrorBanner) ...[
                              Container(
                                padding: const EdgeInsets.all(12),
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                  color: AppColors.errorBg,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.errorBorder),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(Icons.warning_amber_rounded,
                                        color: AppColors.statusError, size: 20),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Invalid email or workspace credentials',
                                            style: AppTypography.bodySm.copyWith(
                                              color: AppColors.statusError,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'AUTH_ERR_401: Invalid credentials for user profile',
                                            style: AppTypography.codeSm.copyWith(
                                              color: AppColors.statusError.withOpacity(0.8),
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () => setState(() => showErrorBanner = false),
                                      child: const Icon(Icons.close,
                                          color: AppColors.statusError, size: 16),
                                    ),
                                  ],
                                ),
                              ),
                            ],

                            // SIGN IN VIEW
                            if (!isSignUp) ...[
                              AppTextField(
                                label: 'Email address',
                                prefixIcon: Icons.mail_outline,
                                controller: _signInEmailController,
                                hintText: 'you@example.com',
                                keyboardType: TextInputType.emailAddress,
                              ),
                              const SizedBox(height: 14),
                              AppTextField(
                                label: 'Password',
                                labelTrailing: GestureDetector(
                                  onTap: widget.onNavigateToRecovery,
                                  child: Text(
                                    'Forgot password?',
                                    style: AppTypography.bodySm.copyWith(
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                prefixIcon: Icons.lock_outline,
                                isPassword: true,
                                controller: _signInPasswordController,
                                hintText: '••••••••••••',
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: Checkbox(
                                      value: rememberSession,
                                      activeColor: AppColors.primary,
                                      checkColor: Colors.white,
                                      side: const BorderSide(color: AppColors.borderSubtle),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      onChanged: (val) =>
                                          setState(() => rememberSession = val ?? true),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Remember this terminal session',
                                      style: AppTypography.bodySm,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              AppButton(
                                text: 'Sign In',
                                isLoading: isLoading,
                                onPressed: _handleSignIn,
                              ),
                              const SizedBox(height: 14),
                              Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('New to Jess Ide Dev? ', style: AppTypography.bodySm),
                                    GestureDetector(
                                      onTap: () => setState(() => isSignUp = true),
                                      child: Text(
                                        'Create account',
                                        style: AppTypography.bodySm.copyWith(
                                          color: AppColors.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ] else ...[
                              // CREATE ACCOUNT VIEW
                              AppTextField(
                                label: 'Full name',
                                prefixIcon: Icons.badge_outlined,
                                controller: _signUpNameController,
                                hintText: 'Ada Lovelace',
                              ),
                              const SizedBox(height: 14),
                              AppTextField(
                                label: 'Email address',
                                prefixIcon: Icons.mail_outline,
                                controller: _signUpEmailController,
                                hintText: 'you@example.com',
                                keyboardType: TextInputType.emailAddress,
                              ),
                              const SizedBox(height: 14),
                              AppTextField(
                                label: 'Password',
                                prefixIcon: Icons.lock_outline,
                                isPassword: true,
                                controller: _signUpPasswordController,
                                hintText: 'Minimum 10 characters',
                                helperText: 'Requires letters, numbers, and symbols.',
                              ),
                              const SizedBox(height: 14),
                              AppTextField(
                                label: 'Confirm password',
                                prefixIcon: Icons.lock_clock_outlined,
                                isPassword: true,
                                controller: _signUpConfirmPasswordController,
                                hintText: 'Re-enter password',
                              ),
                              const SizedBox(height: 14),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: Checkbox(
                                      value: agreeTerms,
                                      activeColor: AppColors.primary,
                                      checkColor: Colors.white,
                                      side: const BorderSide(color: AppColors.borderSubtle),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      onChanged: (val) =>
                                          setState(() => agreeTerms = val ?? false),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'I accept the Developer Agreement and understand that AI orchestration sessions execute in isolated sandboxes.',
                                      style: AppTypography.bodySm,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              AppButton(
                                text: 'Create Account',
                                isLoading: isLoading,
                                onPressed: _handleSignUp,
                              ),
                              const SizedBox(height: 14),
                              Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('Already have an account? ', style: AppTypography.bodySm),
                                    GestureDetector(
                                      onTap: () => setState(() => isSignUp = false),
                                      child: Text(
                                        'Sign in',
                                        style: AppTypography.bodySm.copyWith(
                                          color: AppColors.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
