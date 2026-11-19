import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:pro_image_editor/pro_image_editor.dart';

import '../../theme/neu_colors.dart';

enum ChatImageEditorTool { crop, paint }

/// Explicit image editing; completing it returns bytes to the media preview.
class ChatImageEditorPage extends StatefulWidget {
  const ChatImageEditorPage({
    super.key,
    required this.imagePath,
    this.mimeType,
    this.imageBytes,
    this.initialTool,
  });

  final String imagePath;
  final String? mimeType;
  final Uint8List? imageBytes;
  final ChatImageEditorTool? initialTool;

  @visibleForTesting
  ImageGenerationConfigs get imageGenerationConfigs => ImageGenerationConfigs(
    enableUseOriginalBytes: true,
    captureImageByteFormat: ui.ImageByteFormat.rawStraightRgba,
    jpegQuality: 100,
    maxOutputSize: Size.infinite,
    outputFormat: _editorOutputFormat(mimeType),
  );

  @override
  State<ChatImageEditorPage> createState() => _ChatImageEditorPageState();
}

class _ChatImageEditorPageState extends State<ChatImageEditorPage> {
  final _editor = GlobalKey<ProImageEditorState>();
  bool _openedTool = false;

  void _openInitialTool() {
    if (_openedTool || widget.initialTool == null) return;
    _openedTool = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (widget.initialTool!) {
        case ChatImageEditorTool.crop:
          _editor.currentState?.openCropRotateEditor();
        case ChatImageEditorTool.paint:
          _editor.currentState?.openPaintEditor();
      }
    });
  }

  void _finishTool() {
    if (widget.initialTool == null || !mounted) return;
    final editor = _editor.currentState;
    if (editor?.stateManager.canUndo == true) {
      editor!.doneEditing();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final overlayIconBrightness =
        context.isMaterial && Theme.of(context).brightness == Brightness.light
        ? Brightness.dark
        : Brightness.light;
    // pro_image_editor 14 renders with the decoupled `material_ui` package,
    // whose ThemeData is not interchangeable with the SDK one.
    final editorTheme = material_ui.ThemeData(
      useMaterial3: true,
      brightness: Theme.of(context).brightness,
      scaffoldBackgroundColor: colors.base,
      colorScheme: material_ui.ColorScheme.fromSeed(
        seedColor: colors.accent,
        brightness: Theme.of(context).brightness,
        primary: colors.accent,
        secondary: colors.accent,
        surface: colors.surface,
        onSurface: colors.text,
      ),
    );

    final callbacks = ProImageEditorCallbacks(
      onImageEditingComplete: (bytes) async {
        if (context.mounted) Navigator.of(context).pop(bytes);
      },
      mainEditorCallbacks: MainEditorCallbacks(
        onImageDecoded: _openInitialTool,
        onEndCloseSubEditor: (_) => _finishTool(),
      ),
    );
    final configs = ProImageEditorConfigs(
      theme: editorTheme,
      i18n: _imageEditorI18n,
      mainEditor: MainEditorConfigs(
        tools: const [
          SubEditorMode.cropRotate,
          SubEditorMode.paint,
          SubEditorMode.text,
          SubEditorMode.tune,
          SubEditorMode.filter,
          SubEditorMode.blur,
          SubEditorMode.emoji,
        ],
        style: MainEditorStyle(
          background: colors.base,
          appBarBackground: colors.base,
          appBarColor: colors.text,
          bottomBarBackground: colors.surface,
          bottomBarColor: colors.text,
          uiOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: overlayIconBrightness,
            systemNavigationBarColor: colors.surface,
            systemNavigationBarIconBrightness: overlayIconBrightness,
          ),
        ),
      ),
      paintEditor: PaintEditorConfigs(
        tools: const [
          PaintMode.moveAndZoom,
          PaintMode.freeStyle,
          PaintMode.arrow,
          PaintMode.line,
          PaintMode.rect,
          PaintMode.circle,
          PaintMode.pixelate,
          PaintMode.blur,
          PaintMode.eraser,
        ],
        style: PaintEditorStyle(
          appBarBackground: colors.base,
          appBarColor: colors.text,
          background: colors.base,
          bottomBarBackground: colors.surface,
          bottomBarActiveItemColor: colors.accent,
          bottomBarInactiveItemColor: colors.textSecondary,
          initialColor: colors.accent,
          uiOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: overlayIconBrightness,
            systemNavigationBarColor: colors.surface,
            systemNavigationBarIconBrightness: overlayIconBrightness,
          ),
        ),
      ),
      cropRotateEditor: CropRotateEditorConfigs(
        maxScale: 8,
        style: CropRotateEditorStyle(
          appBarBackground: colors.base,
          appBarColor: colors.text,
          background: colors.base,
          bottomBarBackground: colors.surface,
          bottomBarColor: colors.text,
          cropCornerColor: colors.accent,
          helperLineColor: Colors.white54,
          uiOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: overlayIconBrightness,
            systemNavigationBarColor: colors.surface,
            systemNavigationBarIconBrightness: overlayIconBrightness,
          ),
        ),
      ),
      tuneEditor: TuneEditorConfigs(
        style: TuneEditorStyle(
          appBarBackground: colors.base,
          appBarColor: colors.text,
          background: colors.base,
          bottomBarBackground: colors.surface,
          bottomBarActiveItemColor: colors.accent,
          bottomBarInactiveItemColor: colors.textSecondary,
        ),
      ),
      filterEditor: FilterEditorConfigs(
        style: FilterEditorStyle(
          appBarBackground: colors.base,
          appBarColor: colors.text,
          background: colors.base,
          previewSelectedTextColor: colors.accent,
        ),
      ),
      imageGeneration: widget.imageGenerationConfigs,
    );
    return widget.imageBytes != null
        ? ProImageEditor.memory(
            widget.imageBytes!,
            key: _editor,
            callbacks: callbacks,
            configs: configs,
          )
        : ProImageEditor.file(
            widget.imagePath,
            key: _editor,
            callbacks: callbacks,
            configs: configs,
          );
  }
}

