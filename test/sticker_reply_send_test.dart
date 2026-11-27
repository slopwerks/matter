import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/composer/composer_send_controller.dart';
import 'package:matter/pages/chat/sticker_catalog.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

const key = (roomId: '!room:example.org', userId: '@me:example.org');

class Api implements RustLibApi {
  Completer<void> pending = Completer<void>();
  String? reply;
  String? recipient;
  @override
  Future<void> crateApiMatrixSendSticker({
    required String accountUserId,
    required String roomId,
    required String imageUrl,
    required String body,
    String? mimeType,
    int? width,
    int? height,
    String? replyToEventId,
    String? replyToUserId,
  }) {
    reply = replyToEventId;
    recipient = replyToUserId;
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

rust.ChatMessage target(String id) => rust.ChatMessage(
  id: id,
  senderId: '@other:example.org',
  senderName: 'Other',
  content: 'hello',
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '1',
  isMe: false,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);
void main() {
  final api = Api();
  setUpAll(() => RustLib.initMock(api: api));
  for (final scenario in [(false, false), (true, false), (false, true)]) {
    final fail = scenario.$1;
    final changeReply = scenario.$2;
    testWidgets(
      'sticker reply handles failure=$fail and changeReply=$changeReply',
      (tester) async {
        api.pending = Completer<void>();
        final container = ProviderContainer();
        container.read(activeUserIdProvider.notifier).value = key.userId;
        final original = target(r'$target');
        container.read(replyingToProvider(key).notifier).value = original;
        final text = TextEditingController();
        late ComposerSendController sender;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    sender = ComposerSendController(
                      ref: ref,
                      draftKey: key,
                      context: () => context,
                      isMounted: () => context.mounted,
                      textController: text,
                      textFieldKey: GlobalKey(),
                      totalMembers: () => 2,
                      sourceLoading: () => false,
                      composerOpen: () => true,
                      shouldRestoreKeyboard: () => false,
                      showKeyboard: () {},
                      stopTyping: () {},
                      onChanged: () {},
                      resolveSendPresentation: () =>
                          MessageSendPresentation.quiet,
                      onMessageQueued: (_, _) {},
                      onMessageSent: (_, _) {},
                    );
                    return const SizedBox();
                  },
                ),
              ),
            ),
          ),
        );
        final sent = sender.sendSticker(
          const StickerItem(
            id: 's',
            label: 's',
            body: 'sticker',
            imageUrl: 'mxc://example.org/sticker',
          ),
          null,
        );
        expect(api.reply, original.id);
        expect(api.recipient, original.senderId);
        expect(
          container
              .read(localOutgoingMessagesProvider(key))
              .single
              .message
              .inReplyTo,
          original.id,
        );
        if (changeReply) {
          container.read(replyingToProvider(key).notifier).value = target(
            r'$new-target',
          );
        }
        if (fail) {
          api.pending.completeError(StateError('offline'));
        } else {
          container.read(localOutgoingMessagesProvider(key).notifier).value =
              [];
          api.pending.complete();
        }
        await sent;
        expect(
          container.read(replyingToProvider(key))?.id,
          changeReply
              ? r'$new-target'
              : fail
              ? original.id
              : null,
        );
        await tester.pumpWidget(const SizedBox());
        text.dispose();
        container.dispose();
      },
    );
  }
}
