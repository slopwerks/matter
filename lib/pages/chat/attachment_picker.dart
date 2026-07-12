import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:photo_manager/photo_manager.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../chat/chat_image_editor_page.dart';
import '../chat/latest_message_control.dart';

/// The four attachment modes offered by the floating frosted-glass bar.
enum AttachmentTab { media, file, poll, location }

const _attachmentDockHeight = 72.0;
const _attachmentDockGap = 8.0;
const _attachmentSendButtonHeight = 44.0;
const _attachmentDockClearance = _attachmentDockHeight + _attachmentDockGap;
const _attachmentSendBarClearance =
    _attachmentDockClearance + _attachmentSendButtonHeight + _attachmentDockGap;
const _pollOptionAnimationDuration = Duration(milliseconds: 180);

/// Whether [photo_manager]'s native gallery grid works on this platform.
/// On Web/Linux/Windows it has no implementation and must be replaced with a
/// [file_selector] fallback to avoid MissingPluginException.
bool get photoManagerSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

@visibleForTesting
const attachmentMediaOrder = <OrderOption>[
  OrderOption(type: OrderOptionType.createDate, asc: false),
];

/// An inline attachment panel that starts at the keyboard height and expands
/// as the active content is dragged upward.
class AttachmentPicker extends StatefulWidget {
  final double height;
  final double maxHeight;
  final String roomId;
  final Future<void> Function(String roomId) onRefresh;
  final MessageSendPresentation Function() resolveSendPresentation;
  final void Function(
    MessageSendPresentation presentation,
    bool insertedOptimistically,
  )
  onMessageSent;
  final ValueChanged<double> onHeightChanged;
  final VoidCallback onClose;

  const AttachmentPicker({
    super.key,
    required this.height,
    required this.maxHeight,
    required this.roomId,
    required this.onRefresh,
    required this.resolveSendPresentation,
    required this.onMessageSent,
    required this.onHeightChanged,
    required this.onClose,
  });

  @override
  State<AttachmentPicker> createState() => _AttachmentPickerState();
}

class _AttachmentPickerState extends State<AttachmentPicker> {
  late final DraggableScrollableController _sheetController;
  late final ValueNotifier<double> _sheetExtent;
  AttachmentTab _tab = AttachmentTab.media;
  final Set<AttachmentTab> _visitedTabs = {AttachmentTab.media};
  bool _isSending = false;
  bool _isPickingFiles = false;

  /// Every Dart/FRB upload buffer is capped to avoid multiplying a very large
  /// allocation while it crosses the bridge into Rust.
  static const int _maxBufferedBytes = 64 * 1024 * 1024;
  static const int _maxImageEdge = 4096;
  static const int _maxImageQuality = 92;

  @override
  void initState() {
    super.initState();
    _sheetController = DraggableScrollableController();
    _sheetExtent = ValueNotifier<double>(0);
  }

  @override
  void dispose() {
    _sheetController.dispose();
    _sheetExtent.dispose();
    super.dispose();
  }

  Future<void> _sendMediaAssets(List<AssetEntity> assets) => _runBatch(
    assets
        .map(
          (a) =>
              () => _sendSingleAsset(a),
        )
        .toList(),
    assets,
  );

