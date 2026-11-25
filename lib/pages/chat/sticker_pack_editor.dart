import 'dart:convert';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../widgets/floating_app_bar.dart';
import 'attachment_media_utils.dart';
import 'sticker_catalog.dart';
import 'sticker_preview.dart';

class _ImageDraft {
  _ImageDraft(this.shortcode, this.content);
  String shortcode;
  final Map<String, dynamic> content;
}

class StickerPackEditor extends ConsumerStatefulWidget {
  const StickerPackEditor({
    super.key,
    required this.account,
    required this.roomId,
    this.stateKey,
  });
  final String account;
  final String roomId;
  final String? stateKey;

  @override
  ConsumerState<StickerPackEditor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<StickerPackEditor> {
  late final _key = rust.StickerPackKey(
    roomId: widget.roomId,
    stateKey:
        widget.stateKey ??
        base64Url
            .encode(List.generate(16, (_) => _random.nextInt(256)))
            .replaceAll('=', ''),
  );
  final _random = Random.secure();
  final _images = <_ImageDraft>[];
  Map<String, dynamic> _content = {};
  Map<String, dynamic> _meta = {
    'usage': ['sticker'],
  };
  rust.StickerPackSnapshot? _snapshot;
  bool _loaded = false;
  bool _busy = false;
  String? _error;

  bool get _sameAccount =>
      mounted && ref.read(activeUserIdProvider) == widget.account;
  bool get _writable =>
      _sameAccount &&
      ref
              .read(stickerPackEditPermissionProvider(widget.roomId))
              .asData
              ?.value ==
          true;

  @override
  void initState() {
    super.initState();
    if (widget.stateKey == null) {
      _loaded = true;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final snapshot = await rust.getStickerPackSnapshot(
        accountUserId: widget.account,
        key: _key,
      );
      if (!_sameAccount) return;
      final json = snapshot.contentJson;
      if (json == null) throw '贴纸包已被删除';
      _content = jsonDecode(json) as Map<String, dynamic>;
      _meta = _content['pack'] as Map<String, dynamic>? ?? {};
      final images = _content['images'] as Map<String, dynamic>;
      _images.addAll(
        images.entries.map(
          (entry) =>
              _ImageDraft(entry.key, entry.value as Map<String, dynamic>),
        ),
      );
      _snapshot = snapshot;
      _loaded = true;
    } catch (error) {
      _error = '$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _upload({required bool cover}) async {
    if (_busy || !_writable) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: '图片',
            extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
            mimeTypes: ['image/*'],
            uniformTypeIdentifiers: ['public.image'],
          ),
        ],
      );
      if (file == null || !_writable) return;
      final bytes = await readAttachmentBytes(file);
      final mime = detectImageMime(bytes);
      final size = await decodeAttachmentImageSize(bytes);
      if (mime == null || size == null) throw '无法读取图片格式或尺寸';
      final encrypted = await rust.isRoomEncrypted(roomId: widget.roomId);
      if (!_writable) return;
      if (encrypted &&
          !await _confirm(
            '上传贴纸包图片？',
            '此房间已加密。贴纸包图片会以明文上传，获得媒体地址的人可能在房间外查看或转发图片。',
            '继续上传',
          )) {
        return;
      }
      if (!_writable) return;
      final url = await rust.uploadStickerPackImage(
        accountUserId: widget.account,
        roomId: widget.roomId,
        data: bytes,
        mimeType: mime,
        confirmedPublicUpload: encrypted,
      );
      if (!_sameAccount) return;
      if (cover) {
        _meta['avatar_url'] = url;
      } else {
        final stem = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
        final base = stem.isEmpty ? 'sticker' : stem;
        var code = base;
        var suffix = 2;
        while (_images.any((image) => image.shortcode == code)) {
          code = '${base}_${suffix++}';
        }
        _images.add(
          _ImageDraft(code, {
            'url': url,
            'body': base,
            'info': {
              'mimetype': mime,
              'w': size.width.toInt(),
              'h': size.height.toInt(),
              'size': bytes.length,
            },
          }),
        );
      }
    } catch (error) {
      _error = '上传失败：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool delete = false}) async {
    if (_busy || !_writable) return;
    if (delete &&
        !await _confirm('删除整个贴纸包？', '删除后，房间成员将无法再从此包选择贴纸。', '删除贴纸包')) {
      return;
    }
    if (!_writable) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String? content;
      if (!delete) {
        if (_images.isEmpty) throw '请先添加一张贴纸';
        final images = <String, dynamic>{};
        for (final image in _images) {
          final code = image.shortcode;
          if (code.trim().isEmpty || images.containsKey(code)) {
            throw '每张贴纸都需要唯一且非空的短码';
          }
          images[code] = image.content;
        }
        content = jsonEncode({..._content, 'pack': _meta, 'images': images});
      }
      await rust.writeStickerPack(
        accountUserId: widget.account,
        key: _key,
        stableVersion: _snapshot?.stableVersion,
        legacyVersion: _snapshot?.legacyVersion,
        contentJson: content,
      );
      if (!_sameAccount) return;
      ref.invalidate(stickerPacksProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      _error = '保存失败：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _preview(String url, String label) => SizedBox.square(
    dimension: 56,
    child: RemoteStickerPreview(
      sticker: StickerItem(id: url, label: label, body: label, imageUrl: url),
      cacheDimension: 160,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final sameAccount = ref.watch(activeUserIdProvider) == widget.account;
    final permission = ref.watch(
      stickerPackEditPermissionProvider(widget.roomId),
    );
    final enabled = !_busy && sameAccount && permission.asData?.value == true;
    return Scaffold(
      appBar: buildFloatingAppBar(
        title: Text(widget.stateKey == null ? '创建贴纸包' : '编辑贴纸包'),
        actions: [
          TextButton(
            onPressed: enabled && _loaded && _images.isNotEmpty
                ? () => _save()
                : null,
            child: const Text('保存'),
          ),
        ],
      ),
      body: !sameAccount
          ? const Center(child: Text('账号已切换'))
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (!_loaded && !_busy)
                    TextButton(onPressed: _load, child: const Text('重新读取')),
                  if (permission.asData?.value == false)
                    const Text('当前没有管理贴纸包的权限'),
                  if (_loaded) ...[
                    TextFormField(
                      enabled: enabled,
                      initialValue: _meta['display_name'] as String?,
                      decoration: const InputDecoration(labelText: '包名称'),
                      onChanged: (value) => _meta['display_name'] = value,
                    ),
                    ListTile(
                      leading: _meta['avatar_url'] is String
                          ? _preview(_meta['avatar_url'] as String, '封面')
                          : const Icon(Icons.image_outlined),
                      title: const Text('更换封面'),
                      onTap: enabled ? () => _upload(cover: true) : null,
                    ),
                    for (final image in _images)
                      Padding(
                        key: ObjectKey(image),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            _preview(
                              image.content['url'] as String,
                              image.shortcode,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                children: [
                                  TextFormField(
                                    enabled: enabled,
                                    initialValue: image.shortcode,
                                    decoration: const InputDecoration(
                                      labelText: '短码',
                                    ),
                                    onChanged: (value) =>
                                        image.shortcode = value,
                                  ),
                                  TextFormField(
                                    enabled: enabled,
                                    initialValue:
                                        image.content['body'] as String?,
                                    decoration: const InputDecoration(
                                      labelText: '描述',
                                    ),
                                    onChanged: (value) =>
                                        image.content['body'] = value,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '移除贴纸',
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: !enabled
                                  ? null
                                  : () {
                                      if (_images.length == 1 &&
                                          widget.stateKey != null) {
                                        _save(delete: true);
                                      } else {
                                        setState(() => _images.remove(image));
                                      }
                                    },
                            ),
                          ],
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: enabled ? () => _upload(cover: false) : null,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text('添加贴纸'),
                    ),
                    if (widget.stateKey != null)
                      TextButton(
                        onPressed: enabled ? () => _save(delete: true) : null,
                        child: const Text('删除整包'),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}
