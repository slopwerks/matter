import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';

const room = '!shared:example.org';
const alice = '@alice:example.org';
const bob = '@bob:example.org';

rust.ChatMessage msg(String id, int timestamp) => rust.ChatMessage(
  id: id,
  senderId: alice,
  senderName: 'Alice',
  content: id,
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '$timestamp',
  isMe: true,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

class Api implements RustLibApi {
  final syncEvents = StreamController<rust.SyncEvent>.broadcast();
  Object? redactError;
  Completer<bool>? encryption;
  String active = alice;
  final sentAs = <String>[];
  final attemptedAs = <String>[];
  @override
  Stream<rust.SyncEvent> crateApiMatrixWatchSyncEvents() => syncEvents.stream;
  @override
  rust.ConnectionStatus crateApiMatrixGetConnectionStatus() =>
      rust.ConnectionStatus.connected;
  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) =>
      encryption?.future ?? Future.value(false);
  @override
  Future<void> crateApiMatrixSendFileMessage({
    required String accountUserId,
    required String roomId,
    required List<int> fileData,
    required String filename,
    String? mimeType,
    int? size,
  }) async {
    attemptedAs.add(accountUserId);
    if (accountUserId != active) throw StateError('account switched');
    sentAs.add(active);
  }

  @override
  Future<void> crateApiMatrixRedactMessage({
    required String accountUserId,
    required String roomId,
    required String eventId,
    String? reason,
  }) async {
    if (redactError != null) throw redactError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SlowFile extends XFile {
  SlowFile() : super('/tmp/example.txt', name: 'example.txt');
  final bytes = Completer<Uint8List>();
  bool reading = false;
  @override
  Future<int> length() async => 3;
  @override
  Future<Uint8List> readAsBytes() {
    reading = true;
    return bytes.future;
  }
}

class Selector extends FileSelectorPlatform {
  Selector(this.file);
  final SlowFile file;
  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => [file];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Api api;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = Api();
    RustLib.initMock(api: api);
  });
  tearDown(() async {
    await api.syncEvents.close();
    RustLib.dispose();
  });

  test('a stale snapshot cannot restore a recalled message on disk', () async {
    final snapshot = [msg(r'$old', 100), msg(r'$keep', 200)];
    await saveCachedMessages(
      namespace: alice,
      roomId: room,
      messages: snapshot,
    );
    await redactCachedMessage(namespace: alice, roomId: room, eventId: r'$old');
    await saveCachedMessages(
      namespace: alice,
      roomId: room,
      messages: snapshot,
    );
    expect(
      (await loadCachedMessages(
        namespace: alice,
        roomId: room,
      )).map((m) => m.id),
      [r'$keep'],
    );
    expect((await loadCachedMessages(namespace: bob, roomId: room)), isEmpty);
    await clearCachedMessagesForNamespace(alice);
    expect(
      await loadCachedMessageRedactions(namespace: alice, roomId: room),
      isEmpty,
    );
  });

  testWidgets(
    'remote recalls clear caches without requiring a live-window fetch',
    (tester) async {
      final container = ProviderContainer();
      container.read(activeUserIdProvider.notifier).value = alice;
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(messageCacheOwnerProvider(room).notifier).value = alice;
      container.read(messageCacheProvider(room).notifier).value = [
        msg(r'$old', 100),
      ];
      final subscription = container.listen(
        syncStreamProvider,
        (_, _) {},
        fireImmediately: true,
      );
      api.syncEvents.add(
        const rust.SyncEvent.messageRedacted(roomId: room, eventId: r'$old'),
      );
      await tester.pump();
      expect(container.read(messageCacheProvider(room)), isEmpty);
      expect(
        container.read(
          redactedMessageIdsProvider((roomId: room, userId: alice)),
        ),
        {r'$old'},
      );
      subscription.close();
      container.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'persisted recalls filter a stale snapshot after reopening a room',
    (tester) async {
      await redactCachedMessage(
        namespace: alice,
        roomId: room,
        eventId: r'$old',
      );
      WidgetRef? ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRoomsProvider.overrideWith((_) async => const [])],
          child: Consumer(
            builder: (_, r, _) {
              ref = r;
              return const SizedBox();
            },
          ),
        ),
      );
      ref!.read(activeUserIdProvider.notifier).value = alice;
      await tester.runAsync(() => primeMessageCache(ref!, room));
      updateMessageCache(ref!, room, [msg(r'$old', 100), msg(r'$keep', 200)]);
      expect(ref!.read(messageCacheProvider(room)).map((m) => m.id), [
        r'$keep',
      ]);
    },
  );

  testWidgets('failed recalls keep the original message', (tester) async {
    WidgetRef? ref;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (_, r, _) {
            ref = r;
            return const SizedBox();
          },
        ),
      ),
    );
    ref!.read(activeUserIdProvider.notifier).value = alice;
    ref!.read(messageCacheProvider(room).notifier).value = [msg(r'$old', 100)];
    api.redactError = StateError('offline');
    await expectLater(redactMessage(ref!, room, r'$old'), throwsStateError);
    expect(ref!.read(messageCacheProvider(room)).single.id, r'$old');
    expect(
      ref!.read(redactedMessageIdsProvider((roomId: room, userId: alice))),
      isEmpty,
    );
  });

  testWidgets('account B cache survives late priming from account A', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'msg_cache_v2_$alice::$room': jsonEncode([
        chatMessageToMap(msg(r'$alice', 100)),
      ]),
    });
    WidgetRef? ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRoomsProvider.overrideWith((_) async => const [])],
        child: Consumer(
          builder: (_, r, _) {
            ref = r;
            return const SizedBox();
          },
        ),
      ),
    );
    ref!.read(activeUserIdProvider.notifier).value = alice;
    api.encryption = Completer<bool>();
    final oldPrime = primeMessageCache(ref!, room);
    ref!.read(activeUserIdProvider.notifier).value = bob;
    ref!.read(messageCacheOwnerProvider(room).notifier).value = bob;
    ref!.read(messageCacheProvider(room).notifier).value = [msg(r'$bob', 200)];
    ref!.read(messageCachePrimedProvider(room).notifier).value = true;
    api.encryption!.complete(false);
    await tester.runAsync(() => oldPrime);
    expect(ref!.read(messageCacheOwnerProvider(room)), bob);
    expect(ref!.read(messageCacheProvider(room)).single.id, r'$bob');
  });

  testWidgets(
    'an accepted recall removes an old cached event outside live window',
    (tester) async {
      final latest = List.generate(100, (i) => msg('\$new-$i', 200 + i));
      WidgetRef? ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messagesProvider(room).overrideWith((_) async => latest),
            chatRoomsProvider.overrideWith((_) async => const []),
          ],
          child: Consumer(
            builder: (_, r, _) {
              ref = r;
              return const SizedBox();
            },
          ),
        ),
      );
      ref!.read(activeUserIdProvider.notifier).value = alice;
      ref!.read(messageCacheProvider(room).notifier).value = [
        msg(r'$old', 100),
        ...latest,
      ];
      await tester.runAsync(() => redactMessage(ref!, room, r'$old'));
      expect(
        ref!.read(messageCacheProvider(room)).any((m) => m.id == r'$old'),
        isFalse,
      );
    },
  );

  testWidgets('recalling the last message clears its visible snapshot', (
    tester,
  ) async {
    WidgetRef? ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messagesProvider(room).overrideWith((_) async => const []),
          chatRoomsProvider.overrideWith((_) async => const []),
        ],
        child: Consumer(
          builder: (_, r, _) {
            ref = r;
            return const SizedBox();
          },
        ),
      ),
    );
    ref!.read(activeUserIdProvider.notifier).value = alice;
    ref!.read(messageCacheProvider(room).notifier).value = [msg(r'$last', 100)];
    await tester.runAsync(() => redactMessage(ref!, room, r'$last'));
    expect(ref!.read(messageCacheProvider(room)), isEmpty);
  });

  for (final disposePicker in [true, false]) {
    testWidgets(
      'pending file preparation keeps its account when dispose=$disposePicker',
      (tester) async {
        final previous = FileSelectorPlatform.instance;
        final file = SlowFile();
        FileSelectorPlatform.instance = Selector(file);
        addTearDown(() => FileSelectorPlatform.instance = previous);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.fluttercandies/photo_manager'),
              (call) async => switch (call.method) {
                'requestPermissionExtend' => 3,
                'getAssetPathList' => <String, dynamic>{
                  'data': <Map<String, dynamic>>[],
                },
                'getAssetCountFromPath' => 0,
                _ => null,
              },
            );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNeuTheme(NeuColors.dark, Brightness.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: AttachmentPicker(
                  height: 300,
                  maxHeight: 500,
                  roomId: room,
                  accountUserId: alice,
                  onRefresh: (_) async {},
                  resolveSendPresentation: () => MessageSendPresentation.quiet,
                  onMessageSent: (_, _) {},
                  onHeightChanged: (_) {},
                  onClose: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('文件'));
        await tester.pump();
        expect(file.reading, isTrue);
        // Navigation disposes the old account's picker, then Rust's active client switches.
        if (disposePicker) await tester.pumpWidget(const SizedBox());
        api.active = bob;
        file.bytes.complete(Uint8List.fromList([1, 2, 3]));
        await tester.pump();
        await tester.pump();
        expect(api.sentAs, isNot(contains(bob)));
        expect(api.attemptedAs, disposePicker ? isEmpty : [alice]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
