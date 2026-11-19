import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TextEditingController;
import 'package:photo_manager/photo_manager.dart';

import 'attachment_media_utils.dart';

class AttachmentMediaItem {
  final String id;
  final AssetEntity? asset;
  final XFile? file;
  Future<({XFile file, String filename})>? _original;
  Uint8List? editedBytes;
  String? editedFilename;
  String? editedMimeType;
  String? _originalMimeType;
  bool _compress = true;
  bool spoiler = false;

  String? get mimeType =>
      editedMimeType ??
      _originalMimeType ??
      resolveAttachmentMime(
        asset?.title ?? file?.name ?? '',
        asset?.mimeType ?? file?.mimeType,
      );

  bool get canCompress =>
      mimeType != null && mimeType != 'image/gif' && mimeType != 'image/webp';
  bool get compress => canCompress && _compress;

  AttachmentMediaItem.asset(AssetEntity source)
    : id = 'asset:${source.id}',
      asset = source,
      file = null;
  AttachmentMediaItem.file(XFile source)
    : id = 'file:${source.path}|${source.name}',
      asset = null,
      file = source;

  bool get isImage => asset != null
      ? asset!.type == AssetType.image
      : classifyAttachmentMime(
              resolveAttachmentMime(file!.name, file!.mimeType),
            ) ==
            AttachmentMediaKind.image;

  Future<({XFile file, String filename})> get original async {
    final pending = _original ??= _loadOriginal();
    try {
      return await pending;
    } catch (_) {
      if (identical(_original, pending)) _original = null;
      rethrow;
    }
  }

  Future<({XFile file, String filename})> _loadOriginal() async {
    if (file != null) return (file: file!, filename: file!.name);
    final source = asset!;
    final origin = await source.originFile;
    if (origin == null) throw '无法读取原文件';
    final title = (await source.titleAsync).trim();
    String? mime;
    try {
      mime = await source.mimeTypeAsync;
    } catch (_) {}
    _originalMimeType = resolveAttachmentMime(title, mime);
    return (
      file: XFile(origin.path, mimeType: mime),
      filename: title.isEmpty ? 'asset_${source.id}' : title,
    );
  }

  Future<Uint8List> readImageBytes() async =>
      editedBytes ?? await readAttachmentBytes((await original).file);
}

/// The selection order, common description and image edits are shared by the
/// list and preview, so opening or closing either view never submits a draft.
class AttachmentMediaDraft extends ChangeNotifier {
  final description = TextEditingController();
  final selected = <AttachmentMediaItem>[];
  final _items = <String, AttachmentMediaItem>{};
  bool isSending = false;
  String? albumRootEventId;

  AttachmentMediaItem forAsset(AssetEntity asset) {
    final id = 'asset:${asset.id}';
    return _items.putIfAbsent(id, () => AttachmentMediaItem.asset(asset));
  }

  AttachmentMediaItem forFile(XFile file) {
    final id = 'file:${file.path}|${file.name}';
    return _items.putIfAbsent(id, () => AttachmentMediaItem.file(file));
  }

  int order(AttachmentMediaItem item) => selected.indexOf(item) + 1;
  bool get hasImages => selected.any((item) => item.isImage);

  void toggle(AttachmentMediaItem item) {
    if (isSending) return;
    if (!selected.remove(item)) selected.add(item);
    if (selected.isEmpty) albumRootEventId = null;
    notifyListeners();
  }

  void setSending(bool value) {
    isSending = value;
    notifyListeners();
  }

  void selectionChanged() {
    if (selected.isEmpty) albumRootEventId = null;
    notifyListeners();
  }

  void toggleSpoiler(AttachmentMediaItem item) {
    if (isSending) return;
    item.spoiler = !item.spoiler;
    notifyListeners();
  }

  void toggleCompression(AttachmentMediaItem item) {
    if (isSending || !item.canCompress) return;
    item._compress = !item._compress;
    notifyListeners();
  }

  void applyEdit(AttachmentMediaItem item, Uint8List bytes, String filename) {
    if (isSending) return;
    if (bytes.length > attachmentMaxBufferedBytes) throw '图片超过 64MB 限制';
    final mime = detectImageMime(bytes);
    if (mime == null) throw '无法识别编辑后的图片格式';
    item.editedBytes = bytes;
    item.editedMimeType = mime;
    item.editedFilename = attachmentFilenameWithExtension(
      filename,
      attachmentImageExtension(mime),
    );
    notifyListeners();
  }

  /// Long-lived composer drafts need not retain bytes for removed images.
  void discardUnselected() {
    _items.removeWhere((_, item) => !selected.contains(item));
  }

  @override
  void dispose() {
    description.dispose();
    super.dispose();
  }
}
