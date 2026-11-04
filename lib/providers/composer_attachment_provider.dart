import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../pages/chat/attachment_media_draft.dart';
import 'chat_provider.dart' show RoomAccountKey;

final composerAttachmentDraftProvider =
    ChangeNotifierProvider.family<ComposerAttachmentDraft, RoomAccountKey>(
      (ref, key) => ComposerAttachmentDraft(),
    );

/// Pending images belong to the room/account, independently of a mounted input.
class ComposerAttachmentDraft extends AttachmentMediaDraft {
  final _releases = <VoidCallback>{};

  /// Keep dropped-file access alive until these images are sent or removed.
  Future<void> stage(List<XFile> files) {
    if (isSending || files.isEmpty) return Future.value();
    final items = files.map(forFile).toSet();
    for (final item in items) {
      if (!selected.contains(item)) toggle(item);
    }
    final done = Completer<void>();
    late final VoidCallback changed;
    void release() {
      removeListener(changed);
      _releases.remove(release);
      if (!done.isCompleted) done.complete();
    }

    changed = () {
      if (items.every((item) => !selected.contains(item))) {
        discardUnselected();
        release();
      }
    };
    _releases.add(release);
    addListener(changed);
    changed();
    return done.future;
  }

  @override
  void dispose() {
    for (final release in _releases.toList()) {
      release();
    }
    super.dispose();
  }
}
