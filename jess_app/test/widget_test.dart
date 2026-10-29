import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:jess_app/main.dart';
import 'package:jess_app/services/auth_api_service.dart';
import 'package:jess_app/screens/dashboard/screen_6_project_overview.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() {
    AuthApiService.currentAccessToken = 'test-token-active';
  });

  testWidgets('Three-tab main navigation shell displays Dashboard, Projects, Settings without global Workspace tab', (WidgetTester tester) async {
    await tester.pumpWidget(const MuseFlowApp());
    await tester.pumpAndSettle();

    // Verify exactly three main navigation destinations
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('Projects'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);

    // Verify Workspace is NOT in the global navigation destinations
    expect(find.widgetWithText(NavigationDestination, 'Workspace'), findsNothing);

    // Verify demo 1/11 selector is completely removed
    expect(find.textContaining('1/11'), findsNothing);
  });

  testWidgets('Project overview provides contextual navigation: Overview, Chat, Workspace, Changes', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Screen6ProjectOverview(
          projectId: 'test-proj-123',
          projectName: 'cloudaiagent',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify contextual destinations inside project
    expect(find.text('cloudaiagent'), findsWidgets);
    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Chat'), findsWidgets);
    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('Changes'), findsWidgets);

    // Verify primary session actions
    expect(find.text('Open Coding Session'), findsOneWidget);

    // Switch to Workspace tab contextually
    await tester.tap(find.text('Workspace').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Workspace'), findsWidgets);

    // Switch to Changes tab contextually
    await tester.tap(find.text('Changes').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Changes'), findsWidgets);
  });

  testWidgets('Navigating to project overview and popping back returns cleanly to main three-tab shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MuseFlowApp());
    await tester.pumpAndSettle();

    // Verify main destinations
    expect(find.text('Dashboard'), findsWidgets);

    // Navigate to project overview
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(
      MaterialPageRoute(
        builder: (_) => const Screen6ProjectOverview(
          projectId: 'p-1',
          projectName: 'Project Alpha',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Project Alpha'), findsWidgets);
    expect(find.text('Open Coding Session'), findsOneWidget);

    // Simulate tapping back
    navigator.pop();
    await tester.pumpAndSettle();

    // Verify back on main shell
    expect(find.text('Developer Hub'), findsWidgets);
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.widgetWithText(NavigationDestination, 'Workspace'), findsNothing);
  });
}
