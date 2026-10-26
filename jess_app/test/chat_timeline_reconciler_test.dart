import 'package:flutter_test/flutter_test.dart';
import 'package:jess_app/models/agent_event.dart';
import 'package:jess_app/screens/dashboard/screen_6_project_overview.dart';

void main() {
  group('ChatTimelineReconciler Regression Tests', () {
    test('1. WebSocket -> HTTP order (canonical message_id present in WS): appears exactly once', () {
      final timeline = <ChatTimelineItem>[];
      final now = DateTime.now();

      // Step A: WebSocket message.started arrives with canonical message_id
      final active = ChatTimelineReconciler.onMessageStarted(
        timelineItems: timeline,
        eventId: 'evt_ws_101',
        messageId: 'asst_msg_001',
        createdAt: now,
      );

      expect(timeline.length, equals(1));
      expect(timeline.first, isA<ChatAssistantMessageItem>());
      final item = timeline.first as ChatAssistantMessageItem;
      expect(item.id, equals('asst_msg_001'));
      expect(item.isStreaming, isTrue);

      // Step B: WebSocket message.delta streams text
      ChatTimelineReconciler.onMessageDelta(
        timelineItems: timeline,
        activeMessage: active,
        eventId: 'evt_ws_102',
        messageId: 'asst_msg_001',
        text: 'Hey! What are we working on today?',
        createdAt: now,
      );
      expect(item.content, equals('Hey! What are we working on today?'));

      // Step C: WebSocket message.completed finalizes streaming
      ChatTimelineReconciler.onMessageCompleted(
        timelineItems: timeline,
        activeMessage: active,
        eventId: 'evt_ws_103',
        messageId: 'asst_msg_001',
        text: 'Hey! What are we working on today?',
        createdAt: now,
      );
      expect(item.isStreaming, isFalse);
      expect(timeline.length, equals(1));

      // Step D: HTTP POST response arrives carrying canonical DB message
      final httpMsg = ConversationMessageModel(
        id: 'asst_msg_001',
        conversationId: 'conv_1',
        role: 'assistant',
        content: 'Hey! What are we working on today?',
        createdAt: now,
      );

      ChatTimelineReconciler.onHttpResponse(
        timelineItems: timeline,
        activeMessage: null,
        assistantMessage: httpMsg,
      );

      // Verify no duplicate bubble was created
      expect(timeline.length, equals(1), reason: 'Duplicate bubble must not be added when HTTP arrives after WS');
      expect((timeline.first as ChatAssistantMessageItem).id, equals('asst_msg_001'));
      expect((timeline.first as ChatAssistantMessageItem).content, equals('Hey! What are we working on today?'));
    });

    test('2. WebSocket -> HTTP order (provisional eventId in WS): reconciles provisional bubble', () {
      final timeline = <ChatTimelineItem>[];
      final now = DateTime.now();

      // Step A: WebSocket message.started arrives WITHOUT message_id (falls back to eventId)
      final active = ChatTimelineReconciler.onMessageStarted(
        timelineItems: timeline,
        eventId: 'evt_provisional_999',
        messageId: null,
        createdAt: now,
      );

      expect(timeline.length, equals(1));
      final item = timeline.first as ChatAssistantMessageItem;
      expect(item.id, equals('evt_provisional_999'));
      expect(item.eventId, equals('evt_provisional_999'));
      expect(item.isStreaming, isTrue);

      // Step B: WebSocket message.completed arrives
      ChatTimelineReconciler.onMessageCompleted(
        timelineItems: timeline,
        activeMessage: active,
        eventId: 'evt_provisional_999',
        messageId: null,
        text: 'Autonomous coding plan ready.',
        createdAt: now,
      );

      // Step C: HTTP POST response arrives with canonical DB message ID
      final httpMsg = ConversationMessageModel(
        id: 'db_canonical_msg_777',
        conversationId: 'conv_1',
        role: 'assistant',
        content: 'Autonomous coding plan ready.',
        createdAt: now,
      );

      ChatTimelineReconciler.onHttpResponse(
        timelineItems: timeline,
        activeMessage: null,
        assistantMessage: httpMsg,
      );

      // Verify provisional bubble was reconciled in-place with canonical DB ID
      expect(timeline.length, equals(1), reason: 'Provisional bubble must be reconciled, not duplicated');
      final reconciled = timeline.first as ChatAssistantMessageItem;
      expect(reconciled.id, equals('db_canonical_msg_777'));
      expect(reconciled.content, equals('Autonomous coding plan ready.'));
      expect(reconciled.isStreaming, isFalse);
    });

    test('3. HTTP -> WebSocket order: later WebSocket events do not create second bubble', () {
      final timeline = <ChatTimelineItem>[];
      final now = DateTime.now();

      // Step A: HTTP response arrives first and creates the message bubble
      final httpMsg = ConversationMessageModel(
        id: 'fast_http_msg_500',
        conversationId: 'conv_1',
        role: 'assistant',
        content: 'Hey! Fast response from backend.',
        createdAt: now,
      );

      ChatTimelineReconciler.onHttpResponse(
        timelineItems: timeline,
        activeMessage: null,
        assistantMessage: httpMsg,
      );

      expect(timeline.length, equals(1));
      expect((timeline.first as ChatAssistantMessageItem).id, equals('fast_http_msg_500'));
      expect((timeline.first as ChatAssistantMessageItem).content, equals('Hey! Fast response from backend.'));

      // Step B: Later WebSocket message.started arrives with same canonical message_id
      final wsItem = ChatTimelineReconciler.onMessageStarted(
        timelineItems: timeline,
        eventId: 'evt_late_ws_1',
        messageId: 'fast_http_msg_500',
        createdAt: now,
      );

      expect(timeline.length, equals(1), reason: 'Later WS message.started must not add duplicate bubble');
      expect(identical(wsItem, timeline.first), isTrue);

      // Step C: Later WebSocket message.completed arrives
      ChatTimelineReconciler.onMessageCompleted(
        timelineItems: timeline,
        activeMessage: wsItem,
        eventId: 'evt_late_ws_2',
        messageId: 'fast_http_msg_500',
        text: 'Hey! Fast response from backend.',
        createdAt: now,
      );

      expect(timeline.length, equals(1), reason: 'Later WS message.completed must not add duplicate bubble');
      expect((timeline.first as ChatAssistantMessageItem).id, equals('fast_http_msg_500'));
    });

    test('4. Distinct messages with identical content are NOT incorrectly merged', () {
      final timeline = <ChatTimelineItem>[];
      final now = DateTime.now();

      // Turn 1: User says 'hi', Assistant replies 'Hey!'
      final turn1HttpMsg = ConversationMessageModel(
        id: 'turn_1_asst_msg',
        conversationId: 'conv_1',
        role: 'assistant',
        content: 'Hey! What are we working on today in Calculator Demo Repo?',
        createdAt: now,
      );

      ChatTimelineReconciler.onHttpResponse(
        timelineItems: timeline,
        activeMessage: null,
        assistantMessage: turn1HttpMsg,
      );

      expect(timeline.length, equals(1));
      expect((timeline.first as ChatAssistantMessageItem).id, equals('turn_1_asst_msg'));

      // Turn 2: User says 'hi' again later, Assistant replies with identical template text but distinct DB message ID
      final turn2HttpMsg = ConversationMessageModel(
        id: 'turn_2_asst_msg',
        conversationId: 'conv_1',
        role: 'assistant',
        content: 'Hey! What are we working on today in Calculator Demo Repo?',
        createdAt: now.add(const Duration(minutes: 5)),
      );

      ChatTimelineReconciler.onHttpResponse(
        timelineItems: timeline,
        activeMessage: null,
        assistantMessage: turn2HttpMsg,
      );

      // Verify both legitimate distinct turns exist in timeline
      expect(timeline.length, equals(2), reason: 'Two distinct messages with identical text must both appear');
      expect((timeline[0] as ChatAssistantMessageItem).id, equals('turn_1_asst_msg'));
      expect((timeline[1] as ChatAssistantMessageItem).id, equals('turn_2_asst_msg'));
      expect((timeline[0] as ChatAssistantMessageItem).content, equals((timeline[1] as ChatAssistantMessageItem).content));
    });

    test('5. Reconnect and repeated message.completed events are idempotent', () {
      final timeline = <ChatTimelineItem>[];
      final now = DateTime.now();

      // First delivery of completed event
      ChatTimelineReconciler.onMessageCompleted(
        timelineItems: timeline,
        activeMessage: null,
        eventId: 'evt_replayed_1',
        messageId: 'asst_replayed_msg',
        text: 'Task complete and verified.',
        createdAt: now,
      );
      expect(timeline.length, equals(1));

      // Reconnect: server replays message.completed event with same message_id
      ChatTimelineReconciler.onMessageCompleted(
        timelineItems: timeline,
        activeMessage: null,
        eventId: 'evt_replayed_1',
        messageId: 'asst_replayed_msg',
        text: 'Task complete and verified.',
        createdAt: now,
      );

      expect(timeline.length, equals(1), reason: 'Replayed completed event must be idempotent');
      expect((timeline.first as ChatAssistantMessageItem).id, equals('asst_replayed_msg'));
      expect((timeline.first as ChatAssistantMessageItem).content, equals('Task complete and verified.'));
    });
  });
}
