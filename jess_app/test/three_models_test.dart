import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jess_app/services/ui_suggestions_api_service.dart';
import 'package:jess_app/widgets/chat/ui_suggestion_card.dart';
import 'package:jess_app/widgets/chat/chat_composer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Three Model Strategy Tests (Muse Spark 1.3, Muse Voice, Muse Image)', () {
    test('UiSuggestionModel parses from JSON correctly with muse-image-1.0 defaults', () {
      final json = {
        'id': 'sug_123',
        'prompt': 'Modern dark dashboard with analytics charts',
        'model': 'muse-image-1.0',
        'preview_url': 'http://localhost:8000/api/v1/projects/proj_1/ui-suggestions/preview/sug_123',
        'image_data_uri': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      };

      final model = UiSuggestionModel.fromJson(json);
      expect(model.id, 'sug_123');
      expect(model.prompt, 'Modern dark dashboard with analytics charts');
      expect(model.model, 'muse-image-1.0');
      expect(model.previewUrl, isNotNull);
      expect(model.imageDataUri, isNotNull);
    });

    testWidgets('UiSuggestionCard displays proposal and triggers Code This Design callback',
        (tester) async {
      final model = UiSuggestionModel(
        id: 'mock_1',
        prompt: 'Minimalist login screen with frosted glass cards',
        model: 'muse-image-1.0',
        imageDataUri:
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      );

      String? codedInstruction;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UiSuggestionCard(
              suggestion: model,
              onCodeDesign: (instruction) {
                codedInstruction = instruction;
              },
            ),
          ),
        ),
      );

      // Verify UI proposal badge
      expect(find.text('MUSE IMAGE 1.0 • UI PROPOSAL'), findsOneWidget);
      expect(find.text('Minimalist login screen with frosted glass cards'), findsOneWidget);
      expect(find.text('Code This Design'), findsOneWidget);

      // Tap "Code This Design"
      await tester.tap(find.text('Code This Design'));
      await tester.pump();

      expect(codedInstruction, contains('Implement the following UI design with code'));
      expect(codedInstruction, contains('Minimalist login screen with frosted glass cards'));
    });

    testWidgets('ChatComposer renders mic button and populates transcribed voice for review before sending',
        (tester) async {
      final controller = TextEditingController();
      String? sentText;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatComposer(
              controller: controller,
              onSend: (text) => sentText = text,
              onStop: () {},
              onVoiceTranscribeOverride: () async {
                return 'Add a responsive navigation bar';
              },
            ),
          ),
        ),
      );

      // Verify mic button is rendered
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(controller.text, isEmpty);

      // Tap mic button to trigger transcription
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pumpAndSettle();

      // Transcribed text should populate the input field for user review/edit
      expect(controller.text, 'Add a responsive navigation bar');

      // Verify user can review and edit before sending
      controller.text = '${controller.text} and dark theme toggle';
      await tester.pump();

      // Tap send button
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();

      expect(sentText, 'Add a responsive navigation bar and dark theme toggle');
      expect(controller.text, isEmpty);
    });
  });
}
