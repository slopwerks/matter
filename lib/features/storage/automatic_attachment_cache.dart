import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pages/chat/chat_media_source.dart';
import '../../pages/chat/media_preparation.dart';
import '../../providers/auth_provider.dart';
import 'storage_download_policy.dart';
import 'storage_models.dart';
import 'storage_providers.dart';

/// Downloads visible audio/documents to the same cache used by manual actions.
/// This does not export files into the user's chosen Downloads directory.
class AutomaticAttachmentCache extends ConsumerStatefulWidget {
  final String filename;
  final String? url;
  final String? source;
  final String roomId;
  final int? bytes;
  final StorageKind kind;
  const AutomaticAttachmentCache({
    super.key,
    required this.filename,
    required this.url,
    required this.source,
    required this.roomId,
    required this.bytes,
    required this.kind,
  });
  @override
  ConsumerState<AutomaticAttachmentCache> createState() =>
      _AutomaticAttachmentCacheState();
}

class _AutomaticAttachmentCacheState
    extends ConsumerState<AutomaticAttachmentCache> {
  MediaPreparation? _preparation;
  @override
  void initState() {
    super.initState();
    ref.listenManual(currentUserProvider, (_, _) => _preparation?.cancel());
    ref.listenManual(
      storageAutoDownloadPolicyProvider,
      (_, _) => unawaited(_load()),
    );
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant AutomaticAttachmentCache oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url ||
        widget.source != oldWidget.source ||
        widget.roomId != oldWidget.roomId) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    _preparation?.cancel();
    final preparation = _preparation = MediaPreparation();
    if (widget.bytes == null ||
        widget.bytes! <= 0 ||
        ref.read(currentUserProvider) == null) {
      return;
    }
    try {
      if (!await mayAutoDownload(widget.kind, widget.bytes) ||
          !mounted ||
          preparation.isCancelled) {
        return;
      }
      final source = await prepareChatMediaSource(
        ref: ref,
        url: widget.url,
        mediaSourceJson: widget.source,
        filename: widget.filename,
        roomId: widget.roomId,
        kind: widget.kind,
        preparation: preparation,
      );
      await source.cleanup();
    } catch (error) {
      if (!preparation.isCancelled) {
        debugPrint('Automatic attachment download failed: $error');
      }
    }
  }

  @override
  void dispose() {
    _preparation?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
