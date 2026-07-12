import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import '../../theme/app_theme.dart';

/// Full image editor shown before a gallery image is sent to a chat room.
class ChatImageEditorPage extends StatelessWidget {
  const ChatImageEditorPage({
    super.key,
    required this.imagePath,
    this.mimeType,
  });

  final String imagePath;
  final String? mimeType;

  @visibleForTesting
  ImageGenerationConfigs get imageGenerationConfigs => ImageGenerationConfigs(
    enableUseOriginalBytes: true,
    captureImageByteFormat: ui.ImageByteFormat.rawStraightRgba,
    jpegQuality: 100,
    maxOutputSize: Size.infinite,
    outputFormat: _editorOutputFormat(mimeType),
  );

  @override
  Widget build(BuildContext context) {
    final editorTheme = Theme.of(context).copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: Theme.of(context).colorScheme.copyWith(
        primary: AppColors.primary,
        secondary: AppColors.secondary,
        surface: AppColors.surface,
        onSurface: AppColors.onBackground,
      ),
    );

    return ProImageEditor.file(
      imagePath,
      callbacks: ProImageEditorCallbacks(
        onImageEditingComplete: (bytes) async {
          if (context.mounted) Navigator.of(context).pop(bytes);
        },
      ),
      configs: ProImageEditorConfigs(
        theme: editorTheme,
        i18n: _imageEditorI18n,
        mainEditor: const MainEditorConfigs(
          tools: [
            SubEditorMode.cropRotate,
            SubEditorMode.paint,
            SubEditorMode.text,
            SubEditorMode.tune,
            SubEditorMode.filter,
            SubEditorMode.blur,
            SubEditorMode.emoji,
          ],
          style: MainEditorStyle(
            background: AppColors.background,
            appBarBackground: AppColors.background,
            appBarColor: AppColors.onBackground,
            bottomBarBackground: AppColors.surface,
            bottomBarColor: AppColors.onBackground,
            uiOverlayStyle: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              systemNavigationBarColor: AppColors.surface,
              systemNavigationBarIconBrightness: Brightness.light,
            ),
          ),
        ),
        paintEditor: const PaintEditorConfigs(
          tools: [
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
            appBarBackground: AppColors.background,
            appBarColor: AppColors.onBackground,
            background: AppColors.background,
            bottomBarBackground: AppColors.surface,
            bottomBarActiveItemColor: AppColors.primary,
            bottomBarInactiveItemColor: AppColors.onSurface,
            initialColor: AppColors.primary,
            uiOverlayStyle: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              systemNavigationBarColor: AppColors.surface,
              systemNavigationBarIconBrightness: Brightness.light,
            ),
          ),
        ),
        cropRotateEditor: const CropRotateEditorConfigs(
          maxScale: 8,
          style: CropRotateEditorStyle(
            appBarBackground: AppColors.background,
            appBarColor: AppColors.onBackground,
            background: AppColors.background,
            bottomBarBackground: AppColors.surface,
            bottomBarColor: AppColors.onBackground,
            cropCornerColor: AppColors.primary,
            helperLineColor: Colors.white54,
            uiOverlayStyle: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              systemNavigationBarColor: AppColors.surface,
              systemNavigationBarIconBrightness: Brightness.light,
            ),
          ),
        ),
        tuneEditor: const TuneEditorConfigs(
          style: TuneEditorStyle(
            appBarBackground: AppColors.background,
            appBarColor: AppColors.onBackground,
            background: AppColors.background,
            bottomBarBackground: AppColors.surface,
            bottomBarActiveItemColor: AppColors.primary,
            bottomBarInactiveItemColor: AppColors.onSurface,
          ),
        ),
        filterEditor: const FilterEditorConfigs(
          style: FilterEditorStyle(
            appBarBackground: AppColors.background,
            appBarColor: AppColors.onBackground,
            background: AppColors.background,
            previewSelectedTextColor: AppColors.primary,
          ),
        ),
        imageGeneration: imageGenerationConfigs,
      ),
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
