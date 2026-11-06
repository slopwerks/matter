import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/markdown/markdown_source_store.dart';
import '../../../providers/chat_provider.dart';
import '../../../providers/mutable_state.dart';
import '../../../src/rust/api/matrix.dart' as rust;

/// In-memory draft text, isolated by both account and room.
final messageDraftProvider =
    NotifierProvider.family<MutableState<String>, String, RoomAccountKey>(
      (key) => AccountScopedMutableState('', key.userId),
    );

/// In-progress edit text, matched by event id so an older edit never becomes
/// a different message's prefill. Survives inline input disposal.
final editingDraftProvider =
    NotifierProvider.family<
      MutableState<({String editingId, String text})?>,
      ({String editingId, String text})?,
      RoomAccountKey
    >((key) => AccountScopedMutableState(null, key.userId));

/// The edit being sent, shared across responsive input remounts.
final editingSendInFlightProvider =
    NotifierProvider.family<MutableState<String?>, String?, RoomAccountKey>(
      (key) => AccountScopedMutableState(null, key.userId),
    );

/// Synchronizes an inline editor with the account/room draft providers.
/// Does not own the text controller or sending; dispose with the inline host.
class ComposerDraftController {
  ComposerDraftController({
    required this.ref,
    required this.draftKey,
    required this.textController,
    required this.onTextRestored,
    required this.onEditingCancelled,
    required this.onTextChanged,
  });

  final WidgetRef ref;
  final RoomAccountKey draftKey;
  final TextEditingController textController;
  final VoidCallback onTextRestored;
  final VoidCallback onEditingCancelled;
  final VoidCallback onTextChanged;

  static const _sourceStore = MarkdownSourceStore();
  String? _lastEditingId;
  String? _sourceLoadingId;
  bool _disposed = false;

  bool get isSourceLoading => _sourceLoadingId != null;

  void restoreInitialText() {
    _replaceText(ref.read(messageDraftProvider(draftKey)));
  }

  void saveText() {
    final editing = ref.read(editingMessageProvider(draftKey));
    if (editing == null) {
      ref.read(messageDraftProvider(draftKey).notifier).value =
          textController.text;
    } else {
      ref.read(editingDraftProvider(draftKey).notifier).value = (
        editingId: editing.id,
        text: textController.text,
      );
    }
  }

  /// Call during the host's build: WidgetRef owns these subscriptions.
  void synchronize(rust.ChatMessage? editing) {
    if (editing != null && editing.id != _lastEditingId) {
      _lastEditingId = editing.id;
      _sourceLoadingId = editing.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || _lastEditingId != editing.id) return;
        _prefillEditingSource(editing);
      });
    } else if (editing == null) {
      _lastEditingId = null;
      _sourceLoadingId = null;
    }

    ref.listen(editingMessageProvider(draftKey), (previous, next) {
      if (previous != null && next == null) _restoreDraft();
    });
    ref.listen(messageDraftProvider(draftKey), (_, next) {
      if (ref.read(editingMessageProvider(draftKey)) != null) return;
      if (textController.text != next) _replaceText(next);
    });
    ref.listen(editingDraftProvider(draftKey), (_, next) {
      final editing = ref.read(editingMessageProvider(draftKey));
      if (editing == null || next == null || next.editingId != editing.id) {
        return;
      }
      if (textController.text != next.text) _replaceText(next.text);
    });
  }

  void _replaceText(String text) {
    textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _prefillEditingSource(rust.ChatMessage editing) async {
    // Capture the surviving notifier before awaits: the WidgetRef may be
    // disposed while a full-screen composer keeps updating the edit draft.
    final editDraftState = ref.read(editingDraftProvider(draftKey).notifier);
    var pending = editDraftState.value;
    String? source;
    try {
      if (pending != null && pending.editingId == editing.id) {
        source = pending.text;
      } else {
        var allowPersistence = false;
        try {
          allowPersistence = !await rust.isRoomEncrypted(
            roomId: draftKey.roomId,
          );
        } catch (_) {
          // Unknown encryption state must not allow plaintext persistence.
        }
        source = await _sourceStore.load(
          userId: draftKey.userId,
          roomId: draftKey.roomId,
          eventId: editing.id,
          body: editing.content,
          formattedBody: editing.formattedBody,
          allowPersistence: allowPersistence,
        );
        // A newer full-screen edit written during the store read wins.
        pending = editDraftState.value;
        if (pending != null && pending.editingId == editing.id) {
          source = pending.text;
        }
      }
    } catch (error) {
      debugPrint('Failed to restore markdown source: $error');
    }
    if (_disposed || _lastEditingId != editing.id) return;
    textController.text = source ?? editing.content;
    textController.selection = TextSelection.collapsed(
      offset: textController.text.length,
    );
    if (_sourceLoadingId == editing.id) _sourceLoadingId = null;
    onTextRestored();
  }

  void _restoreDraft() {
    _lastEditingId = null;
    _sourceLoadingId = null;
    onEditingCancelled();
    // Restoring the ordinary draft must not save it as an edit or start typing.
    textController.removeListener(onTextChanged);
    _replaceText(ref.read(messageDraftProvider(draftKey)));
    textController.addListener(onTextChanged);
    onTextRestored();
  }

  void dispose() {
    _disposed = true;
  }
}
