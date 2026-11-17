import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/managed_media.dart';
import '../../features/storage/storage_download_policy.dart';
import '../../features/storage/storage_models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import 'cached_chat_image.dart';
import 'chat_media_source.dart';
import 'media_preparation.dart';

/// Inputs used to decide and resolve an image transfer, without layout state.
class ImageBubbleSource {
  const ImageBubbleSource({
    required this.imageUrl,
    required this.mediaSourceJson,
    required this.fileSize,
    required this.filename,
    required this.roomId,
    required this.isSticker,
    required this.hasPreview,
    required this.spoilerHidden,
  });

  final String? imageUrl;
  final String? mediaSourceJson;
  final int? fileSize;
  final String? filename;
  final String? roomId;
  final bool isSticker;
  final bool hasPreview;
  final bool spoilerHidden;
}

/// Owns download policy, URL resolution, decryption and cancellation.
/// Pixel handover and all bubble rendering remain with the widget.
class ImageMessageLoader extends ChangeNotifier {
  ImageMessageLoader({required this.ref, required this.onLoaded});

  final WidgetRef ref;
  final VoidCallback onLoaded;
  bool _disposed = false;
  MediaPreparation? _imagePreparation;
  String? _resolvedUrl;
  Uint8List? _decryptedBytes;
  bool _isLoadingEncrypted = false;
  bool _encryptedLoadFailed = false;
  bool _resolveFailed = false;
  int? _thumbnailWidth;
  int? _thumbnailHeight;
  int _resolveGeneration = 0;
  int _decisionGeneration = 0;
  ({bool original, bool thumbnail, int? byteLimit})? _lastPolicy;
  bool _manualDownload = false;
  bool _downloadBlocked = true;

  int? get thumbnailWidth => _thumbnailWidth;
  int? get thumbnailHeight => _thumbnailHeight;

  String? get resolvedUrl => _resolvedUrl;
  Uint8List? get decryptedBytes => _decryptedBytes;
  bool get isLoadingEncrypted => _isLoadingEncrypted;
  bool get encryptedLoadFailed => _encryptedLoadFailed;
  bool get resolveFailed => _resolveFailed;
  bool get downloadBlocked => _downloadBlocked;
  ({bool original, bool thumbnail, int? byteLimit})? get policy => _lastPolicy;

  void _update(VoidCallback change) {
    change();
    notifyListeners();
  }

  void reset() {
    _decisionGeneration++;
    _lastPolicy = null;
    _resolveGeneration++;
    _manualDownload = false;
    _downloadBlocked = true;
    _resolvedUrl = null;
    _decryptedBytes = null;
    _isLoadingEncrypted = false;
    _encryptedLoadFailed = false;
    _resolveFailed = false;
  }

  bool updateThumbnailSize(int width, int height) {
    if (thumbnailWidth == width && thumbnailHeight == height) return false;
    _lastPolicy = null;
    _thumbnailWidth = width;
    _thumbnailHeight = height;
    return true;
  }

  void restoreCachedOriginal(String? imageUrl) {
    final cached = cachedOriginalMxcUrl(ref, imageUrl);
    if (cached != null) _resolvedUrl = cached;
  }

  @override
  void dispose() {
    _disposed = true;
    _decisionGeneration++;
    _resolveGeneration++;
    _imagePreparation?.cancel();
    super.dispose();
  }

