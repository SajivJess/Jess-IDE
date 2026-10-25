import 'package:flutter/material.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'theme/app_typography.dart';
import 'screens/auth/screen_1_login_register.dart';
import 'screens/auth/screen_2_email_verification.dart';
import 'screens/auth/screen_3_password_recovery.dart';
import 'screens/dashboard/screen_4_home_dashboard.dart';
import 'screens/dashboard/screen_5_projects_list.dart';
import 'screens/dashboard/screen_6_project_overview.dart';
import 'screens/project_create/screen_7_choose_source.dart';
import 'screens/project_create/screen_8_configure_project.dart';
import 'screens/project_create/screen_9_ideation.dart';
import 'screens/project_create/screen_10_idea_analysis.dart';
import 'screens/project_create/screen_11_technology_stack.dart';
import 'screens/settings/settings_screen.dart';
import 'services/auth_api_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const JessIdeApp());
}

class JessIdeApp extends StatelessWidget {
  const JessIdeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jess IDE Dev',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainShell(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  bool _isAuthenticated = false;
  int _selectedTabIndex = 0;
  String _activeProjectName = 'cloudaiagent';

  @override
  void initState() {
    super.initState();
    _checkInitialAuth();
  }

  Future<void> _checkInitialAuth() async {
    if (AuthApiService.currentAccessToken != null) {
      setState(() => _isAuthenticated = true);
      return;
    }
    final res = await AuthApiService.login(
      email: 'dev@jess.dev',
      password: 'DevPass123!',
    );
    if (mounted && res.success) {
      setState(() => _isAuthenticated = true);
    }
  }

  void _openProjectWorkspace(String projectName) {
    setState(() {
      _activeProjectName = projectName;
      _selectedTabIndex = 2; // Switch to Workspace tab
    });
  }

  void _openCreateProjectFlow(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => Screen7ChooseSource(
          onCancel: () => Navigator.of(ctx).pop(),
          onContinue: (source) {
            Navigator.of(ctx).pop();
            _navigateCreateDetails(context, source);
          },
        ),
      ),
    );
  }

  void _navigateCreateDetails(BuildContext context, ProjectSource source) {
    if (source == ProjectSource.ideation) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (ctx) => Screen9Ideation(
            onBack: () => Navigator.of(ctx).pop(),
            onAnalyzeIdea: () {
              Navigator.of(ctx).push(
                MaterialPageRoute(
                  builder: (aCtx) => Screen10IdeaAnalysis(
                    onBack: () => Navigator.of(aCtx).pop(),
                    onConfirmAnalysis: () {
                      Navigator.of(aCtx).push(
                        MaterialPageRoute(
                          builder: (sCtx) => Screen11TechnologyStack(
                            onBack: () => Navigator.of(sCtx).pop(),
                            onConfirmStack: () {
                              Navigator.of(context).popUntil((route) => route.isFirst);
                              _openProjectWorkspace('autonomous-code-editor');
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (ctx) => Screen8ConfigureProject(
            source: source,
            onBack: () => Navigator.of(ctx).pop(),
            onContinue: () {
              Navigator.of(context).popUntil((route) => route.isFirst);
              setState(() {
                _selectedTabIndex = 1; // Show projects list with newly created project
              });
            },
          ),
        ),
      );
    }
  }

  Widget _buildBody() {
    switch (_selectedTabIndex) {
      case 0:
        return Screen4HomeDashboard(
          onNewProject: () => _openCreateProjectFlow(context),
          onViewAllProjects: () => setState(() => _selectedTabIndex = 1),
          onOpenProject: (name) => _openProjectWorkspace(name),
        );
      case 1:
        return Screen5ProjectsList(
          onNewProject: () => _openCreateProjectFlow(context),
          onSelectProject: (name) => _openProjectWorkspace(name),
        );
      case 2:
        return Screen6ProjectOverview(
          key: ValueKey(_activeProjectName),
          projectName: _activeProjectName,
          onOpenChat: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('AI Coding Chat ready.')),
            );
          },
          onBrowseFiles: () {},
          onReviewChanges: () {},
        );
      case 3:
        return SettingsScreen(
          onSignOut: () => setState(() => _isAuthenticated = false),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAuthenticated) {
      return Screen1LoginRegister(
        onLoginSuccess: () => setState(() => _isAuthenticated = true),
        onNavigateToVerification: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (ctx) => Screen2EmailVerification(
                onContinue: () {
                  Navigator.of(ctx).pop();
                  setState(() => _isAuthenticated = true);
                },
                onChangeEmail: () => Navigator.of(ctx).pop(),
              ),
            ),
          );
        },
        onNavigateToRecovery: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (ctx) => Screen3PasswordRecovery(
                onBackToLogin: () => Navigator.of(ctx).pop(),
              ),
            ),
          );
        },
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        top: false,
        child: _buildBody(),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceMain,
          border: Border(top: BorderSide(color: AppColors.borderSubtle)),
        ),
        child: NavigationBarTheme(
          data: NavigationBarThemeData(
            backgroundColor: AppColors.surfaceMain,
            indicatorColor: AppColors.surfaceElevated,
            labelTextStyle: MaterialStateProperty.resolveWith((states) {
              final isSelected = states.contains(MaterialState.selected);
              return AppTypography.codeSm.copyWith(
                color: isSelected ? AppColors.lavender : AppColors.textSecondary,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              );
            }),
            iconTheme: MaterialStateProperty.resolveWith((states) {
              final isSelected = states.contains(MaterialState.selected);
              return IconThemeData(
                color: isSelected ? AppColors.lavender : AppColors.textSecondary,
                size: 20,
              );
            }),
          ),
          child: NavigationBar(
            height: 60,
            selectedIndex: _selectedTabIndex,
            onDestinationSelected: (index) => setState(() => _selectedTabIndex = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.space_dashboard_outlined),
                selectedIcon: Icon(Icons.space_dashboard),
                label: 'Dashboard',
              ),
              NavigationDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: 'Projects',
              ),
              NavigationDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal),
                label: 'Workspace',
              ),
              NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