  Future<void> _sendSingleAsset(AssetEntity asset) async {
    final file = await asset.originFile;
    if (file == null) throw '无法读取文件';
    final title = (await asset.titleAsync).trim();
    final filename = title.isEmpty ? 'asset_${asset.id}' : title;
    String? declaredMime;
    try {
      declaredMime = await asset.mimeTypeAsync;
    } catch (_) {
      // The filename fallback below is enough when a platform has no MIME API.
    }
    final mime = resolveAttachmentMime(filename, declaredMime);

    if (asset.type == AssetType.video) {
      final bytes = await _readFileBytes(file, '视频');
      final size = asset.size;
      await rust.sendVideoMessage(
        roomId: widget.roomId,
        videoData: bytes,
        filename: filename,
        width: size.width.round(),
        height: size.height.round(),
        durationMs: asset.videoDuration.inMilliseconds,
        size: bytes.length,
        mimeType: mime?.startsWith('video/') == true ? mime : null,
      );
      return;
    }

    if (asset.type == AssetType.image) {
      final prepared = await _prepareAssetImage(
        asset: asset,
        file: file,
        filename: filename,
        mimeType: mime,
      );
      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: prepared.bytes,
        filename: prepared.filename,
        mimeType: prepared.mimeType,
        width: prepared.width,
        height: prepared.height,
      );
    } else {
      final bytes = await _readFileBytes(file, '文件');
      await rust.sendFileMessage(
        roomId: widget.roomId,
        fileData: bytes,
        filename: filename,
        mimeType: mime,
        size: bytes.length,
      );
    }
  }

  Future<void> _sendMediaXFiles(List<XFile> files) => _runBatch(
    files
        .map(
          (file) =>
              () => _sendSingleMediaXFile(file),
        )
        .toList(),
    files,
  );

  Future<void> _sendFiles(List<XFile> files) => _runBatch(
    files
        .map(
          (file) =>
              () => _sendSingleFile(file),
        )
        .toList(),
    files,
  );

  Future<void> _pickFiles() async {
    if (_isSending || _isPickingFiles) return;
    setState(() => _isPickingFiles = true);
    try {
      final files = List<XFile>.of(await openFiles());
      if (!mounted || files.isEmpty) return;
      await _sendFiles(files);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择文件失败: $error')));
      }
    } finally {
      if (mounted) setState(() => _isPickingFiles = false);
    }
  }

  Future<void> _sendSingleMediaXFile(XFile file) async {
    final mime = resolveAttachmentMime(file.name, file.mimeType);
    final kind = classifyAttachmentMime(mime);
    final original = await _readXFileBytes(file);

    if (kind == AttachmentMediaKind.image) {
      final prepared = await _prepareBufferedImage(
        original,
        filename: file.name,
        mimeType: mime!,
      );
      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: prepared.bytes,
        filename: prepared.filename,
        mimeType: prepared.mimeType,
        width: prepared.width,
        height: prepared.height,
      );
    } else if (kind == AttachmentMediaKind.video) {
      await rust.sendVideoMessage(
        roomId: widget.roomId,
        videoData: original,
        filename: file.name,
        mimeType: mime,
        size: original.length,
      );
    } else {
      await rust.sendFileMessage(
        roomId: widget.roomId,
        fileData: original,
        filename: file.name,
        mimeType: mime,
        size: original.length,
      );
    }
  }

  Future<void> _sendSingleFile(XFile file) async {
    final bytes = await _readXFileBytes(file);
    await rust.sendFileMessage(
      roomId: widget.roomId,
      fileData: bytes,
      filename: file.name,
      mimeType: resolveAttachmentMime(file.name, file.mimeType),
      size: bytes.length,
    );
  }

  Future<Uint8List> _readXFileBytes(XFile file) async {
    _ensureBufferedSize(await file.length(), '文件');
    final bytes = await file.readAsBytes();
    _ensureBufferedSize(bytes.length, '文件');
    return bytes;
  }

  Future<_PreparedImage> _prepareAssetImage({
    required AssetEntity asset,
    required File file,
    required String filename,
    required String? mimeType,
  }) async {
    final sourceSize = asset.size;
    if (sourceSize.width <= 0 || sourceSize.height <= 0) {
      final original = await _readFileBytes(file, '图片');
      final detectedMime = mimeType ?? _guessMime(filename);
      if (detectedMime?.startsWith('image/') != true) {
        throw '无法识别图片格式';
      }
      return _prepareBufferedImage(
        original,
        filename: filename,
        mimeType: detectedMime!,
      );
    }

    final target = _boundedImageSize(sourceSize);
    final shouldConvert =
        !_canSendOriginalImageMime(mimeType) ||
        sourceSize.width > _maxImageEdge ||
        sourceSize.height > _maxImageEdge;
    if (shouldConvert) {
      try {
        final compressed = await FlutterImageCompress.compressWithFile(
          file.path,
          minWidth: target.width,
          minHeight: target.height,
          quality: _maxImageQuality,
          format: CompressFormat.jpeg,
        );
        if (compressed != null && compressed.isNotEmpty) {
          return _jpegImage(
            compressed,
            filename: filename,
            expectedSize: target,
          );
        }
      } catch (_) {
        // A correctly typed original is still safe when it is already bounded.
      }
    }

    if (sourceSize.width > _maxImageEdge || sourceSize.height > _maxImageEdge) {
      throw '图片缩放失败';
    }
    if (mimeType?.startsWith('image/') != true) {
      throw '无法识别图片格式';
    }
    final original = await _readFileBytes(file, '图片');
    return _PreparedImage(
      bytes: original,
      filename: filename,
      mimeType: mimeType!,
      width: sourceSize.width.round(),
      height: sourceSize.height.round(),
    );
  }

  Future<_PreparedImage> _prepareBufferedImage(
    Uint8List original, {
    required String filename,
    required String mimeType,
  }) async {
    final sourceSize = await _decodeImageSize(original);
    if (sourceSize == null) throw '无法读取图片尺寸';
    final target = _boundedImageSize(sourceSize);
    final shouldConvert =
        !_canSendOriginalImageMime(mimeType) ||
        sourceSize.width > _maxImageEdge ||
        sourceSize.height > _maxImageEdge;
    if (!shouldConvert) {
      return _PreparedImage(
        bytes: original,
        filename: filename,
        mimeType: mimeType,
        width: sourceSize.width.round(),
        height: sourceSize.height.round(),
      );
    }

    try {
      final compressed = await FlutterImageCompress.compressWithList(
        original,
        minWidth: target.width,
        minHeight: target.height,
        quality: _maxImageQuality,
        format: CompressFormat.jpeg,
      );
      if (compressed.isNotEmpty) {
        return _jpegImage(compressed, filename: filename, expectedSize: target);
      }
    } catch (_) {
      // Preserve a correctly typed original only when it is already bounded.
    }

    if (sourceSize.width > _maxImageEdge || sourceSize.height > _maxImageEdge) {
      throw '图片缩放失败';
    }
    return _PreparedImage(
      bytes: original,
      filename: filename,
      mimeType: mimeType,
      width: sourceSize.width.round(),
      height: sourceSize.height.round(),
    );
  }

  Future<_PreparedImage> _jpegImage(
    Uint8List bytes, {
    required String filename,
    required ({int width, int height}) expectedSize,
  }) async {
    _ensureBufferedSize(bytes.length, '图片');
    final actual = await _decodeImageSize(bytes);
    final width = actual?.width.round() ?? expectedSize.width;
    final height = actual?.height.round() ?? expectedSize.height;
    if (width > _maxImageEdge || height > _maxImageEdge) {
      throw '图片缩放后仍超过 ${_maxImageEdge}px';
    }
    return _PreparedImage(
      bytes: bytes,
      filename: _withExtension(filename, 'jpg'),
      mimeType: 'image/jpeg',
      width: width,
      height: height,
    );
  }

  Future<Uint8List> _readFileBytes(File file, String label) async {
    _ensureBufferedSize(await file.length(), label);
    final bytes = await file.readAsBytes();
    _ensureBufferedSize(bytes.length, label);
    return bytes;
  }

  void _ensureBufferedSize(int length, String label) {
    if (length > _maxBufferedBytes) {
      throw '$label超过 ${_maxBufferedBytes ~/ 1024 ~/ 1024}MB 限制';
    }
  }

  Future<void> _sendEditedImage(
    Uint8List bytes, {
    required String originalFilename,
    required String? originalMimeType,
  }) => _runBatch([
    () async {
      _ensureBufferedSize(bytes.length, '图片');
      final mimeType =
          detectImageMime(bytes) ??
          resolveAttachmentMime(originalFilename, originalMimeType);
      if (mimeType?.startsWith('image/') != true) {
        throw '无法识别编辑后的图片格式';
      }
      final filename = _withExtension(
        originalFilename,
        _imageExtensionForMime(mimeType!),
      );
      final imageSize = await _decodeImageSize(bytes);
      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: bytes,
        filename: filename,
        mimeType: mimeType,
        width: imageSize?.width.round(),
        height: imageSize?.height.round(),
      );
    },
  ], null);

  Future<void> _sendPoll(
    String question,
    List<String> answers,
    bool disclosed,
    int maxSelections,
  ) => _runBatch([
    () => rust.sendPoll(
      roomId: widget.roomId,
      question: question,
      answers: answers,
      disclosed: disclosed,
      maxSelections: maxSelections,
    ),
  ], null);

  Future<void> _sendLocation(String body, String geoUri) => _runBatch([
    () => rust.sendLocation(roomId: widget.roomId, body: body, geoUri: geoUri),
  ], null);

  /// Sends a batch of individual send operations, tracking per-item success so
  /// a partial failure does not re-send already-delivered items on retry, and
  /// so a refresh failure is never misreported as a send failure.
  ///
  /// [items] carries the source selection so successfully-sent entries can be
  /// pruned from the UI; pass `null` for non-batch sends (poll/location/edit).
  Future<void> _runBatch(
    List<Future<void> Function()> ops,
    List<dynamic>? items,
  ) async {
    if (_isSending || ops.isEmpty) return;
    setState(() => _isSending = true);
    final presentation = widget.resolveSendPresentation();
    var sent = 0;
    try {
      for (var i = 0; i < ops.length; i++) {
        try {
          await ops[i]();
          sent++;
          // Prune the head: ops and items advance in lockstep, so after a
          // success the list tail == remaining unsent items. On full success
          // the list is empty; on partial failure the user keeps the unsent
          // remainder, so a retry never re-sends delivered items.
          if (items != null && items.isNotEmpty) {
            items.removeAt(0);
          }
          if (mounted) setState(() {});
        } catch (e) {
          if (sent > 0) {
            await _finishBatch(presentation, closePicker: false);
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(sent > 0 ? '已发送 $sent 项; 随后失败: $e' : '发送失败: $e'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      }
      await _finishBatch(presentation, closePicker: true);
    } finally {
      if (mounted && _isSending) setState(() => _isSending = false);
    }
  }

  /// Best-effort refresh + completion callback. A refresh error is swallowed
  /// (it does not invalidate already-sent messages).
  Future<void> _finishBatch(
    MessageSendPresentation presentation, {
    required bool closePicker,
  }) async {
    try {
      await widget.onRefresh(widget.roomId);
    } catch (_) {
      // Refresh is best-effort; never surface as a send failure.
    }
    if (!mounted) return;
    widget.onMessageSent(presentation, false);
    if (closePicker) {
      setState(() => _isSending = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onClose();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = math.max(widget.height, widget.maxHeight);
    final minSize = (widget.height / maxHeight).clamp(0.01, 1.0);
    if (_sheetExtent.value == 0) _sheetExtent.value = minSize;

    return ValueListenableBuilder<double>(
      valueListenable: _sheetExtent,
      builder: (context, extent, _) {
        final visibleHeight = (extent * maxHeight).clamp(
          widget.height,
          maxHeight,
        );
        return SizedBox(
          width: double.infinity,
          height: visibleHeight,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.bottomCenter,
              minHeight: maxHeight,
              maxHeight: maxHeight,
              child: SizedBox(
                width: double.infinity,
                height: maxHeight,
                child: NotificationListener<DraggableScrollableNotification>(
                  onNotification: (notification) {
                    if ((_sheetExtent.value - notification.extent).abs() >
                        0.0005) {
                      _sheetExtent.value = notification.extent;
                      widget.onHeightChanged(notification.extent * maxHeight);
                    }
                    return false;
                  },
                  child: DraggableScrollableSheet(
                    controller: _sheetController,
                    expand: false,
                    initialChildSize: minSize,
                    minChildSize: minSize,
                    maxChildSize: 1,
                    builder: (context, scrollController) => _buildSheet(
                      context,
                      scrollController,
                      maxHeight: maxHeight,
                      minSize: minSize,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSheet(
    BuildContext context,
    ScrollController scrollController, {
    required double maxHeight,
    required double minSize,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: AppColors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.surface),
          side: BorderSide(
            color: AppColors.surfaceVariant.withValues(alpha: 0.65),
          ),
        ),
        child: Column(
          children: [
            GestureDetector(
              key: const ValueKey('attachment-panel-drag-handle'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) => _dragSheet(
                details.primaryDelta ?? 0,
                maxHeight: maxHeight,
                minSize: minSize,
              ),
              onVerticalDragEnd: (details) =>
                  _settleSheet(details.primaryVelocity ?? 0, minSize: minSize),
              child: SizedBox(
                height: 32,
                child: Center(
                  child: Container(
                    width: 34,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.muted,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: AppColors.surfaceVariant),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IndexedStack(
                      index: _tab.index,
                      children: [
                        _buildTabBody(AttachmentTab.media, scrollController),
                        const SizedBox.shrink(),
                        _buildTabBody(AttachmentTab.poll, scrollController),
                        _buildTabBody(AttachmentTab.location, scrollController),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _FrostedTabBar(
                      tab: _tab,
                      isFileBusy: _isPickingFiles,
                      onTabChanged: _isSending || _isPickingFiles
                          ? null
                          : _selectTab,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBody(
    AttachmentTab tab,
    ScrollController sheetScrollController,
  ) {
    if (!_visitedTabs.contains(tab)) return const SizedBox.shrink();
    final scrollController = _tab == tab ? sheetScrollController : null;
    return switch (tab) {
      AttachmentTab.media =>
        photoManagerSupported
            ? _MediaTabBody(
                isSending: _isSending,
                scrollController: scrollController,
                onSendAssets: _sendMediaAssets,
                onOpenEditor: (source) async {
                  final edited = await Navigator.of(context).push<Uint8List>(
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => ChatImageEditorPage(
                        imagePath: source.path,
                        mimeType: source.mimeType,
                      ),
                    ),
                  );
                  if (edited != null && mounted) {
                    await _sendEditedImage(
                      edited,
                      originalFilename: source.filename,
                      originalMimeType: source.mimeType,
                    );
                  }
                },
              )
            : _MediaFallback(
                isSending: _isSending,
                scrollController: scrollController,
                onSendFiles: _sendMediaXFiles,
              ),
      AttachmentTab.poll => _PollTabBody(
        isSending: _isSending,
        scrollController: scrollController,
        onSendPoll: _sendPoll,
      ),
      AttachmentTab.location => _LocationTabBody(
        isSending: _isSending,
        scrollController: scrollController,
        onSendLocation: _sendLocation,
      ),
      AttachmentTab.file => const SizedBox.shrink(),
    };
  }

  void _selectTab(AttachmentTab tab) {
    if (tab == AttachmentTab.file) {
      unawaited(_pickFiles());
      return;
    }
    setState(() {
      _visitedTabs.add(tab);
      _tab = tab;
    });
  }

  void _dragSheet(
    double delta, {
    required double maxHeight,
    required double minSize,
  }) {
    if (!_sheetController.isAttached) return;
    final target = (_sheetController.size - delta / maxHeight).clamp(
      minSize,
      1.0,
    );
    _sheetController.jumpTo(target);
  }

  Future<void> _settleSheet(double velocity, {required double minSize}) async {
    if (!_sheetController.isAttached) return;
    final target =
        velocity < -300 ||
            (velocity <= 300 &&
                _sheetController.size > minSize + (1 - minSize) / 2)
        ? 1.0
        : minSize;
    await _sheetController.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }
}

// ── Frosted-glass mode bar ────────────────────────────────────────────

class _FrostedTabBar extends StatelessWidget {
  final AttachmentTab tab;
  final bool isFileBusy;
  final ValueChanged<AttachmentTab>? onTabChanged;

  const _FrostedTabBar({
    required this.tab,
    required this.isFileBusy,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    final items = const [
      _TabItem(AttachmentTab.media, Icons.photo_library_rounded, '图片'),
      _TabItem(AttachmentTab.file, Icons.folder_rounded, '文件'),
      _TabItem(AttachmentTab.poll, Icons.poll_rounded, '投票'),
      _TabItem(AttachmentTab.location, Icons.location_on_rounded, '地址'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SizedBox(
        key: const ValueKey('attachment-tab-bar'),
        height: _attachmentDockHeight - _attachmentDockGap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.nav),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(AppRadii.nav),
                border: Border.all(color: AppColors.glassBorder, width: 0.8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  for (final item in items)
                    _TabButton(
                      item: item,
                      selected: tab == item.tab,
                      busy: item.tab == AttachmentTab.file && isFileBusy,
                      onTap: onTabChanged == null
                          ? null
                          : () => onTabChanged!(item.tab),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  final AttachmentTab tab;
  final IconData icon;
  final String label;
  const _TabItem(this.tab, this.icon, this.label);
}

class _TabButton extends StatelessWidget {
  final _TabItem item;
  final bool selected;
  final bool busy;
  final VoidCallback? onTap;

  const _TabButton({
    required this.item,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.primary : AppColors.onSurfaceVariant;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(item.icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(item.label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ── Media tab: gallery grid + multi-select ───────────────────────────

typedef _ImageEditorSource = ({String path, String filename, String? mimeType});

class _MediaTabBody extends StatefulWidget {
  final bool isSending;
  final ScrollController? scrollController;
  final Future<void> Function(List<AssetEntity> assets) onSendAssets;
  final Future<void> Function(_ImageEditorSource source) onOpenEditor;

  const _MediaTabBody({
    required this.isSending,
    required this.scrollController,
    required this.onSendAssets,
    required this.onOpenEditor,
  });

  @override
  State<_MediaTabBody> createState() => _MediaTabBodyState();
}

class _MediaTabBodyState extends State<_MediaTabBody> {
  AssetPathEntity? _album;
  final List<AssetEntity> _assets = [];
  final List<AssetEntity> _selected = [];
  bool _loading = true;
  String? _error;
  bool _fetchingMore = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final perm = await PhotoManager.requestPermissionExtend();
      if (!mounted) return;
      if (!perm.hasAccess) {
        setState(() {
          _loading = false;
          _error = '没有相册访问权限';
        });
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
        filterOption: FilterOptionGroup(orders: attachmentMediaOrder),
      );
      if (!mounted) return;
      if (albums.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final album = albums.firstWhere(
        (a) => a.isAll,
        orElse: () => albums.first,
      );
      final assets = await album.getAssetListPaged(page: 0, size: 100);
      if (!mounted) return;
      setState(() {
        _album = album;
        _assets.addAll(assets);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _fetchMore() async {
    final album = _album;
    if (_fetchingMore || album == null || !mounted) return;
    setState(() => _fetchingMore = true);
    try {
      final total = await album.assetCountAsync;
      if (!mounted || _assets.length >= total) return;
      final next = await album.getAssetListPaged(
        page: _assets.length ~/ 100,
        size: 100,
      );
      if (!mounted) return;
      setState(() => _assets.addAll(next));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载更多媒体失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _fetchingMore = false);
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollEndNotification &&
        n.metrics.pixels >= n.metrics.maxScrollExtent - 240 &&
        _assets.isNotEmpty &&
        !_fetchingMore) {
      _fetchMore();
    }
    return false;
  }

  void _toggleSelect(AssetEntity asset) {
    if (widget.isSending) return;
    setState(() {
      if (_selected.contains(asset)) {
        _selected.remove(asset);
      } else {
        _selected.add(asset);
      }
    });
  }

  int _selectionIndex(AssetEntity asset) =>
      _selected.indexOf(asset) + 1; // 0 means not selected

  Future<void> _openEditor(AssetEntity asset) async {
    if (widget.isSending || asset.type != AssetType.image) return;
    try {
      final file = await asset.originFile;
      if (file == null) throw '无法读取原图';
      final title = (await asset.titleAsync).trim();
      final filename = title.isEmpty ? 'asset_${asset.id}' : title;
      String? declaredMime;
      try {
        declaredMime = await asset.mimeTypeAsync;
      } catch (_) {
        // The filename fallback is enough when MIME metadata is unavailable.
      }
      if (!mounted || widget.isSending) return;
      await widget.onOpenEditor((
        path: file.path,
        filename: filename,
        mimeType: resolveAttachmentMime(filename, declaredMime),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('打开图片失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: const TextStyle(color: AppColors.onSurfaceVariant),
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: _assets.isEmpty
                ? const Center(
                    child: Text(
                      '没有可用的图片或视频',
                      style: TextStyle(color: AppColors.onSurfaceVariant),
                    ),
                  )
                : GridView.builder(
                    controller: widget.scrollController,
                    padding: EdgeInsets.fromLTRB(
                      2,
                      2,
                      2,
                      _selected.isEmpty
                          ? _attachmentDockClearance
                          : _attachmentSendBarClearance,
                    ),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                        ),
                    itemCount: _assets.length + (_fetchingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _assets.length) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        );
                      }
                      final asset = _assets[index];
                      final order = _selectionIndex(asset);
                      final selected = order > 0;
                      final isVideo = asset.type == AssetType.video;
                      return GestureDetector(
                        key: ValueKey(asset.id),
                        // Tapping a video must not open the image editor: it would
                        // feed video bytes to the image decoder. Videos toggle
                        // selection instead; only images open the editor.
                        onTap: widget.isSending
                            ? null
                            : isVideo
                            ? () => _toggleSelect(asset)
                            : () => _openEditor(asset),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              color: selected
                                  ? AppColors.background
                                  : Colors.transparent,
                              padding: selected
                                  ? const EdgeInsets.all(6)
                                  : EdgeInsets.zero,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  selected ? 8 : 0,
                                ),
                                child: _AssetThumbnail(
                                  key: ValueKey('thumbnail_${asset.id}'),
                                  asset: asset,
                                ),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: GestureDetector(
                                onTap: widget.isSending
                                    ? null
                                    : () => _toggleSelect(asset),
                                child: _SelectionBadge(
                                  selected: selected,
                                  order: order,
                                ),
                              ),
                            ),
                            if (isVideo)
                              const Positioned(
                                bottom: 4,
                                left: 4,
                                child: Icon(
                                  Icons.play_circle_fill,
                                  color: Colors.white70,
                                  size: 18,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
        if (_selected.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _SendBar(
              label: '发送 ${_selected.length} 项',
              isSending: widget.isSending,
              // Pass by reference so partial-success items are pruned by the
              // send loop and a retry never re-sends delivered items.
              onSend: () => widget.onSendAssets(_selected),
            ),
          ),
      ],
    );
  }
}

class _AssetThumbnail extends StatefulWidget {
  final AssetEntity asset;
  const _AssetThumbnail({super.key, required this.asset});

  @override
  State<_AssetThumbnail> createState() => _AssetThumbnailState();
}

class _AssetThumbnailState extends State<_AssetThumbnail> {
  late Future<Uint8List?> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _AssetThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _thumbnail = _loadThumbnail();
    }
  }

  Future<Uint8List?> _loadThumbnail() =>
      widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(256));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _thumbnail,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(color: AppColors.surfaceVariant);
        }
        final bytes = snap.data;
        if (bytes == null) {
          return Container(
            color: AppColors.surfaceVariant,
            child: const Icon(
              Icons.broken_image,
              color: AppColors.onSurfaceVariant,
              size: 22,
            ),
          );
        }
        return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}

class _SelectionBadge extends StatelessWidget {
  final bool selected;
  final int order;
  const _SelectionBadge({required this.selected, required this.order});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? AppColors.primary
            : Colors.black.withValues(alpha: 0.35),
        border: Border.all(
          color: Colors.white.withValues(alpha: selected ? 0 : 0.7),
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child: selected
          ? Text(
              '$order',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

class _SendBar extends StatelessWidget {
  final String label;
  final bool isSending;
  final bool enabled;
  final VoidCallback onSend;

  const _SendBar({
    required this.label,
    required this.isSending,
    required this.onSend,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final active = enabled && !isSending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, _attachmentDockClearance),
        child: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            height: _attachmentSendButtonHeight,
            child: FilledButton.icon(
              key: const ValueKey('attachment-send-button'),
              onPressed: active ? onSend : null,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppColors.primary.withValues(
                  alpha: 0.35,
                ),
                disabledForegroundColor: Colors.white.withValues(alpha: 0.7),
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: const StadiumBorder(),
              ),
              icon: isSending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded, size: 20),
              label: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Media fallback (Web/Linux/Windows: no photo_manager) ─────────────

class _MediaFallback extends StatefulWidget {
  final bool isSending;
  final ScrollController? scrollController;
  final Future<void> Function(List<XFile> files) onSendFiles;

  const _MediaFallback({
    required this.isSending,
    required this.scrollController,
    required this.onSendFiles,
  });

  @override
  State<_MediaFallback> createState() => _MediaFallbackState();
}

class _MediaFallbackState extends State<_MediaFallback> {
  final List<XFile> _picked = [];

  static const _groups = <XTypeGroup>[
    XTypeGroup(
      label: '图片 / 视频',
      extensions: [
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
        'heic',
        'heif',
        'avif',
        'tiff',
        'tif',
        'bmp',
        'mp4',
        'mov',
        'm4v',
        'webm',
        'mkv',
        '3gp',
      ],
    ),
  ];

  Future<void> _pick() async {
    if (widget.isSending) return;
    try {
      final files = await openFiles(acceptedTypeGroups: _groups);
      if (!mounted || widget.isSending || files.isEmpty) return;
      setState(() => _picked.addAll(files));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择媒体失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            controller: widget.scrollController,
            padding: EdgeInsets.fromLTRB(
              24,
              32,
              24,
              _picked.isEmpty
                  ? _attachmentDockClearance
                  : _attachmentSendBarClearance,
            ),
            children: [
              const Icon(
                Icons.photo_library_outlined,
                size: 48,
                color: AppColors.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              const Text(
                '此平台的相册网格不可用，请选择图片或视频',
                style: TextStyle(color: AppColors.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Center(
                child: OutlinedButton(
                  onPressed: widget.isSending ? null : _pick,
                  child: const Text('选择图片 / 视频'),
                ),
              ),
              const SizedBox(height: 12),
              for (var index = 0; index < _picked.length; index++)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.insert_drive_file_rounded,
                    color: AppColors.onSurfaceVariant,
                  ),
                  title: Text(
                    _picked[index].name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.onSurface,
                      fontSize: 13,
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: '移除',
                    onPressed: widget.isSending
                        ? null
                        : () => setState(() => _picked.removeAt(index)),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
            ],
          ),
        ),
        if (_picked.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _SendBar(
              label: '发送 ${_picked.length} 项',
              isSending: widget.isSending,
              onSend: () => widget.onSendFiles(_picked),
            ),
          ),
      ],
    );
  }
}

// ── Poll tab ─────────────────────────────────────────────────────────

class _PollTabBody extends StatefulWidget {
  final bool isSending;
  final ScrollController? scrollController;
  final Future<void> Function(
    String question,
    List<String> answers,
    bool disclosed,
    int maxSelections,
  )
  onSendPoll;

  const _PollTabBody({
    required this.isSending,
    required this.scrollController,
    required this.onSendPoll,
  });

  @override
  State<_PollTabBody> createState() => _PollTabBodyState();
}

class _PollTabBodyState extends State<_PollTabBody> {
  final _question = TextEditingController();
  final List<_PollAnswerDraft> _answers = [
    _PollAnswerDraft(0),
    _PollAnswerDraft(1),
  ];
  var _nextAnswerId = 2;
  bool _disclosed = false;
  bool _allowMultiple = false;

  @override
  void dispose() {
    _question.dispose();
    for (final answer in _answers) {
      answer.controller.dispose();
    }
    super.dispose();
  }

  bool get _canSend {
    if (_question.text.trim().isEmpty) return false;
    final valid = _validAnswers.length;
    return valid >= 2;
  }

  List<String> get _validAnswers => _answers
      .where((answer) => answer.visible)
      .map((answer) => answer.controller.text.trim())
      .where((answer) => answer.isNotEmpty)
      .toList();

  int get _visibleAnswerCount =>
      _answers.where((answer) => answer.visible).length;

  void _addAnswer() {
    if (widget.isSending || _visibleAnswerCount >= 20) return;
    final answer = _PollAnswerDraft(_nextAnswerId++, visible: false);
    setState(() => _answers.add(answer));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_answers.contains(answer)) return;
      setState(() => answer.visible = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final answerContext = answer.fieldContext;
        if (!mounted || answerContext == null) return;
        unawaited(
          Scrollable.ensureVisible(
            answerContext,
            alignment: 0.25,
            duration: _pollOptionAnimationDuration,
            curve: Curves.easeOutCubic,
          ),
        );
      });
    });
  }

  void _removeAnswer(_PollAnswerDraft answer) {
    if (widget.isSending || !answer.visible || _visibleAnswerCount <= 2) {
      return;
    }
    setState(() => answer.visible = false);
    Future<void>.delayed(_pollOptionAnimationDuration, () {
      if (!mounted) return;
      setState(() => _answers.remove(answer));
      answer.controller.dispose();
    });
  }

  List<Widget> _buildAnswerRows() {
    var visibleIndex = 0;
    return [
      for (final answer in _answers)
        _buildAnswerRow(answer, answer.visible ? visibleIndex++ : 0),
    ];
  }

  Widget _buildAnswerRow(_PollAnswerDraft answer, int index) {
    return AnimatedSize(
      duration: _pollOptionAnimationDuration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: answer.visible
          ? Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Builder(
                builder: (context) {
                  answer.fieldContext = context;
                  return _PollOptionInput(
                    key: ValueKey('poll-option-${answer.id}'),
                    controller: answer.controller,
                    index: index,
                    enabled: !widget.isSending,
                    showRemoveButton: _visibleAnswerCount > 2,
                    onChanged: (_) => setState(() {}),
                    onRemove: () => _removeAnswer(answer),
                  );
                },
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            controller: widget.scrollController,
            padding: const EdgeInsets.fromLTRB(
              16,
              16,
              16,
              _attachmentSendBarClearance,
            ),
            children: [
              TextField(
                controller: _question,
                enabled: !widget.isSending,
                style: const TextStyle(color: AppColors.onBackground),
                decoration: const InputDecoration(labelText: '问题'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              ..._buildAnswerRows(),
              TextButton.icon(
                onPressed: widget.isSending || _visibleAnswerCount >= 20
                    ? null
                    : _addAnswer,
                icon: const Icon(Icons.add_rounded),
                label: const Text(
                  '添加选项',
                  style: TextStyle(color: AppColors.primary),
                ),
              ),
              SwitchListTile(
                title: const Text(
                  '公开投票结果',
                  style: TextStyle(color: AppColors.onBackground),
                ),
                value: _disclosed,
                onChanged: widget.isSending
                    ? null
                    : (v) => setState(() => _disclosed = v),
                activeThumbColor: AppColors.primary,
              ),
              SwitchListTile(
                title: const Text(
                  '允许多选',
                  style: TextStyle(color: AppColors.onBackground),
                ),
                value: _allowMultiple,
                onChanged: widget.isSending
                    ? null
                    : (v) => setState(() => _allowMultiple = v),
                activeThumbColor: AppColors.primary,
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _SendBar(
            label: '发送',
            isSending: widget.isSending,
            enabled: _canSend,
            onSend: () {
              final answers = _validAnswers;
              unawaited(
                widget.onSendPoll(
                  _question.text.trim(),
                  answers,
                  _disclosed,
                  _allowMultiple ? answers.length : 1,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PollAnswerDraft {
  final int id;
  final TextEditingController controller = TextEditingController();
  BuildContext? fieldContext;
  bool visible;

  _PollAnswerDraft(this.id, {this.visible = true});
}

class _PollOptionInput extends StatelessWidget {
  final TextEditingController controller;
  final int index;
  final bool enabled;
  final bool showRemoveButton;
  final ValueChanged<String> onChanged;
  final VoidCallback? onRemove;

  const _PollOptionInput({
    super.key,
    required this.controller,
    required this.index,
    required this.enabled,
    required this.showRemoveButton,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: ValueKey('poll-option-input-$index'),
            controller: controller,
            enabled: enabled,
            style: const TextStyle(color: AppColors.onBackground),
            decoration: InputDecoration(hintText: '选项 ${index + 1}'),
            onChanged: onChanged,
          ),
        ),
        AnimatedContainer(
          duration: _pollOptionAnimationDuration,
          curve: Curves.easeOutCubic,
          width: showRemoveButton ? 44 : 0,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(),
          child: showRemoveButton
              ? Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: SizedBox.square(
                    dimension: 40,
                    child: IconButton(
                      tooltip: '删除选项',
                      icon: const Icon(
                        Icons.remove_circle_outline_rounded,
                        color: AppColors.onSurfaceVariant,
                      ),
                      onPressed: enabled ? onRemove : null,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                )
              : null,
        ),
      ],
    );
  }
}

// ── Location tab ─────────────────────────────────────────────────────

class _LocationTabBody extends StatefulWidget {
  final bool isSending;
  final ScrollController? scrollController;
  final Future<void> Function(String body, String geoUri) onSendLocation;

  const _LocationTabBody({
    required this.isSending,
    required this.scrollController,
    required this.onSendLocation,
  });

  @override
  State<_LocationTabBody> createState() => _LocationTabBodyState();
}

class _LocationTabBodyState extends State<_LocationTabBody> {
  final MapController _mapController = MapController();
  ll.LatLng? _selected;
  bool _locating = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_locate());
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      final point = await currentAttachmentLocation();
      if (!mounted) return;
      setState(() {
        _selected = point;
        _locating = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapController.move(point, 16);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _locating = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    if (selected == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            24,
            24,
            24,
            _attachmentDockClearance,
          ),
          child: _locating
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: AppColors.primary),
                    SizedBox(height: 12),
                    Text(
                      '正在获取当前位置',
                      style: TextStyle(color: AppColors.onSurfaceVariant),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.location_off_rounded,
                      color: AppColors.onSurfaceVariant,
                      size: 36,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _error ?? '无法获取当前位置',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: widget.isSending ? null : _locate,
                      icon: const Icon(Icons.my_location_rounded),
                      label: const Text('重新定位'),
                    ),
                  ],
                ),
        ),
      );
    }

    final geoUri = canonicalGeoUri(
      selected.latitude.toString(),
      selected.longitude.toString(),
    )!;
    return Stack(
      children: [
        // Keep the sheet controller attached without covering map gestures.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 0,
          child: SingleChildScrollView(
            controller: widget.scrollController,
            primary: false,
            physics: const NeverScrollableScrollPhysics(),
            child: const SizedBox(height: 1),
          ),
        ),
        Positioned.fill(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: selected,
              initialZoom: 16,
              maxZoom: 19,
              onTap: (_, point) {
                if (!widget.isSending) setState(() => _selected = point);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'moe.aks.matter',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: selected,
                    width: 44,
                    height: 44,
                    alignment: Alignment.topCenter,
                    child: const Icon(
                      Icons.location_on_rounded,
                      size: 42,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
              SimpleAttributionWidget(
                alignment: Alignment.topLeft,
                backgroundColor: AppColors.surface.withValues(alpha: 0.82),
                source: const Text(
                  'OpenStreetMap contributors',
                  style: TextStyle(fontSize: 9),
                ),
                onTap: () {
                  unawaited(
                    launchUrl(
                      Uri.parse('https://www.openstreetmap.org/copyright'),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: Material(
            color: AppColors.surfaceElevated.withValues(alpha: 0.92),
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: '回到当前位置',
              onPressed: widget.isSending || _locating ? null : _locate,
              icon: _locating
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location_rounded, size: 20),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _SendBar(
            label: '发送',
            isSending: widget.isSending,
            onSend: () => widget.onSendLocation('位置', geoUri),
          ),
        ),
      ],
    );
  }
}

// ── Helpers ──────────────────────────────────────────────────────────

enum AttachmentMediaKind { image, video, file }

class _PreparedImage {
  final Uint8List bytes;
  final String filename;
  final String mimeType;
  final int width;
  final int height;

  const _PreparedImage({
    required this.bytes,
    required this.filename,
    required this.mimeType,
    required this.width,
    required this.height,
  });
}

@visibleForTesting
String? resolveAttachmentMime(String filename, String? declaredMime) {
  final declared = declaredMime?.split(';').first.trim().toLowerCase();
  if (declared != null &&
      declared.isNotEmpty &&
      declared != 'application/octet-stream') {
    return declared;
  }
  return _guessMime(filename) ?? (declared?.isEmpty == false ? declared : null);
}

@visibleForTesting
AttachmentMediaKind classifyAttachmentMime(String? mimeType) {
  if (mimeType?.startsWith('image/') == true) {
    return AttachmentMediaKind.image;
  }
  if (mimeType?.startsWith('video/') == true) {
    return AttachmentMediaKind.video;
  }
  return AttachmentMediaKind.file;
}

bool _canSendOriginalImageMime(String? mimeType) => const {
  'image/jpeg',
  'image/jpg',
  'image/png',
  'image/gif',
  'image/webp',
}.contains(mimeType);

({int width, int height}) _boundedImageSize(Size source) {
  if (source.width <= 0 || source.height <= 0) {
    return (
      width: _AttachmentPickerState._maxImageEdge,
      height: _AttachmentPickerState._maxImageEdge,
    );
  }
  final longest = source.width > source.height ? source.width : source.height;
  final scale = longest > _AttachmentPickerState._maxImageEdge
      ? _AttachmentPickerState._maxImageEdge / longest
      : 1.0;
  final width = (source.width * scale).floor();
  final height = (source.height * scale).floor();
  return (width: width > 0 ? width : 1, height: height > 0 ? height : 1);
}

final _decimalCoordinate = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$');

double? _parseCoordinate(String raw, {required double maxAbsolute}) {
  final valueText = raw.trim();
  if (!_decimalCoordinate.hasMatch(valueText)) return null;
  final value = double.tryParse(valueText);
  if (value == null || !value.isFinite || value.abs() > maxAbsolute) {
    return null;
  }
  return value;
}

String _formatCoordinate(double value) {
  if (value == 0) return '0';
  var result = value.toStringAsFixed(12);
  result = result.replaceFirst(RegExp(r'0+$'), '');
  return result.replaceFirst(RegExp(r'\.$'), '');
}

@visibleForTesting
String? canonicalGeoUri(String latitude, String longitude) {
  final lat = _parseCoordinate(latitude, maxAbsolute: 90);
  final lng = _parseCoordinate(longitude, maxAbsolute: 180);
  if (lat == null || lng == null) return null;
  return 'geo:${_formatCoordinate(lat)},${_formatCoordinate(lng)}';
}

@visibleForTesting
Future<ll.LatLng> currentAttachmentLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const _AttachmentLocationException('请先开启系统定位服务');
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied) {
    throw const _AttachmentLocationException('未获得定位权限');
  }
  if (permission == LocationPermission.deniedForever) {
    throw const _AttachmentLocationException('定位权限已被永久拒绝，请在系统设置中开启');
  }

  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 12),
    ),
  );
  return ll.LatLng(position.latitude, position.longitude);
}

class _AttachmentLocationException implements Exception {
  final String message;

  const _AttachmentLocationException(this.message);

  @override
  String toString() => message;
}

String? _guessMime(String filename) {
  final lower = filename.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0) return null;
  final ext = lower.substring(dot + 1);
  return const {
    // Images
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'avif': 'image/avif',
    'tiff': 'image/tiff',
    'tif': 'image/tiff',
    'bmp': 'image/bmp',
    // Video (case-insensitive: .MOV is common on iOS)
    'mp4': 'video/mp4',
    'm4v': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'mkv': 'video/x-matroska',
    '3gp': 'video/3gpp',
    // Audio
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'ogg': 'audio/ogg',
    'opus': 'audio/ogg',
    'wav': 'audio/wav',
    'flac': 'audio/flac',
    // Common documents
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'zip': 'application/zip',
  }[ext];
}

@visibleForTesting
String? detectImageMime(Uint8List bytes) {
  bool matches(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) return false;
    }
    return true;
  }

  if (matches(0, const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (matches(0, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return 'image/png';
  }
  if (matches(0, 'GIF87a'.codeUnits) || matches(0, 'GIF89a'.codeUnits)) {
    return 'image/gif';
  }
  if (matches(0, 'RIFF'.codeUnits) && matches(8, 'WEBP'.codeUnits)) {
    return 'image/webp';
  }
  if (matches(0, 'BM'.codeUnits)) return 'image/bmp';
  if (matches(0, const [0x49, 0x49, 0x2a, 0x00]) ||
      matches(0, const [0x4d, 0x4d, 0x00, 0x2a])) {
    return 'image/tiff';
  }
  if (matches(4, 'ftyp'.codeUnits) && bytes.length >= 12) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase();
    if (brand == 'avif' || brand == 'avis') return 'image/avif';
    if ({'heic', 'heix', 'hevc', 'hevx'}.contains(brand)) {
      return 'image/heic';
    }
    if (brand == 'heif' || brand == 'mif1' || brand == 'msf1') {
      return 'image/heif';
    }
  }
  return null;
}

String _imageExtensionForMime(String mimeType) {
  return const {
        'image/jpeg': 'jpg',
        'image/jpg': 'jpg',
        'image/png': 'png',
        'image/gif': 'gif',
        'image/webp': 'webp',
        'image/heic': 'heic',
        'image/heif': 'heif',
        'image/avif': 'avif',
        'image/tiff': 'tiff',
        'image/bmp': 'bmp',
      }[mimeType.toLowerCase()] ??
      'jpg';
}

/// Replace the extension of [name] with [ext]. Used when re-encoding a picked
/// image to JPEG so the filename matches the bytes we actually send.
String _withExtension(String name, String ext) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? '${name.substring(0, dot)}.$ext' : '$name.$ext';
}

Future<Size?> _decodeImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}
