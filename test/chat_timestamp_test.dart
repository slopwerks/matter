import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_timestamp.dart';
import 'package:matter/pages/chat/floating_date_header.dart';

void main() {
  String timestamp(DateTime value) => value.millisecondsSinceEpoch.toString();

  test('formats message time in the device local timezone', () {
    final localTime = DateTime(2026, 6, 13, 21, 7);

    expect(formatMessageTime(timestamp(localTime)), '21:07');
  });

  test('uses calendar-day labels for date separators', () {
    final now = DateTime(2026, 6, 13, 12);

    expect(formatChatDate(timestamp(DateTime(2026, 6, 13)), now: now), '今天');
    expect(formatChatDate(timestamp(DateTime(2026, 6, 12)), now: now), '昨天');
    expect(formatChatDate(timestamp(DateTime(2026, 6, 10)), now: now), '6月10日');
    expect(
      formatChatDate(timestamp(DateTime(2025, 12, 31)), now: now),
      '2025年12月31日',
    );
  });

  test('creates a stable key for each local calendar day', () {
    expect(
      chatDateKey(timestamp(DateTime(2026, 6, 13, 0, 1))),
      chatDateKey(timestamp(DateTime(2026, 6, 13, 23, 59))),
    );
    expect(
      chatDateKey(timestamp(DateTime(2026, 6, 12, 23, 59))),
      isNot(chatDateKey(timestamp(DateTime(2026, 6, 13, 0, 1)))),
    );
  });

  test('floating date selects the older side when scrolling into history', () {
    expect(
      resolveFloatingDateBoundaryIndex(
        separatorIndex: 2,
        boundaryCount: 3,
        scrollingTowardOlder: true,
      ),
      1,
    );
  });

  test('floating date keeps the newer side when scrolling toward present', () {
    expect(
      resolveFloatingDateBoundaryIndex(
        separatorIndex: 1,
        boundaryCount: 3,
        scrollingTowardOlder: false,
      ),
      1,
    );
  });
}