  Future<void> resolve({
    required ImageBubbleSource source,
    bool manual = false,
    bool retry = false,
  }) async {
    if (manual) _manualDownload = true;
    if (source.spoilerHidden) return;
    // An optimistic image already has its pixels: there is no `mxc://` source
    // to resolve until the upload produces one.
    if (source.hasPreview) return;
    final decision = ++_decisionGeneration;
    var generation = _resolveGeneration;
    var started = false;
    final account = ref.read(activeUserIdProvider);
    bool isCurrent() =>
        !_disposed &&
        generation == _resolveGeneration &&
        ref.read(activeUserIdProvider) == account;
    final imageUrl = source.imageUrl;
    int? stickerByteLimit;
    try {
      final unknownStickerSize =
          source.isSticker &&
          (source.fileSize == null || source.fileSize! <= 0);
      if (unknownStickerSize && !_manualDownload) {
        stickerByteLimit = await autoDownloadByteLimit(StorageKind.image);
        // The bridge's bounded download API uses a signed 32-bit length.
        stickerByteLimit = stickerByteLimit.clamp(0, 0x7fffffff);
      }
      final allowed =
          _manualDownload ||
          (stickerByteLimit != null
              ? stickerByteLimit > 0
              : await mayAutoDownload(StorageKind.image, source.fileSize));
      final allowThumbnail =
          allowed ||
          (!source.isSticker &&
              imageUrl?.startsWith('mxc://') == true &&
              source.fileSize != null &&
              source.fileSize! > 0 &&
              await mayAutoDownload(StorageKind.image, 1));
      if (_disposed ||
          decision != _decisionGeneration ||
          ref.read(activeUserIdProvider) != account) {
        return;
      }
      // Initial settings/network notifications often agree. Keep the active
      // request and its result instead of cancelling and downloading again.
      final policy = (
        original: allowed,
        thumbnail: allowThumbnail,
        byteLimit: stickerByteLimit,
      );
      if (!manual && !retry && _lastPolicy == policy) return;
      _lastPolicy = policy;
      _imagePreparation?.cancel();
      final preparation = _imagePreparation = MediaPreparation();
      generation = ++_resolveGeneration;
      started = true;
      _resolveFailed = false;
      _update(() {
        _downloadBlocked = !allowThumbnail;
        if (!allowed) _resolvedUrl = null;
        if (allowed && (imageUrl == null || stickerByteLimit != null)) {
          _isLoadingEncrypted = true;
          _encryptedLoadFailed = false;
        }
      });
      String? resolved;
      Future<String?>? originalFuture;
      if (imageUrl != null && imageUrl.startsWith('mxc://')) {
        if (source.isSticker) {
          // Server thumbnails may contain only the first animation frame.
          resolved = await resolveMxcUrlFull(ref, imageUrl);
        } else if (allowed) {
          originalFuture = resolveMxcUrlFull(ref, imageUrl);
          final fallback = Completer<String?>();
          final timer = Timer(Duration.zero, () => fallback.complete(null));
          try {
            resolved = await Future.any([originalFuture, fallback.future]);
          } finally {
            timer.cancel();
          }
        }
        if (!source.isSticker) {
          resolved ??= await resolveMxcUrl(
            ref,
            imageUrl,
            width: thumbnailWidth,
            height: thumbnailHeight,
            useOriginalIfCached: allowed,
          );
        }
      } else {
        resolved = imageUrl;
      }
      if (!isCurrent()) return;
      final user = ref.read(currentUserProvider);
      final accountKey = user == null
          ? null
          : storageAccountKey(user.id, user.homeserver);
      final filename = source.filename ?? 'image.bin';
      final maxImageBytes = source.fileSize != null && source.fileSize! > 0
          ? source.fileSize!
          : 16 * 1024 * 1024;
      if (!allowed) {
        final cachedUrl = cachedOriginalMxcUrl(ref, imageUrl) ?? resolved;
        var cached = cachedUrl != null
            ? await cachedChatImageBytes(ref, cachedUrl, source.roomId)
            : accountKey == null
            ? null
            : await readManagedMediaBytes(
                account: accountKey,
                key: source.mediaSourceJson ?? '',
                filename: filename,
                kind: StorageKind.image,
                maxBytes: maxImageBytes,
                owner: source.roomId == null
                    ? null
                    : StorageOwner(accountKey, source.roomId!),
              );
        if (cached == null && resolved != null && resolved != cachedUrl) {
          cached = await cachedChatImageBytes(ref, resolved, source.roomId);
        }
        if (isCurrent()) {
          _update(() {
            _downloadBlocked = cached == null && !allowThumbnail;
            _decryptedBytes = cached;
            _resolvedUrl = cached == null && allowThumbnail ? resolved : null;
            _resolveFailed =
                allowThumbnail && cached == null && resolved == null;
          });
        }
        return;
      }
      if (stickerByteLimit != null && allowed) {
        // Unknown-size stickers may load automatically, but the transfer must
        // enforce the network's byte budget before an image widget sees a URL.
        var stickerBytes = resolved == null
            ? null
            : await cachedChatImageBytes(ref, resolved, source.roomId);
        if (!isCurrent()) return;
        if (stickerBytes == null) {
          stickerBytes = await rust.downloadMediaSourceBytes(
            mediaSourceJson: source.mediaSourceJson ?? jsonEncode(imageUrl),
            maxSizeBytes: stickerByteLimit,
          );
          if (!isCurrent()) return;
          if (resolved != null) {
            await cacheChatImageBytes(
              ref,
              resolved,
              stickerBytes,
              source.roomId,
            );
          }
        }
        if (!isCurrent()) return;
        _update(() {
          _downloadBlocked = false;
          _decryptedBytes = stickerBytes;
          _resolvedUrl = null;
        });
        return;
      }
      if (imageUrl == null) {
        final mediaSourceJson = source.mediaSourceJson;
        if (mediaSourceJson == null) return;
        _isLoadingEncrypted = true;
        _encryptedLoadFailed = false;
        Uint8List bytes;
        if (accountKey == null || kIsWeb) {
          bytes = await rust.downloadMediaSourceBytes(
            mediaSourceJson: mediaSourceJson,
            maxSizeBytes: maxImageBytes,
          );
        } else {
          final prepared = await prepareChatMediaSource(
            ref: ref,
            url: null,
            mediaSourceJson: mediaSourceJson,
            filename: filename,
            roomId: source.roomId,
            kind: StorageKind.image,
            preparation: preparation,
          );
          try {
            bytes = (await readManagedMediaBytes(
              account: accountKey,
              key: mediaSourceJson,
              filename: filename,
              kind: StorageKind.image,
              maxBytes: maxImageBytes,
              owner: source.roomId == null
                  ? null
                  : StorageOwner(accountKey, source.roomId!),
            ))!;
          } finally {
            await prepared.cleanup();
          }
        }
        if (isCurrent()) {
          _update(() {
            _downloadBlocked = false;
            _decryptedBytes = bytes;
          });
          onLoaded();
        }
      } else if (isCurrent()) {
        _update(() {
          _downloadBlocked = false;
          _resolvedUrl = resolved;
          _resolveFailed = resolved == null;
        });
        if (resolved != null) onLoaded();
        // Paint the thumbnail while the original is resolving. A failed or
        // slow original must not hide an otherwise usable image/gallery.
        if (originalFuture != null) {
          final original = await originalFuture;
          if (isCurrent() && original != null) {
            _update(() {
              _resolvedUrl = original;
              _resolveFailed = false;
            });
          }
        }
      }
    } catch (_) {
      if (started && isCurrent()) {
        _update(() {
          _resolveFailed = true;
          _encryptedLoadFailed = true;
          if (stickerByteLimit != null) _downloadBlocked = true;
        });
      }
    } finally {
      if (started && generation == _resolveGeneration) {
        _isLoadingEncrypted = false;
      }
    }
  }
}
