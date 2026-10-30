import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jess_app/services/tasks_api_service.dart';
import 'package:jess_app/widgets/chat/contract_approval_card.dart';
import 'package:jess_app/widgets/chat/verification_evidence_card.dart';

void main() {
  group('ContractApprovalCard Widget Tests', () {
    testWidgets('renders contract details, criteria, and triggers approval callback', (tester) async {
      final contract = TaskContractModel(
        taskId: 'test_task_123',
        contractVersion: 1,
        summary: 'Implement safe calculator division with zero handling',
        criteria: [
          AcceptanceCriterionModel(id: 'crit_1', description: 'Division by zero raises ValueError'),
          AcceptanceCriterionModel(id: 'crit_2', description: 'Addition arithmetic functions normally'),
        ],
        allowedFiles: ['calculator.py', 'test_calc.py'],
        allowNewFiles: true,
        protectedFiles: ['auth.py', '.env', 'config.py'],
        testCommands: ['python -m unittest test_calc.py'],
        contractHash: 'a1b2c3d4e5f6',
      );

      bool? approvedResult;
      String? reasonResult;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContractApprovalCard(
              contract: contract,
              onDecision: (approved, {reason}) async {
                approvedResult = approved;
                reasonResult = reason;
              },
            ),
          ),
        ),
      );

      // Verify contract header & version
      expect(find.text('Gate 1: Contract Review'), findsOneWidget);
      expect(find.textContaining('v1 • #a1b2c3d4e5'), findsOneWidget);

      // Verify summary & criteria
      expect(find.text('Implement safe calculator division with zero handling'), findsOneWidget);
      expect(find.text('Division by zero raises ValueError'), findsOneWidget);
      expect(find.text('Addition arithmetic functions normally'), findsOneWidget);

      // Verify scope chips & protected files banner
      expect(find.text('calculator.py'), findsOneWidget);
      expect(find.text('+ New files permitted'), findsOneWidget);
      expect(find.text('Strict Protection Boundary'), findsOneWidget);
      expect(find.text('python -m unittest test_calc.py'), findsOneWidget);

      // Verify buttons
      expect(find.text('Approve Contract'), findsOneWidget);
      expect(find.text('Reject Contract'), findsOneWidget);

      // Tap approve
      await tester.tap(find.text('Approve Contract'));
      await tester.pumpAndSettle();

      expect(approvedResult, isTrue);
      expect(reasonResult, isNull);
    });

    testWidgets('displays approved state when isDecided is true', (tester) async {
      final contract = TaskContractModel(
        taskId: 'test_task_123',
        summary: 'Calculator task',
        criteria: [AcceptanceCriterionModel(id: 'c1', description: 'Valid criterion')],
        allowedFiles: ['calc.py'],
        contractHash: '1234567890',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContractApprovalCard(
              contract: contract,
              isDecided: true,
              wasApproved: true,
              onDecision: (_, {reason}) async {},
            ),
          ),
        ),
      );

      expect(find.textContaining('Contract Approved'), findsOneWidget);
      expect(find.text('Approve Contract'), findsNothing);
    });
  });

  group('VerificationEvidenceCard Widget Tests', () {
    testWidgets('renders PROVEN verdict, probes, and command executions', (tester) async {
      final evidence = VerificationEvidenceModel(
        taskId: 'test_task_123',
        scopeStatus: 'CLEAN',
        allCriteriaMet: true,
        overallVerdict: 'PROVEN',
        commandRuns: [
          CommandEvidenceModel(
            command: 'python -m unittest test_calc.py',
            exitCode: 0,
            durationMs: 42,
            stdoutSnippet: 'Ran 2 tests in 0.042s OK',
            status: 'PASSED',
          ),
        ],
        breakItChecks: [
          BreakItCheckModel(
            name: 'Zero Division Boundary Probe',
            inputDescription: 'divide(10, 0)',
            expectedBehavior: 'Raise ValueError with informative message',
            actualBehavior: 'Passed: Raised ValueError as expected',
            passed: true,
          ),
          BreakItCheckModel(
            name: 'Arithmetic Regression Probe',
            inputDescription: 'add(2, 3)',
            expectedBehavior: 'Return 5 without regression',
            actualBehavior: 'Passed: add(2, 3) returned 5',
            passed: true,
          ),
        ],
      );

      final criteria = [
        AcceptanceCriterionModel(
          id: 'crit_1',
          description: 'Division by zero raises ValueError',
          verified: true,
          evidenceNote: 'Break-It Probe: Passed',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: VerificationEvidenceCard(
                evidence: evidence,
                criteria: criteria,
              ),
            ),
          ),
        ),
      );

      // Verify verdict badge
      expect(find.text('PROVEN'), findsOneWidget);
      expect(find.text('Enforced Scope: Clean adherence (no protected files touched)'), findsOneWidget);

      // Verify break-it probes
      expect(find.text('Zero Division Boundary Probe'), findsOneWidget);
      expect(find.text('divide(10, 0)'), findsOneWidget);
      expect(find.text('Arithmetic Regression Probe'), findsOneWidget);
      expect(find.text('add(2, 3)'), findsOneWidget);

      // Verify command run
      expect(find.text('python -m unittest test_calc.py'), findsOneWidget);
      expect(find.text('exit 0 (42ms)'), findsOneWidget);

      // Verify criteria
      expect(find.text('Division by zero raises ValueError'), findsOneWidget);
      expect(find.text('Break-It Probe: Passed'), findsOneWidget);
    });
  });
}
