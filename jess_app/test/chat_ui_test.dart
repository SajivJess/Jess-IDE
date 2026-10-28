import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:jess_app/widgets/chat/chat_message_bubble.dart';
import 'package:jess_app/widgets/chat/tool_activity_card.dart';
import 'package:jess_app/widgets/chat/approval_request_card.dart';
import 'package:jess_app/widgets/chat/file_changed_card.dart';
import 'package:jess_app/widgets/chat/chat_composer.dart';
import 'package:jess_app/models/agent_event.dart';
import 'package:jess_app/services/chat_stream_service.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('Conversational Chat UI Components', () {
    testWidgets('ChatMessageBubble renders user vs assistant correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ChatMessageBubble(
                  role: 'user',
                  content: 'Investigate auth flow and fix tests',
                ),
                ChatMessageBubble(
                  role: 'assistant',
                  content: 'I will inspect the workspace files.',
                  isStreaming: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Investigate auth flow and fix tests'), findsOneWidget);
      expect(find.textContaining('I will inspect the workspace files.'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
    });

    testWidgets('ToolActivityCard expands to show output details on tap', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ToolActivityCard(
              tool: 'terminal',
              label: 'Running unit tests',
              status: 'completed',
              command: 'pytest -q',
              output: '46 passed in 12.4s',
              exitCode: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Running unit tests'), findsOneWidget);
      expect(find.text('EXIT 0'), findsOneWidget);

      // Tap card header to toggle expansion
      await tester.tap(find.text('Running unit tests'));
      await tester.pumpAndSettle();

      expect(find.text('pytest -q'), findsOneWidget);
      expect(find.text('46 passed in 12.4s'), findsOneWidget);
    });

    testWidgets('ApprovalRequestCard renders action buttons and triggers decision', (tester) async {
      bool? decision;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ApprovalRequestCard(
              prompt: 'Approve modifying auth_service.py?',
              target: 'auth_service.py',
              diff: '--- a/auth_service.py\n+++ b/auth_service.py\n+ # retry logic',
              onDecision: (approved, {reason}) async {
                decision = approved;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('APPROVAL REQUIRED'), findsOneWidget);
      expect(find.text('Approve modifying auth_service.py?'), findsOneWidget);
      expect(find.text('Approve Action'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);

      // Tap Approve
      await tester.tap(find.text('Approve Action'));
      await tester.pumpAndSettle();

      expect(decision, isTrue);
    });

    testWidgets('ApprovalRequestCard renders Git branch, baseCommit and handles stale reviews', (tester) async {
      bool decisionTriggered = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ApprovalRequestCard(
              prompt: 'Approve modifying math_service.py?',
              target: 'math_service.py',
              diff: '--- a/math_service.py\n+++ b/math_service.py\n+ return a / b',
              branch: 'feature/safe-div',
              baseCommit: 'a1b2c3d4e5f6',
              checkCommand: 'pytest tests/test_div.py',
              checkExitCode: 0,
              checkPassed: true,
              isStale: true,
              onDecision: (approved, {reason}) async {
                decisionTriggered = true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('feature/safe-div'), findsOneWidget);
      expect(find.text('a1b2c3d'), findsOneWidget);
      expect(find.textContaining('Check: pytest tests/test_div.py (passed)'), findsOneWidget);
      expect(find.textContaining('Review is stale'), findsOneWidget);

      // Tapping Approve on stale review should be disabled (not trigger decision)
      await tester.tap(find.text('Approve Action'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(decisionTriggered, isFalse);
    });

    testWidgets('FileChangedCard shows additions, deletions and diff lines', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FileChangedCard(
              file: 'lib/services/api_client.dart',
              action: 'modified',
              diff: '--- a/api_client.dart\n+++ b/api_client.dart\n+ final int retries = 3;',
              additions: 3,
              deletions: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('lib/services/api_client.dart'), findsOneWidget);
      expect(find.text('+3'), findsOneWidget);
      expect(find.textContaining('final int retries = 3;'), findsOneWidget);
    });

    testWidgets('ChatComposer handles input, typing, send, and stop', (tester) async {
      String? sentText;
      bool stopped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatComposer(
              isRunning: false,
              statusText: 'Ready',
              onSend: (text) => sentText = text,
              onStop: () => stopped = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ready'), findsOneWidget);

      // Enter prompt text
      await tester.enterText(find.byType(TextField), 'Add unit tests for jwt validation');
      await tester.pumpAndSettle();

      // Tap send button
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(sentText, equals('Add unit tests for jwt validation'));

      // Re-pump with isRunning = true
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatComposer(
              isRunning: true,
              statusText: 'Working...',
              onSend: (text) => sentText = text,
              onStop: () => stopped = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Working...'), findsOneWidget);
      await tester.tap(find.text('Stop Agent'));
      await tester.pumpAndSettle();

      expect(stopped, isTrue);
    });

    test('ChatMessageResponseModel parses conversational greeting without run', () {
      final json = {
        'user_message': {
          'id': 'msg_1',
          'conversation_id': 'conv_1',
          'run_id': null,
          'role': 'user',
          'content': 'hey',
          'created_at': '2026-10-25T10:00:00Z',
        },
        'intent': 'CONVERSATION',
        'assistant_message': {
          'id': 'msg_2',
          'conversation_id': 'conv_1',
          'run_id': null,
          'role': 'assistant',
          'content': 'Hey! 👋 What are we working on today?',
          'created_at': '2026-10-25T10:00:01Z',
        },
        'run': null,
      };

      final parsed = ChatMessageResponseModel.fromJson(json);
      expect(parsed.intent, equals('CONVERSATION'));
      expect(parsed.userMessage.content, equals('hey'));
      expect(parsed.assistantMessage, isNotNull);
      expect(parsed.assistantMessage!.content, contains('Hey!'));
      expect(parsed.run, isNull);
    });

    test('ChatMessageResponseModel parses coding instruction with active run', () {
      final json = {
        'user_message': {
          'id': 'msg_3',
          'conversation_id': 'conv_1',
          'run_id': 'run_10',
          'role': 'user',
          'content': 'Add retry policy with exponential backoff',
          'created_at': '2026-10-25T10:05:00Z',
        },
        'intent': 'CODING_INSTRUCTION',
        'assistant_message': null,
        'run': {
          'id': 'run_10',
          'project_id': 'proj_1',
          'conversation_id': 'conv_1',
          'status': 'QUEUED',
          'prompt': 'Add retry policy with exponential backoff',
          'title': 'Add retry policy',
          'created_at': '2026-10-25T10:05:00Z',
          'updated_at': '2026-10-25T10:05:00Z',
        },
      };

      final parsed = ChatMessageResponseModel.fromJson(json);
      expect(parsed.intent, equals('CODING_INSTRUCTION'));
      expect(parsed.assistantMessage, isNull);
      expect(parsed.run, isNotNull);
      expect(parsed.run!.status, equals('QUEUED'));
    });

    test('AgentRunModel parses executionLog, activeBranch, commitSha', () {
      final json = {
        'id': 'run_20',
        'project_id': 'proj_1',
        'conversation_id': 'conv_1',
        'status': 'APPROVAL_REQUIRED',
        'prompt': 'Refactor user session',
        'title': 'Refactor session',
        'active_branch': 'feature/session-recovery',
        'commit_sha': 'a1b2c3d4',
        'execution_log': '{"diff": "+ session_cache.clear()", "prompt": "Approve refactor?"}',
        'created_at': '2026-10-25T11:00:00Z',
        'updated_at': '2026-10-25T11:05:00Z',
      };

      final parsed = AgentRunModel.fromJson(json);
      expect(parsed.activeBranch, equals('feature/session-recovery'));
      expect(parsed.commitSha, equals('a1b2c3d4'));
      expect(parsed.executionLog, contains('session_cache.clear()'));
      expect(parsed.status, equals('APPROVAL_REQUIRED'));
    });

    test('ChatStreamService initial state is disconnected and retryNow is callable', () {
      final service = ChatStreamService(conversationId: 'test_conv');
      expect(service.isClosed, isFalse);
      service.retryNow();
      service.dispose();
      expect(service.isClosed, isTrue);
    });
  });
}

