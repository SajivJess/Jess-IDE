import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:jess_app/main.dart';
import 'package:jess_app/services/auth_api_service.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('JessIdeApp launches production developer shell smoke test', (WidgetTester tester) async {
    AuthApiService.currentAccessToken = 'test-token-active';
    await tester.pumpWidget(const JessIdeApp());
    await tester.pumpAndSettle();

    // Verify that production navigation tabs are present
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('Projects'), findsWidgets);
    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);

    // Verify that demo 1/11 selector is completely removed
    expect(find.textContaining('1/11'), findsNothing);
  });
}
