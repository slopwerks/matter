import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/connection_provider.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

Future<WidgetRef> _captureRef(WidgetTester tester) async {
  WidgetRef? ref;
  await tester.pumpWidget(
    ProviderScope(
      child: Consumer(
        builder: (context, r, _) {
          ref = r;
          return Container();
        },
      ),
    ),
  );
  return ref!;
}

rust.ChatMessage _message(String id, String timestamp) => rust.ChatMessage(
  id: id,
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: id,
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: timestamp,
  isMe: false,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

rust.ChatRoom _room(String id, {bool isEncrypted = false}) => rust.ChatRoom(
  id: id,
  name: 'Room',
  lastMessage: '',
  lastMessageTime: '0',
  unreadCount: 0,
  roomType: 'group',
  isEncrypted: isEncrypted,
  roomState: 'joined',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('clearActiveSessionState', () {
    testWidgets('resets session-related providers', (tester) async {
      final ref = await _captureRef(tester);

      ref.read(isLoggedInProvider.notifier).value = true;
      ref.read(currentUserProvider.notifier).value = const CurrentUser(
        id: '@alice:example.org',
        displayName: 'Alice',
        homeserver: 'https://example.org',
      );
      ref.read(currentAccessTokenProvider.notifier).value = 'token';
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(connectionProvider.notifier).value =
          AppConnectionState.connected;

      clearActiveSessionState(ref);

      expect(ref.read(isLoggedInProvider), isFalse);
      expect(ref.read(currentUserProvider), isNull);
      expect(ref.read(currentAccessTokenProvider), isNull);
      expect(ref.read(activeUserIdProvider), isNull);
      expect(ref.read(connectionProvider), AppConnectionState.disconnected);
    });

    testWidgets('can mark session ready when requested', (tester) async {
      final ref = await _captureRef(tester);

      clearActiveSessionState(ref, markSessionReady: true);

      expect(ref.read(sessionReadyProvider), isTrue);
    });
  });

  group('invalidateSessionCollections', () {
    testWidgets('invalidates collection providers without throwing', (
      tester,
    ) async {
      final ref = await _captureRef(tester);
      expect(() => invalidateSessionCollections(ref), returnsNormally);
    });
  });

  group('primeMessageCache', () {
    testWidgets('loads the persisted snapshot into the cache', (tester) async {
      const roomId = '!room:example.org';
      const namespace = '@alice:example.org';
      final message = _message(r'$cached', '100');
      final encoded = jsonEncode([chatMessageToMap(message)]);

      SharedPreferences.setMockInitialValues({
        'msg_cache_v2_$namespace::$roomId': encoded,
      });

      WidgetRef? ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRoomsProvider.overrideWith((ref) async => [_room(roomId)]),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return Container();
            },
          ),
        ),
      );
      final widgetRef = ref!;
      await widgetRef.read(chatRoomsProvider.future);
      widgetRef.read(activeUserIdProvider.notifier).value = namespace;

      await primeMessageCache(widgetRef, roomId);

      expect(widgetRef.read(messageCacheProvider(roomId)).length, 1);
      expect(
        widgetRef.read(messageCacheProvider(roomId)).single.id,
        r'$cached',
      );
      expect(widgetRef.read(messageCachePrimedProvider(roomId)), isTrue);
    });

    testWidgets('clears stale cache when the namespace changes', (
      tester,
    ) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(messageCacheProvider(roomId).notifier).value = [
        _message(r'$stale', '100'),
      ];
      ref.read(messageCacheOwnerProvider(roomId).notifier).value =
          '@bob:example.org';

      await primeMessageCache(ref, roomId);

      expect(ref.read(messageCacheProvider(roomId)), isEmpty);
      expect(ref.read(messageCacheOwnerProvider(roomId)), '@alice:example.org');
    });

    testWidgets('only primes once per room', (tester) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(messageCachePrimedProvider(roomId).notifier).value = true;

      await primeMessageCache(ref, roomId);

      // No persisted cache exists, but priming was skipped so the provider stays empty.
      expect(ref.read(messageCacheProvider(roomId)), isEmpty);
    });
  });

  group('MXC URL cache', () {
    testWidgets('cachedResolvedMxcUrl reads from the in-memory cache', (
      tester,
    ) async {
      const mxc = 'mxc://example.org/image';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(mxcUrlCacheProvider.notifier).value = {
        '@alice:example.org::mxc://example.org/image|96x96':
            'https://example.org/image.png',
      };

      final url = cachedResolvedMxcUrl(ref, mxc, width: 96, height: 96);
      expect(url, 'https://example.org/image.png');
    });

    testWidgets('cachedResolvedMxcUrl returns null for non-mxc URLs', (
      tester,
    ) async {
      final ref = await _captureRef(tester);
      expect(
        cachedResolvedMxcUrl(ref, 'https://example.org/image.png'),
        isNull,
      );
      expect(cachedResolvedMxcUrl(ref, null), isNull);
    });

    testWidgets('rememberResolvedMxcUrl updates the in-memory cache', (
      tester,
    ) async {
      const mxc = 'mxc://example.org/new';
      const httpUrl = 'https://example.org/new.png';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';

      rememberResolvedMxcUrl(ref, mxc, httpUrl);

      expect(ref.read(mxcUrlCacheProvider).values, contains(httpUrl));
    });
  });
}