OutputFormat _editorOutputFormat(String? mimeType) {
  return switch (mimeType?.toLowerCase()) {
    'image/png' || 'image/gif' || 'image/webp' => OutputFormat.png,
    'image/tiff' => OutputFormat.tiff,
    'image/bmp' => OutputFormat.bmp,
    _ => OutputFormat.jpg,
  };
}

const _imageEditorI18n = I18n(
  cancel: '取消',
  undo: '撤销',
  redo: '重做',
  done: '完成',
  remove: '删除',
  doneLoadingMsg: '正在生成图片…',
  various: I18nVarious(
    loadingDialogMsg: '请稍候…',
    closeEditorWarningTitle: '放弃图片编辑？',
    closeEditorWarningMessage: '当前修改尚未保存，确定退出吗？',
    closeEditorWarningConfirmBtn: '放弃',
    closeEditorWarningCancelBtn: '继续编辑',
  ),
  layerInteraction: I18nLayerInteraction(
    remove: '删除',
    edit: '编辑',
    rotateScale: '旋转和缩放',
  ),
  paintEditor: I18nPaintEditor(
    bottomNavigationBarText: '标注',
    moveAndZoom: '移动',
    freestyle: '画笔',
    arrow: '箭头',
    line: '直线',
    rectangle: '矩形',
    circle: '圆形',
    blur: '模糊',
    pixelate: '马赛克',
    eraser: '橡皮擦',
    lineWidth: '线宽',
    toggleFill: '填充',
    changeOpacity: '透明度',
    opacity: '透明度',
    color: '颜色',
    strokeWidth: '线宽',
    fill: '填充',
    cancel: '取消',
    undo: '撤销',
    redo: '重做',
    done: '完成',
    back: '返回',
    smallScreenMoreTooltip: '更多',
  ),
  textEditor: I18nTextEditor(
    inputHintText: '输入文字',
    bottomNavigationBarText: '文字',
    back: '返回',
    done: '完成',
    textAlign: '对齐',
    fontScale: '字号',
    backgroundMode: '背景',
    smallScreenMoreTooltip: '更多',
  ),
  cropRotateEditor: I18nCropRotateEditor(
    bottomNavigationBarText: '裁切',
    rotate: '旋转',
    flip: '翻转',
    ratio: '比例',
    back: '返回',
    done: '完成',
    cancel: '取消',
    undo: '撤销',
    redo: '重做',
    reset: '重置',
    smallScreenMoreTooltip: '更多',
  ),
  tuneEditor: I18nTuneEditor(
    bottomNavigationBarText: '调节',
    back: '返回',
    done: '完成',
    brightness: '亮度',
    contrast: '对比度',
    saturation: '饱和度',
    exposure: '曝光',
    hue: '色相',
    temperature: '色温',
    fade: '褪色',
    tint: '色调',
    undo: '撤销',
    redo: '重做',
  ),
  filterEditor: I18nFilterEditor(
    bottomNavigationBarText: '滤镜',
    back: '返回',
    done: '完成',
    filters: I18nFilters(none: '无'),
  ),
  blurEditor: I18nBlurEditor(
    bottomNavigationBarText: '模糊',
    back: '返回',
    done: '完成',
  ),
  emojiEditor: I18nEmojiEditor(
    bottomNavigationBarText: '表情',
    search: '搜索',
    categoryRecent: '最近',
    categorySmileys: '人物',
    categoryAnimals: '动物与自然',
    categoryFood: '食物',
    categoryActivities: '活动',
    categoryTravel: '旅行',
    categoryObjects: '物品',
    categorySymbols: '符号',
    categoryFlags: '旗帜',
  ),
);
