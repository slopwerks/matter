import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:matter/features/audio/audio_source_cache_io.dart';
import 'package:matter/features/storage/managed_media_io.dart';
import 'package:matter/features/storage/storage_attribution.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_registry.dart';
import 'package:matter/pages/chat/media_preparation.dart';
import 'package:matter/pages/chat/prepared_media_source.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/authenticated_media_cache.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_path_provider.dart';

class _HistoryApi implements RustLibApi {
  Map<String, List<rust.ChatMessage>> rooms = {};
  final users = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName ==
        const Symbol('crateApiMatrixStorageGetCachedMediaMessages')) {
      users.add(invocation.namedArguments[#expectedUserId] as String);
      return Future<Map<String, List<rust.ChatMessage>>>.value(rooms);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const user = '@alice:example.org', server = 'https://example.org';
  late Directory root;
  late _HistoryApi api;
  final account = storageAccountKey(user, server);

  rust.ChatMessage message(
    String id,
    String url, {
    String? encrypted,
    String? mime = 'audio/ogg',
  }) => chatMessageFromMap({
    'id': id,
    'msgType': 'file',
    'imageUrl': encrypted == null ? url : null,
    'mediaSourceJson': encrypted,
    'mimeType': mime,
    'filename': 'voice.ogg',
    'timestamp': '1',
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('matter-history-attribution-');
    installTempPathProvider(root);
    api = _HistoryApi();
    RustLib.initMock(api: api);
  });
  tearDown(() async {
    await resetAuthenticatedMediaCacheManagers();
    await storageRegistry.flush();
    RustLib.dispose();
    await root.delete(recursive: true);
  });

  testWidgets(
    'encrypted room production priming keeps plaintext absent but recovers local SDK media',
    (tester) async {
      const roomId = '!encrypted:example.org';
      final privateKey = base64Url
          .encode(List<int>.filled(32, 0))
          .replaceAll('=', '');
      final source = jsonEncode({
        'file': {
          'url': 'mxc://example.org/private',
          'key': {
            'kty': 'oct',
            'key_ops': ['encrypt', 'decrypt'],
            'alg': 'A256CTR',
            'k': privateKey,
            'ext': true,
          },
          'iv': base64.encode(List<int>.filled(16, 0)).replaceAll('=', ''),
          'hashes': {'sha256': privateKey},
          'v': 'v2',
        },
      });
      final media = message('encrypted', '', encrypted: source);
      api.rooms = {
        roomId: [media],
      };
      await saveCachedMessages(
        namespace: user,
        roomId: roomId,
        messages: [media],
      );
      final container = ProviderContainer(
        overrides: [
          chatRoomsProvider.overrideWith(
            (ref) async => [
              rust.ChatRoom(
                id: roomId,
                name: 'Private',
                lastMessage: '',
                lastMessageTime: '0',
                lastEventId: '',
                unreadCount: 0,
                isMarkedUnread: false,
                roomType: 'direct',
                isEncrypted: true,
                isMuted: false,
                roomState: 'joined',
              ),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value = user;
      await container.read(chatRoomsProvider.future);
      late WidgetRef ref;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, value, child) {
              ref = value;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        await primeMessageCache(ref, roomId);
        expect(
          await loadCachedMessages(namespace: user, roomId: roomId),
          isEmpty,
        );
        final file = await managedMediaFile(account, source, 'voice.ogg');
        await file.parent.create(recursive: true);
        await file.writeAsBytes([1, 2, 3]);
        final registry = StorageRegistry();
        await restoreStorageAttribution(
          userId: user,
          homeserver: server,
          registry: registry,
        );
        expect(registry.files[file.path]?.owners.keys, [
          StorageOwner(account, roomId).key,
        ]);
        expect(api.users, [user]);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('msg_cache_v2_$user::$roomId'), isNull);
        expect(
          prefs.getString('storage_file_index_v1'),
          isNot(contains(privateKey)),
        );
      });
    },
  );

  test('SDK history recovers media trimmed from the real 200-message disk snapshot', () async {
    const roomId = '!busy:example.org', url = 'mxc://example.org/old';
    final old = message('old', url);
    await saveCachedMessages(
      namespace: user,
      roomId: roomId,
      messages: [
        old,
        for (var i = 2; i < 205; i++)
          chatMessageFromMap({
            'id': '$i',
            'timestamp': '$i',
            'msgType': 'text',
            'content': 'new',
          }),
      ],
    );
    final recent = await loadCachedMessages(namespace: user, roomId: roomId);
    expect(recent.length, 200);
    expect(recent.any((m) => m.id == 'old'), isFalse);
    api.rooms = {
      roomId: [old],
    };
    final file = await managedMediaFile(account, url, 'voice.ogg');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([4, 5]);
    final orphan = await managedMediaFile(account, 'unmatched', 'orphan.ogg');
    await orphan.parent.create(recursive: true);
    await orphan.writeAsBytes([9]);
    final registry = StorageRegistry();
    await restoreStorageAttribution(
      userId: user,
      homeserver: server,
      registry: registry,
    );
    expect(registry.files[file.path]?.owners.keys, [
      StorageOwner(account, roomId).key,
    ]);
    expect(registry.files.containsKey(orphan.path), isFalse);
    expect(await orphan.readAsBytes(), [9]);
  });

  test('cached image URL identifies MXC media after saved URL mappings are gone', () async {
    const roomId = '!images:example.org';
    const mxc = 'mxc://example.org/photo';
    const url =
        '$server/_matrix/client/v1/media/thumbnail/example.org/photo?width=320&height=320';
    api.rooms = {
      roomId: [
        chatMessageFromMap({
          'id': 'photo',
          'msgType': 'image',
          'imageUrl': mxc,
          'filename': 'photo.jpg',
        }),
      ],
    };
    final manager =
        authenticatedMediaCacheManager(
              url: url,
              userId: user,
              homeserver: server,
            )!
            as CacheManager;
    final key = authenticatedMediaCacheKey(
      url: url,
      userId: user,
      homeserver: server,
    )!;
    final file = await manager.putFile(
      url,
      Uint8List.fromList([1, 2, 3]),
      key: key,
      fileExtension: 'jpg',
    );
    final modified = DateTime(2020);
    await file.setLastModified(modified);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('mxc_http_cache_v1_$user'), isNull);
    final registry = StorageRegistry();
    await restoreStorageAttribution(
      userId: user,
      homeserver: server,
      registry: registry,
    );
    expect(registry.files[file.path]?.owners.keys, [
      StorageOwner(account, roomId).key,
    ]);
    expect(await file.lastModified(), modified);
  });

  for (final mime in <String?>['audio/ogg', null]) {
    test(
      'completed audio cache source markers recover owners without replay or network ($mime)',
      () async {
        const roomId = '!audio:example.org', url = 'mxc://example.org/audio';
        final cache = AudioSourceCache()..selectAccount(user, server);
        addTearDown(cache.close);
        final incoming = File('${root.path}/incoming.ogg');
        await incoming.writeAsBytes([1, 2, 3, 4]);
        final prepared = await cache.prepare(
          key: jsonEncode(['plain', url]),
          filename: 'voice.ogg',
          preparation: MediaPreparation(),
          verifiedLoader: (_) async => PreparedMediaSource(
            media: Media(incoming.path),
            cleanup: () async {},
          ),
        );
        final file = File(Uri.parse(prepared.media.uri).toFilePath());
        await prepared.cleanup();
        await cache.close();
        final marker = File('${file.parent.path}/ready.json');
        expect(await marker.exists(), isTrue);
        final modified = DateTime(2020);
        await file.setLastModified(modified);
        final corrupt = Directory('${file.parent.parent.path}/source-corrupt');
        await corrupt.create();
        final corruptFile = File('${corrupt.path}/data.bin');
        await corruptFile.writeAsBytes([4, 3, 2, 1]);
        await File('${corrupt.path}/ready.json')
            .writeAsString(await marker.readAsString());
        final otherAccount = storageAccountKey('@other:example.org', server);
        final foreign = Directory(
          '${root.path}/matter_audio_cache/$otherAccount/source-other',
        );
        await foreign.create(recursive: true);
        final foreignFile = File('${foreign.path}/data.bin');
        await foreignFile.writeAsBytes([1, 2, 3, 4]);
        await File('${foreign.path}/ready.json')
            .writeAsString(await marker.readAsString());
        final linked = Directory('${file.parent.parent.path}/source-linked');
        await linked.create();
        await Link('${linked.path}/data.bin').create(incoming.path);
        await File('${linked.path}/ready.json')
            .writeAsString(await marker.readAsString());
        api.rooms = {
          roomId: [message('audio', url, mime: mime)],
          '!shared:example.org': [message('shared-audio', url, mime: mime)],
        };
        final registry = StorageRegistry();
        var requests = 0;
        await HttpOverrides.runZoned(
          () => restoreStorageAttribution(
            userId: user,
            homeserver: server,
            registry: registry,
          ),
          createHttpClient: (_) {
            requests++;
            throw StateError('Recovery must not use HTTP');
          },
        );
        expect(requests, 0);
        final expectedOwners = [
          StorageOwner(account, roomId).key,
          StorageOwner(account, '!shared:example.org').key,
        ];
        expect(
          registry.files[file.path]?.owners.keys,
          unorderedEquals(expectedOwners),
        );
        expect(
          registry.files[marker.path]?.owners.keys,
          unorderedEquals(expectedOwners),
        );
        expect(registry.files.containsKey(corruptFile.path), isFalse);
        expect(registry.files.containsKey(foreignFile.path), isFalse);
        expect(registry.files.containsKey('${linked.path}/data.bin'), isFalse);
        expect(registry.files.containsKey(incoming.path), isFalse);
        expect(await file.lastModified(), modified);
        expect(await file.readAsBytes(), [1, 2, 3, 4]);
        expect(registry.files[file.path]?.displayName, 'voice.ogg');
      },
    );
  }
}
