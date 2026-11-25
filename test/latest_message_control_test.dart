import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/latest_message_control.dart';

void main() {
  group('latest-message thresholds', () {
    test('selects flight, insertion, and quiet presentations', () {
      expect(
        resolveMessageSendPresentation(
          distanceFromLatest: 100,
          viewportDimension: 1000,
        ),
        MessageSendPresentation.flight,
      );
      expect(
        resolveMessageSendPresentation(
          distanceFromLatest: 101,
          viewportDimension: 1000,
        ),
        MessageSendPresentation.insert,
      );
      expect(
        resolveMessageSendPresentation(
          distanceFromLatest: 801,
          viewportDimension: 1000,
        ),
        MessageSendPresentation.quiet,
      );
    });

    test('auto-scrolls within 80 percent of the viewport', () {
      expect(
        shouldAutoScrollToLatest(
          distanceFromLatest: 799,
          viewportDimension: 1000,
        ),
        isTrue,
      );
      expect(
        shouldAutoScrollToLatest(
          distanceFromLatest: 801,
          viewportDimension: 1000,
        ),
        isFalse,
      );
    });

    test('uses hysteresis to keep the latest button stable', () {
      expect(
        shouldShowLatestMessageControl(
          distanceFromLatest: 501,
          viewportDimension: 1000,
          currentlyVisible: false,
        ),
        isTrue,
      );
      expect(
        shouldShowLatestMessageControl(
          distanceFromLatest: 300,
          viewportDimension: 1000,
          currentlyVisible: true,
        ),
        isTrue,
      );
      expect(
        shouldShowLatestMessageControl(
          distanceFromLatest: 149,
          viewportDimension: 1000,
          currentlyVisible: true,
        ),
        isFalse,
      );
    });
  });
}
