import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_media_source.dart';
import 'package:matter/pages/chat/media_preparation.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/media_transfer_api.dart';
import 'support/temp_path_provider.dart';

class _RealHttp extends HttpOverrides {}

class _PlainMediaApi extends MediaTransferApi {
  final String resolvedUrl;
  final resolved = <String>[];
  _PlainMediaApi(this.resolvedUrl);

  @override
  Future<String?> crateApiMatrixMxcToHttpFull({required String mxcUrl}) async {
    resolved.add(mxcUrl);
    return resolvedUrl;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer server;
  late String homeserver;
  late _PlainMediaApi api;
  String? authorization;
  String? range;

  // Resource initialization runs outside the widget test's fake clock.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('matter-plain-source-');
    installTempPathProvider(root);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    homeserver = 'http://127.0.0.1:${server.port}';
    api = _PlainMediaApi(
      '$homeserver/_matrix/client/v1/media/download/example.org/clip',
    );
    RustLib.initMock(api: api);
    server.listen((request) async {
      authorization = request.headers.value('authorization');
      range = request.headers.value('range');
      final chunk = Uint8List(64 * 1024);
      for (var i = 0; i < 17 * 16; i++) {
        request.response.add(chunk);
        await request.response.flush();
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    RustLib.dispose();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  testWidgets(
    'plain Matrix source objects download large files with authentication',
    (tester) async {
      late WidgetRef owner;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserProvider.overrideWith(
              () => MutableState(
                CurrentUser(
                  id: '@alice:example.org',
                  displayName: 'Alice',
                  homeserver: homeserver,
                ),
              ),
            ),
            currentAccessTokenProvider.overrideWith(
              () => MutableState('test-token'),
            ),
          ],
          child: Consumer(
            builder: (context, ref, child) {
              owner = ref;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final preparation = MediaPreparation();
      final source = await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => prepareChatMediaSource(
            ref: owner,
            url: null,
            mediaSourceJson: jsonEncode({'url': 'mxc://example.org/clip'}),
            filename: 'clip.mp4',
            preparation: preparation,
          ).timeout(const Duration(seconds: 5)),
          _RealHttp(),
        ),
      );
      expect(api.resolved, ['mxc://example.org/clip']);
      expect(api.requests, isEmpty);
      expect(authorization, 'Bearer test-token');
      expect(range, isNull);
      await tester.runAsync(() async {
        expect(await File(source!.media.uri).length(), 17 * 1024 * 1024);
        await source.cleanup();
        expect(await File(source.media.uri).exists(), isFalse);
      });
      preparation.cancel();
    },
  );
}
