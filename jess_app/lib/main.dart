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
  int _currentScreenIndex = 3; // Default to Screen 4: Home Dashboard
  ProjectSource _selectedSource = ProjectSource.github;
  String _activeProjectName = 'cloudaiagent';

  final List<String> _screenTitles = [
    'Screen 1: Login & Register',
    'Screen 2: Email Verification',
    'Screen 3: Password Recovery',
    'Screen 4: Home Dashboard',
    'Screen 5: Projects List',
    'Screen 6: Project Overview',
    'Screen 7: Choose Source',
    'Screen 8: Configure Project',
    'Screen 9: Ideation Funnel',
    'Screen 10: Idea Analysis',
    'Screen 11: Technology Stack',
  ];

  Widget _buildScreen(int index) {
    switch (index) {
      case 0:
        return Screen1LoginRegister(
          onLoginSuccess: () => setState(() => _currentScreenIndex = 3),
          onNavigateToVerification: () => setState(() => _currentScreenIndex = 1),
          onNavigateToRecovery: () => setState(() => _currentScreenIndex = 2),
        );
      case 1:
        return Screen2EmailVerification(
          onContinue: () => setState(() => _currentScreenIndex = 3),
          onChangeEmail: () => setState(() => _currentScreenIndex = 0),
        );
      case 2:
        return Screen3PasswordRecovery(
          onBackToLogin: () => setState(() => _currentScreenIndex = 0),
        );
      case 3:
        return Screen4HomeDashboard(
          onNewProject: () => setState(() => _currentScreenIndex = 6),
          onViewAllProjects: () => setState(() => _currentScreenIndex = 4),
          onOpenProject: (name) {
            setState(() {
              _activeProjectName = name;
              _currentScreenIndex = 5;
            });
          },
          onOpenDrawer: () => _openScreenSelector(context),
        );
      case 4:
        return Screen5ProjectsList(
          onNewProject: () => setState(() => _currentScreenIndex = 6),
          onSelectProject: (name) {
            setState(() {
              _activeProjectName = name;
              _currentScreenIndex = 5;
            });
          },
        );
      case 5:
        return Screen6ProjectOverview(
          projectName: _activeProjectName,
          onOpenChat: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Opening AI Coding Chat (Screen 17)...')),
            );
          },
          onBrowseFiles: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Opening File Explorer (Screen 19)...')),
            );
          },
          onReviewChanges: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Opening Diff & Change Review (Screen 21)...')),
            );
          },
        );
      case 6:
        return Screen7ChooseSource(
          onContinue: (source) {
            setState(() {
              _selectedSource = source;
              if (source == ProjectSource.ideation) {
                _currentScreenIndex = 8; // Screen 9: Ideation
              } else {
                _currentScreenIndex = 7; // Screen 8: Configure Project
              }
            });
          },
          onCancel: () => setState(() => _currentScreenIndex = 3),
        );
      case 7:
        return Screen8ConfigureProject(
          source: _selectedSource,
          onBack: () => setState(() => _currentScreenIndex = 6),
          onContinue: () => setState(() => _currentScreenIndex = 10), // Proceed to Screen 11: Tech Stack
        );
      case 8:
        return Screen9Ideation(
          onBack: () => setState(() => _currentScreenIndex = 6),
          onAnalyzeIdea: () => setState(() => _currentScreenIndex = 9), // Screen 10
        );
      case 9:
        return Screen10IdeaAnalysis(
          onBack: () => setState(() => _currentScreenIndex = 8),
          onConfirmAnalysis: () => setState(() => _currentScreenIndex = 10), // Screen 11
        );
      case 10:
        return Screen11TechnologyStack(
          onBack: () => setState(() => _currentScreenIndex = 9),
          onConfirmStack: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Stack Confirmed! Project ready to create.')),
            );
            setState(() => _currentScreenIndex = 5); // Return to overview
          },
        );
      default:
        return const Center(child: Text('Screen not found'));
    }
  }

  void _openScreenSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceMain,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Jump to Screen (1–11)', style: AppTypography.headlineSm),
                    IconButton(
                      icon: const Icon(Icons.close, color: AppColors.textSecondary),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(color: AppColors.borderSubtle),
              Expanded(
                child: ListView.builder(
                  itemCount: _screenTitles.length,
                  itemBuilder: (ctx, i) {
                    final isSelected = _currentScreenIndex == i;
                    return ListTile(
                      dense: true,
                      leading: Container(
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected ? AppColors.primary : AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${i + 1}',
                          style: AppTypography.codeSm.copyWith(
                            color: isSelected ? Colors.white : AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      title: Text(
                        _screenTitles[i],
                        style: AppTypography.bodyMd.copyWith(
                          color: isSelected ? AppColors.primary : AppColors.textPrimary,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check, size: 16, color: AppColors.primary)
                          : null,
                      onTap: () {
                        setState(() => _currentScreenIndex = i);
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _buildScreen(_currentScreenIndex),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.surfaceElevated,
        foregroundColor: AppColors.lavender,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: AppColors.primary, width: 1.2),
        ),
        elevation: 4,
        icon: const Icon(Icons.layers_outlined, size: 18),
        label: Text(
          'Screen ${_currentScreenIndex + 1}/11',
          style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
        ),
        onPressed: () => _openScreenSelector(context),
      ),
    );
  }
}
